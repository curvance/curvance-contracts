# LendingOptimizer Security Audit Results

**Contract:** `contracts/market/optimizer/LendingOptimizer.sol`
**Scope:** Non-elevated permissioned functions (deposit, mint, withdraw, redeem, exchangeRateUpdated, accrueIfNeeded, view functions)
**Date:** 2026-02-06

---

## Summary

| Severity | Count |
|----------|-------|
| High     | 1     |
| Low      | 1     |
| Info     | 0     |

**34 PoC tests written across 3 test files. All 34 pass.**

---

## Finding 1: `_totalAssets` Underflow During Active Vesting Causes DoS on Full Withdrawals

**Severity:** High
**Status:** Confirmed (8/8 PoCs pass)
**File:** `LendingOptimizer.sol`
**Lines:** 832, 1020

### Description

During active vesting, `totalAssets()` (line 832) returns `_totalAssets + _assetsToVest()`, which includes unvested yield. However, `_withdraw()` (line 1020) subtracts assets from `_totalAssets` alone:

```solidity
// Line 832
function totalAssets() public view override returns (uint256) {
    return _totalAssets + _assetsToVest();
}

// Line 1020
_totalAssets -= assets;
```

Since `maxWithdraw()` and `maxRedeem()` (inherited from ERC4626) use `totalAssets()` to compute the maximum withdrawable amount, they return values inflated by `_assetsToVest()`. When a user attempts to withdraw their full entitlement (`maxWithdraw(owner)`), the `_totalAssets -= assets` subtraction underflows because `assets > _totalAssets`.

### Root Cause

`_accrueIfNeeded()` (line 1113) returns early at Step 3 during active vesting WITHOUT updating `_totalAssets`. The unvested yield component (`_assetsToVest()`) inflates the view-layer `totalAssets()` but is never reflected in `_totalAssets` until vesting completes. This creates a window where:

```
maxWithdraw(user) ≈ totalAssets() = _totalAssets + _assetsToVest()
                                   ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
                                   But _withdraw subtracts from _totalAssets only
```

### Impact

- **DoS on full withdrawals:** Any user holding shares during an active vesting period cannot withdraw their full entitlement via `withdraw(maxWithdraw(owner))` or `redeem(maxRedeem(owner))`. The transaction reverts with arithmetic underflow.
- **Weaponizable:** `exchangeRateUpdated()` is permissionless. An attacker can call it after every vesting period ends to start a new one, creating near-permanent DoS on full withdrawals for all users.
- **ERC4626 violation:** The ERC4626 spec mandates that `withdraw(maxWithdraw(owner))` MUST NOT revert. This invariant is broken.
- **Quantified impact:** On a 1M USDC vault with 1-day vesting, the underflow amount scales linearly with vesting progress:
  - At 10% vested: ~4,254 USDC excess
  - At 50% vested: ~21,584 USDC excess
  - At 90% vested: ~38,914 USDC excess

### Workaround

Partial withdrawals that stay below `_totalAssets` still succeed. Users can withdraw in smaller amounts, but this is unreliable since they have no on-chain way to know the exact `_totalAssets` value.

### PoC Tests

| Test | File | Description |
|------|------|-------------|
| `test_vestingExploit_maxWithdrawExceedsTotalAssetsIndexed_causesRevert` | VestingExploit.t.sol | Proves maxWithdraw > _totalAssets during vesting, withdraw reverts |
| `test_vestingExploit_maxRedeemCausesUnderflow_viaRedeemPath` | VestingExploit.t.sol | Same bug via redeem() path |
| `test_vestingExploit_perpetualVestingLocksUsers` | VestingExploit.t.sol | 5 consecutive vesting cycles all block withdrawals |
| `test_vestingExploit_boundaryTiming` | VestingExploit.t.sol | Edge cases at exact vestEnd timestamp |
| `test_vestingExploit_weaponizedDoS_attackerPreventsVictimWithdraw` | VestingExploit.t.sol | Attacker weaponizes permissionless exchangeRateUpdated() |
| `test_vestingExploit_quantifyDoSMagnitude` | VestingExploit.t.sol | Measures underflow at 10/25/50/75/90% vesting |
| `test_vestingExploit_partialWithdrawSucceeds_fullWithdrawFails` | VestingExploit.t.sol | Partial works, full fails |
| `test_vestingExploit_underflowWithPerformanceFees` | VestingExploit.t.sol | Bug persists with 10% performance fee |

### Recommendation

Override `maxWithdraw()` and `maxRedeem()` to cap the returned value at what `_totalAssets` can actually support, or adjust `_withdraw()` to handle the vesting component. For example:

```solidity
function maxWithdraw(address owner) public view override returns (uint256) {
    uint256 ownerAssets = convertToAssets(balanceOf(owner));
    return ownerAssets > _totalAssets ? _totalAssets : ownerAssets;
}
```

---

## Finding 2: `mint()` Mints Fewer Shares Than Requested (ERC4626 Compliance)

**Severity:** Low
**Status:** Confirmed (2/2 PoCs pass)
**File:** `LendingOptimizer.sol`
**Lines:** 965-973, 981-1002

### Description

When a user calls `mint(shares, receiver)`, the function:
1. Computes `assets = previewMint(shares)` (line 970)
2. Calls `_processDeposit(assets, receiver, targetMarket)` (line 972)

Inside `_processDeposit`, the actual shares minted are recalculated:
1. `trackedAssets = _depositToMarket(targetMarket, assets)` (line 990) - can be less than `assets` due to cToken rounding
2. `shares = convertToShares(trackedAssets)` (line 994) - recalculated from the reduced `trackedAssets`

The recalculated shares can be 1 less than the originally requested amount. The user pays `previewMint(shares)` worth of assets but receives `shares - 1` shares.

### Impact

- **Per-call impact:** At most 1 share shortfall per `mint()` call (~1-2 wei in asset terms)
- **Accumulation:** Over 50 `mint()` calls, the accumulated shortfall is 50 shares
- **ERC4626 spec:** The spec states mint() MUST mint exactly the requested number of shares. The current implementation violates this.
- **Real-world significance:** Minimal. The overpayment per call is ~1-2 wei, which is economically negligible.

### PoC Tests

| Test | File | Description |
|------|------|-------------|
| `test_exploit_mintGivesFewerSharesThanRequested` | SharePriceExploit.t.sol | 1 share shortfall on mint of 500K shares |
| `test_exploit_mintDiscrepancyAmplification` | SharePriceExploit.t.sol | 50 shortfall over 50 calls, ~50 wei value |

### Recommendation

In the `_mint()` function, after `_processDeposit`, check if the actual shares minted are less than requested. If so, either revert or mint the difference. Alternatively, document this as a known deviation from ERC4626 strict compliance due to cToken rounding.

---

## Confirmed Defenses (Attack Vectors That Were Tested and Found Non-Exploitable)

### 1. Cross-Market Arbitrage: Not Exploitable

Depositing into market A and withdrawing from market B does not yield profit. The optimizer uses global `_totalAssets/totalSupply` accounting, so share prices are independent of per-market cToken rates. All 9 cross-market pair combinations were tested with zero profit.

**Tests:** `test_crossMarket_depositMarketA_withdrawMarketB_noProfit`, `test_crossMarket_lowRateDeposit_highRateWithdraw_noArbitrage`, `test_crossMarket_roundTripAllPairs`

### 2. Fee Dilution via Large Deposits: Defended

`_accrueIfNeeded()` runs inside `deposit()` BEFORE processing the deposit. Performance fees are charged on existing shareholders' yield before any new shares are minted, preventing dilution.

**Tests:** `test_feeDilution_largeDepositBeforeFeeAccrual`, `test_exploit_largeDepositDilutesFees`

### 3. Sandwich Attack Around Fee Accrual: Defended

Front-running a fee accrual with a large deposit and back-running with immediate redeem results in a loss (not profit) for the attacker, because fees are charged atomically before deposit processing.

**Tests:** `test_exploit_sandwichFeeAccrual`

### 4. Rounding Exploitation via Rapid Deposit/Redeem Cycles: Defended

50 rapid deposit/redeem cycles result in a total loss of ~50 wei for the attacker (1 wei per cycle). Rounding consistently favors the vault. Exchange rate never decreases.

**Tests:** `test_exploit_rapidDepositRedeemRounding`, `test_exploit_roundingWithAdversarialAmounts`

### 5. Exchange Rate Monotonicity: Confirmed

Exchange rate never decreases across complex sequences of deposits, withdrawals, vesting cycles, and fee accruals (tested over 5 vesting cycles with 3 users).

**Tests:** `test_invariant_exchangeRateMonotonicity`

### 6. Deposit During Active Vesting: Fair

A user depositing mid-vesting earns yield proportional to their time in the vault. The vesting mechanism prevents flash-loan-style instant yield capture. The longer-deposited user always earns more yield.

**Tests:** `test_exploit_depositDuringActiveVesting`

### 7. Cap Bypass via Targeted Deposits: By Design

Users can push a market above its allocation cap via targeted `deposit(assets, receiver, market)`. This is documented as intentional - allocation caps are only enforced during `rebalance()`. No accounting issues result.

**Tests:** `test_capBypass_targetedDepositExceedsCap`, `test_capBypass_doesNotBreakWithdrawals`

### 8. Multi-User Market Draining: Handled

One user draining a market via targeted withdrawal does not prevent other users from withdrawing via auto-routing to markets with remaining liquidity.

**Tests:** `test_multiUser_drainOtherUsersMarket`, `test_multiUser_largeWithdrawalAccountingConsistency`

### 9. Post-Bad-Debt Deposit Timing: Fair

Depositing after bad debt detection gives shares at the reduced exchange rate. This is correct behavior - the depositor takes on risk at fair pricing.

**Tests:** `test_badDebt_postBadDebtDeposit_fairSharing`

### 10. Watermark Monotonicity: Confirmed

The exchange rate high watermark never decreases across multiple vesting cycles, ensuring fees are never double-charged.

**Tests:** `test_feeCharging_watermarkMonotonicity`

### 11. ERC4626 Rounding Direction: Correct

`convertToShares` rounds down, `previewWithdraw` rounds up, `previewMint` rounds up - all favoring the vault as required by ERC4626.

**Tests:** `test_erc4626_roundingDirectionConsistency`, `test_erc4626_previewDepositAccuracy`, `test_erc4626_previewMintAccuracy`

---

## Test File Summary

| File | Tests | Pass | Fail |
|------|-------|------|------|
| `tests/market/optimizer/VestingExploit.t.sol` | 8 | 8 | 0 |
| `tests/market/optimizer/SharePriceExploit.t.sol` | 12 | 12 | 0 |
| `tests/market/optimizer/CrossMarketExploit.t.sol` | 14 | 14 | 0 |
| **Total** | **34** | **34** | **0** |

### Running the Tests

```bash
forge test --match-path "tests/market/optimizer/VestingExploit.t.sol" -vv
forge test --match-path "tests/market/optimizer/SharePriceExploit.t.sol" -vv
forge test --match-path "tests/market/optimizer/CrossMarketExploit.t.sol" -vv
```

Requires `MON_NODE_URI_MONAD_MAINNET` environment variable set to a Monad mainnet RPC endpoint.
