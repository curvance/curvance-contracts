# LendingOptimizer.sol — Comprehensive Analysis

## 1. What It Is

LendingOptimizer is an **ERC4626 yield-aggregation vault** that accepts a single underlying asset (e.g. USDC) and distributes it across up to **6 Curvance lending markets** (cTokens) to optimize yield. Users deposit the underlying asset, receive optimizer shares representing proportional ownership, and the vault's authorized harvesters rebalance capital between markets to chase the best supply rates.

**Inheritance chain:**

```
LendingOptimizer
  ├── ERC4626          (tokenized vault standard — deposit/withdraw/mint/redeem)
  ├── PluginDelegable  (delegated actions via CentralRegistry)
  ├── ReentrancyGuard  (nonReentrant + nonReadReentrant modifiers)
  └── ERC165           (interface detection)
```

---

## 2. Lifecycle Overview

### Phase 1 — Deployment

The constructor (`LendingOptimizer.sol:182`) sets:
- Underlying asset, name (`"Curvance USDC Optimizer"`), symbol (`"cUSDC+"`), decimals
- Initial list of approved cToken markets (1–6), each validated for correct underlying and registered market manager
- Allocation caps in WAD (must sum to >= 100%)
- Performance fee (max 50% = 5000 BPS)
- Vesting period (1 second to 3 days)
- Rounding buffer default of 1000 wei
- Exchange rate high watermark initialized at `1e18` (1:1)

**No deposits can occur yet** — `mintPaused` is `0` (uninitialized).

### Phase 2 — Initialization

`initializeDeposits(uint256 targetMarket)` (`LendingOptimizer.sol:248`) must be called by someone with market permissions. It:

1. Transfers 77,777 wei of the underlying asset from the caller
2. Deposits it into the chosen market
3. Mints **dead shares** to `address(0)` equal to the tracked (recoverable) asset amount
4. Sets `mintPaused = 1` (active)
5. Initializes the vesting timestamp

The dead shares permanently lock a small amount of value at the bottom of the share supply, making inflation/donation attacks economically infeasible. This replaces the virtual shares approach some vaults use — the contract explicitly returns `false` from `_useVirtualShares()` and `0` from `_decimalsOffset()`.

### Phase 3 — Normal Operation

Users deposit/withdraw. Harvesters rebalance. Market managers add/remove markets and adjust caps.

---

## 3. Core Mechanisms

### 3.1 Deposits and Withdrawals

All deposit/withdraw paths follow the same pattern:

```
User call -> pause/permission check -> _accrueIfNeeded() -> execute -> state update
```

There are **two variants** of each ERC4626 function:

| Standard (ERC4626) | Targeted |
|---|---|
| `deposit(assets, receiver)` | `deposit(assets, receiver, targetMarket)` |
| `mint(shares, receiver)` | `mint(shares, receiver, targetMarket)` |
| `withdraw(assets, receiver, owner)` | `withdraw(assets, receiver, owner, targetMarket)` |
| `redeem(shares, receiver, owner)` | `redeem(shares, receiver, owner, targetMarket)` |

The standard variants call `optimalDepositTarget()` / `optimalWithdrawalTarget()` to auto-select the best market. The targeted variants let the caller pick.

**Deposit flow** (`_processDeposit` at line 1020):
1. Transfer underlying from caller to optimizer
2. Approve cToken and call `cToken.deposit()` — get `sharesReceived`
3. Convert shares back to assets via `convertToAssets(sharesReceived)` to get `trackedAssets`
4. Calculate optimizer shares from `trackedAssets` (not the original input) to prevent exchange rate drops from cToken rounding
5. Update `_totalAssets += trackedAssets`, then mint optimizer shares

**Withdrawal flow** (`_withdraw` at line 1049):
1. Spend allowance if caller != owner
2. Burn optimizer shares
3. Call `cToken.withdraw()` for the underlying
4. Decrement `_totalAssets`
5. Transfer underlying to receiver

### 3.2 Yield Vesting

This is the most subtle mechanism. The problem it solves: without vesting, an attacker could deposit right before interest accrues and withdraw immediately after, extracting yield disproportionate to their time in the vault.

**How it works:**

All vesting data is packed into a single `uint256` storage slot (`_vestingData`):

```
Bits [0..175]   -> VESTING_RATE  (176 bits, WAD-scaled rate per second)
Bits [176..215] -> VEST_END      (40 bits, unix timestamp)
Bits [216..255] -> LAST_VEST     (40 bits, unix timestamp)
```

`totalAssets()` returns `_totalAssets + _assetsToVest()`, where `_assetsToVest()` linearly interpolates based on elapsed time:

```
if (block.timestamp < vestingEnd):
    vested = vestingRate * (block.timestamp - lastVestingClaim) / WAD
else:
    vested = vestingRate * (vestingEnd - lastVestingClaim) / WAD
```

This means the exchange rate rises **gradually** over `vestingPeriod` rather than jumping instantly.

**New yield detection** only happens when the current vesting period ends. At that point, `_accrueIfNeeded()` compares `rawTa` (actual sum of all cToken positions) against `totalAssets()` (tracked + vested). If `rawTa > totalAssets()`, the difference is the new yield and a new vesting schedule begins.

### 3.3 Bad Debt Detection

During an **active** vesting period (line 1156–1163), if the actual market value drops below what the optimizer expects by more than `roundingBuffer`:

```solidity
if (rawTa + roundingBuffer < ta) {
    emit BadDebtDetected(ta, rawTa, ta - rawTa);
    _totalAssets = rawTa;       // sync to reality
    _setVestingData(0);         // cancel vesting
}
```

The `roundingBuffer` (default 1000 wei, max 10,000 wei) exists because each rebalance operation loses ~2 wei per cToken interaction due to integer rounding in the `assets -> shares -> assets` round-trip. The buffer prevents false positives from these expected rounding losses.

When vesting finishes, any accumulated rounding loss is simply absorbed — `_totalAssets = rawTa` syncs to reality.

### 3.4 Performance Fees

Fees are charged in `_accrueIfNeeded()` (step 4, line 1186–1231) **only when vesting has finished**:

1. Calculate current exchange rate: `currentRate = WAD * totalAssets() / totalSupply()`
2. Compare against `exchangeRateHighWatermark` — if not above it, no fee
3. Calculate profit above watermark: `profit = currentAssets - (highRate * supply / WAD)`
4. Calculate fee: `feeAssets = profit * fee(WAD) / WAD` (rounded up)
5. Mint fee shares to the DAO: `feeShares = feeAssets * supply / (currentAssets - feeAssets)`

This formula ensures the DAO receives shares worth exactly the fee amount. The watermark is then updated to the post-dilution exchange rate, so the same profit is never taxed twice.

Key design choices:
- Fees are only charged on **vested** yield (uses `totalAssets()` not `rawTa`), preventing dilution at vesting boundaries
- The high watermark prevents double-charging after drawdowns recover
- When enabling fees from 0%, the watermark resets to the current rate so prior yield isn't taxed

### 3.5 Optimal Market Selection

**For deposits** (`optimalDepositTarget`, line 716):
- For each market, check if it has cap headroom: `(cap * newTotal / WAD) > currentMarketAssets`
- Among viable markets, pick the one with the **highest projected supply rate** after the deposit
- If no market has headroom, fall back to index 0

**For withdrawals** (`optimalWithdrawalTarget`, line 791):
- For each market, check both: (a) optimizer holds enough cTokens, (b) market has enough idle liquidity
- Among viable markets, pick the one with the **lowest projected supply rate** — withdraw from the weakest performer to preserve yield in better markets
- If no market is viable, revert with `InsufficientLiquidity`

Both use `previewAssetImpact()` (line 875) which queries the market's interest rate model (IRM) to simulate the rate after a hypothetical deposit/withdrawal.

### 3.6 Rebalancing

`rebalance(RebalanceAction[])` (line 435) is harvester-only and processes in **two passes**:

1. **Withdrawal pass**: Pull assets from markets where the harvester wants to reduce allocation
2. **Deposit pass**: Push assets into markets where the harvester wants to increase allocation

Invariants enforced:
- Actions array must match `approvedCTokensList` in length and order (1:1 mapping)
- `intentWithdrawn == intentDeposited` (zero-sum rebalance)
- After rebalance, every market's allocation must be within its cap

---

## 4. Permission Model

| Role | Controlled By | Can Do |
|---|---|---|
| Market Manager | `centralRegistry.hasMarketPermissions()` | `initializeDeposits`, `addApprovedAsset`, `removeApprovedAsset`, `updateCap`, `setFee`, `setMintPaused` |
| Harvester | `centralRegistry.hasHarvestPermissions()` | `rebalance`, `setRoundingBuffer` |
| Users | Anyone | `deposit`, `mint`, `withdraw`, `redeem` |
| Delegates | Approved via `PluginDelegable` | Act on behalf of users for withdrawals (via allowance) |

---

## 5. Key Invariants

1. **Exchange rate monotonicity**: The exchange rate should never decrease for existing holders (absent bad debt). Rounding always favors the vault.
2. **Cap compliance**: After any rebalance, each market's allocation % <= its cap. Sum of all caps >= 100%.
3. **Zero-sum rebalancing**: Total withdrawn == total deposited during rebalance.
4. **Asset tracking consistency**: `_totalAssets` tracks what `_accrueMarkets()` would report, minus unvested yield. The two converge when vesting finishes.
5. **Dead shares**: 77,777 wei worth of shares are permanently locked at `address(0)`, preventing the total supply from ever reaching 0 after initialization.

---

## 6. Rounding Philosophy

cToken interactions involve two rounding operations: `assets -> cToken shares` (rounds down, fewer shares) and `cToken shares -> assets` (rounds down, fewer assets). This means depositing 100 wei and immediately querying the recoverable value might return 98–99 wei.

The optimizer handles this by using `trackedAssets = convertToAssets(sharesReceived)` as the canonical value rather than the user's input. This ensures `_totalAssets` stays synchronized with what `_accrueMarkets()` reports, preventing phantom gains or false bad debt triggers.

---

## 7. Storage Layout Summary

| Variable | Type | Purpose |
|---|---|---|
| `_asset` | `IERC20 immutable` | Underlying token |
| `_name`, `_symbol` | `string` | ERC20 metadata |
| `_decimals` | `uint8 immutable` | Token decimals |
| `approvedCTokensList` | `address[]` | Ordered list of approved markets |
| `allocationCaps` | `mapping(address => uint256)` | Per-market caps in WAD |
| `fee` | `uint256` | Performance fee in BPS |
| `exchangeRateHighWatermark` | `uint256` | Highest exchange rate (WAD) |
| `_vestingData` | `uint256` | Packed: rate (176b) + end (40b) + lastClaim (40b) |
| `vestingPeriod` | `uint256` | Vesting duration in seconds |
| `_totalAssets` | `uint256` | Tracked assets (excludes unvested yield) |
| `mintPaused` | `uint8` | 0=uninitialized, 1=active, 2=paused |
| `roundingBuffer` | `uint256` | Bad debt detection tolerance (wei) |

---

## 8. Security Considerations for New Engineers

1. **Reentrancy**: Every state-changing external function uses `nonReentrant`. View functions like `exchangeRate()` use `nonReadReentrant`.
2. **Inflation attacks**: Mitigated by dead shares at initialization rather than virtual shares.
3. **Frontrunning yield**: Mitigated by the vesting mechanism — yield is dripped over time.
4. **cToken rounding**: Handled by tracking `convertToAssets(sharesReceived)` instead of input amounts.
5. **Bad debt**: Detected during active vesting when losses exceed the rounding buffer; vesting is canceled and `_totalAssets` syncs to reality.
6. **Fee manipulation**: High watermark prevents re-taxing recovered losses. Fees only apply to vested yield.
