// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/FFactory.sol";
import "../src/VirtualPair.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract FFactoryTest is Test {
    FFactory factory;
    address taxVault = address(0xBEEF);
    bytes32 ADMIN_ROLE;
    bytes32 CREATOR_ROLE;

    event PairCreated(address indexed tokenA, address indexed tokenB, address pair, uint index);

    function setUp() public {
        // Deploy implementation and proxy, initialize via proxy
        FFactory impl = new FFactory();
        bytes memory initData = abi.encodeWithSelector(
            FFactory.initialize.selector,
            taxVault,
            10,
            20
        );
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            initData
        );
        factory = FFactory(address(proxy));

        ADMIN_ROLE = factory.ADMIN_ROLE();
        CREATOR_ROLE = factory.CREATOR_ROLE();
    }

    /// @notice Verifies default state after initialize(): vault, taxes, and zeroed router/virtuals
    function testInitialState() public {
        assertEq(factory.taxVault(), taxVault);
        assertEq(factory.buyTax(), 10);
        assertEq(factory.sellTax(), 20);
        assertEq(factory.router(), address(0));
        assertEq(factory.defaultVirtToken(), 0);
        assertEq(factory.defaultVirtSei(), 0);
        assertEq(factory.allPairsLength(), 0);
    }

    /// @notice The proxy initializer should grant DEFAULT_ADMIN_ROLE to the deployer (this test contract)
    function testOwnerHasAdminRole() public {
        bytes32 defaultAdmin = factory.DEFAULT_ADMIN_ROLE();
        assertTrue(factory.hasRole(defaultAdmin, address(this)), "Deployer is not DEFAULT_ADMIN_ROLE");
    }


    /// @notice Should revert when a non-admin tries to set the router
    function testOnlyAdminCanSetRouter() public {
        vm.prank(address(0x1234));
        vm.expectRevert();
        factory.setRouter(address(1));
    }

    /// @notice Admin can successfully set router address
    function testAdminCanSetRouter() public {
        factory.grantRole(ADMIN_ROLE, address(this));
        factory.setRouter(address(42));
        assertEq(factory.router(), address(42));
    }

    /// @notice Reverts when non-admin attempts to update tax params
    function testOnlyAdminCanSetTaxParams() public {
        vm.prank(address(0x1234));
        vm.expectRevert();
        factory.setTaxParams(address(0xC0FFEE), 5, 5);
    }

    /// @notice Admin update validations: zero vault and out-of-range taxes
    function testSetTaxParamsBounds() public {
        factory.grantRole(ADMIN_ROLE, address(this));
        vm.expectRevert("Zero tax vault");
        factory.setTaxParams(address(0), 0, 0);
        vm.expectRevert("Tax must be a percentage between 0 to 100");
        factory.setTaxParams(address(0xCAFE), 101, 0);
    }

    /// @notice Admin can set new tax vault and percentages correctly
    function testAdminCanSetTaxParams() public {
        factory.grantRole(ADMIN_ROLE, address(this));
        factory.setTaxParams(address(0xDEAD), 7, 8);
        assertEq(factory.taxVault(), address(0xDEAD));
        assertEq(factory.buyTax(), 7);
        assertEq(factory.sellTax(), 8);
    }

    /// @notice Non-admin cannot set virtual liquidity defaults
    function testOnlyAdminCanSetVirtualLiquidity() public {
        vm.prank(address(0x2222));
        vm.expectRevert();
        factory.setVirtualLiquidity(1, 2);
    }

    /// @notice Admin can update default virtualToken and virtualSei values
    function testAdminCanSetVirtualLiquidity() public {
        factory.grantRole(ADMIN_ROLE, address(this));
        factory.setVirtualLiquidity(5, 7);
        assertEq(factory.defaultVirtToken(), 5);
        assertEq(factory.defaultVirtSei(), 7);
    }

    /// @notice Creator role cannot create a pair before router is set
    function testCreatorCannotCreatePairBeforeRouter() public {
        factory.grantRole(CREATOR_ROLE, address(this));
        vm.expectRevert("Router not set");
        factory.createPair(address(1), address(2));
    }

    /// @notice Creating a pair with zero address inputs should revert
    function testCreatePairRevertsOnZeroAddress() public {
        factory.grantRole(CREATOR_ROLE, address(this));
        factory.grantRole(ADMIN_ROLE, address(this));
        factory.setRouter(address(99));
        vm.expectRevert("Zero address");
        factory.createPair(address(0), address(1));
    }

    /// @notice Duplicate pair creation should revert with "Pair exists"
    function testCreatePairRevertsIfExists() public {
        factory.grantRole(CREATOR_ROLE, address(this));
        factory.grantRole(ADMIN_ROLE, address(this));
        factory.setRouter(address(9));
        address tA = address(0x10);
        address tB = address(0x20);
        factory.createPair(tA, tB);
        vm.expectRevert("Pair exists");
        factory.createPair(tA, tB);
    }

    /// @notice Happy path for createPair: mappings, array and virtual reserves set
    function testCreatePairHappyPath() public {
        factory.grantRole(CREATOR_ROLE, address(this));
        factory.grantRole(ADMIN_ROLE, address(this));
        factory.setRouter(address(this));
        address tokenA = address(0x100);
        address tokenB = address(0x200);
        address pairAddr = factory.createPair(tokenA, tokenB);

        assertEq(factory.getPair(tokenA, tokenB), pairAddr);
        assertEq(factory.getPair(tokenB, tokenA), pairAddr);
        assertEq(factory.allPairsLength(), 1);
        assertEq(factory.pairs(0), pairAddr);

        VirtualPair vp = VirtualPair(pairAddr);
        assertEq(vp.virtualToken(), factory.defaultVirtToken());
        assertEq(vp.virtualAsset(), factory.defaultVirtSei());
    }

    /// @notice getPair should return address(0) for unknown token pairs
    function testGetPairReturnsZero() public {
        assertEq(factory.getPair(address(1), address(2)), address(0));
    }

    /// @notice Creating a pair should emit the PairCreated event with correct args
    function testCreatePairEmitsEvent() public {
        factory.grantRole(CREATOR_ROLE, address(this));
        factory.grantRole(ADMIN_ROLE,   address(this));
        factory.setRouter(address(this));

        address tA = address(0xABC);
        address tB = address(0xDEF);

        vm.expectEmit(true, true, false, false, address(factory));
        emit PairCreated(tA, tB, address(0), 0);
        factory.createPair(tA, tB);
    }

}
