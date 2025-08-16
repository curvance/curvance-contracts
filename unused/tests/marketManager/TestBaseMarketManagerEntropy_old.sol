// // SPDX-License-Identifier: GPL-3.0
// pragma solidity ^0.8.19;

// import "./TestBaseMarketManagerMultiMarkets.sol";

// contract TestBaseMarketManagerEntropy is TestBaseMarketManagerMultiMarkets {
//     uint256 public entropy;
//     uint256 public constant BASE_UNDERLYING_RESERVE = 42069;

//     function _genRandom(
//         uint256 _value,
//         uint256 _entropy,
//         uint256 _lower,
//         uint256 _upper
//     ) internal pure returns (uint256) {
//         return
//             _lower == _upper
//                 ? _lower
//                 : (uint256(keccak256(abi.encodePacked(_value, _entropy))) %
//                     (_upper - _lower)) + _lower;
//     }

//     function _genCollateralateraltoken(
//         uint256 _noOfTokens,
//         uint256 _entropy
//     )
//         internal
//         returns (
//             MockSimpleCToken[] memory,
//             MockV3Aggregator[] memory,
//             MockV3Aggregator[] memory
//         )
//     {
//         MockSimpleCToken[] memory cTokens = new MockSimpleCToken[](
//             _noOfTokens
//         );
//         MockV3Aggregator[] memory cTokensAgg = new MockV3Aggregator[](
//             _noOfTokens
//         );
//         MockV3Aggregator[]
//             memory cTokensUnderlyingAgg = new MockV3Aggregator[](_noOfTokens);
//         for (uint256 i = 0; i < _noOfTokens; i++) {
//             MockSimpleCToken cToken = _deployCollaterToken();
//             cTokens[i] = cToken;
//             cTokensAgg[i] = _deployOracleManagerForToken(cToken.underlying());
//             cTokensUnderlyingAgg[i] = _deployOracleManagerForToken(
//                 address(cToken)
//             );
//             if (_entropy > 0) {
//                 console2.log("a %s", i);
//                 _setCollateralDataWithEntropy(
//                     address(cToken),
//                     i,
//                     _entropy + i
//                 );
//             } else {
//                 _setCollateralData(address(cToken));
//             }
//             console2.log("b %s", i);
//             _setCollateralData(address(cToken));
//         }
//         return (cTokens, cTokensAgg, cTokensUnderlyingAgg);
//     }

//     function _setCollateralDataWithEntropy(
//         address collateralToken,
//         uint256 index,
//         uint256 randomEntropy
//     ) internal {
//         // set collateral factor
//         uint256 collRatio = _genRandom(randomEntropy, index, 3000, 9100);
//         uint256 collReqA = _genRandom(randomEntropy, index + 1, 1000, 4000);
//         console2.log("collRatio %s collReqA %s", collRatio, collReqA);
//         uint256 collReqALimit = (1e4 * 1e4) / collRatio - 1e4;
//         console2.log("collReqALimit %s", collReqALimit);
//         if (collReqA > collReqALimit) {
//             collReqA = collReqALimit;
//         }
//         colRatios[index] = collRatio;

//         uint256 collReqB = _genRandom(
//             randomEntropy,
//             index + 2,
//             collReqA / 2,
//             collReqA
//         ) - (collReqA / 4);
//         if (
//             collReqB <=
//             400 +
//                 (marketManagerIsolated.MIN_EXCESS_COLLATERAL_REQUIREMENT() / 10 ** 14)
//         ) {
//             collReqB =
//                 400 +
//                 (marketManagerIsolated.MIN_EXCESS_COLLATERAL_REQUIREMENT() /
//                     10 ** 14) +
//                 1;
//         }

//         marketManagerIsolated.updateCollateralToken(
//             collateralToken,
//             collRatio,
//             collReqA,
//             collReqB,
//             200,
//             400,
//             1000
//         );
//         address[] memory tokens = new address[](1);
//         tokens[0] = address(collateralToken);
//         uint256[] memory caps = new uint256[](1);
//         caps[0] = 100_000e18;
//         marketManagerIsolated.setCollateralCaps(tokens, caps);
//     }

//     function _genColWithEntropy(
//         address user,
//         MockSimpleCToken cToken,
//         uint256 amount
//     ) internal {
//         _genCollateral(user, cToken, amount);
//         _postCollateral(user, cToken, amount);
//     }

//     function _supplyETokenWithEntropy(
//         address user,
//         EToken eToken,
//         uint256 amount
//     ) internal {
//         _supplyEToken(user, eToken, amount);
//     }

//     function _selectBorrow(
//         uint256 i,
//         EToken[] memory eTokens,
//         uint256 noOfDebtTokens
//     ) internal view returns (bool, EToken, uint256) {
//         console2.log("select borrow");
//         EToken borrowToken = eTokens[
//             _genRandom(i, entropy, 0, noOfDebtTokens)
//         ];
//         uint256 underlyingHeld = borrowToken.marketUnderlyingHeld();
//         uint256 amount = underlyingHeld - BASE_UNDERLYING_RESERVE;

//         console2.log("amount %s", amount);
//         if (amount < uint256(borrowToken.decimals()) * 100) {
//             for (uint256 j = 0; j < noOfDebtTokens; j++) {
//                 if (
//                     eTokens[j].marketUnderlyingHeld() >
//                     uint256(eTokens[j].decimals()) * 100
//                 ) {
//                     borrowToken = eTokens[j];
//                     underlyingHeld = borrowToken.marketUnderlyingHeld();
//                     amount = underlyingHeld - BASE_UNDERLYING_RESERVE;

//                     return (false, borrowToken, amount);
//                 }
//             }
//             return (true, borrowToken, amount);
//         }
//         return (false, borrowToken, amount);
//     }

//     function _executeBorrows(
//         address[] memory users,
//         EToken[] memory eTokens,
//         MockSimpleCToken[] memory /* colToken */
//     ) internal {
//         uint256 amount;
//         //uint256 borrowToken;

//         for (uint256 i = 0; i < noOfCollateralTokens; i++) {
//             console2.log("col token %s col ratio %s", i, colRatios[i]);
//         }

//         console2.log("borrow");

//         for (uint256 i = 0; i < noOfUsersCollateral; i++) {
//             console2.log("user %s", i);
//             while (true) {
//                 (accCollateral, accMaxDebt, accDebt) = marketManagerIsolated.statusOf(
//                     users[i]
//                 );
//                 amount = _genRandom(i, entropy, 100e18, 500e18);
//                 console2.log("borrow amount %s", amount);
//                 console2.log(
//                     "Status: col %s max debt %s debt %s",
//                     accCollateral,
//                     accMaxDebt,
//                     accDebt
//                 );
//                 (, EToken borrowToken, uint256 avail) = _selectBorrow(
//                     i,
//                     eTokens,
//                     noOfDebtTokens
//                 );

//                 console2.log("avail %s amount %s", avail, amount);
//                 if (avail < amount) {
//                     amount = avail / 2;
//                 }

//                 console2.log("borrowToken %s", address(borrowToken));
//                 if (accMaxDebt - accDebt < amount) {
//                     _borrow(
//                         users[i],
//                         borrowToken,
//                         ((accMaxDebt - accDebt) * 9500) / 10000
//                     );
//                     break;
//                 } else {
//                     _borrow(users[i], borrowToken, amount);
//                 }
//             }
//         }
//     }
// }
