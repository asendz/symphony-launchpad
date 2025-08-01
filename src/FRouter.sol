// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

import "./FFactory.sol";
import "./IFPair.sol";
import "./VirtualPair.sol"; 

contract FRouter is
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    FFactory public factory;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address factory_
    ) external initializer {
        __ReentrancyGuard_init();
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        require(factory_ != address(0), "Zero addresses are not allowed.");

        factory = FFactory(factory_);
    }

    // Calculates the expected output when swapping inputToken for outputToken
    function getAmountOut(
        address inputToken,
        address outputToken,
        uint256 amountIn
    ) public view returns (uint256 amountOut) {
        require(inputToken != address(0) && outputToken != address(0), "Zero addresses are not allowed.");
        require(inputToken != outputToken, "Tokens must be different.");

        address pairAddress = factory.getPair(inputToken, outputToken);
        IFPair pair = IFPair(pairAddress);

        amountOut = pair.getAmountOut(inputToken, amountIn);

        return amountOut;
    }


    function addInitialLiquidity(
        address token_,
        address assetToken,
        uint256 amountToken_,
        uint256 amountAsset_
    ) public onlyRole(EXECUTOR_ROLE) returns (uint256, uint256) {
        require(token_ != address(0), "Zero addresses are not allowed.");

        address pairAddress = factory.getPair(token_, assetToken);

        IFPair pair = IFPair(pairAddress);

        IERC20 token = IERC20(token_);

        token.safeTransferFrom(msg.sender, pairAddress, amountToken_);
        IERC20(assetToken).safeTransferFrom(msg.sender, pairAddress, amountAsset_);

        pair.mint();

        return (amountToken_, amountAsset_);
    }

    // Sell token at tokenAddress for assetToken
    function sell(
        uint256 amountIn,
        address tokenAddress,
        address assetToken,
        address to
    ) public nonReentrant onlyRole(EXECUTOR_ROLE) returns (uint256, uint256, uint256) {
        require(tokenAddress != address(0), "Zero addresses are not allowed.");
        require(to != address(0), "Zero addresses are not allowed.");

        address pairAddress = factory.getPair(tokenAddress, assetToken);
        IFPair pair = IFPair(pairAddress);
        IERC20 token = IERC20(tokenAddress);

        uint256 amountOut = getAmountOut(tokenAddress, assetToken, amountIn);

        // Send the funds to the pair
        token.safeTransferFrom(msg.sender, pairAddress, amountIn);

        // Deduct fees from the outputs
        uint sellTax = factory.sellTax();
        uint256 sellTaxAmt = (sellTax * amountOut) / 100;
        uint256 amountReceived = amountOut - sellTaxAmt;
        
        address feeTo = factory.taxVault();

        // Send outputs to the seller and the fee vault
        pair.transferAsset(to, amountReceived);
        pair.transferAsset(feeTo, sellTaxAmt);

        // Allow the pair to emit an event (This is a no-op otherwise)
        pair.swap(amountIn, 0, 0, amountOut);

        return (amountIn, amountOut, amountReceived);
    }

    function buy(
        uint256 amountIn,
        address tokenAddress,
        address assetToken,
        address to
    ) public onlyRole(EXECUTOR_ROLE) nonReentrant returns (uint256, uint256) {
        require(tokenAddress != address(0), "Zero addresses are not allowed.");
        require(to != address(0), "Zero addresses are not allowed.");
        require(amountIn > 0, "amountIn must be greater than 0");

        address pair = factory.getPair(tokenAddress, assetToken);

        // Calculate the tax to deduct from the input
        uint buyTax = factory.buyTax();
        uint256 buyTaxAmt = (buyTax * amountIn) / 100;
        address feeTo = factory.taxVault();

        uint256 amount = amountIn - buyTaxAmt;

        // Calculate the amountOut based on the current state of the pool
        uint256 amountOut = getAmountOut(assetToken, tokenAddress, amount);
        
        // Send fudns to the pool and the tax vault
        IERC20(assetToken).safeTransferFrom(msg.sender, pair, amount);
        IERC20(assetToken).safeTransferFrom(msg.sender, feeTo, buyTaxAmt);

        // Send the tokens to the buyer
        IFPair(pair).transferTo(to, amountOut);

        // Emit an event on the pool (This is a no-op otherwise)
        IFPair(pair).swap(0, amountOut, amount, 0);

        return (amount, amountOut);
    }

    // Graduates the pool by transferring balances to the sender so that they can be deposited into a Dragonswap pool.
    // It transfers all the SEI but only enough token so that the price in the Dragonswap pool will continue to be the same.
    // All remaining tokens are burned.
    function graduatePool(address tokenAddress, address assetToken)
        public onlyRole(EXECUTOR_ROLE) nonReentrant
        returns (uint256 tokenOut, uint256 assetOut)
    {
        address pair = factory.getPair(tokenAddress, assetToken);
        VirtualPair vPair = VirtualPair(pair);

        uint256 assetBalance = vPair.assetBalance();   // real SEI ( y )
        uint256 tokenBalance = vPair.balance();        // real tokens ( x )

        // read virtual constants
        uint256 vT = vPair.virtualToken();
        uint256 vA = vPair.virtualAsset();

        // amount of real tokens to keep price identical on DragonSwap
        uint256 targetToken = (assetBalance * (tokenBalance + vT)) / (assetBalance + vA);
        uint256 tokensToBurn = tokenBalance - targetToken;

        // move assets to Bonding / caller
        vPair.transferAsset(msg.sender, assetBalance);
        vPair.transferTo(msg.sender, targetToken);
        vPair.burnToken(tokensToBurn);

        return (targetToken, assetBalance);
    }
}
