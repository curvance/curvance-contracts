---
description: Defines logic for interacting with and setting parameters for markets
---

# Comptroller.sol

### Functions

* `enterMarkets(address[] memory cTokens) returns (uint256[])`
  * Enter the sender into one or several asset markets. Often `cTokens` is just an array containing one market, but may be called with many markets for gas efficiency
  * Used In liquidity calculations for the caller's account
* `exitMarket(address cTokenAddress) returns (uint256)`
  * Exits the sender from an asset market
  * Sender must not have an outstanding borrow balance or be providing necessary collateral for an outstanding borrow
* `supportMarket(CToken cToken) returns (uint256)`
  * Add support for an asset market
  * Only callable by `admin`
* `checkMembership(address account, CToken cToken) returns (bool)`
  * Check whether an `account` is entered in a given asset market (represented by `CToken`)
* `getAllMarkets() returns (CToken[])`
  * Get a list of all asset market addresses
* `getAssetsIn(address account) returns (CToken[] memory)`
  * Get a list of all asset markets an `account` has entered (i.e. has opened positions in)
* `getCompAddress() returns (address)`
  * Get the address of the COMP token (i.e. token that is distributed as a reward to suppliers and borrowers)
* `claimComp(address[] holders, CToken[] cTokens, bool borrowers, bool suppliers)`
  * Claim all COMP accrued by `holders` in the specified asset markets
    * Usually `holders` is just one address, but can claim COMP for multiple addresses for gas efficiency
  * Can specifiy whether or not to claim COMP earned by borrowing with `borrowers` and same for COMP earned by supplying with `suppliers`
* `grantComp(address recipient, uint256 amount)`
  * Transfer an `amount` of COMP to a `recipient`
  * Only callable by `admin`
* `setCompSpeed(CToken cToken, uint256 compSpeed)`
  * Set `compSpeed` (i.e. amount of _COMP_ that is distributed, per block, to suppliers and borrowers in an asset market) for a given `cToken` asset market
  * Only callable by `admin`
* `setContributorCompSpeed(address contributor, uint256 compSpeed)`
  * Set `compSpeed` for an individual (represented by `contributor`)
  * Only callable by `admin`
* `isDeprecated(CToken cToken) returns (bool)`
  * Checks if a given asset market has been deprecated
  * All borrows in a deprecated market can be immediately liquidated
