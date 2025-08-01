// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "forge-std/Test.sol";
import "../src/FFactory.sol";
import "../src/FRouter.sol";
import "../src/WSEI.sol";
import "../src/Bonding.sol";
import "../src/interfaces/IDragonswapFactory.sol";
import "../src/interfaces/IDragonswapRouter.sol";
import "../src/VirtualPair.sol";

contract MockDragonFactory is IDragonswapFactory {
    mapping(address => mapping(address => address)) public pairs;

    function getPair(address tokenA, address tokenB) external view returns (address) {
        return pairs[tokenA][tokenB];
    }

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        pair = address(uint160(uint256(keccak256(abi.encodePacked(tokenA, tokenB)))));
        pairs[tokenA][tokenB] = pair;
        pairs[tokenB][tokenA] = pair;
        return pair;
    }

    function feeTo() external view returns (address) { return address(0); }
    function feeToSetter() external view returns (address) { return address(0); }
    function setFeeTo(address) external {}
    function setFeeToSetter(address) external {}
    function allPairs(uint) external view returns (address) { return address(0); }
    function allPairsLength() external view returns (uint) { return 0; }
}

contract MockDragonRouter {
    MockDragonFactory public dfactory;

    constructor(MockDragonFactory _factory) {
        dfactory = _factory;
    }

    // Returns a dummy WSEI address; Bonding only treats WSEI specially when assetToken == wsei
    function WSEI() external pure returns (address) {
        return address(0);
    }

    // Simulate adding liquidity on Dragonswap
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint,
        uint,
        address,
        uint
    ) external returns (uint, uint, uint) {
        dfactory.createPair(tokenA, tokenB);
        return (amountADesired, amountBDesired, 0);
    }

    // Simulate adding liquidity with native SEI
    function addLiquiditySEI(
        address token,
        uint amountTokenDesired,
        uint,
        uint,
        address,
        uint
    ) external payable returns (uint, uint, uint) {
        dfactory.createPair(token, address(this));
        return (amountTokenDesired, msg.value, 0);
    }

    fallback() external payable {
        revert("Not implemented");
    }
}

/// @dev A simple ERC20 for testing
contract TestERC20 is ERC20 {
    constructor() ERC20("TestToken","TKN") {}
    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

contract BondingTest is Test {
    FFactory public factory;
    FRouter public router;
    WSEI public wsei;
    MockDragonFactory public dragonFactory;
    MockDragonRouter public dragonRouter;
    Bonding public bonding;

    address alice = address(0xABCD);
    address public owner = address(this);

    uint256 public assetLaunchFee = 1e18;
    uint256 public seiLaunchFee = 1e18;
    uint256 public initialSupply = 1e24;
    uint256 public maxTx = 10;
    uint256 public graduationSlippage = 5;
    uint256 public seiGradThreshold   = 3 ether;
    uint256 public assetGradThreshold = 3 ether;
    uint256 public dragonswapTaxBps = 100;

    function setUp() public {
        // Deploy and initialize factory via proxy
        FFactory factoryImpl = new FFactory();
        bytes memory factoryInit = abi.encodeWithSelector(
            FFactory.initialize.selector,
            owner,       // taxVault
            1,           // buyTax%
            1            // sellTax%
        );
        ERC1967Proxy factoryProxy = new ERC1967Proxy(
            address(factoryImpl),
            factoryInit
        );
        factory = FFactory(address(factoryProxy));
        // Grant roles to owner
        factory.grantRole(factory.ADMIN_ROLE(), owner);
        
        assertTrue(
            address(factoryProxy) == address(factory),
            "factory must be the proxy, not the impl!"
        );
        
        // set virtualLiquidity
        vm.prank(owner);
        factory.setVirtualLiquidity(0, 4500 * 1e18);

        // Deploy and initialize router via proxy
        FRouter routerImpl = new FRouter();
        bytes memory routerInit = abi.encodeWithSelector(
            FRouter.initialize.selector,
            address(factory)
        );
        ERC1967Proxy routerProxy = new ERC1967Proxy(
            address(routerImpl),
            routerInit
        );
        router = FRouter(address(routerProxy));

        // Configure factory with router
        factory.setRouter(address(router));

        // Deploy WSEI wrapper
        wsei = new WSEI();

        // Deploy mock DragonSwap contracts
        dragonFactory = new MockDragonFactory();
        dragonRouter = new MockDragonRouter(dragonFactory);

        // Deploy and initialize Bonding via proxy
        Bonding bondingImpl = new Bonding();
        bytes memory bondingInit = abi.encodeWithSelector(
            Bonding.initialize.selector,
            address(factory),
            address(router),
            payable(address(wsei)),
            assetLaunchFee,
            seiLaunchFee,
            initialSupply,
            maxTx,
            graduationSlippage,
            seiGradThreshold,
            assetGradThreshold,
            dragonswapTaxBps,
            address(dragonFactory),
            address(dragonRouter)
        );
        ERC1967Proxy bondingProxy = new ERC1967Proxy(
            address(bondingImpl),
            bondingInit
        );
        bonding = Bonding(payable(address(bondingProxy)));

        assertTrue(
            address(bonding.factory()) == address(factoryProxy),
            "Bonding was wired to the wrong factory!"
        );

        // grant CREATOR_ROLE to bonding curve contract
        factory.grantRole(factory.CREATOR_ROLE(), address(bondingProxy));

        // grant EXECUTOR_ROLE on the router to Bonding
        router.grantRole(router.EXECUTOR_ROLE(), address(bonding));


        assertTrue(
            factory.hasRole(factory.CREATOR_ROLE(), address(bonding)),
            "Bonding proxy must have CREATOR_ROLE"
        );

    }

    function testOwnerIsDeployer() public {
        assertEq(bonding.owner(), owner);
    }

    //
    // 1. Initializer guards
    //

    // Checks that deploying via proxy with a zero factory address reverts
    function testInitializeRevertsOnZeroFactory() public {
        Bonding impl = new Bonding();
        bytes memory data = abi.encodeWithSelector(
            Bonding.initialize.selector,
            address(0),
            address(router),
            payable(address(wsei)),
            assetLaunchFee,
            seiLaunchFee,
            initialSupply,
            maxTx,
            graduationSlippage,
            seiGradThreshold,
            assetGradThreshold,
            dragonswapTaxBps,
            address(dragonFactory),
            address(dragonRouter)
        );
        vm.expectRevert();
        new ERC1967Proxy(address(impl), data);
    }

    // Checks that deploying via proxy with a zero router address reverts
    function testInitializeRevertsOnZeroRouter() public {
        Bonding impl = new Bonding();
        bytes memory data = abi.encodeWithSelector(
            Bonding.initialize.selector,
            address(factory),
            address(0),
            payable(address(wsei)),
            assetLaunchFee,
            seiLaunchFee,
            initialSupply,
            maxTx,
            graduationSlippage,
            seiGradThreshold,
            assetGradThreshold,
            dragonswapTaxBps,
            address(dragonFactory),
            address(dragonRouter)
        );
        vm.expectRevert();
        new ERC1967Proxy(address(impl), data);
    }

    // Checks that deploying via proxy with a zero WSEI address reverts
    function testInitializeRevertsOnZeroWSEI() public {
        Bonding impl = new Bonding();
        bytes memory data = abi.encodeWithSelector(
            Bonding.initialize.selector,
            address(factory),
            address(router),
            payable(address(0)),
            assetLaunchFee,
            seiLaunchFee,
            initialSupply,
            maxTx,
            graduationSlippage,
            seiGradThreshold,
            assetGradThreshold,
            dragonswapTaxBps,
            address(dragonFactory),
            address(dragonRouter)
        );
        vm.expectRevert();
        new ERC1967Proxy(address(impl), data);
    }

    // Checks that deploying via proxy with a zero Dragonswap factory address reverts
    function testInitializeRevertsOnZeroDragonFactory() public {
        Bonding impl = new Bonding();
        bytes memory data = abi.encodeWithSelector(
            Bonding.initialize.selector,
            address(factory),
            address(router),
            payable(address(wsei)),
            assetLaunchFee,
            seiLaunchFee,
            initialSupply,
            maxTx,
            graduationSlippage,
            seiGradThreshold,
            assetGradThreshold,
            dragonswapTaxBps,
            address(0),
            address(dragonRouter)
        );
        vm.expectRevert();
        new ERC1967Proxy(address(impl), data);
    }

    // Checks that deploying via proxy with a zero Dragonswap router address reverts
    function testInitializeRevertsOnZeroDragonRouter() public {
        Bonding impl = new Bonding();
        bytes memory data = abi.encodeWithSelector(
            Bonding.initialize.selector,
            address(factory),
            address(router),
            payable(address(wsei)),
            assetLaunchFee,
            seiLaunchFee,
            initialSupply,
            maxTx,
            graduationSlippage,
            seiGradThreshold,
            assetGradThreshold,
            dragonswapTaxBps,
            address(dragonFactory),
            address(0)
        );
        vm.expectRevert();
        new ERC1967Proxy(address(impl), data);
    }

    //
    // 2. Owner‐only setters
    //

    // Ensures non-owner cannot call setInitialSupply
    function testSetInitialSupplyOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        bonding.setInitialSupply(42);
    }
    // Ensures owner can successfully call setInitialSupply
    function testOwnerCanSetInitialSupply() public {
        bonding.setInitialSupply(42);
        assertEq(bonding.initialSupply(), 42);
    }

    // Ensures non-owner cannot call setAssetLaunchFee
    function testSetAssetLaunchFeeOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        bonding.setAssetLaunchFee(123);
    }
    // Ensures owner can successfully call setAssetLaunchFee
    function testOwnerCanSetAssetLaunchFee() public {
        bonding.setAssetLaunchFee(123);
        assertEq(bonding.assetLaunchFee(), 123);
    }

    // Ensures non-owner cannot call setSeiLaunchFee
    function testSetSeiLaunchFeeOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        bonding.setSeiLaunchFee(456);
    }
    // Ensures owner can successfully call setSeiLaunchFee
    function testOwnerCanSetSeiLaunchFee() public {
        bonding.setSeiLaunchFee(456);
        assertEq(bonding.seiLaunchFee(), 456);
    }

    // Ensures non-owner cannot call setMaxTx
    function testSetMaxTxOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        bonding.setMaxTx(77);
    }
    // Ensures owner can successfully call setMaxTx
    function testOwnerCanSetMaxTx() public {
        bonding.setMaxTx(77);
        assertEq(bonding.maxTx(), 77);
    }

    // Ensures non-owner cannot call setGraduationSlippage
    function testSetGraduationSlippageOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        bonding.setGraduationSlippage(9);
    }
    // Ensures owner can successfully call setGraduationSlippage
    function testOwnerCanSetGraduationSlippage() public {
        bonding.setGraduationSlippage(9);
        assertEq(bonding.graduationSlippage(), 9);
    }

    // Ensures non-owner cannot call setSeiGradThreshold
    function testSetSeiGradThresholdOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        bonding.setSeiGradThreshold(500);
    }
    // Ensures owner can successfully call setSeiGradThreshold
    function testOwnerCanSetSeiGradThreshold() public {
        bonding.setSeiGradThreshold(500);
        assertEq(bonding.seiGradThreshold(), 500);
    }

    // Ensures non-owner cannot call setAssetGradThreshold
    function testSetAssetGradThresholdOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        bonding.setAssetGradThreshold(200);
    }
    // Ensures owner can successfully call setAssetGradThreshold
    function testOwnerCanSetAssetGradThreshold() public {
        bonding.setAssetGradThreshold(200);
        assertEq(bonding.assetGradThreshold(), 200);
    }

    //
    // 3. Profile management
    //

    // Verifies getUserTokens reverts before any launch
    function testGetUserTokensRevertsBeforeLaunch() public {
        vm.expectRevert("User Profile dose not exist.");
        bonding.getUserTokens(alice);
    }

    // Verifies profile contains exactly one token after a single launchWithAsset
    function testUserProfileOneLaunch() public {
        TestERC20 asset = new TestERC20();
        asset.mint(alice, assetLaunchFee + 1e18);
        vm.startPrank(alice);
        asset.approve(address(bonding), assetLaunchFee + 1e18);
        (address tok,,) = bonding.launchWithAsset("Tkn","TKN", assetLaunchFee, address(asset));
        address[] memory toks = bonding.getUserTokens(alice);
        assertEq(toks.length, 1);
        assertEq(toks[0], tok);
        vm.stopPrank();
    }

    // Verifies profile accumulates tokens across multiple launchWithAsset calls
    function testUserProfileMultipleLaunches() public {
        TestERC20 asset = new TestERC20();
        asset.mint(alice, 2 * (assetLaunchFee + 1e18));
        vm.startPrank(alice);
        asset.approve(address(bonding), 2 * (assetLaunchFee + 1e18));
        (address tok1,,) = bonding.launchWithAsset("A","AAA", assetLaunchFee, address(asset));
        (address tok2,,) = bonding.launchWithAsset("B","BBB", assetLaunchFee, address(asset));
        address[] memory toks = bonding.getUserTokens(alice);
        assertEq(toks.length, 2);
        assertEq(toks[0], tok1);
        assertEq(toks[1], tok2);
        vm.stopPrank();
    }

    //
    // 4. ERC-20 launch
    //

    // Verifies launchWithAsset reverts when purchaseAmount < fee
    function testLaunchWithAssetRevertsOnLowFee() public {
        TestERC20 asset = new TestERC20();
        asset.mint(alice, assetLaunchFee - 1);
        vm.prank(alice);
        asset.approve(address(bonding), assetLaunchFee - 1);
        vm.prank(alice);
        vm.expectRevert("Purchase amount must be greater than or equal to fee");
        bonding.launchWithAsset("X","XXX", assetLaunchFee - 1, address(asset));
    }

    // Verifies launchWithAsset reverts when allowance is missing
    function testLaunchWithAssetRevertsOnNoApproval() public {
        TestERC20 asset = new TestERC20();
        asset.mint(alice, assetLaunchFee + 1e18);
        vm.prank(alice);
        vm.expectRevert();
        bonding.launchWithAsset("X","XXX", assetLaunchFee, address(asset));
    }

    // Verifies happy-path for launchWithAsset: pair creation, whitelisting, and profile update
    function testLaunchWithAssetHappyPath() public {
        TestERC20 asset = new TestERC20();
        asset.mint(alice, assetLaunchFee + 1e18);
        vm.startPrank(alice);
        asset.approve(address(bonding), assetLaunchFee + 1e18);
        (address tok, address pair, uint256 idx) = bonding.launchWithAsset("Z","ZZZ", assetLaunchFee, address(asset));
        assertEq(factory.getPair(tok, address(asset)), pair);
        FERC20 fT = FERC20(tok);
        assertTrue(fT.isWhitelisted(address(router)));
        assertTrue(fT.isWhitelisted(address(bonding)));
        assertTrue(fT.isWhitelisted(pair));
        address[] memory toks = bonding.getUserTokens(alice);
        assertEq(toks.length, 1);
        assertEq(idx, 1);
        vm.stopPrank();
    }

    //
    // 5. Native-SEI launch
    //

    // Verifies launchWithSei reverts when sent ETH < fee
    function testLaunchWithSeiRevertsOnLowValue() public {
        vm.deal(alice, seiLaunchFee);
        vm.prank(alice);
        vm.expectRevert("Purchase amount must be greater than or equal to fee");
        bonding.launchWithSei{ value: seiLaunchFee - 1 }("N","NNN");
    }

    // Verifies happy-path for launchWithSei: wraps SEI and creates pair
    function testLaunchWithSeiHappyPath() public {               
        uint256 send  = seiLaunchFee;             // small first-buy
        
        vm.deal(alice, send + 1 ether);
        
        vm.prank(alice, alice);
        
        (address tok, address pair,) =
            bonding.launchWithSei{ value: send }("S","SSS");

        assertEq(factory.getPair(tok, address(wsei)), pair);
    }

    // helper: local copy of event sig so expectEmit works
    event Graduated(address indexed token, address indexed pair);

    // ---------------------------------------------------------
    //  B-1  Secondary BUY
    // ---------------------------------------------------------
    function testSecondaryBuyUpdatesData() public {
        // launch
        TestERC20 asset = new TestERC20();
        asset.mint(alice, assetLaunchFee + 1 ether);
        vm.startPrank(alice);
        asset.approve(address(bonding), assetLaunchFee + 1 ether);
        (address tok, address pairAddr,) =
            bonding.launchWithAsset("BUY","BUY", assetLaunchFee, address(asset));
        vm.stopPrank();

        // tiny buy well under maxTx
        uint256 tiny      = 0.00001 ether; 
        asset.mint(alice, tiny);
        vm.startPrank(alice);
        asset.approve(address(bonding), tiny);
        bonding.buyWithAsset(tiny, tok, address(asset), 0);
        vm.stopPrank();

        // vault taxed
        uint256 taxed = tiny * factory.buyTax() / 100;
        assertEq(asset.balanceOf(owner), taxed);

        // reserves increased
        VirtualPair vp = VirtualPair(pairAddr);
        assertGt(vp.assetBalance(), 0);
    }

    // ---------------------------------------------------------
    //  B-2  Secondary SELL
    // ---------------------------------------------------------
    function testSecondarySellUpdatesData() public {
        // launch
        TestERC20 asset = new TestERC20();
        asset.mint(alice, assetLaunchFee + 1 ether);
        vm.startPrank(alice);
        asset.approve(address(bonding), assetLaunchFee + 1 ether);
        (address tok,,) =
            bonding.launchWithAsset("SEL","SEL", assetLaunchFee, address(asset));
        vm.stopPrank();

        // tiny buy so alice has tokens
        uint256 tiny = 0.00001 ether;
        asset.mint(alice, tiny);
        vm.startPrank(alice);
        asset.approve(address(bonding), tiny);
        bonding.buyWithAsset(tiny, tok, address(asset), 0);

        // sell half the received tokens
        uint256 bal = FERC20(tok).balanceOf(alice);
        uint256 sellAmt = bal / 2;
        FERC20(tok).approve(address(bonding), sellAmt);
        bonding.sellForAsset(sellAmt, tok, address(asset), 0);
        vm.stopPrank();

        // vault now has both buy & sell tax (> 0)
        assertGt(asset.balanceOf(owner), 0);
    }

    // ---------------------------------------------------------
    //  G-1  Trigger graduation
    // ---------------------------------------------------------
    function testGraduationTriggered() public {
        TestERC20 asset = new TestERC20();
        asset.mint(address(this), assetLaunchFee + 2 ether);
        asset.approve(address(bonding), assetLaunchFee + 2 ether);
        (address tok, address pairAddr,) =
            bonding.launchWithAsset("GRD","GRD", assetLaunchFee, address(asset));

        // top-up reserve to threshold
        asset.mint(address(this), assetGradThreshold);
        asset.transfer(pairAddr, assetGradThreshold);

        // tiny buy to trigger
        uint256 tinyBuy = 0.00001 ether;
        asset.mint(address(this), tinyBuy);
        asset.approve(address(bonding), tinyBuy);
        bonding.buyWithAsset(tinyBuy, tok, address(asset), 0);
    }

    // ---------------------------------------------------------
    //  G-2  Post-graduation state
    // ---------------------------------------------------------
    function testPostGraduationState() public {
        testGraduationTriggered();
        address tok = bonding.tokenInfos(0);
        ( , , address pairAddr, , bool trading, bool onDragon) = bonding.tokenInfo(tok);

        assertFalse(trading);
        assertTrue(onDragon);
        assertFalse(FERC20(tok).isLocked());
        assertTrue(pairAddr != address(0));
    }

    // ---------------------------------------------------------
    //  G-3  No trades after graduation
    // ---------------------------------------------------------
    function testCannotTradeAfterGraduation() public {
        testGraduationTriggered();
        address tok = bonding.tokenInfos(0);

        TestERC20 asset = new TestERC20();
        asset.mint(alice, 1 ether);
        vm.startPrank(alice);
        asset.approve(address(bonding), 1 ether);
        vm.expectRevert("Token not trading");
        bonding.buyWithAsset(1 ether, tok, address(asset), 0);
        vm.stopPrank();
    }

    /// @notice After graduation, the VirtualPair should have zero real reserves
    function testGraduationDustClearsReserves() public {
        // 1) Launch a token with ERC-20 asset
        TestERC20 asset = new TestERC20();
        asset.mint(address(this), assetLaunchFee + 5 ether);
        asset.approve(address(bonding), assetLaunchFee + 5 ether);
        (address tok, address pairAddr,) =
            bonding.launchWithAsset("DUST","DUST", assetLaunchFee, address(asset));

        // 2) Top up the pair’s real asset reserve to exactly the threshold
        asset.mint(address(this), assetGradThreshold);
        asset.transfer(pairAddr, assetGradThreshold);

        // 3) Trigger graduation via a tiny buy
        uint256 tiny = 0.00001 ether;
        asset.mint(address(this), tiny);
        asset.approve(address(bonding), tiny);
        bonding.buyWithAsset(tiny, tok, address(asset), 0);

        // 4) After graduation, the VirtualPair real balances must be zero
        VirtualPair vp = VirtualPair(pairAddr);
        assertEq(vp.balance(),      0, "Real token balance should be zero after graduate");
        assertEq(vp.assetBalance(), 0, "Real asset balance should be zero after graduate");
    }

    /// @notice Fuzz: buying then immediately selling always returns ≤ the asset spent
    function testBuyThenSellInvariant(uint256 rawBuy) public {
        // 1) bound rawBuy so we can mint safely and avoid overflow
        vm.assume(rawBuy > 0 && rawBuy <= 1 ether);

        // 2) prep a fresh ERC20 asset and fund Alice for launch + buy
        TestERC20 asset = new TestERC20();
        asset.mint(alice, assetLaunchFee + 1 ether);

        // 3) launch the token (Alice pays exactly assetLaunchFee, no immediate buy)
        vm.startPrank(alice);
        asset.approve(address(bonding), assetLaunchFee + 1 ether);
        (address tok,,) = bonding.launchWithAsset("FUZ","FUZ", assetLaunchFee, address(asset));
        vm.stopPrank();

        // 4) figure out the on-chain cap for a buy and bound rawBuy to that
        uint256 maxIn = bonding.getMaxBuyInputAsset(tok, address(asset));
        vm.assume(rawBuy <= maxIn);

        // 5) Alice buys with rawBuy
        asset.mint(alice, rawBuy);
        vm.startPrank(alice);
        asset.approve(address(bonding), rawBuy);
        bonding.buyWithAsset(rawBuy, tok, address(asset), 0);

        // 6) Alice now owns all tokens from that buy—sell them back
        uint256 tokBal = FERC20(tok).balanceOf(alice);
        FERC20(tok).approve(address(bonding), tokBal);
        uint256 received = bonding.sellForAsset(tokBal, tok, address(asset), 0);
        vm.stopPrank();

        // 7) Invariant: you can’t walk away with more asset than you spent
        assertLe(received, rawBuy, "profit from buy -> sell!");
    }

    // ---------------------------------------------------------
    // Invariant: (real+virtual) constant-product never decreases
    // ---------------------------------------------------------
    function testConstantProductInvariant(uint256 inAmt) public {
        // only test small swaps to avoid rounding to zero or overflow
        vm.assume(inAmt > 0 && inAmt < 1e21);

        // 1) Deploy two test ERC20s
        TestERC20 tok   = new TestERC20();
        TestERC20 asset = new TestERC20();

        // 2) Mint plenty of both to this test
        tok.mint(address(this),   1e24);
        asset.mint(address(this), 1e24);

        // 3) Deploy a VirtualPair with some virtual cushions
        uint112 vT = uint112(1e21);  // virtual token reserve
        uint112 vA = uint112(1e21);  // virtual asset reserve
        VirtualPair vp = new VirtualPair(
            address(router),
            address(tok),
            address(asset),
            vT,
            vA
        );

        // 4) Seed the pair with real liquidity: 1e23 of each
        tok.transfer(address(vp),   1e23);
        asset.transfer(address(vp), 1e23);

        // 5) Tell the pair to mint (must call as the router)
        vm.prank(address(router));
        vp.mint();

        // 6) Record the initial k = (rT+vT)*(rA+vA)
        (uint256 rT0, uint256 rA0) = vp.getReserves();
        uint256 k0 = rT0 * rA0;

        // 7) Simulate a token-for-asset swap of inAmt token
        //    (transfer tokens into the pair, then call swap via router)
        tok.transfer(address(vp), inAmt);
        uint256 out = vp.getAmountOut(address(tok), inAmt);
        vm.prank(address(router));
        vp.swap(inAmt, 0, 0, out);

        // 8) Recompute k and assert it never shrank
        (uint256 rT1, uint256 rA1) = vp.getReserves();
        uint256 k1 = rT1 * rA1;
        assertGe(k1, k0, "constant-product invariant violated");
    }

    // ---------------------------------------------------------
    // Invariant: swapping asset→token never decreases (rT+vT)*(rA+vA)
    // ---------------------------------------------------------
    function testConstantProductInvariantAssetToToken(uint256 inAmt) public {
        // bound to avoid tiny/no‐op swaps or overflow
        vm.assume(inAmt > 0 && inAmt < 1e21);

        // 1) Deploy two ERC20s
        TestERC20 tok   = new TestERC20();
        TestERC20 asset = new TestERC20();

        // 2) Mint both tokens to this contract
        tok.mint(address(this),   1e24);
        asset.mint(address(this), 1e24);

        // 3) Deploy VirtualPair with virtual reserves
        uint112 vT = uint112(1e21);
        uint112 vA = uint112(1e21);
        VirtualPair vp = new VirtualPair(
            address(router),
            address(tok),
            address(asset),
            vT,
            vA
        );

        // 4) Seed real reserves: 1e23 each
        tok.transfer(address(vp),   1e23);
        asset.transfer(address(vp), 1e23);

        // 5) Mint event via router
        vm.prank(address(router));
        vp.mint();

        // 6) Capture initial k
        (uint256 R0, uint256 A0) = vp.getReserves();
        uint256 k0 = R0 * A0;

        // 7) Perform asset→token swap:
        //    transfer inAmt asset, compute out, then call swap via router
        asset.transfer(address(vp), inAmt);
        uint256 tokenOut = vp.getAmountOut(address(asset), inAmt);
        vm.prank(address(router));
        vp.swap(0, tokenOut, inAmt, 0);

        // 8) Recompute and assert k didn’t shrink
        (uint256 R1, uint256 A1) = vp.getReserves();
        uint256 k1 = R1 * A1;
        assertGe(k1, k0, "CP invariant failed for asset -> token swap");
    }

    /// @notice Fuzz: getMaxBuyInputAsset(token,asset) is the true buy‐limit
    function testMaxBuyInputBehavior(uint256 raw) public {
        // 1) We only care about nonzero tries up to some sane cap
        vm.assume(raw > 0 && raw < 1 ether);

        // 2) Deploy a fresh ERC20 asset and fund Alice for launch + buy
        TestERC20 asset = new TestERC20();
        // she'll need at most launchFee + 1 ether
        uint256 totalMint = assetLaunchFee + 1 ether;
        asset.mint(alice, totalMint);

        // 3) Alice launches the token, paying exactly assetLaunchFee
        vm.startPrank(alice);
        asset.approve(address(bonding), totalMint);
        (address tok,,) = bonding.launchWithAsset("FUZ","FUZ", assetLaunchFee, address(asset));

        // 4) Read the on-chain max buy input
        uint256 maxIn = bonding.getMaxBuyInputAsset(tok, address(asset));
        vm.stopPrank();

        // 5) Bound our raw amount into [1, maxIn * 2]
        uint256 buyAmt = bound(raw, 1, maxIn * 2);

        // 6) Fund + approve Alice for exactly buyAmt more
        asset.mint(alice, buyAmt);
        vm.startPrank(alice);
        asset.approve(address(bonding), buyAmt);

        // 7) If buyAmt ≤ maxIn, buy should succeed; else revert “Exceeds MaxTx”
        if (buyAmt <= maxIn) {
            bonding.buyWithAsset(buyAmt, tok, address(asset), 0);
        } else {
            vm.expectRevert("Exceeds MaxTx");
            bonding.buyWithAsset(buyAmt, tok, address(asset), 0);
        }
        vm.stopPrank();
    }

    /// @notice Fuzz: any buy ≤ getMaxLaunchInputAsset must succeed (never revert)
    function testMaxLaunchInputAssetBehavior(uint8  maxTxRaw,
                                            uint256 feeRaw,
                                            uint256 supplyRaw,
                                            uint256 rawAmt) public {
        // 1) Bound fuzz inputs
        uint8   maxTxPct       = uint8(bound(maxTxRaw, 1, 100));
        uint256 assetLaunchFee_= bound(feeRaw, 1, 1 ether);
        uint256 initialSupply_ = bound(supplyRaw, 1e20, 1e25);

        // 2) Deploy & init Factory proxy
        FFactory facImpl = new FFactory();
        bytes memory facInit = abi.encodeWithSelector(
            FFactory.initialize.selector,
            address(this), 0, 0
        );
        ERC1967Proxy facProxy = new ERC1967Proxy(address(facImpl), facInit);
        FFactory factory2 = FFactory(address(facProxy));
        factory2.grantRole(factory2.ADMIN_ROLE(), address(this));

        // 3) Deploy & init Router proxy
        FRouter routerImpl = new FRouter();
        bytes memory routerInit = abi.encodeWithSelector(
            FRouter.initialize.selector,
            address(factory2)
        );
        ERC1967Proxy routerProxy = new ERC1967Proxy(address(routerImpl), routerInit);
        FRouter router2 = FRouter(address(routerProxy));

        // 4) Wire roles
        factory2.setRouter(address(router2));
        factory2.grantRole(factory2.CREATOR_ROLE(), address(router2));

        // 5) Dragonswap & WSEI mocks
        WSEI wsei2 = new WSEI();
        MockDragonFactory df2 = new MockDragonFactory();
        MockDragonRouter  dr2 = new MockDragonRouter(df2);

        // 6) Deploy & init Bonding proxy with fuzz params
        Bonding bondImpl = new Bonding();
        bytes memory bondInit = abi.encodeWithSelector(
            Bonding.initialize.selector,
            address(factory2),
            address(router2),
            payable(address(wsei2)),
            assetLaunchFee_,      // fuzzed launch fee
            0,                    // seiLaunchFee unused
            initialSupply_,       // fuzzed supply
            maxTxPct,             // fuzzed maxTx
            5,                    // slippage
            initialSupply_*10,    // high graduation thresholds
            initialSupply_*10,
            100,
            address(df2),
            address(dr2)
        );
        ERC1967Proxy bondProxy = new ERC1967Proxy(address(bondImpl), bondInit);
        Bonding bonding2 = Bonding(payable(address(bondProxy)));

        // 7) Grant roles to Bonding2
        factory2.grantRole(factory2.CREATOR_ROLE(), address(bonding2));
        router2.grantRole(router2.EXECUTOR_ROLE(), address(bonding2));

        // 8) Prepare asset for launch
        TestERC20 asset2 = new TestERC20();
        asset2.mint(alice, assetLaunchFee_ + 1 ether);

        // 9) Read on-chain view
        vm.startPrank(alice);
        asset2.approve(address(bonding2), assetLaunchFee_ + 1 ether);
        uint256 maxInput = bonding2.getMaxLaunchInputAsset();
        vm.stopPrank();

        vm.assume(maxInput >= assetLaunchFee_);

        // 10) Bound our rawAmt to [1, maxInput]
        uint256 purchaseAmt = bound(rawAmt, assetLaunchFee_, maxInput);

        // 11) Mint & approve
        asset2.mint(alice, purchaseAmt);
        vm.startPrank(alice);
        asset2.approve(address(bonding2), purchaseAmt);

        // 12) MUST succeed for any purchaseAmt ≤ maxInput
        bonding2.launchWithAsset("OK","OK", purchaseAmt, address(asset2));
        vm.stopPrank();
    }


    /// @notice Transfers to/from the taxReceiver incur no tax, even if involved in tax‐inclusion
    function testTaxReceiverNeutrality() public {
        // 1) Deploy an FERC20 with a 10% maxTx and mint to this test contract
        FERC20 token = new FERC20("Token","TN", 1_000_000, 10);
        address vault = address(0xABCD);

        token.unlock();   // caller is owner (address(this))

        // 2) Configure a 1% tax to go to `vault`, and include this contract in tax
        token.updateTaxSettings(vault, 100);               // 100 bps = 1%
        token.setIsIncludedInTax(address(this));           // mark sender as taxable

        // 3) Initial sanity balances
        assertEq(token.balanceOf(address(this)), 1_000_000);
        assertEq(token.balanceOf(vault), 0);

        // 4) Transfer 1_000 tokens to Bob — taxed at 1%
        address bob = address(0xBEEF);
        token.transfer(bob, 1_000);
        // Bob should get 990, vault gets 10
        assertEq(token.balanceOf(bob), 990);
        assertEq(token.balanceOf(vault), 10);

        // 5) Transfer 1_000 tokens *to* vault — should be untaxed
        token.transfer(vault, 1_000);
        // vault had 10, now +1000 => 1010
        assertEq(token.balanceOf(vault), 1_010);

        // 6) Transfer tokens *from* vault back to this contract — should be untaxed
        vm.prank(vault);
        token.transfer(address(this), 123);
        // test contract began at 1_000_000
        // -1_000 (to Bob) -1_000 (to vault) +123 (from vault) = 998_123
        assertEq(token.balanceOf(address(this)), 998_123);

        // 7) Bob’s balance remains unchanged
        assertEq(token.balanceOf(bob), 990);
    }


}
