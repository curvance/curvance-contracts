// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { ProtocolReader } from "contracts/views/ProtocolReader.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { IOracleManager } from "contracts/interfaces/IOracleManager.sol";
import { BAD_SOURCE } from "contracts/libraries/ConstantsLib.sol";
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

    function test_hypotheticalLiquidityOf_activeDebtSubtractsExistingDebt()
        external
        view
    {
        ProtocolReader.HypotheticalResult memory liquidity =
            protocolReader.hypotheticalLiquidityOf(
                marketManagerIsolated,
                user1,
                address(0),
                0,
                0,
                0
            );

        assertGt(liquidity.debt, 0);
        assertGt(liquidity.maxDebt, liquidity.debt);
        assertEq(
            liquidity.collateralSurplus,
            liquidity.maxDebt - liquidity.debt
        );
        assertEq(liquidity.liquidityDeficit, 0);
    }

    function test_hypotheticalBorrowOf_activeDebtTopUpUsesPostBorrowDebtForLoanSize()
        external
        view
    {
        (
            uint256 collateralSurplus,
            uint256 liquidityDeficit,
            bool possible,
            bool loanSizeError,
            bool oracleError
        ) = protocolReader.hypotheticalBorrowOf(
            user1,
            address(borrowableCUSDC),
            1,
            0
        );

        assertTrue(possible, "active debt top-up should be simulated");
        assertGt(
            collateralSurplus,
            0,
            "tiny top-up should preserve collateral surplus"
        );
        assertEq(liquidityDeficit, 0);
        assertFalse(
            loanSizeError,
            "loan size check should use post-borrow active debt"
        );
        assertFalse(oracleError);
    }

    function test_hypotheticalBorrowOf_freshDebtTokenIncludesHypotheticalBorrow()
        external
    {
        _prepareDAI(user2, 1_000e18);

        vm.startPrank(user2);
        dai.approve(address(borrowableCDAI), 1_000e18);
        borrowableCDAI.depositAsCollateral(1_000e18, user2);
        vm.stopPrank();

        (
            uint256 collateralSurplus,
            uint256 liquidityDeficit,
            bool possible,
            bool loanSizeError,
            bool oracleError
        ) = protocolReader.hypotheticalBorrowOf(
            user2,
            address(borrowableCUSDC),
            1_000e6,
            0
        );

        assertTrue(possible, "fresh borrow should be simulated");
        assertEq(
            collateralSurplus,
            0,
            "over-limit fresh borrow should not report surplus"
        );
        assertGt(
            liquidityDeficit,
            0,
            "fresh borrow should include hypothetical debt"
        );
        assertFalse(loanSizeError);
        assertFalse(oracleError);
    }

    function test_hypotheticalLiquidityOf_skipsZeroExposureStaleDebtRow()
        external
    {
        vm.warp(
            marketManagerIsolated.accountAssets(user1) +
            marketManagerIsolated.MIN_HOLD_PERIOD()
        );

        uint256 repayBuffer = borrowableCUSDC.debtBalance(user1) + 10e6;
        _prepareUSDC(user1, repayBuffer);

        vm.startPrank(user1);
        usdc.approve(address(borrowableCUSDC), repayBuffer);
        borrowableCUSDC.repay(0);
        vm.stopPrank();

        assertEq(borrowableCUSDC.debtBalance(user1), 0);
        address[] memory accountAssets = marketManagerIsolated.assetsOf(user1);
        assertEq(accountAssets.length, 2, "closed debt row should remain listed");
        assertEq(accountAssets[1], address(borrowableCUSDC));

        uint256 staleTimestamp =
            block.timestamp - chainlinkAdaptor.DEFAULT_HEARTBEAT() - 1;
        mockUsdcFeed.setMockUpdatedAt(staleTimestamp);
        (, uint256 errorCode) =
            oracleManager.getPrice(_USDC_ADDRESS, true, false);
        assertEq(errorCode, BAD_SOURCE, "test setup should make USDC stale");

        ProtocolReader.HypotheticalResult memory liquidity =
            protocolReader.hypotheticalLiquidityOf(
                marketManagerIsolated,
                user1,
                address(0),
                0,
                0,
                0
            );

        assertGt(liquidity.collateral, 0, "live collateral should be priced");
        assertEq(liquidity.debt, 0, "closed debt should have no value");
        assertFalse(
            liquidity.oracleError,
            "zero-exposure stale debt row should not trip reader oracle error"
        );

        ProtocolReader.UserMarket memory market = _findUserMarket(
            protocolReader.getUserData(user1),
            address(marketManagerIsolated)
        );
        assertFalse(
            market.errorCodeHit,
            "user data should mirror zero-exposure skip"
        );
    }

    function test_hypotheticalLeverageOf_saturatedDebtCapReturnsZeroBorrowable()
        external
    {
        uint256 outstandingDebt = borrowableCUSDC.marketOutstandingDebt();
        assertGt(outstandingDebt, 1);

        _setCTokenConfigBasic(
            address(borrowableCUSDC),
            100_000e6,
            outstandingDebt - 1
        );

        (
            ,
            uint256 adjustedMaxLeverage,
            uint256 maxLeverage,
            uint256 maxDebtBorrowable,
            bool loanSizeError,
            bool oracleError
        ) = protocolReader.hypotheticalLeverageOf(
            user2,
            address(borrowableCDAI),
            address(borrowableCUSDC),
            100e18,
            0
        );

        assertEq(maxDebtBorrowable, 0);
        assertEq(adjustedMaxLeverage, 0);
        assertGt(maxLeverage, 0);
        assertFalse(loanSizeError);
        assertFalse(oracleError);
    }

    function test_hypotheticalLeverageOf_saturatedDebtCapSkipsDebtPrice()
        external
    {
        uint256 outstandingDebt = borrowableCUSDC.marketOutstandingDebt();
        assertGt(
            outstandingDebt,
            1,
            "precondition: market should have active debt"
        );

        _setCTokenConfigBasic(
            address(borrowableCUSDC),
            100_000e6,
            outstandingDebt - 1
        );

        vm.mockCallRevert(
            address(oracleManager),
            abi.encodeWithSelector(
                IOracleManager.getPrice.selector,
                borrowableCUSDC.asset(),
                true,
                false
            ),
            "debt price should not be read"
        );

        (
            ,
            uint256 adjustedMaxLeverage,
            uint256 maxLeverage,
            uint256 maxDebtBorrowable,
            bool loanSizeError,
            bool oracleError
        ) = protocolReader.hypotheticalLeverageOf(
            user2,
            address(borrowableCDAI),
            address(borrowableCUSDC),
            100e18,
            0
        );

        assertEq(
            maxDebtBorrowable,
            0,
            "saturated debt cap should leave no borrowable assets"
        );
        assertEq(
            adjustedMaxLeverage,
            0,
            "saturated debt cap should zero adjusted leverage"
        );
        assertGt(
            maxLeverage,
            0,
            "theoretical leverage should remain available"
        );
        assertFalse(loanSizeError, "loan size should remain valid");
        assertFalse(oracleError, "existing-position pricing should be clean");
    }

    function test_hypotheticalLeverageOf_projectedDebtCapReturnsZeroBorrowable()
        external
    {
        uint256 bufferTime = 30 days;
        uint256 cachedDebt = borrowableCUSDC.marketOutstandingDebt();
        uint256 projectedDebt = protocolReader.debtBalanceAtTimestamp(
            user1,
            address(borrowableCUSDC),
            block.timestamp + bufferTime
        );
        assertGt(
            projectedDebt,
            cachedDebt + 1,
            "precondition: buffered interest should exceed cached debt"
        );

        uint256 debtCap = projectedDebt - 1;
        assertLt(
            cachedDebt,
            debtCap,
            "precondition: cached debt should not saturate the cap"
        );

        _setCTokenConfigBasic(
            address(borrowableCUSDC),
            100_000e6,
            debtCap
        );

        vm.mockCallRevert(
            address(oracleManager),
            abi.encodeWithSelector(
                IOracleManager.getPrice.selector,
                borrowableCUSDC.asset(),
                true,
                false
            ),
            "debt price should not be read"
        );

        (
            ,
            uint256 adjustedMaxLeverage,
            uint256 maxLeverage,
            uint256 maxDebtBorrowable,
            bool loanSizeError,
            bool oracleError
        ) = protocolReader.hypotheticalLeverageOf(
            user2,
            address(borrowableCDAI),
            address(borrowableCUSDC),
            100e18,
            bufferTime
        );

        assertEq(
            maxDebtBorrowable,
            0,
            "projected debt cap should leave no borrowable assets"
        );
        assertEq(
            adjustedMaxLeverage,
            0,
            "projected debt cap should zero adjusted leverage"
        );
        assertGt(
            maxLeverage,
            0,
            "theoretical leverage should remain available"
        );
        assertFalse(loanSizeError, "loan size should remain valid");
        assertFalse(oracleError, "existing-position pricing should be clean");
    }

    function test_hypotheticalLeverageOf_aboveMaxDebtReturnsZeroBorrowable()
        external
    {
        _setCTokenConfigCustomRatio(
            address(borrowableCDAI),
            4000,
            100_000e18,
            100_000e18
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
        assertGt(
            liquidity.collateral,
            liquidity.debt,
            "precondition: account should remain solvent"
        );
        assertLe(
            liquidity.maxDebt,
            liquidity.debt,
            "precondition: account should be above borrowable max debt"
        );

        (
            uint256 currentLeverage,
            uint256 adjustedMaxLeverage,
            uint256 maxLeverage,
            uint256 maxDebtBorrowable,
            bool loanSizeError,
            bool oracleError
        ) = protocolReader.hypotheticalLeverageOf(
            user1,
            address(borrowableCDAI),
            address(borrowableCUSDC),
            0,
            0
        );

        assertGt(currentLeverage, 1e18, "active debt should create leverage");
        assertEq(
            adjustedMaxLeverage,
            0,
            "above-max account should not have adjusted leverage room"
        );
        assertEq(
            maxLeverage,
            currentLeverage,
            "above-max account max leverage should equal current leverage"
        );
        assertEq(
            maxDebtBorrowable,
            0,
            "above-max account should have no new borrowable debt"
        );
        assertFalse(loanSizeError, "loan size should remain valid");
        assertFalse(oracleError, "pricing should remain clean");
    }

    function test_hypotheticalLeverageOf_aboveMaxDebtWithNewCollateralUpdatesMaxLeverage()
        external
    {
        _setCTokenConfigCustomRatio(
            address(borrowableCDAI),
            4000,
            100_000e18,
            100_000e18
        );

        ProtocolReader.HypotheticalResult memory before =
            protocolReader.hypotheticalLiquidityOf(
                marketManagerIsolated,
                user1,
                address(0),
                0,
                0,
                0
        );
        uint256 newCollateralAssets = 100e18;
        (
            uint256 currentLeverage,
            uint256 adjustedMaxLeverage,
            uint256 maxLeverage,
            uint256 maxDebtBorrowable,
            bool loanSizeError,
            bool oracleError
        ) = protocolReader.hypotheticalLeverageOf(
            user1,
            address(borrowableCDAI),
            address(borrowableCUSDC),
            newCollateralAssets,
            0
        );

        (uint256 collateralPrice, uint256 priceError) =
            oracleManager.getPrice(address(borrowableCDAI), true, true);
        assertEq(priceError, 0, "precondition: collateral price should be clean");

        uint256 newCollateralValue = (
            borrowableCDAI.previewDeposit(newCollateralAssets) *
                collateralPrice
        ) / (10 ** borrowableCDAI.decimals());
        uint256 postCollateral = before.collateral + newCollateralValue;
        uint256 postMaxDebt =
            before.maxDebt + ((newCollateralValue * 4000) / 10_000);

        assertLe(
            postMaxDebt,
            before.debt,
            "precondition: account should still be above borrowable max debt"
        );

        assertEq(
            currentLeverage,
            (before.collateral * 1e18) / (before.collateral - before.debt),
            "current leverage should describe pre-action state"
        );
        assertEq(
            maxLeverage,
            (postCollateral * 1e18) / (postCollateral - before.debt),
            "max leverage should describe post-deposit no-borrow state"
        );
        assertLt(
            maxLeverage,
            currentLeverage,
            "added collateral should improve no-borrow leverage"
        );
        assertEq(
            adjustedMaxLeverage,
            0,
            "above-max account should not have adjusted leverage room"
        );
        assertEq(
            maxDebtBorrowable,
            0,
            "above-max account should have no new borrowable debt"
        );
        assertFalse(loanSizeError, "loan size should remain valid");
        assertFalse(oracleError, "pricing should remain clean");
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

    function _setCTokenConfigCustomRatio(
        address cToken,
        uint256 collRatio,
        uint256 collateralCap,
        uint256 debtCap
    ) internal {
        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = cToken;
        tokenConfig.collRatio = collRatio;
        tokenConfig.collReqSoft = 4000;
        tokenConfig.collReqHard = 3000;
        tokenConfig.liqIncBase = 1000;
        tokenConfig.liqIncHard = 1500;
        tokenConfig.liqIncMin = 10;
        tokenConfig.liqIncMax = 2000;
        tokenConfig.closeFactorBase = 2000;
        tokenConfig.closeFactorMin = 2000;
        tokenConfig.closeFactorMax = 5000;
        tokenConfig.collateralCap = collateralCap;
        tokenConfig.debtCap = debtCap;

        marketManagerIsolated.updateTokenConfig(tokenConfig);
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
