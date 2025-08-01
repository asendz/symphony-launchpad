// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title VirtualPair
 * @notice Replacement for `SyntheticPair` that fixes the multiplier exploit by
 *         using *additive* virtual reserves instead of multiplying a single side.
 *         The contract still satisfies the IFPair interface, so existing Router
 *         & Bonding logic remains unchanged.
 *
 *         Pricing reserves = realReserve + virtualReserve
 *         Accounting reserves (for TVL / graduation) = realReserve only
 */

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./IFPair.sol";
import "./FERC20.sol";

contract VirtualPair is IFPair, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------
    // Immutable parameters (set at construction)
    // ---------------------------------------------------------------------
    address public router;
    address public tokenA;            // The bonding token
    address public tokenB;            // The asset token (e.g. WSEI)

    // Virtual reserves that cushion price at launch.
    // Stored as uint112 to keep slot packing tight.
    uint112 public virtualToken;      // added to tokenA reserve for pricing
    uint112 public virtualAsset;      // added to tokenB reserve for pricing

    // Timestamp of last liquidity-affecting event (mint/swap)
    uint256 private lastUpdated;

    // ---------------------------------------------------------------------
    // Events (same signature as SyntheticPair)
    // ---------------------------------------------------------------------
    event Mint(uint256 reserve0, uint256 reserve1);
    event Swap(
        uint256 amount0In,
        uint256 amount0Out,
        uint256 amount1In,
        uint256 amount1Out
    );

    // ---------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------
    modifier onlyRouter() {
        require(msg.sender == router, "Only router");
        _;
    }

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------
    constructor(
        address router_,
        address token0_,
        address token1_,
        uint112 virtualToken_,
        uint112 virtualAsset_
    ) {
        require(router_ != address(0) && token0_ != address(0) && token1_ != address(0), "Zero address");
        router = router_;
        tokenA = token0_;
        tokenB = token1_;
        virtualToken = virtualToken_;
        virtualAsset = virtualAsset_;
    }

    // ---------------------------------------------------------------------
    // Core AMM hooks (no-op but emit events to stay indexer-friendly)
    // ---------------------------------------------------------------------

    /**
     * @dev Called once by Router right after initial liquidity has been transferred.
     *      We emit the **real** reserves (without virtual liquidity) to stay
     *      consistent with the original SyntheticPair behaviour and with what
     *      on‑chain indexers historically stored in the Mint event.
     */
    function mint() external onlyRouter returns (bool) {
        require(lastUpdated == 0, "Already minted");
        (uint256 r0, uint256 r1) = _realReserves();
        lastUpdated = block.timestamp;
        emit Mint(r0, r1);
        return true;
    }

    /** @dev Router calls this after moving funds to emit a Swap event */
    function swap(
        uint256 amount0In,
        uint256 amount0Out,
        uint256 amount1In,
        uint256 amount1Out
    ) external onlyRouter returns (bool) {
        lastUpdated = block.timestamp;
        emit Swap(amount0In, amount0Out, amount1In, amount1Out);
        return true;
    }

    // ---------------------------------------------------------------------
    // Reserve helpers
    // ---------------------------------------------------------------------

    /** @return realToken realAsset  (does NOT include virtual liquidity) */
    function _realReserves() internal view returns (uint256 realToken, uint256 realAsset) {
        realToken = IERC20(tokenA).balanceOf(address(this));
        realAsset = IERC20(tokenB).balanceOf(address(this));
    }

    /** @notice Reserves used in price calculation (real + virtual) */
    function getReserves() public view override returns (uint256, uint256) {
        (uint256 realToken, uint256 realAsset) = _realReserves();
        return (realToken + virtualToken, realAsset + virtualAsset);
    }

    // ---------------------------------------------------------------------
    // IFPair read-only getters (real-reserve versions)
    // ---------------------------------------------------------------------

    function balance() public view override returns (uint256) {
        (uint256 realToken, ) = _realReserves();
        return realToken;
    }

    function assetBalance() public view override returns (uint256) {
        (, uint256 realAsset) = _realReserves();
        return realAsset;
    }

    /** @dev Kept for backward compatibility - now returns real + virtual asset reserve */
    function syntheticAssetBalance() public view override returns (uint256) {
        return assetBalance() + virtualAsset;
    }

    // ---------------------------------------------------------------------
    // Token movements (invoked by Router)
    // ---------------------------------------------------------------------

    function transferAsset(address recipient, uint256 amount) external onlyRouter override {
        require(recipient != address(0), "Zero address");
        IERC20(tokenB).safeTransfer(recipient, amount);
    }

    function transferTo(address recipient, uint256 amount) external onlyRouter override {
        require(recipient != address(0), "Zero address");
        IERC20(tokenA).safeTransfer(recipient, amount);
    }

    function burnToken(uint256 amount) external onlyRouter override returns (bool) {
        FERC20(tokenA).burn(amount);
        return true;
    }

    function approval(
        address _user,
        address _token,
        uint256 amount
    ) external onlyRouter override returns (bool) {
        IERC20(_token).forceApprove(_user, amount);
        return true;
    }

    // ---------------------------------------------------------------------
    // AMM pricing formula (x+v1)(y+v2)=k
    // ---------------------------------------------------------------------

    function getAmountOut(address inputToken, uint256 amountIn) external view override returns (uint256 amountOut) {
        require(amountIn > 0, "Amount in = 0");

        (uint256 rToken, uint256 rAsset) = getReserves();

        uint256 reserveIn;
        uint256 reserveOut;

        if (inputToken == tokenA) {
            reserveIn = rToken;
            reserveOut = rAsset;
        } else if (inputToken == tokenB) {
            reserveIn = rAsset;
            reserveOut = rToken;
        } else {
            revert("Invalid input token");
        }

        amountOut = (amountIn * reserveOut) / (reserveIn + amountIn);
    }
}
