<p style="text-align: center;width:100%"> <img src="https://pbs.twimg.com/profile_banners/1445781144125857796/1752160592"/></p>

<h1> <img style="text-align: center; height: 18px" src="https://user-images.githubusercontent.com/77558763/148961492-99d86d51-41a3-45a8-9af6-bdc1a85c722b.png"/> Isolated Markets</h1>

## Overview

This document contains information regarding how Curvance markets function regarding dependencies, execution, and asset support inside the Curvance Protocol ("Curvance").

## Solidity Versioning

All contracts are written using Solidity 0.8.28, this is for usage of tstore/tload opcodes and our enshrined usage of the Atlas Execution Environment (AEE). 

## Market Positioning and design methodology

Curvance markets are extremely opinionated in their design and are not intended to compete with more generalized models like Aave or curation platforms like Morpho 
or Euler. Curvance isolated markets by design support two tokens, which can have one or two borrowable tokens, but not zero. Any token can be collateralized inside 
Curvance, but not all tokens need to be borrowable. These two tokens are listed simultaneously on calling `listTokens()` and can not be changed afterwards, once a token
becomes collateralizable or borrowable it cannot be disabled, though this functionality can be paused for new entrants via changes to collateral/debt caps and/or direct pausing of corresponding actions via the Market Manager.

Curvance focuses heavily on optimizing liquidations through bundled execution, cached state reads, and compressed storage variables through transient storage, 
packed bitshifting, and packed structured variables. The purpose of cheap liquidations is to substantially increase the level of leverage offered by the platform 
as well as the ability to support nascent assets safely.

## Asset Support

```
Unique assets with esoteric functionality such as:
- Rebasing tokens
- ERC777 transfer on hook
- Dual-entry point tokens
- Abnormal token decimals (This is measured via decimals < 6 and decimals > 24)
- Extremely low value tokens due to extremely high total supply (This is measured as > 10T supply)
- Extremely high value tokens due to extremely low total supply (This is measured as < 1000 supply)
- Time-locked liquidity assets
- Fee on transfer tokens

Are all intentionally not considered in protocol design.
```

## Enforced holding periods

Curvance introduces an additional protective layer for extremely short term price manipulation. When a user account collateralized a Curvance token and/or borrows against 
collateralized assets, a 20 minute cooldown period is applied. This cooldown period prevents redemption of collateral assets and repayment of debt. The purpose of this is 
to minimize the impact of extremely aggressive orderflow skewing asset prices (toxic flow). It is important to note that this does not impact the ability of a user to add 
additional collateral as margin or the liquidation of an accounts assets if prices move against them very quickly.

## Minimum Loan Size

Every Curvance market has a corresponding minimum loan size configured in WAD dollars. This is set per market within a permitted range of $10–$100 (WAD). Deployments commonly use $10 on lower-cost chains. This check applies when opening new loans and when partially repaying if the remaining debt would be non‑zero; full repayments are always allowed.

## Asset Pricing

All assets when priced for liquidity checks are measured in dollars, this is enforced by all calls to 📄 `OracleManager.sol` with the input inUSD = true. 
Every asset can be configured with up to two oracle feeds, examples include but are not limited to:

```
- Chainlink Price Feeds
- Chainlink Data Streams
- Redstone Classic
- Redstone Core
- Pyth Price Feeds
- Chainsight Price Feeds
```

Every oracle feed is normalized to return prices, in 18 decimal form (WAD) dollars, if an oracle feed cannot report a price, or the differential in value between 
the two oracle feeds is too large, an error code can be returned. For the simplicity:

### Error Codes

```
Δ = Delta, or differential between values.

- Error Code = 0/NO_ERROR: No oracles had any issues in pricing and the Δ was small, every market functionality is allowed.
- Error Code = 1/CAUTION: Either one of two oracle prices ran into issues in pricing or the Δ was moderate; new borrows, partial repayments
  that leave residual debt, and collateral-removing redemptions are paused. Full debt-closing repayments can proceed.
- Error Code = 2/BAD_SOURCE: All oracle prices ran into issues in pricing and/or the Δ was large; new borrows, partial repayments that leave
  residual debt, collateral-removing redemptions, and liquidations are paused. Full debt-closing repayments can proceed.
```

### Pessimistic pricing

When using oracle prices, Curvance always sides in favor of lenders. This is done by taking the more conservative of the two prices when valuing 
an account's liquidity. When valuing an asset posted as collateral the lower of the two prices will be used, when valuing an outstanding debt position to lenders 
the higher of the two prices will be used. The impact of this is relatively small in periods of low volatility while becoming impactful in periods of high volatility 
such as liquidation cascades.


## Liquidations

Curvance implements a far more complex liquidation system that is generally referred to as the DLE. The DLE features:

```
- A dual path liquidation system allowing for both auction-based liquidations and traditional liquidations.
- Native MEV capture of excessive liquidation penalties via orderflow auctions.
- Bundled liquidations which are rolled up into a single debt repayment.
- Native bad debt socialization to lenders to prevent bank runs.
- Cached token configuration and oracle price reads.
- Runtime dynamic liquidation values via transient storage for auction-based liquidations.
- Dynamically scaling liquidation penalties and close factors via a runtime calculated liquidation factor (lFactor) 
  for traditional liquidations.
- Exact or optimistic traditional liquidations.
```

### Auction-based Liquidations

Auction-based liquidations are the "primary" liquidation path inside Curvance. Auction-based liquidations are built in collaboration with Fastlane Labs and their AEE. 
Auction-based liquidations have a slight priority against traditional liquidations (market-dependent: 10 bps for correlated markets, 50 bps for uncorrelated markets) which acts as a discount on account collateral when compared to their outstanding debt obligations. Auction-based liquidations also have priority via backrunning oracle updates, currently built through Redstone oracle feeds.

```
The workflow of an auction-based liquidation follows the steps:
1. An account enters soft liquidation range for an auction-based liquidation.
2. Any prospective liquidation can start an auction offchain with the Atlas sdk.
3. The created auction is desired for all combinations of collateral and Curvance market. The bids are then isolated to 
   each unique collateral and market via the ordering rule highlighted in `AuctionManager_README.md`.
4. The auction determines a winner after 300 milliseconds.
5. The Fastlane bundler can then execute the liquidation via account abstraction to the AEE.
6. This includes the winning bid as well as several sequential bids (up to 10 total) incase there is left over liquidity 
to liquidate, or the tx includes multiple auctions for different collateral tokens.
7. The AEE then calls the Curvance Auction Manager setting up an auction-based liquidation configuration including 
   unlocking the market and collateral for liquidation, optionally dynamic liquidation values such as liquidation penalty 
   and close factor. 
8. The liquidation is then allowed within that call, conditional on the liquidator transferring the agreed upon 
   bid (currently in native gas tokens) back to the AEE which then transfers it to the Curvance Auction Manager.
9. Sequential auction-based liquidations can be executed in a singular meta call (repeating steps 6 - 8). Transient storage
   resets back to empty slots at the end of the transaction locking down auctions until a new auction-based liquidation is
   executed.

Additionally, auction-based liquidations follow all the additional checks and execution logic highlighted below in 
`Traditional Liquidations`.
```

### Traditional Liquidations

Traditional liquidations are intended to be used as a fallback when auction-based liquidations are either too slow (high volatility), or Atlas somehow cannot complete an auction. As highlighted above, traditional liquidations have an extra hurdle for approved execution when compared to auction-based liquidation, the `AUCTION_BUFFER` (10 bps for correlated markets, 50 bps for uncorrelated markets) which is applied to the accounts collateral value when viewed against soft liquidation thresholds. Traditional liquidations leak MEV like every 
overcollateralized protocol does today. When compared to traditional models, these traditional liquidations are still vastly superior in the ability to keep marginal 
execution costs low due to its bundling structure.

```
The workflow of a traditional liquidation follows the steps:
1. An account or accounts enters liquidation range for the liquidation of some collateral against their 
   outstanding debt obligation(s).
2. A liquidator can call liquidate() or liquidateExact() on the corresponding borrowableCToken (Borrowable 
   Curvance token which gives its underlying asset tokens to borrowers).
3. The liquidation call includes a particular Curvance Token (cToken) posted as collateral to be liquidated 
   and then account(s) to be liquidated. If calling liquidateExact() the debt obligations to repay are provided 
   in `assets` denomination. The cToken to be liquidated CANNOT be the borrowableCToken owed as its implicitly 
   enforced within the protocol that users cannot borrow from a cToken they also are posting as collateral 
   themselves.
4. The liquidation states of all accounts are then reviewed via the `MarketManager` calculating whether a 
   liquidation is possible and if so, how much debt and collateral can be liquidated. For liquidateExact() 
   calls if the allowed debt repayment is more than the value provided in the exact call then the liquidation 
   reverts. The magnitude of collateral that can be liquidated and the penalty paid to liquidators is determined 
   by the `lFactor` which scales from a soft liquidation with a moderate penalty and liquidation size, to a hard 
   liquidation which completely liquidates an account with a huge penalty. Any accounts who cannot be liquidated 
   are merely skipped, if no accounts can be liquidated the entire operation reverts. Because of this a liquidator 
   may think that includes a huge number of accounts who potentially can be liquidated makes sense, however this is 
   not the case as the network gas cost of liquidation will increase without any additional rewards due to the 
   additional logic processessing costs.
5. For all accounts who can be liquidated their debt repayment is bundled with all other accounts liquidated into a 
   singular repayment (E.g. 10 users who will have $100 of usdc debt obligations repaid will have it done as a 
   singular $1000 usdc debt repayment to the borrowableCToken contract), their collateral is then individually 
   transferred to the liquidator.
6. Corresponding events are emitted for all frontends to pick up that liquidation(s) have occurred.
```

## Crosschain

Curvance is often described as a multichain liquidity hub. A reasonable mistake many make is assuming that Curvance markets communicate with one another crosschain. This 
is not the case, while this sounds compelling in theory it creates downstream issues across network reorganization, fee market congestion, and increased execution costs. 
Curvance's crosschain user execution is facilitated by its plugin system which allows for pre/post execution of crosschain bridging.

As an example, a user collateralizes WBTC on Ethereum Layer 1, then borrows USDC via a Mayan Swift plugin that takes the borrowed USDC and bridges it to HyperEVM in the same transaction. The experience for users is essentially the same while vastly improving the security model of Curvance.

## Additional Information

*Last updated: 11/23/2025*

*Maintained by: Curvance Core Team*


