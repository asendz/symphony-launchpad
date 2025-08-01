# Symphony Launchpad - Engineering Change-Log

## Overview
This report lists every line-level change together with the rationale for each modification.

**Scope of work**
1. **Virtual-liquidity redesign** – replace the flawed *multiplier* model with additive virtual reserves, integrate the new logic across Factory, Router, Bonding, and Pair contracts, and migrate storage/ABIs with zero breaking changes.
2. **Code review & hardening** – review legacy code and patch discovered bugs.
3. **Developing test suite** – unit, scenario, and fuzz-tests that enforce invariants, cover edge-cases, and prove that previous issues are now mitigated.

The sections that follow present the exact diffs and justifications.

---

## 1.  Bug Fixes (legacy code)

| ID       | File / Method                | **Old code**                                   | **New code**                                                       | Why it matters                                                                              |
| -------- | ---------------------------- | ---------------------------------------------- | ------------------------------------------------------------------ | ------------------------------------------------------------------------------------------- |
| **I-01** | **`FFactory.setTaxParams`**  | `require(buyTax <= 100 …`  *(checked storage)* | `require(buyTax_ <= 100 && sellTax_ <= 100, "Tax must be 0-100");` | Prevents setting taxes > 100 % which would brick swaps.                                     |
| **I-02** | **`FERC20.burn & burnFrom`** | *no cap refresh*                               | `super.burn(amount); _updateMaxTx(maxTx);`          | Keeps `maxTxAmount` in sync after any supply burn so users can’t exceed the intended % cap. |

### Issue-by-Issue Summary

**I-01 - Tax-parameter validation**

The original `setTaxParams` routine compared its *old* storage values (`buyTax`, `sellTax`) against the 0-100 % bound. An admin(via a mistake or malicious behavior) could pass in 150 % and brick every swap. The fix moves the check to the **new** inputs (`buyTax_`, `sellTax_`) and enforces the 0-100 % range for both in a single `require`.

**I-02 - maxTx drift after burns**

`FERC20` capped transfers by a percentage of total supply (`maxTxAmount`) but never recalculated that cap when tokens were burned. After a large burn, users could still move more than the intended percentage. The patch hooks `_updateMaxTx(maxTx)` into both `burn` and `burnFrom`, so the cap automatically shrinks whenever supply does.

---

## 2.  Pair-Level Refactor – **`VirtualPair`**

| What changed         | Exact diff                                                                                              | Reason                                                                                         |
| -------------------- | ------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| **File swap**        | `SyntheticPair.sol` **->** `VirtualPair.sol`                                                             | Multiplier design caused asymmetric curve; additive virtual reserves shift both sides equally. |
| **Immutable state**  | **+** `uint112 public immutable virtualToken;`**+** `uint112 public immutable virtualAsset;`        | Stored once at deploy → gas-free reads, predictable invariant.                                 |
| **Reserve math**     | Everywhere `reserve = balanceOf(...)` **->** `reserve = real + virtual`                                  | Restores constant-product invariant and blocks buy-sell arbitrage.                             |
| **Getter behaviour** | `syntheticAssetBalance()` **now returns** real + virtual                                                | Indexers receive price-ready reserve without change of ABI.                                    |
| **Safety gates**     | All “router-only” functions keep modifier; input-token validation msg tweaked to `Invalid input token`. | No functional change – matched names for clarity.                                              |

---

## 3.  `FFactory.sol`

| Change ID | Code before                                                                        | Code after                                                                                   | Why                                                       |
| --------- | ---------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- | --------------------------------------------------------- |
| F-01      | *(none)*                                                                           | `uint112 public defaultVirtToken;`<br>`uint112 public defaultVirtSei;`                       | Global defaults for new pairs.                            |
| F-02      | *(none)*                                                                           | `function setVirtualLiquidity(uint112 vt,uint112 vs) onlyRole(ADMIN_ROLE) {...}` | Owner can tune cushions. Emits `VirtualLiquidityUpdated`. |
| F-03      | `new SyntheticPair(router,…`                                                       | `new VirtualPair(router, tokenA, tokenB, defaultVirtToken, defaultVirtSei)`                  | Deploy correct pair type.                                 |
| F-04      | **-** `import "./FPair.sol";`                                                      | *(removed)*                                                                                  | Dead include.                                             |
| F-05      | `require(newVault_ != address(0) …` **but** validation used `buyTax` not `buyTax_` | Validation now uses the *inputs* (`buyTax_`, `sellTax_`).                                    | Fix I-01 issue in factory.                               |
| F-06      | *(none)*                                                                           | `require(_pair[tokenA][tokenB]==address(0), "Pair exists");`                                 | Extra guard against accidental duplicate creation.        |
| F-07      | `address pair = _createPair(...); return pair;`                                    | `return _createPair(...);`                                                                   | Cosmetic.                                                 |

---

## 4.  `Bonding.sol`

| Section                   | Old                                         | New                                                                                                                                            | Rationale                                                            |
| ------------------------- | ------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------- |
| **Launch metrics**        | used `balance()` & fee maths                | `(uint256 rT,uint256 rA)=IFPair(_pair).getReserves(); price = rT / rA; marketCap = supply * rA / rT; liquidity = rA * 2;` | Reserves now include virtual -> UI shows true on-chain price / depth. |
| **`getMaxLaunchInput`**   | `syntheticAssets = multiplier * launchFee;` | `syntheticAssets = factory.defaultVirtSei();`                                                                                                  | Multiplier field removed.                                            |
| **`getMaxBuyInputAsset`** | token side ‘real’, asset side ‘synthetic’   | both reserves from `pair.getReserves()`                                                                                                        | Always same basis → prevents “transfer exceeds balance” revert.      |
| **Init guard**            | *(none)*                                    | `require(factory_!=0 && router_!=0 … , "Zero address")`                                                                                        | Align with Factory/Router init checks.                               |

---

## 5.  `FRouter.sol`

* **Import / cast**

  ```solidity
  import "./VirtualPair.sol";
  VirtualPair vPair = VirtualPair(pair);
  ```

* **`graduatePool` formula**

  ```solidity
  uint256 target = assetBal * (tokenBal + vT) / (assetBal + vA);
  uint256 burn   = tokenBal - target;
  ```

  *Transfers*: `transferAsset`, `transferTo`, `burnToken`.

*No ABI touch – Bonding keeps using existing signatures.*

**Design choice note**

When graduating tokens, we're burning a certain amount of tokens to ensure price continuity on Dragonswap. This amount of tokens could just as easily be sent to a protocol-owned address (e.g. a treasury or time-lock) instead of burn().
Burning keeps math simple and guarantees no future sell-pressure, but redirecting them can be an option for treasury accrual. If sent to treasury, this would also preserve the original totalSupply of the token.

---

## 6.  Tests Added (113 total, all pass)

| Contract                  | “Base” tests (sanity / guards)                                                 | Scenario & fuzz tests                                         |
| ------------------------- | ------------------------------------------------------------------------------ | ------------------------------------------------------------- |
| **Router**                | Non-executor reverts, zero-address guards, factory wiring                      | Quote correctness                                             |
| **Factory**               | Role checks, initial state, duplicate guards                                   | Event emission, virtual-liquidity flow                        |
| **VirtualPair**           | Reserve getters, router-only modifiers                                         | Swap maths, constant-product across directions                |
| **FERC20**                | Lock / whitelist / tax / maxTx                                                 | Burn-cap sync, fuzzed conservation & limits                   |
| **Bonding**               | Launch/Buy/Sell/Graduate happy-paths & owner setters                           | Invariant fuzz ×4, buy→sell profit, TVL dust after graduation |
| **VirtualLiquiditySweep** | One-shot graduation; staged bucket buys across 4 virtual-liquidity presets | –                                                             |

## Test suite development
Below is a contract-by-contract map of the 113 tests with a one-sentence purpose each.

You can run them with `forge test`.

The `VirtualLiquiditySweep.t.sol` test file has 2 tests scenarios to simulate the bonding curve behavior:
| Scenario                       | What it does                                                                                                                                                           | Why we care                                                                                                                                                                                                                                              |
| ------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **1. Single-buyer graduation** | Launch four tokens that differ only in their virtual-reserve percentages, then place **one large buy** that takes each to the graduation threshold in a single stroke. | Tells us, for each preset, exactly how many real tokens end up in the buyer’s hands, how many are burned, and how many are migrated to the DragonSwap LP.|
| **2. Bucketed flow**           | Replays a **40-step purchase schedule** (101 SEI -> 9 * 100 SEI -> 20 * 250 SEI -> 10 * 300 SEI) against the same four presets, logging reserves and price after every bucket.  | Lets us see the **slope of the curve** rather than just its end-points. Shows how much output each buy yields as the pool gets deeper, so team can tune virtual parameters for the launch UX they want.                    |

Run only these sims and stream their logs:
`forge test --match-contract VirtualLiquiditySweep -vv`

Use -vv (or -vvv) to surface the console.log lines that print token out, burned amount, DragonSwap deposits, and the evolving price at every step.

### Quick Foundry install (macOS / Linux)

```bash
# 1-liner bootstrap
curl -L https://foundry.paradigm.xyz | bash

# add the binaries to your PATH (open a new shell **or** run)
foundryup
```

That drops the two CLI tools—`forge` and `cast`—into `~/.foundry/bin`.
After that you can run the project tests straight away.

---

### 1 · `FRouter.sol` tests  (`FRouterTest` – 14 tests)

#### Base / access-control

* **testInitializeZeroFactoryReverts** – deploy via proxy must fail when `factory` address is `0x0`.
* **testFactorySetCorrectly** – after init, `router.factory()` points to the stub factory.
* **testGetAmountOutZeroAddressReverts** / **…SameTokenReverts** – invalid token args revert.
* **testAddInitialLiquidityNonExecutorReverts** / **testBuyNonExecutorReverts** / **testSellNonExecutorReverts** – only `EXECUTOR_ROLE` can move assets.
* **testAddInitialLiquidityRevertsOnZeroToken** / **Buy/Sell RevertsOnZero...** – guard clauses for `0x0` token or recipient.
* **testBuyRevertsOnZeroAmountIn** – cannot submit a zero-amount swap.
* **testGetAmountOutHappyPath** – router returns the pair’s `getAmountOut` value (stub set to 123).

---

### 2 · `FFactory.sol` tests  (`FFactoryTest` – 15 tests)

#### Base

* **testInitialState** – verifies vault, tax %, router =`0`, virtual-liquidity defaults and pairs array length.
* **testOwnerHasAdminRole** – proxy deployer owns `DEFAULT_ADMIN_ROLE`.
* **testOnlyAdminCanSetRouter/TaxParams/VirtualLiquidity** – role gating.
* **testSetTaxParamsBounds** – rejects zero vault or taxes > 100 %.
* **testGetPairReturnsZero** – unknown pair -> `address(0)`.

#### Creation scenarios

* **testCreatorCannotCreatePairBeforeRouter** – router must be set first.
* **testCreatePairRevertsOnZeroAddress / …IfExists** – sanity guards.
* **testCreatePairHappyPath** – maps both directions, stores pair in array, inherits default virtual reserves.
* **testCreatePairEmitsEvent** – confirms `PairCreated` topics & index.

---

### 3 · `VirtualPair.sol` tests  (`VirtualPairTest` – 19 tests)

#### Base maths & getters

* **testGetReserves / ReservesWhenEmpty** – returns *(real + virtual)* cushions.
* **testBalance / AssetBalance / RealBalancesWhenEmpty** – expose **real** balances only.
* **testSyntheticAssetBalance** – real + virtual asset side.
* **testGetAmountOutAtoB / BtoA** – formula matches expected `(Δ × Rout)/(Rin+Δ)`.
* **testTokenAddressGetters** – `tokenA()` / `tokenB()` wires.

#### Access-control & events

* **testMintOnlyRouter / SwapOnlyRouter / TransferAssetOnlyRouter / …TransferTo / BurnToken / Approval** – router-only modifiers guard side-effects.
* **testMintEmitsEvent / testSwapEmitsEvent** – event payloads correct.
* **testGetAmountOutRevertsOnZeroAmount / InvalidToken** – input validation.

*(No heavy scenarios; the invariant itself is exercised in `BondingTest`.)*

---

### 4 · `FERC20.sol` tests  (`FERC20Test` – 23 tests)

#### Base token behaviour

* **testInitialSupplyAndLock / UnlockAllowsTransfers / LockBehavior / WhitelistBypassesLock** – minting & lock-whitelist flow.
* **testForceApprove / AllowanceIncreaseDecrease** – custom approval helpers.
* **testMaxTxEnforced / MaxTxBoundaryPct / DynamicMaxTxRecalculation** – `maxTx` cap logic.

#### Tax & treasury paths

* **testTaxedTransfer / TaxWhenRecipientOnly / TaxReceiverNeutrality / NoTaxWhenSending{To|From}TaxReceiver / ExtremeTaxSettings** – all fee permutations incl. 0 % & 100 %.

#### Burn & supply dynamics

* **testBurnReducesMaxTx / ConcurrentBurnAndTransfer** – new max-tx recompute after burns.

#### Robustness / fuzz

* **ZeroValueOps, RevertWhenAmountExceedsMax, TransferConservation** – edge-cases, fuzzed conservation invariant.

---

### 5 · `Bonding.sol` tests  (`BondingTest` – 40 tests)

#### Base constructor & owner setters

* **testInitializeRevertsOnZero{Factory|Router|WSEI|DragonFactory|DragonRouter}** – non-zero guards.
* **Owner-only setter trio** – `set{InitialSupply|Fees|Thresholds|MaxTx|Slippage}` positive & negative paths.
* **testOwnerIsDeployer** – ownership wired.

#### Profile & launch basics

* **testGetUserTokensRevertsBeforeLaunch / UserProfile{One|Multiple}Launches** – profile auto-creation.
* **testLaunchWithAsset{HappyPath, RevertsOnLowFee, RevertsOnNoApproval}**.
* **testLaunchWithSei{HappyPath, RevertsOnLowValue}**.

#### Secondary trading & data updates

* **testSecondaryBuyUpdatesData / SecondarySellUpdatesData** – taxes go to vault, reserves move.

#### Graduation flow

* **testGraduationTriggered / PostGraduationState / GraduationDustClearsReserves / CannotTradeAfterGraduation** – end-to-end migration and lock.

#### Invariants & fuzz

* **testBuyThenSellInvariant** – buy-sell round-trip never yields profit (> fees).
* **testConstantProductInvariant{,AssetToToken}** – (real + virtual) *k* non-decreasing.
* **testMaxBuyInputBehavior / MaxLaunchInputAssetBehavior** – ensures helper caps work under fuzzed params.
* **TaxReceiverNeutrality** – mixed tax inclusion paths.
---

### 6 · Cross-contract integration  (`VirtualLiquiditySweep` – 2 tests)

#### Scenario buckets

* **testGraduateSingleBuy** – for four (vT%, vA%) tuples, launches, tops up SEI, triggers a **single-shot graduation**, checks zero dust and correct flags.
* **testCurveBuckets** – uses 40 staged buys (9 001 SEI total) under different virtual-liquidity settings to chart curve smoothness and ensure no invariant break.

---

### 7 · Overall test coverage

* **Base behaviour**: role-gates, zero-address guards, parameter bounds 
* **Math correctness**: `getAmountOut`, max-buy helper, constant-product invariant 
* **State machine**: launch -> trade -> graduate -> halt 
* **Edge & stress**: zero transfers, 0 % / 100 % tax, fuzz across supply/tax/maxTx 


