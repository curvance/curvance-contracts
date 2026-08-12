# Lending Optimizer Integration and Operations

This document defines the launch and integration constraints for a
`LendingOptimizer`. It supplements the contract's runtime checks; it does not
replace source review or chain-specific risk approval.

## Dependency rule

An approved borrowable cToken must not have any collateral or valuation path
that returns to the optimizer being funded. The rule applies transitively
through cTokens, receipt tokens, vaults, LP components, and oracle quote assets.

The optimizer's `_validateCToken()` check is narrower. It verifies
the underlying, borrowable status, market registration, and listing, then rejects
a listed sibling only when that sibling's immediate `asset()` is the optimizer.
It does not prove that a deeper dependency graph is acyclic.

For an optimizer `O` and borrowable market `D`, this independent topology is
supported:

```text
O -> D -> collateral C -> terminal assets independent of O
```

These direct and nested self-dependencies are prohibited:

```text
O -> D -> optimizer-share cToken C1 -> O
O -> D -> receipt cToken C2 -> optimizer-share cToken C1 -> O
```

A path through a `VaultAggregator`, LP component, Uniswap quote token, Pendle
quote asset, another optimizer, or a future receipt-token type is also
prohibited when following the path reaches `O`. Undeclared unknown node types,
asset-ancestry cycles, or a walk that exceeds the verifier's supported bounds
fail closed. An
opaque contract exposing none of the verifier's known dependency selectors can
only be accepted through an explicit terminal attestation; that classification
remains an operator review responsibility.

## Verification responsibility

Two read-only scripts cover different parts of the dependency graph:

- `script/deployment/VerifyLendingOptimizerLaunch.s.sol` verifies exact
  optimizer configuration and walks the connected Curvance cToken graph: it
  follows `ICToken.asset()` ancestry and expands every reached cToken's full
  MarketManager sibling listing. The optimizer underlying is an implicit
  terminal; every other valid terminal must be declared in the exact, reviewed
  terminal-asset attestation. The walk rejects optimizer reachability,
  asset-ancestry cycles, unregistered or mismatched cTokens, unknown
  nonterminal contracts, more than 64 unique cTokens, and receipt ancestry
  deeper than eight nodes. A declared terminal is also rejected when it exposes
  a known `asset()`, `underlying()`, `token0()`, or `token1()` dependency
  surface. This is a conservative structural overapproximation: every reached
  cToken's listed siblings are expanded even when that reached cToken is not
  borrowable; the configured approved markets are separately required to be
  borrowable.
- `script/deployment/VerifyOptimizerShareDeScope.s.sol` verifies the maintained
  oracle and integration manifests, including market cTokens, vault
  aggregators, LP components, Uniswap quote tokens, and Pendle quote assets.

Both scripts are required, but they do not override one another. The launch
verifier currently admits only registered Curvance cToken ancestry ending in
plain reviewed terminals. It rejects known LP and wrapper surfaces rather than
expanding them, even when the separate de-scope manifest is otherwise valid.
Supporting such a listed-token dependency requires adding typed closure support
to the launch verifier; passing the de-scope verifier alone is not an exception.

The de-scope verifier validates declared route endpoints but does not recursively
expand each endpoint. If an LP component or quote asset is itself a receipt
token or depends on another integration, operators must trace it to independent
terminals and extend the relevant verifier before approval.
Operators must extend the relevant manifest and verifier before approving an
unmodeled receipt or pricing type; unknown graph edges must not be waved through
as terminals.

Passing the optimizer's constructor or `addApprovedAsset()` is not proof of
transitive safety. A verifier result is valid only for the inspected chain,
block, contract code, market pairings, terminal manifest, and oracle
configuration.

## Launch and change checklist

1. Freeze the expected optimizer address, underlying, registry, fee, ordered
   markets, WAD-scaled allocation caps, terminal assets, and de-scope manifests.
2. Ensure every candidate market and its token pair are deployed and listed; the
   launch verifier is a post-listing chain-state verifier.
3. After optimizer deployment and before `initializeDeposits()`, run both
   verifiers. Archive their inputs, block number, and output.
4. Initialize only after both checks pass. Immediately read back and archive the
   initialized state and dead-share reserve.
5. Before `addApprovedAsset()`, simulate the proposed addition on a current fork
   and run both verifiers there. Pause deposits before the live addition and do
   not rebalance or otherwise seed the new market until chain-state readback
   passes.
6. Rerun the launch verifier after approved-market changes or after any reached
   cToken's MarketManager, sibling listing, or receipt ancestry changes. Rerun
   the de-scope verifier after any vault, LP, Pendle, Uniswap quote,
   allowed-adaptor, or oracle-route configuration change.
7. Monitor code and configuration against both verified manifests. Treat drift
   as a new integration requiring reapproval.

## Freshness boundary

`totalAssets()`, `exchangeRate()`, conversions, previews, and max methods are
view-only estimates built from cached optimizer and cToken state. User share
actions and rebalances accrue approved markets before settlement, but a raw view
does not recursively refresh an arbitrary wrapper or pricing graph.

Do not use a raw optimizer view as authoritative collateral or credit state.
Force stateful accrual in the same atomic execution as the final authoritative
read, or use an integration whose stateful path explicitly accrues the
optimizer. The direct
`LendingOptimizerShareCToken` does so in `_accrueIfNeeded()`; adding another
view-only receipt layer above it does not inherit that guarantee automatically.

Credit impairment has a separate timing boundary. Borrower health can be
negative while a borrowable cToken still accounts for the loan at par. The loss
reaches optimizer NAV only when the cToken recognizes it, such as during
liquidation and bad-debt accounting.

## Withdrawals and loss recognition

Withdrawals are weighted by each cToken position and capped by its available
cash. A shortfall in one market is redistributed to other approved markets with
spare liquidity. This pooled-liquidity behavior improves ordinary exit
availability.

It also means an exit can be funded by healthy-market cash before an impaired
cToken recognizes its loss. If that loss is recognized later, remaining holders
own the resulting concentration. The contract's rounding-adjusted share burn
prevents dilution from cToken conversion rounding only; it does not provide
real-time loan-loss realization.

Operators should coordinate liquidation and any emergency redemption pause when
a material impairment is known but not yet recognized. This is an operational
control, not a complete substitute for queued or batched loss settlement.

## Allocation caps

Allocation caps constrain post-rebalance and post-removal allocations. They are
not continuous hard limits on live exposure. Different market yields, donated
cTokens, and other balance changes can move a market above its configured cap.
Normal deposits are routed according to current allocations and can preserve an
already over-cap ratio.

Monitoring must compare live per-market positions with caps. A keeper rebalance
is required to restore an allocation; updating a cap alone does not move assets.

## Performance fee rounding

Performance fees apply only above the exchange-rate high watermark. The
high-watermark asset baseline rounds up, while fee assets and minted fee shares
round down to atomic units. Permissionless accrual can therefore advance the
watermark when an individual positive fee increment is too small to mint a fee
share, permanently forgiving that dust amount.

This is accepted V1 revenue rounding, not a user-principal loss. Accounting and
monitoring must not assume the configured fee percentage is exact at atomic
precision, and callers should not attempt to batch or delay accrual to change
fee collection.
