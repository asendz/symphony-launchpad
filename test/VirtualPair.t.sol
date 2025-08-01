// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/VirtualPair.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Simple mintable ERC20 for testing
contract ERC20Mock is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract VirtualPairTest is Test {
    ERC20Mock tokenA;
    ERC20Mock tokenB;
    VirtualPair pair;

    uint112 constant VIRT_TOKEN = 100;
    uint112 constant VIRT_ASSET = 200;

    /// @dev Redeclare events so forge’s expectEmit can catch them
    event Mint(uint256 reserve0, uint256 reserve1);
    event Swap(uint256 amount0In, uint256 amount0Out, uint256 amount1In, uint256 amount1Out);

    function setUp() public {
        // Deploy two mock tokens and mint some to this contract
        tokenA = new ERC20Mock("TokenA", "TKA");
        tokenB = new ERC20Mock("TokenB", "TKB");
        tokenA.mint(address(this), 1_000);
        tokenB.mint(address(this),   500);

        // Deploy the pair with this test as the router, plus virtual reserves
        pair = new VirtualPair(
            address(this),
            address(tokenA),
            address(tokenB),
            VIRT_TOKEN,
            VIRT_ASSET
        );
    }

    /// @notice getReserves() should return real + virtual
    function testGetReserves() public {
        tokenA.transfer(address(pair), 1_000);
        tokenB.transfer(address(pair),   500);
        (uint256 r0, uint256 r1) = pair.getReserves();
        assertEq(r0, 1_000 + VIRT_TOKEN);
        assertEq(r1,   500 + VIRT_ASSET);
    }

    /// @notice balance() returns only the real tokenA balance
    function testBalance() public {
        tokenA.transfer(address(pair), 123);
        assertEq(pair.balance(), 123);
    }

    /// @notice assetBalance() returns only the real tokenB balance
    function testAssetBalance() public {
        tokenB.transfer(address(pair), 321);
        assertEq(pair.assetBalance(), 321);
    }

    /// @notice syntheticAssetBalance() = real assetBalance + virtualAsset
    function testSyntheticAssetBalance() public {
        tokenB.transfer(address(pair), 321);
        assertEq(pair.syntheticAssetBalance(), 321 + VIRT_ASSET);
    }

    /// @notice Pricing formula: tokenA → tokenB
    function testGetAmountOutAtoB() public {
        tokenA.transfer(address(pair), 1_000);
        tokenB.transfer(address(pair),   500);
        uint256 amountIn = 100;
        uint256 reserveIn = 1_000 + VIRT_TOKEN;
        uint256 reserveOut=   500 + VIRT_ASSET;
        uint256 expected = (amountIn * reserveOut) / (reserveIn + amountIn);
        assertEq(pair.getAmountOut(address(tokenA), amountIn), expected);
    }

    /// @notice Pricing formula: tokenB → tokenA
    function testGetAmountOutBtoA() public {
        tokenA.transfer(address(pair), 1_000);
        tokenB.transfer(address(pair),   500);
        uint256 amountIn =  50;
        uint256 reserveIn =  500 + VIRT_ASSET;
        uint256 reserveOut=1_000 + VIRT_TOKEN;
        uint256 expected = (amountIn * reserveOut) / (reserveIn + amountIn);
        assertEq(pair.getAmountOut(address(tokenB), amountIn), expected);
    }

    /// @notice mint() reverts when msg.sender != router
    function testMintOnlyRouter() public {
        tokenA.transfer(address(pair), 10);
        tokenB.transfer(address(pair), 20);
        vm.prank(address(0x1234));
        vm.expectRevert("Only router");
        pair.mint();
    }

    /// @notice mint() emits a Mint(realToken, realAsset) event
    function testMintEmitsEvent() public {
        tokenA.transfer(address(pair), 10);
        tokenB.transfer(address(pair), 20);
        vm.expectEmit(true, true, false, false, address(pair));
        emit Mint(10, 20);
        pair.mint();
    }

    /// @notice swap() reverts when msg.sender != router
    function testSwapOnlyRouter() public {
        vm.prank(address(0x1234));
        vm.expectRevert("Only router");
        pair.swap(1, 2, 3, 4);
    }

    /// @notice swap() emits the Swap event with correct args
    function testSwapEmitsEvent() public {
        vm.expectEmit(false, false, true, true, address(pair));
        emit Swap(5, 6, 7, 8);
        pair.swap(5, 6, 7, 8);
    }

    /// @notice transferAsset() reverts when msg.sender != router
    function testTransferAssetOnlyRouter() public {
        vm.prank(address(0x1234));
        vm.expectRevert("Only router");
        pair.transferAsset(address(0x1), 1);
    }

    /// @notice transferTo() reverts when msg.sender != router
    function testTransferToOnlyRouter() public {
        vm.prank(address(0x1234));
        vm.expectRevert("Only router");
        pair.transferTo(address(0x1), 1);
    }

    /// @notice burnToken() reverts when msg.sender != router
    function testBurnTokenOnlyRouter() public {
        vm.prank(address(0x1234));
        vm.expectRevert("Only router");
        pair.burnToken(1);
    }

        /// @notice getAmountOut should revert on zero amountIn
    function testGetAmountOutRevertsOnZeroAmount() public {
        vm.expectRevert("Amount in = 0");
        pair.getAmountOut(address(tokenA), 0);
    }

    /// @notice getAmountOut should revert when input token is invalid
    function testGetAmountOutRevertsOnInvalidToken() public {
        vm.expectRevert("Invalid input token");
        pair.getAmountOut(address(0xDEAD), 10);
    }

    /// @notice approval() should revert when msg.sender != router
    function testApprovalOnlyRouter() public {
        vm.prank(address(0x1234));
        vm.expectRevert("Only router");
        pair.approval(address(this), address(tokenA), 1);
    }

    /// @notice Even with zero real reserves, getReserves includes the virtual cushions
    function testReservesWhenEmpty() public {
        (uint256 r0, uint256 r1) = pair.getReserves();
        assertEq(r0, VIRT_TOKEN);
        assertEq(r1, VIRT_ASSET);
    }

        /// @notice tokenA() and tokenB() getters return the correct addresses
    function testTokenAddressGetters() public {
        assertEq(pair.tokenA(), address(tokenA));
        assertEq(pair.tokenB(), address(tokenB));
    }

    /// @notice Even if only virtual reserves exist, balance() and assetBalance() remain zero
    function testRealBalancesWhenEmpty() public {
        assertEq(pair.balance(), 0);
        assertEq(pair.assetBalance(), 0);
    }

}
