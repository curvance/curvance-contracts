# CToken.sol / CErc20.sol

* Each asset market is represented by a cToken contract, which is an ERC-20 compliant representation of balances supplied to the protocol
* By minting cTokens, users (1) earn interest through the cToken's exchange rate, which increases in value relative to the underlying asset, and (2) gain the ability to use cTokens as collateral
* There are currently two types of cTokens: CErc20 and CEther. Though both types expose the EIP-20 interface, CErc20 wraps an underlying ERC-20 asset, while CEther simply wraps Ether itself

### Definitions

* **supply rate:** Interest earned by collateral deposits per block
  * Derived from the borrow rate, reserve factor, and the amount of total borrows currently loaned out by the market
    * Interest accrued on loans is paid out to suppliers of the market
* **borrow rate:** Interest paid on active loans per block
* **reserve factor:** Portion of borrower interest that is set aside as reserves which can be withdrawn or transferred

### Functions

* `mint(uint mintAmount)`
  * Transfers an asset into the protocol, which begins accumulating interest based on the current supply rate for the asset
* `redeem(uint redeemTokens)`
  * Converts a specified amount of cTokens (represented by `redeemTokens`) into the underlying asset
  * The amount of underlying tokens received is equal to the quantity of cTokens redeemed, multiplied by the current exchange rate
  * The amount redeemed must be less than the user's borrow limit and the market's available liquidity
* `redeemUnderlying(uint redeemAmount)`
  * Converts cTokens (represented by `redeemTokens`) into a specified amount of underlying asset (represented by `redeemAmount`)
  * Similar to `redeem`
* `borrow(uint borrowAmount)`
  * Transfers an asset from the protocol to the user, and creates a borrow balance which begins accumulating interest based on the borrow rate for the asset
  * The amount borrowed must be less than the user's account liquidity and the market's available liquidity
* `repayBorrow(uint repayAmount)`
  * Transfers an asset into the protocol, reducing the user's borrow balance
* `repayBorrowBehalf(address borrower, uint repayAmount)`
  * Transfers an asset into the protocol, reducing the target user's borrow balance
* `transfer(address recipient, uint256 amount)`
  * Works the same as the ERC-20 transfer method
* `liquidateBorrow(address borrower, uint amount, address collateral)`
  * The sender liquidates the `borrower`'s collateral in a specified asset market (represented by `collateral`, which is seized and transferred to the liquidator after repaying an `amount` of the `borrower`'s loan
  * Only usable on a `borrower` account with negative account liquidity to return their account liquidity back to positive (i.e. above the collateral requirement)
  * When a liquidation occurs, a liquidator may repay some or all of an outstanding borrow on behalf of a borrower and in return receive a discounted amount of collateral held by the borrower
    * This discount is defined as the liquidation incentive.
  * A liquidator may close up to a certain fixed percentage (i.e. close factor) of any individual outstanding borrow of the underwater account
  * When collateral is seized, the liquidator is transferred cTokens, which they may redeem the same as if they had supplied the asset themselves.
  * Users must approve each cToken contract before calling liquidate (i.e. on the borrowed asset which they are repaying), as they are transferring funds into the contract
* `sweepToken(ERC20 token)`
  * Sweep accidental ERC-20 transfers to this contract. Tokens are sent to admin.
  * `token` cannot be the same as the underlying token
* `addReserves(uint addAmount`)
  * The sender adds the specified `addAmount` of underlying token to reserves
* `reduceReserves(uint reduceAmount)`
  * Reduces a specified `reduceAmount` of reserves by transferring to admin
  * Only callable by `admin`
* `getCashPrior()`
  * Gets the balance of underlying token owned by the contract
* `setReserveFactor(uint newReserveFactorMantissa)`
  * Sets a new reserve factor for the protocol
  * Only callable by `admin`
* `setInterestRateModel(InterestRateModel newInterestRateModel)`
  * Sets a new interest rate model
  * Only callable by `admin`
