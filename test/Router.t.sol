// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/FRouter.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/IFPair.sol";

/// @notice A minimal stub pair implementing only getAmountOut for testing
contract StubPair {
    uint256 public returnAmount;
    constructor(uint256 _returnAmount) {
        returnAmount = _returnAmount;
    }
    function getAmountOut(address, uint256) external view returns (uint256) {
        return returnAmount;
    }
}

/// @notice Stub factory returning a fixed StubPair address
contract StubFactory {
    address public pairAddr;
    constructor(address _pairAddr) {
        pairAddr = _pairAddr;
    }
    function getPair(address, address) external view returns (address) {
        return pairAddr;
    }
}

contract FRouterTest is Test {
    FRouter public router;
    StubFactory public factoryMock;
    StubPair public pairMock;
    bytes32 public EXECUTOR_ROLE;

    function setUp() public {
        // Deploy stub pair returning 123
        pairMock = new StubPair(123);
        // Deploy stub factory pointing to stub pair
        factoryMock = new StubFactory(address(pairMock));

        // Deploy FRouter behind proxy and initialize with stub factory
        FRouter impl = new FRouter();
        bytes memory initData = abi.encodeWithSelector(
            FRouter.initialize.selector,
            address(factoryMock)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        router = FRouter(address(proxy));

        EXECUTOR_ROLE = router.EXECUTOR_ROLE();
    }

    /// @notice Proxy initialization should revert if factory address is zero
    function testInitializeZeroFactoryReverts() public {
        FRouter impl = new FRouter();
        vm.expectRevert("Zero addresses are not allowed.");
        new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(FRouter.initialize.selector, address(0))
        );
    }

    /// @notice Should revert when inputToken or outputToken is zero
    function testGetAmountOutZeroAddressReverts() public {
        vm.expectRevert("Zero addresses are not allowed.");
        router.getAmountOut(address(0), address(1), 1);
    }

    /// @notice Should revert when inputToken == outputToken
    function testGetAmountOutSameTokenReverts() public {
        vm.expectRevert("Tokens must be different.");
        router.getAmountOut(address(1), address(1), 1);
    }

    /// @notice Happy path: returns stub pair's getAmountOut
    function testGetAmountOutHappyPath() public {
        uint256 out = router.getAmountOut(address(1), address(2), 42);
        assertEq(out, 123);
    }

    /// @notice Only executor can call addInitialLiquidity
    function testAddInitialLiquidityNonExecutorReverts() public {
        vm.expectRevert();
        router.addInitialLiquidity(address(1), address(2), 1, 1);
    }

    /// @notice Only executor can call sell
    function testSellNonExecutorReverts() public {
        vm.expectRevert();
        router.sell(1, address(1), address(2), address(this));
    }

    /// @notice Only executor can call buy
    function testBuyNonExecutorReverts() public {
        vm.expectRevert();
        router.buy(1, address(1), address(2), address(this));
    }

    /// @notice After initialize, router.factory() must point at the stub factory
    function testFactorySetCorrectly() public {
        assertEq(address(router.factory()), address(factoryMock));
    }

    /// @notice Executor cannot call addInitialLiquidity with zero token address
    function testAddInitialLiquidityRevertsOnZeroToken() public {
        router.grantRole(EXECUTOR_ROLE, address(this));
        vm.expectRevert("Zero addresses are not allowed.");
        router.addInitialLiquidity(address(0), address(1), 1, 1);
    }

    /// @notice Executor buy() must revert on zero tokenAddress
    function testBuyRevertsOnZeroTokenAddress() public {
        router.grantRole(EXECUTOR_ROLE, address(this));
        vm.expectRevert("Zero addresses are not allowed.");
        router.buy(1, address(0), address(1), address(this));
    }

    /// @notice Executor buy() must revert on zero `to` address
    function testBuyRevertsOnZeroTo() public {
        router.grantRole(EXECUTOR_ROLE, address(this));
        vm.expectRevert("Zero addresses are not allowed.");
        router.buy(1, address(1), address(2), address(0));
    }

    /// @notice Executor buy() must revert when amountIn == 0
    function testBuyRevertsOnZeroAmountIn() public {
        router.grantRole(EXECUTOR_ROLE, address(this));
        vm.expectRevert("amountIn must be greater than 0");
        router.buy(0, address(1), address(2), address(this));
    }

    /// @notice Executor sell() must revert on zero tokenAddress
    function testSellRevertsOnZeroTokenAddress() public {
        router.grantRole(EXECUTOR_ROLE, address(this));
        vm.expectRevert("Zero addresses are not allowed.");
        router.sell(1, address(0), address(1), address(this));
    }

    /// @notice Executor sell() must revert on zero `to` address
    function testSellRevertsOnZeroTo() public {
        router.grantRole(EXECUTOR_ROLE, address(this));
        vm.expectRevert("Zero addresses are not allowed.");
        router.sell(1, address(1), address(2), address(0));
    }

}
