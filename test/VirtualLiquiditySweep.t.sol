// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console2.sol";

import "../src/FFactory.sol";
import "../src/FRouter.sol";
import "../src/WSEI.sol";
import "../src/Bonding.sol";
import "../src/VirtualPair.sol";
import "../src/interfaces/IDragonswapFactory.sol";
import "../src/interfaces/IDragonswapRouter.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// very-light mock factory / router – identical to ones in BondingTest
contract MockDragonFactory is IDragonswapFactory {
    mapping(address => mapping(address => address)) public pairs;

    function getPair(address a, address b) external view returns (address) { return pairs[a][b]; }
    function createPair(address a, address b) external returns (address p) {
        p = address(uint160(uint256(keccak256(abi.encodePacked(a,b)))));
        pairs[a][b] = p; pairs[b][a] = p; return p;
    }
    function allPairs(uint) external pure returns (address) { return address(0); }
    function allPairsLength() external pure returns (uint) { return 0; }
    function feeTo() external pure returns (address) { return address(0); }
    function feeToSetter() external pure returns (address) { return address(0); }
    function setFeeTo(address) external {}
    function setFeeToSetter(address) external {}
}
contract MockDragonRouter {
    MockDragonFactory public df;
    constructor(MockDragonFactory _f) { df = _f; }
    function WSEI() external pure returns (address) { return address(0); }
    function addLiquidity(address a,address b,uint A,uint B,uint,uint,address,uint) external returns(uint,uint,uint){
        df.createPair(a,b); return (A,B,0);
    }
    function addLiquiditySEI(address t,uint A,uint,uint,address,uint) external payable returns(uint,uint,uint){
        df.createPair(t,address(this)); return (A,msg.value,0);
    }
    fallback() external payable { revert("not impl"); }
}

/// sweep test
contract VirtualLiquiditySweep is Test {
    /* ------------------------------------------------------------ constants */
    uint256 constant THRESHOLD_SEI   = 9_001 ether;
    uint256 constant LAUNCH_FEE_SEI  = 1 ether;
    uint256 constant INITIAL_SUPPLY  = 1_000_000_000 ether;
    uint8    constant MAX_TX_PCT     = 20;          // generous cap
    uint8[]  V_T_PCTS = [0, 0, 0, 0];
    uint8[]  V_A_PCTS = [25, 30, 50, 75];

    /* ------------------------------------------------------------- contracts */
    FFactory            factory;
    FRouter             router;
    WSEI                wsei;
    MockDragonFactory   dFactory;
    MockDragonRouter    dRouter;
    Bonding             bonding;

    function _deployFactory() internal returns (FFactory fac) {
        FFactory impl = new FFactory();
        bytes memory init = abi.encodeWithSelector(
            FFactory.initialize.selector,
            address(this), 0, 0
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), init);
        fac = FFactory(address(proxy));
    }

    function _deployRouter(address facAddr) internal returns (FRouter r) {
        FRouter impl = new FRouter();
        bytes memory init = abi.encodeWithSelector(
            FRouter.initialize.selector,
            facAddr
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), init);
        r = FRouter(address(proxy));
    }

    function _deployBonding(
        address facAddr,
        address routerAddr,
        address wseiAddr,
        address dfAddr,
        address drAddr
    ) internal returns (Bonding b) {
        Bonding impl = new Bonding();
        bytes memory init = abi.encodeWithSelector(
            Bonding.initialize.selector,
            facAddr,
            routerAddr,
            payable(wseiAddr),
            LAUNCH_FEE_SEI,
            0,
            INITIAL_SUPPLY,
            MAX_TX_PCT,
            5,
            THRESHOLD_SEI,
            THRESHOLD_SEI,
            100,
            dfAddr,
            drAddr
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), init);
        b = Bonding(payable(address(proxy)));
    }


    /* ------------------------------------------------------------ set-up */
    function setUp() public {
        /* 1. deploy factory proxy */
        factory = _deployFactory();

        /* 2. promote proxy to ADMIN_ROLE */
        vm.prank(address(factory));                         // proxy has DEFAULT_ADMIN_ROLE
        factory.grantRole(factory.ADMIN_ROLE(), address(factory));

        /* 3. deploy router proxy */
        router  = _deployRouter(address(factory));

        /* 4. wire router (now passes onlyRole(ADMIN_ROLE)) */
        vm.prank(address(factory));
        factory.setRouter(address(router));

        /* ---------------------------------------------- */
        /* rest of your setup stays unchanged             */
        wsei     = new WSEI();
        dFactory = new MockDragonFactory();
        dRouter  = new MockDragonRouter(dFactory);

        bonding  = _deployBonding(
            address(factory),
            address(router),
            address(wsei),
            address(dFactory),
            address(dRouter)
        );

        /* give Bonding its roles */
        vm.prank(address(factory));
        factory.grantRole(factory.CREATOR_ROLE(),  address(bonding));

        vm.prank(address(router));      // router proxy owns DEFAULT_ADMIN_ROLE
        router.grantRole(router.EXECUTOR_ROLE(),   address(bonding));
    }



    /* helper: launcher */
    function _setupVirtual(uint8 vTPct, uint8 vAPct)
        internal
        returns (address tok, address pair)
    {
        // set default virtual liquidity
        uint112 vT = uint112(INITIAL_SUPPLY * vTPct / 100);
        uint112 vA = uint112(THRESHOLD_SEI  * vAPct / 100);
        vm.prank(address(factory));
        factory.setVirtualLiquidity(vT, vA);

        // launch with SEI fee only (no initial purchase)
        vm.deal(address(this), LAUNCH_FEE_SEI);
        (tok, pair,) = bonding.launchWithSei{value: LAUNCH_FEE_SEI}("VIRT","VT");
    }

    /* test: one-shot graduation without maxTx */
    function testGraduateSingleBuy() public {
        uint8[] memory vTPcts = V_T_PCTS;   // [0,0,0,0]
        uint8[] memory vAPcts = V_A_PCTS;   // [25,30,50,75]

        for (uint i; i < vTPcts.length; ++i) {
            uint8 vtPct = vTPcts[i];
            uint8 vaPct = vAPcts[i];

            // 1. Launch with chosen virtual cushions
            (address tok, address pair) = _setupVirtual(vtPct, vaPct);

            // 2. Disable maxTx so we can buy in one shot
            vm.prank(address(bonding));          // Bonding owns the token
            FERC20(tok).updateMaxTx(100);

            // 3. Calculate gross SEI needed to reach 9 001 real SEI
            uint256 realSei  = VirtualPair(pair).assetBalance();
            uint256 deficit  = THRESHOLD_SEI - realSei;
            uint256 grossWei = deficit;          // buyTax = 0 in this setup

            // 4. Execute the buy
            vm.deal(address(this), grossWei);
            bonding.buyWithSei{value: grossWei}(tok, 0);

            // 5. Metrics
            uint256 tokOut = FERC20(tok).balanceOf(address(this));
            uint256 burnt  = INITIAL_SUPPLY - FERC20(tok).totalSupply();
            address dragon = dFactory.getPair(tok, address(0));   // mock WSEI() = 0
            uint256 dTok   = INITIAL_SUPPLY - tokOut - burnt;
            uint256 dSei   = wsei.balanceOf(dragon);

            // 6. Console logs (build strings then log)
            string memory line = string.concat(
                "[vT%=",  vm.toString(vtPct),
                " vA%=",  vm.toString(vaPct),
                "] buy: SEI=", vm.toString(grossWei / 1e18),
                " tokens=",    vm.toString(tokOut   / 1e18)
            );
            console2.log(line);

            string memory sum = string.concat(
                ">> SUMMARY vT%=",  vm.toString(vtPct),
                " vA%=",            vm.toString(vaPct),
                " realSEI=",        vm.toString(THRESHOLD_SEI / 1e18),
                " tokensOut=",      vm.toString(tokOut / 1e18),
                " burnt=",          vm.toString(burnt  / 1e18),
                " dTok=",           vm.toString(dTok   / 1e18),
                " dSei=",           vm.toString(dSei   / 1e18)
            );
            console2.log(sum);
            console2.log("----------------------------------------------");

            // 7. Sanity checks
            ( , , , , bool trading, ) = bonding.tokenInfo(tok);
            assertFalse(trading, "graduation flag not cleared");

            VirtualPair vp = VirtualPair(pair);
            assertEq(vp.assetBalance(), 0, "SEI dust in pair");
            assertEq(vp.balance(),      0, "token dust in pair");
        }
    }

    /* test: staged buys 101 + 9*100 + 20*250 + 10*300 */
    function testCurveBuckets() public {
        /* fixed buy schedule: 40 entries totalling 9 001 SEI */
        uint256[40] memory buckets;

        buckets[0] = 101 ether;                              // 1 × 101
        for (uint256 j = 1; j < 10;  j++) { buckets[j] = 100 ether; } // 9 × 100
        for (uint256 j = 10; j < 30; j++) { buckets[j] = 250 ether; } // 20 × 250
        for (uint256 j = 30; j < 40; j++) { buckets[j] = 300 ether; } // 10 × 300

        for (uint256 i = 0; i < V_T_PCTS.length; ++i) {
            uint8 vtPct = V_T_PCTS[i];
            uint8 vaPct = V_A_PCTS[i];

            (address tok, address pair) = _setupVirtual(vtPct, vaPct);

            /* lift max-Tx so scripted buys can’t revert */
            vm.prank(address(bonding));
            FERC20(tok).updateMaxTx(100);

            uint256 prevBal = 0;
            uint256 cumSei  = 0;
            uint256 buyIdx  = 0;

            for (uint256 k = 0; k < buckets.length; ++k) {
                uint256 amt = buckets[k];
                vm.deal(address(this), amt);

                /* clamp amount if token side is exhausted */
                uint256 realTok = VirtualPair(pair).balance();
                uint256 out     = VirtualPair(pair).getAmountOut(address(wsei), amt);
                if (out > realTok) {
                    amt = amt * realTok / out;           // proportional clamp
                    vm.deal(address(this), amt);
                }

                bonding.buyWithSei{value: amt}(tok, 0);

                uint256 newBal = FERC20(tok).balanceOf(address(this));
                uint256 gained = newBal - prevBal;
                prevBal        = newBal;
                cumSei        += amt;

                console2.log(
                    string.concat(
                        "[vT%=",  vm.toString(vtPct),
                        " vA%=",  vm.toString(vaPct),
                        "] buy#", vm.toString(buyIdx),
                        ": SEI=", vm.toString(amt / 1e18),
                        " tokens=", vm.toString(gained / 1e18)
                    )
                );
                ++buyIdx;
            }

            uint256 burnt  = INITIAL_SUPPLY - FERC20(tok).totalSupply();
            address dragon = dFactory.getPair(tok, address(0));

            console2.log(
                string.concat(
                    ">> SUMMARY vT%=", vm.toString(vtPct),
                    " vA%=", vm.toString(vaPct),
                    " buys=", vm.toString(buyIdx),
                    " totalSEI=", vm.toString(cumSei / 1e18),
                    " tokensOut=", vm.toString(prevBal / 1e18),
                    " burnt=", vm.toString(burnt / 1e18),
                    " dTok=", vm.toString(FERC20(tok).balanceOf(dragon) / 1e18),
                    " dSei=", vm.toString(wsei.balanceOf(dragon)        / 1e18)
                )
            );
            console2.log("----------------------------------------------");
        }
    }


}
