// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { ProtocolReader } from "contracts/views/ProtocolReader.sol";
import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

contract GetUserDataTest is TestBaseMarketIsolated {
    function setUp() public override {
        super.setUp();

        _prepareUSDC(address(this), 2000e6 + 77777);
        _prepareDAI(address(this), 1e18 + 77777);
        _prepareDAI(user1, 2000e18);

        usdc.approve(address(borrowableCUSDC), 2000e6 + 77777);
        dai.approve(address(borrowableCDAI), 1e18 + 77777);

        marketManagerIsolated.listTokens(address(borrowableCDAI), address(borrowableCUSDC));

        _setCTokenConfigBasic(address(borrowableCDAI), 100_000e18, 100_000e18);
        _setCTokenConfigBasic(address(borrowableCUSDC), 100_000e18, 100_000e6);

        borrowableCDAI.mint(1e18, address(this));
        borrowableCUSDC.deposit(2000e6, address(this));

        vm.startPrank(user1);
        dai.approve(address(borrowableCDAI), 2000e18);
        borrowableCDAI.depositAsCollateral(2000e18, user1);
        borrowableCUSDC.borrow(1000e6, user1);
        vm.stopPrank();
    }

    function test_getUserData_emptyAccount_returnsZeroExposureTokens() external view {
        address emptyAccount = address(0x1234);
        ProtocolReader.UserData memory data = protocolReader.getUserData(emptyAccount);
        ProtocolReader.UserMarket memory market = _findUserMarket(
            data,
            address(marketManagerIsolated)
        );

        assertEq(market.collateral, 0);
        assertEq(market.maxDebt, 0);
        assertEq(market.debt, 0);
        assertEq(market.positionHealth, type(uint256).max);
        assertEq(market.cooldown, 20 minutes);
        assertFalse(market.errorCodeHit);
        assertEq(market.tokens.length, 2);

        for (uint256 i; i < market.tokens.length; ++i) {
            ProtocolReader.UserMarketToken memory token = market.tokens[i];
            assertEq(token.userAssetBalance, 0);
            assertEq(token.userShareBalance, 0);
            assertEq(token.userUnderlyingBalance, 0);
            assertEq(token.userCollateral, 0);
            assertEq(token.userDebt, 0);
            assertEq(token.liquidationPrice, type(uint256).max);
        }
    }

    function test_getUserData_activeMarket_matchesReaderSummaries() external view {
        ProtocolReader.UserData memory data = protocolReader.getUserData(user1);
        ProtocolReader.UserMarket memory market = _findUserMarket(
            data,
            address(marketManagerIsolated)
        );
        ProtocolReader.HypotheticalResult memory liquidity =
            protocolReader.hypotheticalLiquidityOf(
                marketManagerIsolated,
                user1,
                address(0),
                0,
                0,
                0
            );
        (
            uint256 cSoft,
            ,
            uint256 debt,
            ,
            bool errorCodeHit
        ) = protocolReader.liquidationValuesOf(marketManagerIsolated, user1, true);

        assertEq(market.collateral, liquidity.collateral);
        assertEq(market.maxDebt, liquidity.maxDebt);
        assertEq(market.debt, liquidity.debt);
        assertEq(market.errorCodeHit, errorCodeHit);
        assertEq(
            market.positionHealth,
            debt == 0 ? type(uint256).max : (cSoft * 1e18) / debt
        );

        ProtocolReader.UserMarketToken memory collateralToken = _findUserMarketToken(
            market,
            address(borrowableCDAI)
        );
        ProtocolReader.UserMarketToken memory debtToken = _findUserMarketToken(
            market,
            address(borrowableCUSDC)
        );

        assertGt(collateralToken.userCollateral, 0);
        assertLt(collateralToken.liquidationPrice, type(uint256).max);
        assertGt(debtToken.userDebt, 0);
        assertLt(debtToken.liquidationPrice, type(uint256).max);
    }

    function test_getMarketSummaries_emptyAccount_matchesUserDataSummary() external view {
        address[] memory markets = new address[](1);
        markets[0] = address(marketManagerIsolated);

        ProtocolReader.UserMarketSummary[] memory summaries =
            protocolReader.getMarketSummaries(markets, address(0x1234));
        ProtocolReader.UserMarket memory userMarket = _findUserMarket(
            protocolReader.getUserData(address(0x1234)),
            address(marketManagerIsolated)
        );

        assertEq(summaries.length, 1);
        assertEq(summaries[0]._address, userMarket._address);
        assertEq(summaries[0].collateral, userMarket.collateral);
        assertEq(summaries[0].maxDebt, userMarket.maxDebt);
        assertEq(summaries[0].debt, userMarket.debt);
        assertEq(summaries[0].positionHealth, userMarket.positionHealth);
        assertEq(summaries[0].cooldown, userMarket.cooldown);
        assertEq(summaries[0].errorCodeHit, userMarket.errorCodeHit);
    }

    function test_getMarketSummaries_activeAccount_matchesUserDataSummary() external view {
        address[] memory markets = new address[](1);
        markets[0] = address(marketManagerIsolated);

        ProtocolReader.UserMarketSummary[] memory summaries =
            protocolReader.getMarketSummaries(markets, user1);
        ProtocolReader.UserMarket memory userMarket = _findUserMarket(
            protocolReader.getUserData(user1),
            address(marketManagerIsolated)
        );

        assertEq(summaries.length, 1);
        assertEq(summaries[0]._address, userMarket._address);
        assertEq(summaries[0].collateral, userMarket.collateral);
        assertEq(summaries[0].maxDebt, userMarket.maxDebt);
        assertEq(summaries[0].debt, userMarket.debt);
        assertEq(summaries[0].positionHealth, userMarket.positionHealth);
        assertEq(summaries[0].cooldown, userMarket.cooldown);
        assertEq(summaries[0].errorCodeHit, userMarket.errorCodeHit);
    }

    function test_getLiquidationPrice_matchesUserDataTokenRows() external view {
        ProtocolReader.UserMarket memory market = _findUserMarket(
            protocolReader.getUserData(user1),
            address(marketManagerIsolated)
        );
        ProtocolReader.UserMarketToken memory collateralToken = _findUserMarketToken(
            market,
            address(borrowableCDAI)
        );
        ProtocolReader.UserMarketToken memory debtToken = _findUserMarketToken(
            market,
            address(borrowableCUSDC)
        );

        (uint256 collateralPrice, bool collateralError) = protocolReader.getLiquidationPrice(
            user1,
            address(borrowableCDAI),
            true
        );
        (uint256 debtPrice, bool debtError) = protocolReader.getLiquidationPrice(
            user1,
            address(borrowableCUSDC),
            false
        );

        assertFalse(collateralError);
        assertFalse(debtError);
        assertEq(collateralPrice, collateralToken.liquidationPrice);
        assertEq(debtPrice, debtToken.liquidationPrice);
    }

    function test_getLiquidationPrice_emptyAccount_returnsMaxWithoutError() external view {
        address emptyAccount = address(0x1234);

        (uint256 collateralPrice, bool collateralError) = protocolReader.getLiquidationPrice(
            emptyAccount,
            address(borrowableCDAI),
            true
        );
        (uint256 debtPrice, bool debtError) = protocolReader.getLiquidationPrice(
            emptyAccount,
            address(borrowableCUSDC),
            false
        );

        assertEq(collateralPrice, type(uint256).max);
        assertEq(debtPrice, type(uint256).max);
        assertFalse(collateralError);
        assertFalse(debtError);
    }

    function test_getMarketStates_activeAccount_matches_split_readers() external view {
        address[] memory markets = new address[](1);
        markets[0] = address(marketManagerIsolated);

        (
            ProtocolReader.DynamicMarketData[] memory dynamicMarkets,
            ProtocolReader.UserMarket[] memory userMarkets
        ) = protocolReader.getMarketStates(markets, user1);

        ProtocolReader.DynamicMarketData memory expectedDynamic = _findDynamicMarket(
            protocolReader.getDynamicMarketData(),
            address(marketManagerIsolated)
        );
        ProtocolReader.UserMarket memory expectedUser = _findUserMarket(
            protocolReader.getUserData(user1),
            address(marketManagerIsolated)
        );

        assertEq(dynamicMarkets.length, 1);
        assertEq(userMarkets.length, 1);
        _assertDynamicMarketEq(dynamicMarkets[0], expectedDynamic);
        _assertUserMarketEq(userMarkets[0], expectedUser);
    }

    function test_getAllDynamicState_activeAccount_matches_split_readers() external view {
        (
            ProtocolReader.DynamicMarketData[] memory dynamicMarkets,
            ProtocolReader.UserData memory userData
        ) = protocolReader.getAllDynamicState(user1);

        ProtocolReader.DynamicMarketData memory expectedDynamic = _findDynamicMarket(
            protocolReader.getDynamicMarketData(),
            address(marketManagerIsolated)
        );
        ProtocolReader.UserMarket memory expectedUser = _findUserMarket(
            protocolReader.getUserData(user1),
            address(marketManagerIsolated)
        );

        assertEq(dynamicMarkets.length, 1);
        assertEq(userData.markets.length, 1);
        _assertDynamicMarketEq(dynamicMarkets[0], expectedDynamic);
        _assertUserMarketEq(userData.markets[0], expectedUser);
    }

    function _findUserMarket(
        ProtocolReader.UserData memory data,
        address marketAddress
    ) internal pure returns (ProtocolReader.UserMarket memory market) {
        uint256 numMarkets = data.markets.length;
        for (uint256 i; i < numMarkets; ++i) {
            if (data.markets[i]._address == marketAddress) {
                return data.markets[i];
            }
        }

        revert("market not found");
    }

    function _findUserMarketToken(
        ProtocolReader.UserMarket memory market,
        address tokenAddress
    ) internal pure returns (ProtocolReader.UserMarketToken memory token) {
        uint256 numTokens = market.tokens.length;
        for (uint256 i; i < numTokens; ++i) {
            if (market.tokens[i]._address == tokenAddress) {
                return market.tokens[i];
            }
        }

        revert("token not found");
    }

    function _findDynamicMarket(
        ProtocolReader.DynamicMarketData[] memory data,
        address marketAddress
    ) internal pure returns (ProtocolReader.DynamicMarketData memory market) {
        uint256 numMarkets = data.length;
        for (uint256 i; i < numMarkets; ++i) {
            if (data[i]._address == marketAddress) {
                return data[i];
            }
        }

        revert("dynamic market not found");
    }

    function _assertUserMarketEq(
        ProtocolReader.UserMarket memory actual,
        ProtocolReader.UserMarket memory expected
    ) internal pure {
        assertEq(actual._address, expected._address);
        assertEq(actual.collateral, expected.collateral);
        assertEq(actual.maxDebt, expected.maxDebt);
        assertEq(actual.debt, expected.debt);
        assertEq(actual.positionHealth, expected.positionHealth);
        assertEq(actual.cooldown, expected.cooldown);
        assertEq(actual.errorCodeHit, expected.errorCodeHit);
        assertEq(actual.tokens.length, expected.tokens.length);

        uint256 numTokens = actual.tokens.length;
        for (uint256 i; i < numTokens; ++i) {
            ProtocolReader.UserMarketToken memory actualToken = actual.tokens[i];
            ProtocolReader.UserMarketToken memory expectedToken = expected.tokens[i];
            assertEq(actualToken._address, expectedToken._address);
            assertEq(actualToken.userAssetBalance, expectedToken.userAssetBalance);
            assertEq(actualToken.userShareBalance, expectedToken.userShareBalance);
            assertEq(actualToken.userUnderlyingBalance, expectedToken.userUnderlyingBalance);
            assertEq(actualToken.userCollateral, expectedToken.userCollateral);
            assertEq(actualToken.userDebt, expectedToken.userDebt);
            assertEq(actualToken.liquidationPrice, expectedToken.liquidationPrice);
        }
    }

    function _assertDynamicMarketEq(
        ProtocolReader.DynamicMarketData memory actual,
        ProtocolReader.DynamicMarketData memory expected
    ) internal pure {
        assertEq(actual._address, expected._address);
        assertEq(actual.tokens.length, expected.tokens.length);

        uint256 numTokens = actual.tokens.length;
        for (uint256 i; i < numTokens; ++i) {
            ProtocolReader.DynamicMarketToken memory actualToken = actual.tokens[i];
            ProtocolReader.DynamicMarketToken memory expectedToken = expected.tokens[i];
            assertEq(actualToken._address, expectedToken._address);
            assertEq(actualToken.exchangeRate, expectedToken.exchangeRate);
            assertEq(actualToken.totalSupply, expectedToken.totalSupply);
            assertEq(actualToken.totalAssets, expectedToken.totalAssets);
            assertEq(actualToken.collateral, expectedToken.collateral);
            assertEq(actualToken.debt, expectedToken.debt);
            assertEq(actualToken.sharePrice, expectedToken.sharePrice);
            assertEq(actualToken.assetPrice, expectedToken.assetPrice);
            assertEq(actualToken.sharePriceLower, expectedToken.sharePriceLower);
            assertEq(actualToken.assetPriceLower, expectedToken.assetPriceLower);
            assertEq(actualToken.borrowRate, expectedToken.borrowRate);
            assertEq(actualToken.predictedBorrowRate, expectedToken.predictedBorrowRate);
            assertEq(actualToken.utilizationRate, expectedToken.utilizationRate);
            assertEq(actualToken.supplyRate, expectedToken.supplyRate);
            assertEq(actualToken.liquidity, expectedToken.liquidity);
        }
    }
}
