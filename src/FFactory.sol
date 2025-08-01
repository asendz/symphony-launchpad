// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title FFactory (v2)
 * @notice Updated factory that mints `VirtualPair` instead of the old
 *         `SyntheticPair`.  Adds owner‑configurable default virtual reserves
 *         so the launchpad can set the starting price globally.
 *
 *         External interface changes:
 *         – **new** `setVirtualLiquidity(uint112 vt, uint112 vs)`
 *         – public getters `defaultVirtToken`, `defaultVirtSei`
 *         Everything else (roles, events, createPair signature) remains
 *         unchanged for compatibility with Router & Bonding.
 */

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

import "./VirtualPair.sol";

contract FFactory is Initializable, AccessControlUpgradeable, ReentrancyGuardUpgradeable {
    // ---------------------------------------------------------------------
    // Roles
    // ---------------------------------------------------------------------
    bytes32 public constant ADMIN_ROLE   = keccak256("ADMIN_ROLE");
    bytes32 public constant CREATOR_ROLE = keccak256("CREATOR_ROLE");

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------
    mapping(address => mapping(address => address)) private _pair;
    address[] public pairs;

    // Router address settable by admin
    address public router;

    // Tax configuration (unchanged from v1)
    address public taxVault;
    uint256 public buyTax;
    uint256 public sellTax;

    // *** New: default virtual reserves applied to every new pair ***
    uint112 public defaultVirtToken;   // added to tokenA reserve
    uint112 public defaultVirtSei;     // added to tokenB reserve (e.g., SEI)

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------
    event PairCreated(address indexed tokenA, address indexed tokenB, address pair, uint index);
    event VirtualLiquidityUpdated(uint112 virtToken, uint112 virtSei);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ---------------------------------------------------------------------
    // Initializer
    // ---------------------------------------------------------------------
    function initialize(
        address taxVault_,
        uint256 buyTax_,
        uint256 sellTax_
    ) external initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        require(buyTax_ <= 100 && sellTax_ <= 100, "Tax must be a percentage between 0 to 100");
        require(taxVault_ != address(0), "Zero tax vault");

        taxVault = taxVault_;
        buyTax   = buyTax_;
        sellTax  = sellTax_;

        // virtual reserves default to 0; admin should call setVirtualLiquidity()
    }

    // ---------------------------------------------------------------------
    // Admin functions
    // ---------------------------------------------------------------------

    /**
     * @notice Configure the default virtual reserves that will be baked into
     *         every pair created *after* this call.
     *         Only callable by ADMIN_ROLE.
     */
    function setVirtualLiquidity(uint112 virtToken_, uint112 virtSei_) external onlyRole(ADMIN_ROLE) {
        defaultVirtToken = virtToken_;
        defaultVirtSei   = virtSei_;
        emit VirtualLiquidityUpdated(virtToken_, virtSei_);
    }

    function setTaxParams(address newVault_, uint256 buyTax_, uint256 sellTax_) external onlyRole(ADMIN_ROLE) {
        require(newVault_ != address(0), "Zero tax vault");

        require(buyTax_ <= 100 && sellTax_ <= 100, "Tax must be a percentage between 0 to 100");

        taxVault = newVault_;
        buyTax   = buyTax_;
        sellTax  = sellTax_;
    }

    function setRouter(address router_) external onlyRole(ADMIN_ROLE) {
        require(router_ != address(0), "Zero router");
        router = router_;
    }

    // ---------------------------------------------------------------------
    // Pair factory logic
    // ---------------------------------------------------------------------

    /** @dev Internal helper that actually deploys the pair */
    function _createPair(address tokenA, address tokenB) internal returns (address pairAddr) {
        require(tokenA != address(0) && tokenB != address(0), "Zero address");
        require(router != address(0), "Router not set");
        require(_pair[tokenA][tokenB] == address(0), "Pair exists");

        VirtualPair pair = new VirtualPair(router, tokenA, tokenB, defaultVirtToken, defaultVirtSei);

        pairAddr = address(pair);

        _pair[tokenA][tokenB] = pairAddr;
        _pair[tokenB][tokenA] = pairAddr;

        pairs.push(pairAddr);

        emit PairCreated(tokenA, tokenB, pairAddr, pairs.length);
    }

    /**
     * @notice Public factory method called by Bonding contract (CREATOR_ROLE)
     *         to spin up a new bonding pool.
     */
    function createPair(address tokenA, address tokenB) external onlyRole(CREATOR_ROLE) nonReentrant returns (address) {
        return _createPair(tokenA, tokenB);
    }

    // ---------------------------------------------------------------------
    // Read helpers (unchanged)
    // ---------------------------------------------------------------------

    function getPair(address tokenA, address tokenB) external view returns (address) {
        return _pair[tokenA][tokenB];
    }

    function allPairsLength() external view returns (uint256) {
        return pairs.length;
    }
}
