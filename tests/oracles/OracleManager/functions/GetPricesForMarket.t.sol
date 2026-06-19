// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseOracleManager } from "../TestBaseOracleManager.sol";
import { ICToken, AccountSnapshot } from "contracts/interfaces/ICToken.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { BAD_SOURCE } from "contracts/libraries/ConstantsLib.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { MockOracleAdaptor } from "contracts/mocks/MockOracleAdaptor.sol";

contract GetPricesForMarketTest is TestBaseOracleManager {
    address[] public assets;

    function setUp() public override {
        super.setUp();

        assets.push(address(borrowableCUSDC));

        _deployPendleStrategyCTokenSTETH();

        deal(address(LP_wstETH_24Dec2025), address(this), 1e18);
        _prepareUSDC(address(this), 1e18);

        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 1e18);
        
    }

    function test_getPricesForMarket_fail_whenAssetsLengthIsZero() public {
        assets.pop();

        (
            AccountSnapshot[] memory snapshots,
            uint256[] memory underlyingPrices,
            uint256 numAssets
        ) = oracleManager.getPricesForMarket(address(this), assets, 1);
        assertEq(snapshots.length, 0);
        assertEq(underlyingPrices.length, 0);
        assertEq(numAssets, 0);
    }

    function test_getPricesForMarket_fail_whenMarketNotStarted() public {
        vm.expectRevert();
        oracleManager.getPricesForMarket(address(this), assets, 1);
    }

    function test_getPricesForMarket_revertsErrorCodeFlagged_whenSequencerStartedAtIsFuture() public {
        sequencer.setMockStartedAt(block.timestamp + 1);

        vm.expectRevert(
            OracleManager.OracleManager__ErrorCodeFlagged.selector
        );
        oracleManager.getPricesForMarket(address(this), assets, BAD_SOURCE);
    }

    function test_getPricesForMarket_fail_whenNoFeedsAvailable() public {
        _openDaiCollateralUsdcDebtPosition();
        oracleManager.removeAssetPricingAdaptor(
            _DAI_ADDRESS,
            address(chainlinkAdaptor)
        );

        vm.expectRevert(OracleManager.OracleManager__NotSupported.selector);
        oracleManager.getPricesForMarket(
            user1,
            _daiCollateralUsdcDebtAssets(),
            BAD_SOURCE
        );
    }

    function test_getPricesForMarket_fail_whenErrorCodeExceedsBreakpoint()
        public
    {
        _openDaiCollateralUsdcDebtPosition();

        vm.expectRevert(
            OracleManager.OracleManager__ErrorCodeFlagged.selector
        );
        oracleManager.getPricesForMarket(
            user1,
            _daiCollateralUsdcDebtAssets(),
            0
        );
    }

    function test_getPricesForMarket_success() public {
        _openDaiCollateralUsdcDebtPosition();

        (
            AccountSnapshot[] memory snapshots,
            uint256[] memory prices,
            uint256 numAssets
        ) = oracleManager.getPricesForMarket(
            user1,
            _daiCollateralUsdcDebtAssets(),
            BAD_SOURCE
        );

        uint256 exchangeRate = borrowableCDAI.exchangeRate();
        (uint256 daiPrice, ) = oracleManager.getPrice(
            _DAI_ADDRESS,
            true,
            true
        );
        uint256 expectedSharesPrice = (daiPrice * exchangeRate) / 1e18;
        (uint256 usdcDebtPrice, ) = oracleManager.getPrice(
            _USDC_ADDRESS,
            true,
            false
        );

        assertEq(numAssets, 2);

        assertEq(prices[0], expectedSharesPrice);
        assertEq(snapshots[0].asset, address(borrowableCDAI));
        assertTrue(snapshots[0].isCollateral);
        assertEq(snapshots[0].decimals, dai.decimals());
        assertGt(snapshots[0].collateralPosted, 0, "collateralPosted");
        assertEq(snapshots[0].debtBalance, 0, "collateral debtBalance");

        assertEq(prices[1], usdcDebtPrice);
        assertEq(snapshots[1].asset, address(borrowableCUSDC));
        assertFalse(snapshots[1].isCollateral);
        assertEq(snapshots[1].decimals, usdc.decimals());
        assertEq(snapshots[1].collateralPosted, 0, "debt collateralPosted");
        assertGt(snapshots[1].debtBalance, 0, "debtBalance");
    }

    function test_getPricesForMarket_success_zeroExposureSkipsBadSourceOracle()
        public
    {
        _prepareUSDC(address(this), 1e18);
        vm.prank(address(this));
        usdc.approve(address(borrowableCUSDC), 1e18);

        _setMockFeedsInitial();
        oracleManager.addAssetPricingAdaptor(
            _USDC_ADDRESS,
            address(chainlinkAdaptor),
            180,
            130,
            180,
            130
        );
        oracleManager.addCTokenSupport(address(borrowableCUSDC));
        marketManagerIsolated.listTokens(address(pendleStrategyCTokenSTETH), address(borrowableCUSDC));

        uint256 staleTimestamp =
            block.timestamp - chainlinkAdaptor.DEFAULT_HEARTBEAT() - 1;
        mockUsdcFeed.setMockUpdatedAt(staleTimestamp);
        (, uint256 errorCode) =
            oracleManager.getPrice(_USDC_ADDRESS, true, true);
        assertEq(errorCode, BAD_SOURCE, "test setup should make USDC stale");

        (
            AccountSnapshot[] memory snapshots,
            uint256[] memory prices,
            uint256 numAssets
        ) = oracleManager.getPricesForMarket(user1, assets, BAD_SOURCE);

        assertEq(numAssets, 1);
        assertEq(prices[0], 0, "zero-exposure row should not be priced");
        assertEq(snapshots[0].asset, address(borrowableCUSDC));
        assertEq(snapshots[0].collateralPosted, 0);
        assertEq(snapshots[0].debtBalance, 0);
    }
function test_getPricesForMarket_accruesAndUsesExchangeRateAndDebt() public {
    // Set up market with two borrowable cTokens.
    _deployBorrowableCDAI();
    // switch to mock feeds to enable time skipping.
    _setMockFeedsInitial();
    oracleManager.addAssetPricingAdaptor(_USDC_ADDRESS, address(chainlinkAdaptor), 150, 180, 150, 180);
    oracleManager.addAssetPricingAdaptor(_DAI_ADDRESS, address(chainlinkAdaptor), 150, 180, 150, 180);

    oracleManager.addCTokenSupport(address(borrowableCDAI));
    oracleManager.addCTokenSupport(address(borrowableCUSDC));

    _prepareDAI(address(this), 77777);
    _prepareUSDC(address(this), 77777);
    dai.approve(address(borrowableCDAI), type(uint256).max);
    usdc.approve(address(borrowableCUSDC), type(uint256).max);

    marketManagerIsolated.listTokens(address(borrowableCDAI), address(borrowableCUSDC));
    _setCTokenConfigBasic(address(borrowableCDAI), 5000e18, 5000e18);
    _setCTokenConfigBasic(address(borrowableCUSDC), 5000e6, 5000e6);

    // Provide liquidity
    address liquidityProvider = makeAddr("liquidityProvider");
    _prepareUSDC(liquidityProvider, 1_000e6);
    vm.startPrank(liquidityProvider);
    usdc.approve(address(borrowableCUSDC), type(uint256).max);
    borrowableCUSDC.deposit(1_000e6, liquidityProvider);
    vm.stopPrank();

    // Create debt
    _prepareDAI(user1, 200e18);
    vm.startPrank(user1);
    dai.approve(address(borrowableCDAI), 200e18);
    borrowableCDAI.depositAsCollateral(200e18, user1);
    borrowableCUSDC.borrow(100e6, user1);
    vm.stopPrank();

    // Skip a huge amount of time
    skip(30 days);
    _refreshMockFeeds();

    // Use getPricesForMarket which is used along the path of canBorrowWithNotify.
    address[] memory assetsToPrice = new address[](2);
    assetsToPrice[0] = address(borrowableCDAI); // collateral
    assetsToPrice[1] = address(borrowableCUSDC);

    (AccountSnapshot[] memory snaps, uint256[] memory prices, ) =
        oracleManager.getPricesForMarket(user1, assetsToPrice, 2);

    // verify exchangeRate is applied
    uint256 exchangeRate = borrowableCDAI.exchangeRate();
    (uint256 daiPrice, ) = oracleManager.getPrice(address(dai), true, true);
    uint256 expectedSharesPrice = (daiPrice * exchangeRate) / 1e18;
    assertEq(prices[0], expectedSharesPrice, "collateral price must be underlying * exchangeRate");

    // snapshot reflects accrued interest
    assertGt(snaps[1].debtBalance, 100e6, "debt snapshot must include accrued interest");
}

    function test_getPricesForMarket_revertsWhenLiveCollateralOracleIsStale()
        public
    {
        _openDaiCollateralUsdcDebtPosition();

        uint256 staleTimestamp =
            block.timestamp - chainlinkAdaptor.DEFAULT_HEARTBEAT() - 1;
        mockDaiFeed.setMockUpdatedAt(staleTimestamp);
        (, uint256 errorCode) =
            oracleManager.getPrice(_DAI_ADDRESS, true, true);
        assertEq(errorCode, BAD_SOURCE, "test setup should make DAI stale");

        vm.expectRevert(OracleManager.OracleManager__ErrorCodeFlagged.selector);
        oracleManager.getPricesForMarket(
            user1,
            _daiCollateralUsdcDebtAssets(),
            BAD_SOURCE
        );
    }

    function test_getPricesForMarket_revertsWhenLiveDebtOracleIsStale()
        public
    {
        _openDaiCollateralUsdcDebtPosition();

        uint256 staleTimestamp =
            block.timestamp - chainlinkAdaptor.DEFAULT_HEARTBEAT() - 1;
        mockUsdcFeed.setMockUpdatedAt(staleTimestamp);
        (, uint256 errorCode) =
            oracleManager.getPrice(_USDC_ADDRESS, true, false);
        assertEq(errorCode, BAD_SOURCE, "test setup should make USDC stale");

        vm.expectRevert(OracleManager.OracleManager__ErrorCodeFlagged.selector);
        oracleManager.getPricesForMarket(
            user1,
            _daiCollateralUsdcDebtAssets(),
            BAD_SOURCE
        );
    }

    function test_getPricesForMarket_bubblesBadSource_whenZeroPrice() public {
        _openDaiCollateralUsdcDebtPosition();

        // Set up a mock adaptor
        MockOracleAdaptor mockAdaptor = new MockOracleAdaptor(
            ICentralRegistry(address(centralRegistry)),
            "Mock"
        );
        oracleManager.addApprovedAdaptor(address(mockAdaptor));
        mockAdaptor.addAsset(_DAI_ADDRESS);
        mockAdaptor.setPrice(_DAI_ADDRESS, 1e18, 1e18);

        oracleManager.replaceAssetPricingAdaptor(
            _DAI_ADDRESS,
            address(chainlinkAdaptor),
            address(mockAdaptor),
            180,
            130,
            180,
            130
        );

        // Force zero price for live collateral underlying.
        mockAdaptor.setPrice(_DAI_ADDRESS, 1e18, 0);

        vm.expectRevert(OracleManager.OracleManager__ErrorCodeFlagged.selector);
        oracleManager.getPricesForMarket(
            user1,
            _daiCollateralUsdcDebtAssets(),
            BAD_SOURCE
        );
    }

    function _openDaiCollateralUsdcDebtPosition() internal {
        _deployBorrowableCDAI();
        _setMockFeedsInitial();
        oracleManager.addAssetPricingAdaptor(_USDC_ADDRESS, address(chainlinkAdaptor), 150, 180, 150, 180);
        oracleManager.addAssetPricingAdaptor(_DAI_ADDRESS, address(chainlinkAdaptor), 150, 180, 150, 180);

        oracleManager.addCTokenSupport(address(borrowableCDAI));
        oracleManager.addCTokenSupport(address(borrowableCUSDC));

        _prepareDAI(address(this), 77777);
        _prepareUSDC(address(this), 77777);
        dai.approve(address(borrowableCDAI), type(uint256).max);
        usdc.approve(address(borrowableCUSDC), type(uint256).max);

        marketManagerIsolated.listTokens(address(borrowableCDAI), address(borrowableCUSDC));
        _setCTokenConfigBasic(address(borrowableCDAI), 5000e18, 5000e18);
        _setCTokenConfigBasic(address(borrowableCUSDC), 5000e6, 5000e6);

        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareUSDC(liquidityProvider, 1_000e6);
        vm.startPrank(liquidityProvider);
        usdc.approve(address(borrowableCUSDC), type(uint256).max);
        borrowableCUSDC.deposit(1_000e6, liquidityProvider);
        vm.stopPrank();

        _prepareDAI(user1, 200e18);
        vm.startPrank(user1);
        dai.approve(address(borrowableCDAI), 200e18);
        borrowableCDAI.depositAsCollateral(200e18, user1);
        borrowableCUSDC.borrow(100e6, user1);
        vm.stopPrank();
    }

    function _daiCollateralUsdcDebtAssets()
        internal
        view
        returns (address[] memory assetsToPrice)
    {
        assetsToPrice = new address[](2);
        assetsToPrice[0] = address(borrowableCDAI);
        assetsToPrice[1] = address(borrowableCUSDC);
    }
}
