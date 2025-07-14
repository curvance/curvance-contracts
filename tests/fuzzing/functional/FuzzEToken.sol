// pragma solidity 0.8.26;

// import { FuzzMarketManager } from "tests/fuzzing/FuzzMarketManager.sol";
// import { EToken } from "contracts/market/token/EToken.sol";
// import { IERC20 } from "contracts/interfaces/IERC20.sol";
// import { WAD } from "contracts/libraries/Constants.sol";
// import { ICToken } from "contracts/interfaces/ICToken.sol";

// contract FuzzEToken is FuzzMarketManager {
//     constructor() {
//         require(_mintAndApprove(address(usdc), address(pUSDC), 1000 ether));
//         require(_mintAndApprove(address(dai), address(pDAI), 1000 ether));
//         require(_mintAndApprove(address(usdc), address(borrowableCUSDC), 1000 ether));
//         require(_mintAndApprove(address(dai), address(borrowableCDAI), 1000 ether));
//     }

//     /// @custom:property dtok-1 calling EToken.mint should succeed with correct preconditions
//     /// @custom:property dtok-2 underlying balance for sender EToken should decrease by amount
//     /// @custom:property dtok-3  balance should increase by `amount * WAD/exchangeRateCached()`
//     /// @custom:property dtok-4 EToken totalSupply should increase by `amount * WAD/exchangeRateCached()`
//     /// @custom:proeprty dtok-18 If amount * WAD / exchange_rate = 0 , the mint function should revert when trying to deposit to GaugePool.
//     /// @custom:precondition amount bound between [1, uint256.max]
//     function mint_should_actually_succeed(
//         address eToken,
//         uint256 amount
//     ) public {
//         _isSupportedEToken(eToken);
//         require(gaugeManager.gaugeStartTime() < block.timestamp);
//         _check_price_feed();
//         (bool mintingPossible, ) = address(marketManager).call(
//             abi.encodeWithSignature("canMint(address)", eToken)
//         );
//         require(mintingPossible);
//         address underlyingTokenAddress = EToken(eToken).underlying();
//         // amount = clampBetweenBoundsFromOne(lower, amount);
//         amount = clampBetween(amount, 0, type(uint64).max);
//         require(_mintAndApprove(underlyingTokenAddress, eToken, amount));
//         uint256 preUnderlyingBalance = IERC20(underlyingTokenAddress)
//             .balanceOf(address(this));
//         uint256 preETokenBalance = EToken(eToken).balanceOf(address(this));
//         uint256 preETokenTotalSupply = EToken(eToken).totalSupply();
//         // uint256 er = EToken(eToken).exchangeRateCached();

//         try EToken(eToken).mint(amount) {
//             uint256 postETokenBalance = EToken(eToken).balanceOf(
//                 address(this)
//             );
//             uint256 new_er = EToken(eToken).exchangeRateCached();

//             // The new_er needs to be used here because the _mint function first accrues interest, therefore we need the updated exchange rate
//             uint256 adjustedNumberOfTokens = (amount * WAD) / new_er;
//             uint256 postUnderlyingBalance = IERC20(underlyingTokenAddress)
//                 .balanceOf(address(this));

//             assertEq(
//                 preUnderlyingBalance - amount,
//                 postUnderlyingBalance,
//                 "DTOK-2 mint should reduce underlying token balance"
//             );

//             assertEq(
//                 preETokenBalance,
//                 postETokenBalance - adjustedNumberOfTokens,
//                 "DTOK-3 mint should increase balanceOf[msg.sender] by (amount*WAD)/exchangeRate"
//             );

//             uint256 postETokenTotalSupply = EToken(eToken).totalSupply();

//             assertEq(
//                 preETokenTotalSupply,
//                 postETokenTotalSupply - adjustedNumberOfTokens,
//                 "DTOK-4 mint should increase totalSupply"
//             );
//         } catch (bytes memory revertData) {
//             uint256 errorSelector = extractErrorSelector(revertData);

//             // We need to accrue interest to get the most recent exchange rates that was used in this calculation
//             EToken(eToken).accrueInterest();

//             uint256 new_er = EToken(eToken).exchangeRateCached();
//             uint256 adjustedNumberOfTokens = (amount * WAD) / new_er;
//             emit LogUint256(
//                 "adjusted number of tokens",
//                 adjustedNumberOfTokens
//             );

//             // if the underlying token mint totalSupply calculation expected to overflow, revert
//             bool underlyingTokenSupplyOverflow = doesOverflow(
//                 preUnderlyingBalance + amount,
//                 preUnderlyingBalance
//             );
//             // if the eToken token mint totalSupply calculation expected to overflow, revert
//             bool eTokenSupplyOverflow = doesOverflow(
//                 preETokenTotalSupply + adjustedNumberOfTokens,
//                 preETokenTotalSupply
//             );
//             // if the balance calculation expected to overflow, revert
//             bool balanceOverflow = doesOverflow(
//                 preETokenBalance + adjustedNumberOfTokens,
//                 preETokenBalance
//             );
//             if (adjustedNumberOfTokens == 0) {
//                 assertEq(
//                     errorSelector,
//                     invalid_amount,
//                     "DTOK-18 if amount*WAD/er==0, gauge pool deposit should fail"
//                 );
//             } else if (
//                 underlyingTokenSupplyOverflow ||
//                 eTokenSupplyOverflow ||
//                 balanceOverflow
//             ) // if any of the above conditions are met, then expect a revert for overflow
//             {
//                 assertEq(
//                     errorSelector,
//                     0,
//                     "DTOK-X mint should revert if overflow"
//                 );
//             } else {
//                 // DTOK-1
//                 assertWithMsg(
//                     false,
//                     "DTOK-1 mint should succeed with correct preconditions"
//                 );
//             }
//         }
//     }

//     /// @custom:property dtok-5 borrow should succeed with correct preconditions
//     /// @custom:property dtok-6 totalBorrows if interest has not accrued should increase by amount after borrow is called
//     /// @custom:property dtok-7 underlying balance if interest has not accrued should increase by amount for msg.sender
//     /// @custom:precondition token to borrow is either eUSDC or eDAI
//     /// @custom:precondition amount is bound between [1, marketUnderlyingHeld() - totalReserves]
//     /// @custom:precondition borrow is not paused
//     /// @custom:precondition eToken must be listed
//     /// @custom:precondition user must not have a shortfall for respective token
//     /// @custom:limitation TODO missing check for increase in _debtOf[account].principal and  _debtOf[account].accountExchangeRate
//     function borrow_should_succeed_not_accruing_interest(
//         address eToken,
//         uint256 amount
//     ) public {
//         _isSupportedEToken(eToken);
//         _check_price_feed();
//         address underlying = EToken(eToken).underlying();
//         require(marketManager.isListed(eToken));
//         require(marketManager.borrowPaused(eToken) != 2);
//         uint256 upperBound = EToken(eToken).marketUnderlyingHeld() -
//             EToken(eToken).totalReserves() -
//             77777; // TODO: constant
//         amount = clampBetween(amount, 1, upperBound - 1);
//         require(_mintAndApprove(EToken(eToken).underlying(), eToken, amount));
//         (bool borrowPossible, ) = address(marketManager).call(
//             abi.encodeWithSignature(
//                 "canBorrow(address,address,uint256)",
//                 eToken,
//                 address(this),
//                 amount
//             )
//         );
//         require(borrowPossible);
//         (uint40 lastTimestampUpdated, , uint256 compoundRate) = EToken(eToken)
//             .marketData();
//         require(lastTimestampUpdated + compoundRate > block.timestamp);

//         uint256 preTotalBorrows = EToken(eToken).totalBorrows();
//         uint256 preUnderlyingBalance = IERC20(underlying).balanceOf(
//             address(this)
//         );

//         try EToken(eToken).borrow(amount) {
//             // Interest was not accrued
//             assertEq(
//                 EToken(eToken).totalBorrows(),
//                 preTotalBorrows + amount,
//                 "DTOK-6 borrow postTotalBorrows failed = preTotalBorrows + amount"
//             );
//             uint256 postUnderlyingBalance = IERC20(underlying).balanceOf(
//                 address(this)
//             );

//             assertEq(
//                 postUnderlyingBalance,
//                 preUnderlyingBalance + amount,
//                 "DTOK-7 borrow postUnderlyingBalance failed = underlyingBalance + amount"
//             );

//             postedCollateralAt[eToken] = block.timestamp;
//         } catch {
//             assertWithMsg(
//                 false,
//                 "DTOK-5 borrow should succeed with correct preconditions"
//             );
//         }
//     }

//     /// @custom:property dtok-8 borrow should succeed with correct preconditions
//     /// @custom:property dtok-9 totalBorrows if interest has accrued should increase by amount after borrow is called
//     /// @custom:property dtok-10 underlying balance if interest not accrued should increase by amount for msg.sender
//     /// @custom:precondition token to borrow is either eUSDC or eDAI
//     /// @custom:precondition amount is bound between [1, marketUnderlyingHeld() - totalReserves]
//     /// @custom:precondition borrow is not paused
//     /// @custom:precondition eToken must be listed
//     /// @custom:precondition user must not have a shortfall for respective token
//     function borrow_should_succeed_accruing_interest(
//         address eToken,
//         uint256 amount
//     ) public {
//         _isSupportedEToken(eToken);
//         _check_price_feed();
//         address underlying = EToken(eToken).underlying();
//         require(marketManager.borrowPaused(eToken) != 2);
//         uint256 upperBound = EToken(eToken).marketUnderlyingHeld() -
//             EToken(eToken).totalReserves() -
//             77777;
//         amount = clampBetween(amount, 1, upperBound - 1);
//         require(_mintAndApprove(EToken(eToken).underlying(), eToken, amount));
//         require(marketManager.isListed(eToken));
//         (bool borrowPossible, ) = address(marketManager).call(
//             abi.encodeWithSignature(
//                 "canBorrow(address,address,uint256)",
//                 eToken,
//                 address(this),
//                 amount
//             )
//         );
//         require(borrowPossible);
//         (uint40 lastTimestampUpdated, , uint256 compoundRate) = EToken(eToken)
//             .marketData();
//         require(lastTimestampUpdated + compoundRate <= block.timestamp);

//         uint256 preTotalBorrows = EToken(eToken).totalBorrows();
//         uint256 preUnderlyingBalance = IERC20(underlying).balanceOf(
//             address(this)
//         );
//         // Old exchange rate may be useful when determining the amount of interest that was accrued
//         // uint256 er = EToken(eToken).exchangeRateCached();

//         try EToken(eToken).borrow(amount) {
//             // Interest is accrued
//             /* Commenting this out as this does not currently accurately calculate the amount of interest remaining 
//             uint256 interestAccrued = _calculate_interest_accrued(
//                 amount,
//                 eToken,
//                 er,
//                 lastTimestampUpdated,
//                 compoundRate
//             );
//             */
//             //  TODO: determine how much interest should have accrued instead of just Gt.
//             assertGte(
//                 EToken(eToken).totalBorrows(),
//                 preTotalBorrows + amount,
//                 "DTOK-9 borrow postTotalBorrows failed = preTotalBorrows + amount"
//             );

//             uint256 postUnderlyingBalance = IERC20(underlying).balanceOf(
//                 address(this)
//             );
//             assertGte(
//                 postUnderlyingBalance,
//                 preUnderlyingBalance + amount,
//                 "DTOK-10 borrow postUnderlyingBalance failed = underlyingBalance + amount"
//             );
//             // TODO: Add check for _debtOf[account].principal
//             // TODO: Add check for _debtOf[account].accountExchangeRate
//         } catch (bytes memory revertData) {
//             uint256 errorSelector = extractErrorSelector(revertData);

//             // The repay function is going to first accrueInterest to update the reserves and total balances, which is why we need to match this behaviour here
//             // If there is interest to be accrued, and we don't call this, the state of the contract when doing this check will not be the same
//             EToken(eToken).accrueInterest();
//             // This implements the same check as in the contracts to check against the correct error message
//             if (
//                 EToken(eToken).marketUnderlyingHeld() -
//                     EToken(eToken).totalReserves() <
//                 amount + 77777
//             ) {
//                 assertWithMsg(
//                     errorSelector ==
//                         marketManager_insufficientUnderlyingHeldSelectorHash,
//                     "DTOK-X borrow if insufficient after accruing interest should fail"
//                 );
//             } else {
//                 assertWithMsg(
//                     false,
//                     "DTOK-8 borrow should succeed with correct preconditions"
//                 );
//             }
//         }
//     }

//     /// @custom:precondition dtok-11 the repay function should fail with amount too large under correct preconditions
//     function repay_should_fail_with_amount_too_large(
//         address eToken,
//         uint256 amount
//     ) public {
//         _isSupportedEToken(eToken);
//         uint256 accountDebt = EToken(eToken).debtBalance(address(this));
//         emit LogUint256("account debt", accountDebt);
//         address underlying = EToken(eToken).underlying();
//         require(_mintAndApprove(underlying, eToken, amount));
//         require(marketManager.isListed(eToken));

//         amount = clampBetween(amount, accountDebt + 1, type(uint256).max);
//         dai.mint(amount);
//         dai.approve(address(borrowableCDAI), amount);
//         try marketManager.canRepay(address(eToken), address(this)) {} catch {
//             return;
//         }

//         // uint256 preTotalBorrows = EToken(eToken).totalBorrows();
//         // uint256 preUnderlyingBalance = IERC20(underlying).balanceOf(
//         // address(this)
//         // );

//         try EToken(eToken).repay(amount) {
//             // interestAccrued should be set to the function that will return hypothetical interest accrual
//             /*
//             uint256 interestAccrued = _calculate_interest_accrued(
//                 amount,
//                 eToken,
//                 old_er,
//                 lastTimestampUpdated,
//                 compoundRate
//             );
//             */
//             uint256 interestAccrued;
//             // if interest accrued and final amount underflowed, repay with more than account debt balance should fail.
//             int256 finalAmount = int256(
//                 amount + interestAccrued - accountDebt
//             );
//             if (finalAmount < 0) {
//                 assertWithMsg(
//                     false,
//                     "DTOK-11 repay more than accountDebt balance should fail"
//                 );
//             }
//         } catch (bytes memory revertData) {
//             uint256 errorSelector = extractErrorSelector(revertData);
//             assertWithMsg(
//                 errorSelector == etoken_excessive_value,
//                 "DTOK-11 repay more than accountDebt should have EXCESSIVE_VALUE error"
//             );
//         }
//     }

//     /// @custom:property dtok-12 repaying within account debt should succeed
//     /// @custom:property dtok-13 repaying any amount should make total borrows equivalent to preTotalBorrows - amount when interest has not accrued
//     /// @custom:property dtok-14 repay with amount=0 should reduce underlying balance by accountDebt
//     /// @custom:property dtok-15 repay with amount!=0 should reduce underlying balance by provided amount
//     /// @custom:property dtok-17 repay with interest accruing should make totalBorrows equivalent to totalBorrows - preTotalBorrows - amount - (|new_exchange_rate - old_exchange_rate|*accountDebt)
//     function repay_within_account_debt_should_succeed(
//         address eToken,
//         uint256 amount
//     ) public {
//         _isSupportedEToken(eToken);
//         address underlying = EToken(eToken).underlying();
//         uint256 accountDebt = EToken(eToken).debtBalance(address(this));
//         emit LogUint256("acct debt", accountDebt);
//         amount = clampBetween(amount, 0, accountDebt);
//         require(_mintAndApprove(underlying, eToken, accountDebt));
//         // TODO: The real amount that a user should approve on repay is the amount they want to repay + interestAccrued, and not an amount that (could be) significantly greater than the amount.
//         IERC20(underlying).approve(eToken, accountDebt * WAD);
//         require(marketManager.isListed(eToken));
//         try marketManager.canRepay(address(eToken), address(this)) {} catch {
//             return;
//         }
//         uint256 preTotalBorrows = EToken(eToken).totalBorrows();
//         uint256 preUnderlyingBalance = IERC20(underlying).balanceOf(
//             address(this)
//         );
//         (uint40 lastTimestampUpdated, , uint256 compoundRate) = EToken(eToken)
//             .marketData();
//         // uint256 borrow_rate = EToken(eToken)
//         //     .interestRateModel()
//         //     .getBorrowRateWithUpdate(
//         //         EToken(eToken).marketUnderlyingHeld(),
//         //         EToken(eToken).totalBorrows(),
//         //         EToken(eToken).totalReserves()
//         //     );

//         try EToken(eToken).repay(amount) {
//             uint256 postUnderlyingBalance = IERC20(underlying).balanceOf(
//                 address(this)
//             );
//             if (amount == 0) {
//                 // interest accrued
//                 if (lastTimestampUpdated + compoundRate <= block.timestamp) {
//                     // TODO this should be adjusted for hypothetical interest accrual
//                     assertLte(
//                         postUnderlyingBalance,
//                         preUnderlyingBalance - accountDebt,
//                         "DTOK-14 repay with amount=0 should reduce underlying balance by accountDebt"
//                     );
//                     // TODO: Adjust this to accurately calculate the total interest accrued, because this uses MarketData.exchangeRate which is not DebtData.accountExchangeRate, therefore this currently checks an incorrect assertion.
//                     /* 
//                     assertEq(
//                         EToken(eToken).totalBorrows(),
//                         preTotalBorrows -
//                             amount +
//                             _calculate_interest_accrued(
//                                 preTotalBorrows,
//                                 eToken,
//                                 borrow_rate,
//                                 lastTimestampUpdated,
//                                 compoundRate
//                             ),
//                         "DTOK-17 repay totalBorrows = postBorrows - amount - interest accrued for amount"
//                     );
//                     */
//                 } else {
//                     // interest was not accrued
//                     assertEq(
//                         EToken(eToken).totalBorrows(),
//                         preTotalBorrows - accountDebt,
//                         "DTOK-13 repay postTotalBorrows failed = preTotalBorrows - amount"
//                     );
//                     assertEq(
//                         postUnderlyingBalance,
//                         preUnderlyingBalance - accountDebt,
//                         "DTOK-X repay with amount=0 should reduce underlying balance by accountDebt"
//                     );
//                 }
//             } else {
//                 assertEq(
//                     postUnderlyingBalance,
//                     preUnderlyingBalance - amount,
//                     "DTOK-15 repay with amount>0 should reduce underlying balance by amount"
//                 );
//             }
//             postedCollateralAt[eToken] = block.timestamp;
//         } catch {
//             assertWithMsg(
//                 false,
//                 "DTOK-12 repay should succeed with correct preconditions"
//             );
//         }
//     }

//     // SOFT liquidation

//     // by default, this should just liquidate the maximum amount, assuming nonexist liquidation
//     /// @custom:property dtok-20 liquidating a non-exact amount should remove the user's position in the position token
//     /// @custom:property dtok-21  liquidating a non-exact amount should zero out the collateral posted for a user in the position token
//     /// @custom:property dtok-22 liquidating a non-exact amount should zero out the debt balance of the respective debt token
//     /// @custom:property dtok-23 liquidating a non-exact amount should decrease collateral balance for an account
//     /// @custom:property dtok-24 liquidating a non-exact amount should decrease the liquidator's underlying eTokenBalance by `debtToLiquidate`
//     /// @custom:property dtok-25 liquidating a non-exact amount should increase the position token balance by (amount seized by liquidation - amount seized by protocol)
//     /// @custom:precondition liquidating an account's maximum
//     /// @custom:precondition eToken is supported
//     /// @custom:precondition cToken is supported
//     /// @custom:precondition market manager for eToken and cToken match
//     /// @custom:precondition account has collateral posted for respective token
//     /// @custom:precondition account is in "danger" of liquidation
//     /// @custom:limitation insufficient assertions on the invalid_amount error check, as the calculation on # of shares is needed to determine if it will actually revert
//     /// @custom:limitation currently this contract is accruing interest to make sure exchange rates catch up before calculating. This property should be loosened to allow for more dynamic range testing, however this will require a hypothetical interest function to exist
//     /// @custom:limitation this property is also currently ONLY testing the eToken = DAI, cToken = pUSDC and should be expanded as other liquidation functions should be
//     /// @custom:limitation missing collateralPostedFor assertion difference checks
//     function liquidate_should_succeed_with_non_exact(uint256 amount) public {
//         address eToken = address(borrowableCDAI);
//         address collateralToken = address(pUSDC);
//         require(marketManager.seizePaused() != 2);
//         address account = address(this);
//         _preLiquidate(amount, DAI_PRICE, USDC_PRICE);

//         EToken(eToken).accrueInterest();
//         (
//             uint256 debtToLiquidate, // debt tokens to be repaid on liquidation
//             uint256 seizedForLiquidation // number of position tokens to be seized for the liquidator
//         ) = marketManager.canLiquidate(
//                 eToken,
//                 collateralToken,
//                 account,
//                 0, // unused as a non-exact liquidation will liquidate the maximum soft liquidation amount possible
//                 false // false represents a non-exact liquidation
//             );

//         address underlyingEToken = EToken(eToken).underlying();

//         {
//             uint256 senderBalanceUnderlying = IERC20(underlyingEToken)
//                 .balanceOf(msg.sender);
//             uint256 collateralBalanceBefore = ICToken(collateralToken).balanceOf(
//                 address(this)
//             );
//             uint256 priorDebt = EToken(eToken).debtBalance(
//                 address(this)
//             );
//             uint256 preSenderCollateral = IERC20(collateralToken).balanceOf(
//                 msg.sender
//             );

//             hevm.prank(msg.sender);
//             try EToken(eToken).liquidate(account, collateralToken) {
//                 // After a non-exact (maximum) liquidation, the user should no longer have a position in the position token.
//                 assertWithMsg(
//                     !_hasPosition(collateralToken),
//                     "DTOK-20 soft liquidate entire account should clear position for collateral"
//                 );

//                 // The amount of collateral posted for a user must be zero.
//                 assertEq(
//                     _collateralPostedFor(collateralToken),
//                     0,
//                     "DTOK-21 soft liquidate entire account should zero out collateral posted for the user"
//                 );

//                 // The debt of the account should decrease by debtToLiquidate
//                 assertEq(
//                     priorDebt -
//                         EToken(eToken).debtBalance(address(this)),
//                     debtToLiquidate,
//                     "DTOK-22 soft liquidate entire account should zero out debt balance for user"
//                 );

//                 // The position token balance for the liquidated account should decrease by `seizedForLiquidation`
//                 emit LogUint256(
//                     "collateralBalanceBefore",
//                     collateralBalanceBefore
//                 );
//                 emit LogUint256(
//                     "current bal",
//                     ICToken(collateralToken).balanceOf(address(this))
//                 );
//                 assertEq(
//                     collateralBalanceBefore -
//                         ICToken(collateralToken).balanceOf(address(this)),
//                     seizedForLiquidation,
//                     "DTOK-23 soft liquidate should decrease collateral balance for account"
//                 );

//                 // The liquidator's underlying debt token balance should DECREASE by `debtToLiquidate` as they had to front the user's debt
//                 assertEq(
//                     IERC20(underlyingEToken).balanceOf(msg.sender),
//                     senderBalanceUnderlying - debtToLiquidate,
//                     "DTOK-24 soft liquidate should decresae liquidator's underlying eToken balance by `debtToLiquidate"
//                 );

//                 // When liquidating, the liquidator should receive the user's COLLATERAL token in exchange
//                 // Therefore, the liquidator's position token balance must be equivalent to their previous balance + their allocation of tokens
//                 {
//                     // The # of tokens allocated to the liquidator is equivalent to the total number of tokens seized for liquidation
//                     uint256 collateralTokensForLiquidator = seizedForLiquidation;
//                     emit LogAddress("msg.sender", msg.sender);

//                     assertEq(
//                         IERC20(collateralToken).balanceOf(msg.sender),
//                         preSenderCollateral + collateralTokensForLiquidator,
//                         "DTOK-25 soft liquidate: position token balance of sender must increase by (amount seized by liquidation - amount seized for protocol)"
//                     );
//                 }
//             } catch (bytes memory revertData) {
//                 uint256 errorSelector = extractErrorSelector(revertData);
//                 if (errorSelector == invalid_amount) {
//                     // An assertion check is missing here.
//                     // TODO: Determine condition where this should be true
//                     // hypothetically if amount = 0 OR
//                     // amount to be deposited to gaugepool would round down to zero
//                 } else {
//                     assertWithMsg(
//                         false,
//                         "DTOK-22 liquidate should succeed with nonexact"
//                     );
//                 }
//             }
//         }
//     }

//     /// @custom:property dtok-19 Applying a soft liquidation of exactly 0 tokens should fail with InvalidParameter or InvalidParameter errors.
//     /// @custom:precondition marketmanager must not have seizePaused
//     /// @custom:precondition cToken must be listed in the marketmanager
//     /// @custom:precondition eToken must be listed in the marketmanager
//     function liquidate_should_fail_with_exact_with_zero(
//         address eToken,
//         address collateralToken
//     ) public {
//         require(marketManager.seizePaused() != 2);

//         address account = address(this);
//         _isSupportedPToken(collateralToken);
//         _isSupportedEToken(eToken);
//         uint256 amount = 0;

//         _preLiquidate(amount, DAI_PRICE, USDC_PRICE);
//         calculateLiquidation_exact(amount, true);

//         hevm.prank(msg.sender);
//         try
//             EToken(eToken).liquidateExact(account, amount, collateralToken)
//         {} catch (bytes memory revertData) {
//             uint256 errorSelector = extractErrorSelector(revertData);
//             // liquidating 0 tokens SHOULD fail with one of these two error messages
//             assertWithMsg(
//                 errorSelector == invalid_amount ||
//                     errorSelector ==
//                     marketManager_invalidParameterSelectorHash,
//                 "DTOK-19 liquidateExact should fail with amount 0"
//             );
//         }
//     }

//     /// @custom:property dtok-26 liquidating an exact amount should result in the priorCollateral - currentCollateral being equal to the amount seized for liquidation.
//     /// @custom:property dtok-27 Liquidating an exact amount should result in account debt decreasing by debtToLiquidate.
//     /// @custom:property dtok-28 Liquidating an exact amount should result in the underlying token balance of msg.sender after liquidation being equal to the previous underlying balance + debt to liquidate.
//     /// @custom:property dtok-29 Liquidating an exact amount should result in position token balance of the sender increasing by (amount seized by liquidation - amount seized by the protocol)
//     /// @custom:precondition eToken being liquidated is eDAI
//     /// @custom:precondition cToken being liquidated is pUSDC
//     /// @custom:precondition account being liquidated is address(this)
//     /// @custom:limitation once posting of collateral etc can be done by any address, open up to any account can be liquidated
//     /// @custom:limitation current uses a constant for dai and usdc price to push the position into an liquidatable state, see liquidateAccount in marketManager for dynamic generation
//     /// @custom:limitation missing check for position token balance of account
//     function liquidate_should_succeed_with_exact(uint256 amount) public {
//         address eToken = address(borrowableCDAI);
//         address collateralToken = address(pUSDC);
//         address account = address(this);
//         uint256 priorCollateral = _collateralPostedFor(address(collateralToken));
//         EToken(eToken).accrueInterest();
//         uint256 priorDebt = EToken(eToken).debtBalance(address(this));
//         amount = _preLiquidate(amount, DAI_PRICE, USDC_PRICE);

//         (uint256 debtToLiquidate, uint256 seizedForLiquidation) = marketManager
//             .canLiquidate(
//                 eToken,
//                 collateralToken,
//                 account,
//                 amount, // specifying this particular amount
//                 true // liquidate an exact amount
//             );

//         {
//             address underlyingEToken = EToken(eToken).underlying();

//             {
//                 uint256 senderBalanceUnderlying = IERC20(underlyingEToken)
//                     .balanceOf(msg.sender);
//                 uint256 preSenderCollateral = IERC20(collateralToken).balanceOf(
//                     msg.sender
//                 );

//                 hevm.prank(msg.sender);
//                 EToken(eToken).liquidateExact(account, amount, collateralToken);

//                 // The user's previous collateral balance - post collateral balance must equal the total amount that was seized for liquidation
//                 assertEq(
//                     priorCollateral - _collateralPostedFor(collateralToken),
//                     seizedForLiquidation,
//                     "DTOK-26 soft liquidation exact should result in priorCollateral - current collateral = seized for liquidation"
//                 );

//                 // The user's previous debt balance - current debt balance must equal the total amount of debt that was liquidated
//                 assertEq(
//                     priorDebt -
//                         EToken(eToken).debtBalance(address(this)),
//                     debtToLiquidate,
//                     "DTOK-27 soft liquidate exact acct debt should decrease by debtToLiquidate"
//                 );

//                 // When liquidating, the liquidator will REPAY debt tokens TO the system
//                 // Therefore, the liquidator's underlying eToken after execution should be equal to the pre underlying eToken balance + debtToLiquidate
//                 assertEq(
//                     IERC20(underlyingEToken).balanceOf(msg.sender),
//                     senderBalanceUnderlying + debtToLiquidate,
//                     "DTOK-28 liquidate: underlying msg.sender balance after liquidate = previous underlying + debt to liquidate"
//                 );

//                 // When liquidating, the liquidator should receive the user's COLLATERAL token in exchange
//                 // Therefore, the liquidator's position token balance must be equivalent to their previous balance + their allocation of tokens
//                 {
//                     // The # of tokens allocated to the liquidator is equivalent to the total number of tokens seized for liquidation
//                     uint256 collateralTokensForLiquidator = seizedForLiquidation;
//                     assertEq(
//                         IERC20(collateralToken).balanceOf(msg.sender),
//                         preSenderCollateral + collateralTokensForLiquidator,
//                         "DTOK-29 soft liquidate: position token balance of sender must increase by (amount sized by liquidation - amount seized for protocol)"
//                     );
//                 }
//             }
//         }
//     }

//     // helper functions

//     // This function no longer used, was in an attempt to calculate the exact amount of interest accrued over a period of time.
//     function _calculate_interest_accrued(
//         uint256 priorBorrows,
//         uint256 old_er,
//         uint256 lastTimestampUpdated,
//         uint256 compoundRate
//     ) private view returns (uint256) {
//         uint256 interestCompounds = (block.timestamp - lastTimestampUpdated) /
//             compoundRate;
//         uint256 interestAccumulated = old_er * interestCompounds;
//         uint256 debtAccumulated = (interestAccumulated * priorBorrows) / WAD;
//         return debtAccumulated;
//     }

//     function _get_er_difference(
//         uint256 old_er,
//         address eToken
//     ) private view returns (uint256) {
//         uint256 new_er = EToken(eToken).exchangeRateCached();
//         return new_er > old_er ? new_er - old_er : old_er - new_er;
//     }
// }
