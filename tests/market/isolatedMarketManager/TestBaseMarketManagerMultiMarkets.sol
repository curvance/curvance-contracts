// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "tests/market/TestBaseMarketIsolated.sol";
import { MockSimplePToken } from "contracts/mocks/MockSimplePToken.sol";
import { MockERC20Token } from "contracts/mocks/MockERC20Token.sol";

import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";
import { WAD } from "contracts/libraries/Constants.sol";
import { PriceReturnData } from "contracts/interfaces/IOracleAdaptor.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

import "forge-std/console2.sol";

contract TestBaseMarketManagerMultiMarkets is TestBaseMarketIsolated {
    uint256 public constant MAX_DEPOSIT = 1e26;
    uint256 public constant MIN_WITHDRAW = 1e18;
    uint256 public constant BP = 1e4;
    uint256 public constant MAX_TOKENS = 10;
    uint256 public constant MAX_USERS = 20;

    uint256 public noOfPositionTokens;
    uint256 public noOfEarnTokens;
    uint256 public noOfUsersCollateral;

    uint256 public noOfUsersDebt;
    uint256 public noOfUsersMixed;
    uint256 public noOfUsers;

    uint256 public solvency;
    uint256 public debt;

    uint256 public accCollateral;
    uint256 public accMaxDebt;
    uint256 public accDebt;

    uint256[MAX_TOKENS] public colRatios;

    function _genEarnToken(
        uint256 _noOfTokens
    ) internal returns (EToken[] memory, MockV3Aggregator[] memory) {
        EToken[] memory eTokens = new EToken[](_noOfTokens);
        MockV3Aggregator[] memory eTokensAgg = new MockV3Aggregator[](
            _noOfTokens
        );
        for (uint256 i = 0; i < _noOfTokens; i++) {
            EToken eToken = _deployEarnToken();
            eTokens[i] = eToken;
            eTokensAgg[i] = _deployOracleManagerForToken(eToken.underlying());
        }
        return (eTokens, eTokensAgg);
    }

    function _deployCollaterToken() internal returns (MockSimplePToken) {
        // deploy collateral token and pToken
        MockERC20Token mockUnderlying = new MockERC20Token();
        vm.label(address(mockUnderlying), "tokenCollateral");
        MockSimplePToken SimplePToken = new MockSimplePToken(
            ICentralRegistry(address(centralRegistry)),
            address(mockUnderlying),
            address(marketManagerIsolated)
        );
        vm.label(address(SimplePToken), "pToken");

        // start market for pToken
        uint256 startAmount = 77777;
        mockUnderlying.mint(address(this), startAmount);
        mockUnderlying.approve(address(SimplePToken), startAmount);
        marketManagerIsolated.listToken(address(SimplePToken));
        vm.label(address(marketManagerIsolated), "marketManager");
        return SimplePToken;
    }

    function _deployEarnToken() internal returns (EToken) {
        // start market for eToken
        MockERC20Token mockUnderlying = new MockERC20Token();
        vm.label(address(mockUnderlying), "tokenDebt");
        EToken earnToken = _deployEToken(address(mockUnderlying));
        vm.label(address(earnToken), "eToken");
        uint256 startAmount = 77777;
        mockUnderlying.mint(address(this), startAmount);
        mockUnderlying.approve(address(earnToken), startAmount);
        marketManagerIsolated.listToken(address(earnToken));
        return earnToken;
    }

    function _deployOracleManagerForToken(
        address token
    ) internal returns (MockV3Aggregator) {
        MockV3Aggregator oneUsd = new MockV3Aggregator(8, 1e8, 1e10, 1e5);
        chainlinkAdaptor.addAsset(token, address(oneUsd), 0, true);
        oracleManager.addAssetPriceFeed(token, address(chainlinkAdaptor));
        return oneUsd;
    }

    function _setCollateralData(address positionToken) internal {
        // set collateral factor
        marketManagerIsolated.updatePositionToken(
            positionToken,
            7000,
            4000,
            3000,
            200,
            400,
            1000
        );
        address[] memory tokens = new address[](1);
        tokens[0] = address(positionToken);
        uint256[] memory caps = new uint256[](1);
        caps[0] = 100_000e18;
        marketManagerIsolated.setCollateralCaps(tokens, caps);
    }

    function _genCollateral(
        address _user,
        MockSimplePToken _pToken,
        uint256 _amount
    ) internal {
        MockERC20Token tokenCollateral = MockERC20Token(_pToken.underlying());
        vm.startPrank(_user);
        tokenCollateral.mint(address(_user), _amount);
        tokenCollateral.approve(address(_pToken), _amount);
        _pToken.deposit(_amount, address(_user));
        vm.stopPrank();
    }

    function _postCollateral(
        address _user,
        MockSimplePToken _pToken,
        uint256 _amount
    ) internal {
        vm.prank(_user);
        _pToken.postCollateral(_amount);
    }

    function _supplyEToken(
        address _user,
        EToken _eToken,
        uint256 _amount
    ) internal {
        MockERC20Token tokenDebt = MockERC20Token(_eToken.underlying());
        vm.startPrank(_user);
        tokenDebt.mint(address(_user), _amount);
        tokenDebt.approve(address(_eToken), _amount);
        _eToken.mint(_amount);
        vm.stopPrank();
    }

    function _borrow(address _user, EToken _eToken, uint256 _amount) internal {
        vm.prank(_user);
        _eToken.borrow(_amount);
    }

    function _checkLiquidation(
        address _user,
        EToken _eToken,
        MockSimplePToken _pToken,
        uint256 _amount,
        bool _exact
    ) internal view returns (uint256 liqAmount, uint256 liquidatedTokens) {
        (liqAmount, liquidatedTokens) = marketManagerIsolated.canLiquidate(
            address(_eToken),
            address(_pToken),
            _user,
            _amount,
            _exact
        );

        console2.log(
            "liqAmount %s liquidatedTokens %s",
            liqAmount,
            liquidatedTokens
        );
    }

    function _prepareLiquidation(
        address _liquidator,
        EToken _eToken,
        uint256 _amount
    ) internal {
        vm.startPrank(_liquidator);
        console2.log("\n prep liq");
        MockERC20Token tokenDebt = MockERC20Token(_eToken.underlying());
        console2.log(
            "eToken %s underlying %s",
            address(_eToken),
            address(tokenDebt)
        );
        console2.log("liquidator %s", liquidator);
        tokenDebt.approve(address(_eToken), _amount);
        tokenDebt.mint(_liquidator, _amount); // this doesnt seem to alignt when a user is affected accross multiple markets
        vm.stopPrank();
    }

    function _prepareLiquidationMultiple(
        address _liquidator,
        EToken[] memory _eTokens
    ) internal {
        vm.startPrank(_liquidator);
        for (uint256 i = 0; i < _eTokens.length; i++) {
            MockERC20Token tokenDebt = MockERC20Token(
                _eTokens[i].underlying()
            );
            tokenDebt.approve(address(_eTokens[i]), 1e26);
            tokenDebt.mint(_liquidator, 1e26);
        }
        vm.stopPrank();
    }

    function _expectedLiquidation(
        uint256 _collateralAvailable,
        address _user,
        EToken _eToken,
        MockSimplePToken _pToken,
        bool _exact
    ) internal view returns (uint256, uint256) {
        (, , , , , , uint256 baseCFactor, uint256 cFactorCurve) = marketManagerIsolated
            .tokenData(address(_pToken));

        uint256 cFactor = baseCFactor + ((cFactorCurve * 1e18) / WAD);
        uint256 debtAmount = (cFactor * _eToken.debtBalanceCached(_user)) /
            WAD;

        PriceReturnData memory data = chainlinkAdaptor.getPrice(
            _pToken.underlying(),
            true,
            true
        );
        return
            _calcExpected(
                _collateralAvailable,
                _eToken,
                _pToken,
                cFactor,
                debtAmount,
                data.price,
                _exact
            );
    }

    function _calcExpected(
        uint256 _collateralAvailable,
        EToken _eToken,
        MockSimplePToken _pToken,
        uint256 /* cFactor */,
        uint256 debtAmount,
        uint256 price,
        bool _exact
    )
        internal
        view
        returns (uint256 expectedLiqAmount, uint256 collateralAvailable)
    {
        collateralAvailable = _collateralAvailable - 1;
        (
            ,
            ,
            ,
            ,
            uint256 liqBaseIncentive,
            uint256 liqCurve,
            ,

        ) = marketManagerIsolated.tokenData(address(_pToken));

        PriceReturnData memory earnTokenData = chainlinkAdaptor.getPrice(
            _eToken.underlying(),
            true,
            true
        );
        uint256 earnTokenPrice = uint256(earnTokenData.price);
        console2.log("earnTokenPrice %s", earnTokenPrice);
        console2.log("incentive %s %s", liqBaseIncentive, liqCurve);

        uint256 incentive = liqBaseIncentive + liqCurve;
        uint256 debtToCollateralRatio = (incentive * earnTokenPrice * WAD) /
            (price * _pToken.exchangeRateCached());
        uint256 amountAdjusted = (debtAmount * (10 ** _pToken.decimals())) /
            (10 ** _eToken.decimals());
        uint256 expectedLiquidatedTokens = (amountAdjusted *
            debtToCollateralRatio) / WAD;
        expectedLiqAmount = debtAmount;

        if (expectedLiquidatedTokens > collateralAvailable) {
            if (_exact) {
                expectedLiqAmount =
                    (expectedLiqAmount * collateralAvailable) /
                    expectedLiquidatedTokens;
            } else {
                expectedLiqAmount = FixedPointMathLib.mulDivUp(
                    expectedLiqAmount,
                    collateralAvailable,
                    expectedLiquidatedTokens
                );
            }
        }

        console2.log(
            "expectedLiqAmount %s collateralAvailable %s",
            expectedLiqAmount,
            collateralAvailable
        );
    }

    function _updateRoundData(
        MockV3Aggregator _agg,
        uint80 _roundId,
        int256 _price
    ) internal {
        _agg.updateRoundData(
            _roundId,
            _price,
            block.timestamp,
            block.timestamp
        );
    }

    function _liquidateAllExact(
        EToken[] memory eTokens,
        MockSimplePToken[] memory pTokens,
        address[] memory users
    ) internal {
        console2.log("_liquidateExact");
        for (uint256 i = 0; i < noOfUsersCollateral; i++) {
            for (uint256 j = 0; j < noOfPositionTokens; j++) {
                if (!auxiliaryData.flaggedForLiquidation(address(marketManagerIsolated), users[i], address(eTokens[j]), address(pTokens[j]))) {
                    console2.log(
                        "user %s not flagged for liquidation",
                        users[i]
                    );
                    continue;
                }
                if (pTokens[j].balanceOf(users[i]) == 0) {
                    continue;
                }
                for (uint256 k = 0; k < noOfEarnTokens; k++) {
                    if (
                        IERC20(eTokens[k].underlying()).balanceOf(users[i]) ==
                        0
                    ) {
                        continue;
                    }
                    console2.log(
                        "liquidate %s %s",
                        address(eTokens[k]),
                        address(pTokens[j])
                    );
                    _liquidate(eTokens[k], pTokens[j], users[i], true);
                    break;
                }
            }
        }
    }

    function _liquidateAllByEToken(
        EToken[] memory eTokens,
        MockSimplePToken[] memory pTokens,
        address[] memory users
    ) internal {
        for (uint256 i = 0; i < noOfUsersCollateral; i++) {
            console2.log("user %s", users[i]);
            for (uint256 j = 0; j < noOfPositionTokens; j++) {
                if (!auxiliaryData.flaggedForLiquidation(address(marketManagerIsolated), users[i], address(eTokens[j]), address(pTokens[j]))) {
                    console2.log(
                        "user %s not flagged for liquidation",
                        users[i]
                    );
                    continue;
                }
                if (pTokens[j].balanceOf(users[i]) == 0) {
                    continue;
                }
                for (uint256 k = 0; k < noOfEarnTokens; k++) {
                    if (
                        IERC20(eTokens[k].underlying()).balanceOf(users[i]) ==
                        0
                    ) {
                        continue;
                    }
                    console2.log(
                        "liquidate %s %s",
                        address(eTokens[k]),
                        address(pTokens[j])
                    );
                    _liquidate(eTokens[k], pTokens[j], users[i], false);
                    break;
                }
            }
        }
    }

    function _liquidate(
        EToken _eToken,
        MockSimplePToken _pToken,
        address _user,
        bool _exact
    ) internal {
        _eToken.accrueInterest();

        console2.log("\n expected liquidation");
        (uint256 expectedLiqAmount, ) = _expectedLiquidation(
            _pToken.balanceOf(_user),
            _user,
            _eToken,
            _pToken,
            _exact
        );

        console2.log("\n check liquidation");
        _checkLiquidation(_user, _eToken, _pToken, expectedLiqAmount, _exact);

        console2.log("\n prep liquidation");
        _prepareLiquidation(liquidator, _eToken, expectedLiqAmount);

        console2.log("\n liquidate");
        if (_exact) {
            _eTokenLiquidateExact(
                _eToken,
                _pToken,
                expectedLiqAmount,
                _user,
                liquidator
            );
        } else {
            _eTokenLiquidate(_eToken, _pToken, _user, liquidator);
        }
    }

    // function _liquidateAccount(
    //     address _account,
    //     address _liquidator
    // ) internal {
    //     vm.prank(_liquidator);
    //     marketManager.liquidateAccount(_account);
    // }

    function _eTokenLiquidateExact(
        EToken _eToken,
        MockSimplePToken _collateral,
        uint256 _expectedLiqAmount,
        address _account,
        address _liquidator
    ) internal {
        address[] memory accounts = new address[](1);
        accounts[0] = _account;
        uint256[] memory debtAmounts = new uint256[](1);
        debtAmounts[0] = _expectedLiqAmount;
        vm.prank(_liquidator);
        _eToken.liquidateExact(
            accounts,
            debtAmounts,
            address(_collateral)
        );
    }

    function _eTokenLiquidate(
        EToken _eToken,
        MockSimplePToken _collateral,
        address _account,
        address _liquidator
    ) internal {
        address[] memory accounts = new address[](1);
        accounts[0] = _account;
        uint256[] memory debtAmounts = new uint256[](1);
        debtAmounts[0] = 1000e6;
        vm.prank(_liquidator);
        _eToken.liquidate(
            accounts,
            address(_collateral)
        );
    }
}
