# AuctionManager

## Overview
- Determine market driven liquidation bonuses unique to each pairing of pool + collateral asset.
- Execute these liquidations at a close factor set by the DappControl (initially static but dynamic in the future).
- Have priority to liquidations triggered by interest accrual as well as oracle updates.

This service is exposed to Curvance in the form of an “oracle for risk parameters”, specifically an oracle for the close factor and liquidation penalty. Whenever Curvance is processing a liquidation, they can read from the “risk oracle” to determine the liquidation penalty and close factor to offer.

Rather than determining a single risk parameter to deliver to Curvance, the service actually functions as an application-specific ordering rule. Liquidators are ordered from lowest to highest liquidation bonus, and in a single Atlas tx, the liquidation bonus that the application reads from the “risk oracle” will be modified for each liquidator. This is accomplished by using the multipleSuccessfulSolvers config in Atlas. In the future this ordering rule can become more complex and take close factor bids into account as well.

The service functioning as an ordering rule is a hard requirement to avoid a case where a solver bids the minimum penalty, only to not perform the liquidation in the SolverOp, in hopes of performing a more profitable liquidation by backrunning the Atlas tx. This attack would be free for the solver to perform (aside from gas costs); and Atlas would be unable to revert the solverOp for doing this because in this case there is no clear concept of “was the bid amount paid”, because the bid amount being paid is implicitly performed by actually doing the liquidation at the given liquidation penalty. Atlas has no easy way of determining if the liquidation was actually performed. For this reason Atlas will allow all Solvers to execute, meaning if one Solver attempts this attack, it is likely there will be one honest solver following them that will do the liquidation. This design gives us the property of only needing one honest solver. 

There is also a secondary benefit of this approach where smaller accounts can be liquidated at smaller liquidation penalties, and larger accounts can be liquidated at larger penalties in a following SolverOp.

## Requirements 
1. This service should operate without any changes to RedStone data feed implementations.
2. This service should build seamlessly on top of the existing RedStone OEV Relayer logic.

### Understanding Potential Data Feed Requirements

- The protocol may or may not require a data feed that is unique to that application to avoid distorting app specific risk parameters with liquidations on other apps. Imagine a scenario where a liquidator bids for a liquidation penalty of .01% on Curvance because this gives them priority to liquidations on another application. The outcome of this actually appears benefitial to Curvance because in effect they capture value from the other app, so this may be OK.
- If another protocol shares a data feed with Curvance, but this other protocol wants OEV capture, then this appears to be in-compatible. This is a similiar problem to OEV v1 where the oracle must calculate off-chain which app deserves which proceeds; although in this scenario much of the proceeds may be atomically paid out to Curvance users in the form of a lower penalty, rendering this seemingly not possible.

So the requirement seems to be that Curvance can use the same data feed as another app, only if this other app does not get any OEV capture.

## Auction Priority Mechanisms

This section will outline exactly how Atlas auctions are awarded priority to Curvance liquidations.

1. Backrunning oracle updates.
2. Curvance has given Atlas auctions a slightly earlier liquidation threshold than everyone else (~5 bips), just enough to give Atlas priority in liquidations triggered by causes other than the oracle such as interest accrual. This is a built-in “early bird” access to all liquidations for Atlas, setting this at 5 bips should be just enough to give Atlas priority to interest triggered liquidations, but in most cases will not suffice for priority to oracle driven liquidations.

The DappControl must allow UserOps that update a data feed, and no-op UserOps without a data feed update.

## DappControl as a Whitelisted Data Feed Updater

RedStone, as part of the integration process, must whitelist the OEV DAppControl smart contract  as a whitelisted updater of the RedStone data feed. Only a single entity will be able to trigger a data feed update via this DAppControl. This entity will be the assigned Atlas auctioneer EOA, who is also the assigned Atlas UserOp generator EOA. Note that multiple Bundler EOAs are allowed to be the tx.origin of a transaction that performs a data feed update via the DAppControl for performance reasons, but doing so always requires a valid signed UserOp and DAppOp pairing from the Auctioneer EOA. Furthermore, the Auctioneer EOA assigns a single Bundler the rights to do the data feed update transaction on a per-transaction basis, and no other party can perform that given data feed update.  

### **Implementation Details**

- Upon deployment of the OEV DAppControl, the governor EOA of the DAppControl must call setAuthorizedUserOpSigner() on the DAppControl, and provide the address of a single EOA that is allowed to generate UserOps that update the RedStone data feed. During the setAuthorizedUserOpSigner() function call, the DAppControl will query Atlas, and receive the ExecutionEnvironment address that is matched to the provided UserOp signer and the given DAppControl. Any data feed updates via the DAppControl will validate that the msg.sender is this ExecutionEnvironment.
- Upon deployment of OEV DAppControl, the governor EOA of the DAppControl must call AtlasVerification.initializeGovernance() for the given OEV DAppControl. The governor EOA must then also call AtlasVerification.addSignatory() for the given OEV DAppControl, and provide the EOA of the Atlas auctioneer. By setting userAuctioneer to false in the OEV DAppControl config, Atlas Verification will now validate that any calls to update the data feed via the DAppControl must include a DAppOp signed by the EOA of the Atlas auctioneer.
- Additional validations are in the preOps hook of the DAppControl, and validate that userOp.from is the authorizedUserOpSigner.

## Curvance Risk Parameters Modifiable by DappControl

These risk parameters are unique to each isolated pool (Isolated Market Manager):

- Liquidation Penalty
- Close Factor

## Enforcement of liquidation penalties specific to each market + collateral

Atlas liquidators when they place a bid must also specify the market and collateral they want to liquidate. If they want to liquidate across two markets or collaterals, they must place a bid for each (using a different EOA). To do this, solvers must encode (market, collateral, and liquidation penalty) in their solverOp data in the required format for us to extract it. In each preSolver hook, DappControl will notify Curvance the exact market and collateral that the bid was placed for, allowing Curvance to block all liquidations to other markets or collaterals.

**preSolver flow**:

1. Extract market, collateral, and liquidation bonus from solverOp data.
2. Call Curvance Central Registry to unlock the specific market, thus blocking all other markets.
3. Call the given Curvance Market Manager to unlock the specific collateral, thus blocking all other collaterals.
4. Update the liquidation bonus of the given market to the liquidators bid.

Only one market and collateral can be unlocked at a given time on Curvance, meaning if one is unlocked all the others are locked. Each preSolver call that unlocks a new market and collateral with thus lock the previous market and collateral from the prior solverOp.

Note: The action of unlocking collateral on a market is what gives Atlas an early liquidation threshold. 

## Implementation of auxillary bid types/logic in Atlas

To allow solvers to supply these auxillary bids in the form of: liquidation penalty, market, collateral; solvers will be required to attach this information in a pre-set way to their SolverOp.data. The Auctioneer can then decode each SolverOp.data to understand the bids each solver is placing, and the DappControl can do the same logic on-chain to extract the auxillary bid data.

## Auction Enforcement Implementation

Before any liquidation Curvance does the following checks:

1. Checks to see if the given market is unlocked.
2. Checks to see if the collateral chosen by the liquidator is unlocked.

Cases:

1. If both checks return false -> return 0 auction buffer (i.e no priority given to Atlas).
2. If 1 check returns true -> revert (do not allow the liquidation 
3. If both checks return true true -> return 10 bps auction buffer (priority given to Atlas).

Case 1: This case will occur when it is not an Atlas tx, so allow liquidations to proceed using standard liquidation threshold and standard liquidation bonus + close factor calc.

Case 2: This case will occur only when it is an Atlas tx, but the liquidator is attempting to liquidate a market or collateral which they have not been given permission for, so revert the liquidation.

Case 3: This case will occur during an Atlas tx where the liquidator is executing on the market + collateral allowed, so give the liquidator the early liquidation threshold, and pull values for the bonus and close factor from the dynamic Atlas parameters set in the preSolver. 

## Risk Oracle Constraints Implementation

### Constraining Atlas from setting risk parameters that are either deemed too high or too low

- Risk Oracle close factor must be within the bounds of the min and max values of the underlying default Curvance liq engine.
- Risk Oracle liquidation penalty must be within the bounds of the min and max values of the underlying default Curvance liq engine.

These checks will be enforced during the preSolver hook where DappControl attempts to set the parameters.

### Constraining Atlas risk parameters to only apply to Atlas txs

Another key concept here is that the dynamic risk parameters set by Atlas within Curvance only live within transient storage. This prevents a couple risks by using transient storage to have the EVM natively guarantee that the risk parameters or collateral/market unlocks set by Atlas will revert to defaults as soon as the Atlas tx has completed:

1. Where Atlas sets the liquidation penalty extremely low, and does not successfuly reset it back to the default; potentially causing non-Atlas liquidations to be unprofitable.
2. Where Atlas unlocks a given market + collateral, if this were to remain post an Atlas tx liquidators could not liquidate any other collateral or markets outside of an Atlas tx. 

## Sequencing Rule

For each market + collateral pair, bids are ordered by lowest liquidation penalty first. The ordering of market + collateral pairs initially can be random. The auctioneer must gather all bids and group them into a unique market + collateral bucket. 

Take the following bids as an example:

Solver A: bidding for BTC/ETH market and BTC collateral at 2% penalty.

Solver B: bidding for BTC/ETH market and ETH collateral at 1% penalty.

Solver C: bidding for BTC/ETH market and BTC as collateral at 1.1% penalty.

Solver D: bidding for BTC/ETH market and ETH as collateral at 2% penalty.

Solver E: bidding for BTC/USD market and BTC as collateral at 2% penalty.

Solver F: bidding for BTC/USD market and USD as collateral at 1% penalty.

Solver G: bidding for BTC/USD market and BTC as collateral at 1% penalty.

They would first be grouped and ordered like so by the auctioneer (order of markets + collateral is random):

**BTC/ETH market + BTC collateral**

1. Solver A: bidding for BTC/ETH market and BTC collateral at 1% penalty.
2. Solver C: bidding for BTC/ETH market and BTC as collateral at 1.1% penalty.

**BTC/ETH market + ETH collateral**

1. Solver B: bidding for BTC/ETH market and ETH collateral at 1% penalty.
2. Solver D: bidding for BTC/ETH market and ETH as collateral at 2% penalty.

**BTC/USD market + BTC collateral**

1. Solver G: bidding for BTC/USD market and BTC as collateral at 1% penalty.
2. Solver E: bidding for BTC/USD market and BTC as collateral at 2% penalty.

**BTC/USD market + USD collateral**

1. Solver F: bidding for BTC/USD market and USD as collateral at 1% penalty.

The final ordering of the solvers in multiple successful solvers would then be:

1. Solver A: bidding for BTC/ETH market and BTC collateral at 1% penalty.
2. Solver C: bidding for BTC/ETH market and BTC as collateral at 1.1% penalty.
3. Solver B: bidding for BTC/ETH market and ETH collateral at 1% penalty.
4. Solver D: bidding for BTC/ETH market and ETH as collateral at 2% penalty.
5. Solver G: bidding for BTC/USD market and BTC as collateral at 1% penalty.
6. Solver E: bidding for BTC/USD market and BTC as collateral at 2% penalty.
7. Solver F: bidding for BTC/USD market and USD as collateral at 1% penalty.