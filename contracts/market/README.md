# Curvance OEV Documentation

## High Level

- Prioritize the winning liquidators of OEV auctions for a small period before falling back to the status quo liquidations without an auction.  
- Liquidations from OEV auction winners occur immediately and atomically after verifying that the `tx.origin` is a whitelisted auctioneer/bundler.  
- Whitelisted auctioneer/bundlers can include multiple liquidations from a permissionless set of liquidators in a single atomic tx.  
- If OEV auctions are offline then non-auction liquidations can occur after a queueing process (small delay).  
Any downtime in the OEV auction will only cause Curvance to be unable to capture OEV, without direct risk to user funds.  

### Chain of events if OEV auctions are online and successful:

**Block N:**  
- **Tx 1:** Oracle update(s) land on-chain.  
- **Tx 2:** OEV winning liquidators can now liquidate immediately, and atomically without queuing after the auctioneer/bundler passes `tx.origin` check.  

### Chain of events if OEV auctions are offline/all Atlas liquidators fail:

**Block N:**  
- **Tx 1:** Oracle update(s) lands.  
- **Tx 2:** OEV auctioneer lands a tx but all liquidations fail, or maybe no OEV tx is landed.  
- **Tx 3:** Liquidator A lands `queueLiquidation()` tx to enable fallback liquidations.  

**Block N + 1:**  
Liquidator A waits for the priority duration to pass.  

**Block N + 2:**  
- **Tx 1:** The priority duration has passed so Liquidator A can now liquidate.  

**Block N + 3:**  
- **Tx 1:** The regular duration has now passed so any liquidator can now liquidate without ever having called `queueLiquidation()`.  

---

## Auctioneer Overview

Fastlane will operate the auctioneer role, which encompasses both off-chain components, and on-chain smart contracts.  

### Off-chain Components for Auctioneer

Fastlane will operate an off-chain service that can conduct an auction when there are price changes to Curvance data feeds. This service will receive bids from liquidators in the form of signed AA-like “operations”. These operations include the bid amount, and all the necessary data to call into the liquidators smart contract. After an auction period concludes of ~300ms, the auctioneer will select the 5-10 highest bidding “operations”. The auctioneer will then generate a single atomic tx with itself as the `tx.origin`, that includes all 5-10 selected “operations”, and execute this tx on the Atlas Entrypoint contract.  

### On-chain Interactions for Auctioneer

The Entrypoint contract performs validation of the “operations”.  
- The Entrypoint contract will perform a before balance check, which it will in the future use to verify on-chain if a liquidator has paid their bid amount.  
- The Entrypoint contract will then call out to the contract of the highest bidding liquidator.  
- The liquidator’s contract will call out to the Curvance smart contracts to perform the liquidation.  
- After the liquidator’s contract has concluded execution, the Entrypoint contract performs another balance check to verify the change in balance that occurred during the liquidator’s contract execution, this is the bid paid by the liquidator.  
- If the liquidator paid the bid amount they promised, the bid is then programmatically distributed to the Curvance address provided, and a fee to the auctioneer.  
- If the liquidator did not pay the bid amount they promised, the Entrypoint will repeat steps 2-5 on the second highest bidding liquidator’s contract. It will continue to execute on each of the 5-10 liquidators’ contracts in order of descending bid amount until it successfully finds a liquidator who pays the promised bid amount.  

The above results in the auctioneer always being the `tx.origin` of the tx, and the `msg.sender` will be the liquidator’s contract when the Curvance contracts query it.  

---

## Risks

If the auctioneer is offline or there is some bug, then OEV capture may either be lessened or go to zero. Liquidations can still occur with a small delay such as 2 blocks. Liquidations still occur at the current price shown by the data feed at the time of liquidation execution. If one of the private keys used in the `tx.origin` check was compromised, the most the attacker who gained access to the key could do is to front-run the auctioneer and win liquidations without paying anything in the auction.  

To summarize, adding OEV capture mechanisms to the Curvance protocol will not cause deposits to be directly at risk. If OEV off-chain components go offline then there will be small delay to liquidations based on the length of the queueing delay (priority duration and regular duration).  

---

## Queuing Details  

There will not be a gas war to call `queueLiquidation()` because this function itself does not produce any value for the caller. If two liquidators call `queueLiquidation()` in the same block as each other, neither has any privileges over the other based on their position in the block. This means that the `queueLiquidation()` tx can land at the bottom of the block, so there is no reason to participate in a gas war.  

Calling `queueLiquidation()` is necessary if OEV auctions are down. Due to this fact, calling `queueLiquidation()` is incentivized by giving those who call it a 1 block priority to executing liquidations over those who do not call it. This both ensures that:  
- there are strong incentives for liquidators to quickly call `queueLiquidation()` so they can get a priority.  
- and if they fail to quickly liquidate the position, the liquidation will eventually become available to those who didn't call `queueLiquidation()`, potentially reducing delays to liquidations.  

---

## Setting Delay Periods

The delay after queuing a liquidation needs to be long enough to allow an OEV auction to occur, and for the auctioneer to land the tx. The delay may have to assume that the oracle tx may be a private transaction, so the OEV auction in this case can only start after block N is available if the oracle update triggering the liquidation lands in block N. The delay should also assume a `queueLiquidation()` tx may land in block N alongside the oracle update if a liquidator is optimistically spamming. So if the block time is long enough so that the auction can conclude and the auctioneer can land his tx in between block N data being available and block N + 1, then the delay must be at least until block N + 2, so 2 blocks. If the block time is too short for the auction to occur and tx to land in 1 block, such as an L2 like Arbitrum or Optimism, the delay should be probably only 1 block more.  

---

## Implementation Details

### `liquidationBundlers` Mapping

A mapping of addresses to a `bool`. The addresses mapped to `True` are allowed to be the `tx.origin` of an OEV liquidation tx that can bypass the queue mechanism. An “Auction Manager” role (can either be given to both Curvance and Fastlane, or a shared multisig) should be able to add and remove from this whitelist.  

### `PRIORITY_HOLD_DURATION` var

A chain specific variable that represents the time that must pass after a `queueLiquidation()` tx has landed before the caller of the `queueLiquidation()` tx can perform the liquidation. This will be determined based on the block time of the respective chain.  

### `REGULAR_HOLD_DURATION` var

A chain specific variable that represents the time that must pass after a `queueLiquidation()` tx has landed before any liquidator can perform the liquidation. This will be determined based on block time of the respective chain. `PRIORITY_HOLD_DURATION` should always be less than `REGULAR_HOLD_DURATION` so that doing the queue tx is incentivized with at least a 1 block time priority for the sender of that tx. This allows any liquidator to perform the liquidation without queuing it if the caller of `queueLiquidation()` has failed to perform the liquidation within 1 block.  

### `END_DURATION` var

A chain specific variable that represents the window of time that a liquidation is available for anyone to execute `REGULAR_HOLD_DURATION` time after `queueLiquidation` was called. This period should be set to be more than long enough for a liquidation to have occurred. After this period is over we can assume the liquidation has occurred and we can reset the nonce for that account the next time a liquidation on that account needs to be performed. If the account needs to be liquidated a second time before this period is over, we will be unable to capture OEV for that second liquidation because it is available to the public until the period is over. `END_DURATION` should always be greater than `PRIORITY_HOLD_DURATION` and `REGULAR_HOLD_DURATION`.  

---

### `priorityAccess` Mapping

A mapping of a `bytes32` to a `uint256`. The `bytes32` would be a keccak(accountToBeLiquidated, liquidator, nonce, liquidationTarget), and the `uint256` is the timestamp when that liquidation is valid for the liquidator to perform, which will be the timestamp when `queueLiquidation()` was called plus the `PRIORITY_HOLD_DURATION`. The nonce is specific to the account to be liquidated and is used in the case where an account has previously been liquidated, and must then be liquidated again a second or Nth time. The liquidationTarget distinguishes between an account that has been queued for a `canLiquidateWithExecution()` call or a `liquidateAccount()` call.  

---

### `regularQueue` Mapping

A mapping of a `bytes32` which will be a keccak(accountToBeLiquidated, liquidationTarget) to a struct containing a:  
- `priorityStartLine` timestamp: the timestamp when the position can be liquidated by the first caller of `queueLiquidation()`, which is the timestamp when `queueLiquidation()` was first called plus the `PRIORITY_HOLD_DURATION`.  
- `regularStartLine` timestamp: the timestamp when the position can be liquidated by any party who has not called `queueLiquidation()`, which is the timestamp when `queueLiquidation()` was first called plus the `REGULAR_HOLD_DURATION`.  
- `endLine` timestamp: the timestamp until which liquidations by any party are valid atomically after the `REGULAR_HOLD_DURATION`. After this timestamp if another liquidation needs to be performed the nonce for the liquidation of this account will need to be incremented either by an auctioneer/bundler calling `unlockLiquidation()` or a `queueLiquidation()` tx.  
- `uint64 nonce`: unique number representing the instance of the account being liquidated.  

---

### `queueLiquidation()` Func

The `queueLiquidation()` function must take as inputs all of the parameters already required for `canLiquidate()`. It must then call `canLiquidate()` to determine if the specified account is currently liquidatable, and will only successfully queue the account if `_canLiquidate()` returns that the attempted liquidation is currently possible. If the account has not already been added to the `regularQueue`, or if the account was previously registered in the `regularQueue` for a previous liquidation (nonce), the `regularQueue` should be updated with this new pending liquidation for the account.  

Here is a quick example for why calling `canLiquidate()` within this function is needed: a liquidator who wants to bypass paying Curvance via the OEV auction could optimistically queue a liquidation for an account before the account is liquidatable. As long as this queue tx is done `priority duration` before the account becomes actually liquidatable, then once the account becomes liquidatable the OEV auction winners could be front-run and OEV cannot be captured for Curvance.  

---

### `validateLiquidation()` Func

This function must be called before Curvance allows a liquidation to be processed in `canLiquidateWithExecution()`, it works as follows:  
- **IF** OEV functionality is turned off by the manager role **THEN** proceed with the liquidation as currently implemented by Curvance protocol.  
- **IF** the `tx.origin` is a whitelisted auctioneer/bundler **THEN** proceed with the liquidation as currently implemented by Curvance protocol.  
- **ELSE IF** the keccak hash of (account, liquidator, nonce, liquidationTarget) is in the `priorityQueue`, the timestamp mapped to that hash is less than the current timestamp, and the `endLine` is greater than the current timestamp **THEN** proceed with the liquidation as currently implemented by Curvance protocol.  
- **ELSE IF** the account to be liquidated is in the `regularQueue`, the current timestamp is greater than the `regularStartLine` mapped to the account, and the `endLine` is greater than the current timestamp **THEN** proceed with the liquidation as currently implemented by Curvance protocol.  
- **ELSE** revert the liquidation.  

---

### `liquidateAccount()`

This liquidation function will work exactly as the changes to `canLiquidateWithExecution()`, although it will use its own unique queue distinguished by the liquidationTarget. This allows for OEV to be captured in the case that an account takes on bad debt within the `END_DURATION` from when it was previously liquidated using `canLiquidateWithExecution()`.  
