// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseOracleManager } from "../TestBaseOracleManager.sol";
import { IChainlink } from "contracts/interfaces/external/chainlink/IChainlink.sol";
import { ICToken, AccountSnapshot } from "contracts/interfaces/ICToken.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { MockOracleAdaptor } from "contracts/mocks/MockOracleAdaptor.sol";
import { console2 } from "forge-std/console2.sol";

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

    function test_getPricesForMarket_fail_whenNoFeedsAvailable() public {
        _prepareUSDC(address(this), 1e18);
        vm.prank(address(this));
        usdc.approve(address(borrowableCUSDC), 1e18);

        marketManagerIsolated.listTokens(address(pendleStrategyCTokenSTETH), address(borrowableCUSDC));

        vm.prank(address(marketManagerIsolated));
        borrowableCUSDC.initializeDeposits(address(this));

        vm.expectRevert(OracleManager.OracleManager__NotSupported.selector);
        oracleManager.getPricesForMarket(address(this), assets, 1);
    }

    function test_getPricesForMarket_fail_whenErrorCodeExceedsBreakpoint()
        public
    {
        _prepareUSDC(address(this), 1e18);
        vm.prank(address(this));
        usdc.approve(address(borrowableCUSDC), 1e18);

        oracleManager.addCTokenSupport(address(borrowableCUSDC));
        marketManagerIsolated.listTokens(address(pendleStrategyCTokenSTETH), address(borrowableCUSDC));

        vm.prank(address(marketManagerIsolated));
        borrowableCUSDC.initializeDeposits(address(this));

        _addSinglePriceFeed();

        vm.expectRevert(
            OracleManager.OracleManager__ErrorCodeFlagged.selector
        );
        oracleManager.getPricesForMarket(address(this), assets, 0);
    }

    function test_getPricesForMarket_success() public {
        _prepareUSDC(address(this), 1e18);
        vm.prank(address(this));
        usdc.approve(address(borrowableCUSDC), 1e18);

        oracleManager.addCTokenSupport(address(borrowableCUSDC));
        marketManagerIsolated.listTokens(address(pendleStrategyCTokenSTETH), address(borrowableCUSDC));

        _addSinglePriceFeed();

        (
            AccountSnapshot[] memory snapshots,
            uint256[] memory underlyingPrices,
            uint256 numAssets
        ) = oracleManager.getPricesForMarket(address(this), assets, 1);

        uint256 exchangeRate = borrowableCUSDC.exchangeRate();
        console2.log("exchangeRate", exchangeRate);

        (, int256 usdcPrice, , , ) = IChainlink(_CHAINLINK_USDC_USD)
            .latestRoundData();

        assertEq(numAssets, 1);

        for (uint256 i = 0; i < numAssets; i++) {
            assertEq(underlyingPrices[i], uint256(usdcPrice) * 1e10);
            assertEq(snapshots[i].asset, address(borrowableCUSDC));
            assertTrue(snapshots[i].isCollateral);
            assertEq(snapshots[i].decimals, usdc.decimals());
            assertEq(
                ICToken(assets[i]).balanceOf(address(this)),
                borrowableCUSDC.balanceOf(address(this)),
                "balanceOf"
            );
            assertEq(snapshots[i].debtBalance, 0, "debtBalance");
        }
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

    function test_getPricesForMarket_bubblesBadSource_whenZeroPrice() public {
        _prepareUSDC(address(this), 1e18);
        vm.prank(address(this));
        usdc.approve(address(borrowableCUSDC), 1e18);

        oracleManager.addCTokenSupport(address(borrowableCUSDC));
        marketManagerIsolated.listTokens(address(pendleStrategyCTokenSTETH), address(borrowableCUSDC));

        // Set up a mock adaptor
        MockOracleAdaptor mockAdaptor = new MockOracleAdaptor(
            ICentralRegistry(address(centralRegistry)),
            "Mock"
        );
        oracleManager.addApprovedAdaptor(address(mockAdaptor));
        mockAdaptor.addAsset(_USDC_ADDRESS);
        mockAdaptor.setPrice(_USDC_ADDRESS, 1e18, 1e18);

        oracleManager.addAssetPricingAdaptor(
            _USDC_ADDRESS,
            address(mockAdaptor),
            180,
            130,
            180,
            130
        );

        // Force zero price for underlying USDC
        mockAdaptor.setPrice(_USDC_ADDRESS, 1e18, 0);

        vm.expectRevert(OracleManager.OracleManager__ErrorCodeFlagged.selector);
        oracleManager.getPricesForMarket(address(this), assets, 2);
    }
}
