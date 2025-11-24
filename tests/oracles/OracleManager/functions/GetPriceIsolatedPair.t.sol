// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";
import { WAD } from "contracts/libraries/ConstantsLib.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { MockOracleAdaptor } from "contracts/mocks/MockOracleAdaptor.sol";
import { console2 } from "forge-std/console2.sol";

contract GetPriceIsolatedPairTest is TestBaseMarketIsolated {

    function setUp() public override {
        super.setUp();

        _prepareDAI(address(this), 77777);
        _prepareUSDC(address(this), 77777);
        dai.approve(address(borrowableCDAI), type(uint256).max);
        usdc.approve(address(borrowableCUSDC), type(uint256).max);

        marketManagerIsolated.listTokens(address(borrowableCDAI), address(borrowableCUSDC));

        _setCTokenConfigBasic(address(borrowableCDAI), 10_000_000e18, 10_000_000e18);
        _setCTokenConfigBasic(address(borrowableCUSDC), 10_000_000e6, 10_000_000e6);
    }

    function test_getPriceIsolatedPair_fail_whenCollateralTokenNotSupported() public {
        oracleManager.removeCTokenSupport(address(borrowableCDAI));

        vm.expectRevert(OracleManager.OracleManager__NotSupported.selector);
        oracleManager.getPriceIsolatedPair(
            address(borrowableCDAI),
            address(borrowableCUSDC),
            2
        );
    }

    function test_getPriceIsolatedPair_fail_whenDebtTokenNotSupported() public {
        oracleManager.removeCTokenSupport(address(borrowableCUSDC));

        vm.expectRevert(OracleManager.OracleManager__NotSupported.selector);
        oracleManager.getPriceIsolatedPair(
            address(borrowableCDAI),
            address(borrowableCUSDC),
            2
        );
    }

    // Not exactly needed, as the above tests already cover this.
    // This is only to address an audit finding where they found that entering the zero address
    // would trigger checking the native token price.
    function test_getPriceIsolatedPair_reverts_onZeroCollateral() public {
        vm.expectRevert(OracleManager.OracleManager__NotSupported.selector);
        oracleManager.getPriceIsolatedPair(address(0), address(borrowableCUSDC), 2);
    }

    function test_getPriceIsolatedPair_reverts_onZeroDebt() public {
        vm.expectRevert(OracleManager.OracleManager__NotSupported.selector);
        oracleManager.getPriceIsolatedPair(address(borrowableCDAI), address(0), 2);
    }

    function test_getPriceIsolatedPair_success() public {
        (uint256 collateralSharesPrice, uint256 debtUnderlyingPrice) =
            oracleManager.getPriceIsolatedPair(
                address(borrowableCDAI),
                address(borrowableCUSDC),
                2
            );

        (uint256 daiPrice, ) = oracleManager.getPrice(address(dai), true, true);
        uint256 exchangeRate = borrowableCDAI.exchangeRate();
        uint256 expectedCollateralPrice = FixedPointMathLib.mulDiv(daiPrice, exchangeRate, WAD);

        assertEq(collateralSharesPrice, expectedCollateralPrice);

        (uint256 usdcPrice, ) = oracleManager.getPrice(address(usdc), true, false);
        assertEq(debtUnderlyingPrice, usdcPrice);
    }

    // Test that getPriceIsolatedPair properly accrues interest and includes it in exchange rate
    function test_getPriceIsolatedPair_includesPendingInterestInExchangeRate() public {

        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareDAI(liquidityProvider, 10_000_000e18);
        vm.startPrank(liquidityProvider);
        dai.approve(address(borrowableCDAI), type(uint256).max);
        borrowableCDAI.deposit(10_000_000e18, liquidityProvider);
        vm.stopPrank();

        // Bump the exchange rate
        address borrower = makeAddr("borrower");
        _prepareUSDC(borrower, 8_000_000e6);
        vm.startPrank(borrower);
        usdc.approve(address(borrowableCUSDC), type(uint256).max);
        borrowableCUSDC.depositAsCollateral(8_000_000e6, borrower);
        borrowableCDAI.borrow(5_000_000e18, borrower);
        vm.stopPrank();

        uint256 initialExchangeRate = borrowableCDAI.exchangeRate();
        assertEq(initialExchangeRate, 1e18, "Initial exchange rate should be 1e18");

        // Skip 4 weeks to allow interest to accrue.
        skip(4 weeks);
        _refreshMockFeeds();

        // Do not accrue manually.

        (uint256 collateralSharesPrice, uint256 debtUnderlyingPrice) =
            oracleManager.getPriceIsolatedPair(
                address(borrowableCDAI),
                address(borrowableCUSDC),
                2
            );

        // Verify exchange rate has increased.
        uint256 exchangeRateAfterAccrual = borrowableCDAI.exchangeRate();
        assertGt(exchangeRateAfterAccrual, 1e18, "Exchange rate should be > 1e18 after interest accrual"
        );

        // Verify collateralSharesPrice is underlyingPrice * exchangeRateUpdated / 1e18
        (uint256 daiUnderlyingPrice, ) = oracleManager.getPrice(
            address(dai),
            true,
            true
        );

        uint256 expectedCollateralSharesPrice = FixedPointMathLib.mulDiv(
            daiUnderlyingPrice,
            exchangeRateAfterAccrual,
            WAD
        );

        assertEq(
            collateralSharesPrice,
            expectedCollateralSharesPrice,
            "collateralSharesPrice should equal underlyingPrice * exchangeRateUpdated / WAD"
        );

        console2.log("Initial exchange rate:", initialExchangeRate);
        console2.log("Exchange rate after accrual:", exchangeRateAfterAccrual);
    }

    function test_getPriceIsolatedPair_revertsWithBadSource_whenCollateralPriceZero() public {
        // Remove existing adaptors for DAI to allow using a mock adaptor
        oracleManager.removeAssetPricingAdaptor(_DAI_ADDRESS, address(chainlinkAdaptor));
        oracleManager.removeAssetPricingAdaptor(_DAI_ADDRESS, address(dualChainlinkAdaptor));

        // Set up mock adaptor that will be set to zero
        MockOracleAdaptor mockAdaptor = new MockOracleAdaptor(
            ICentralRegistry(address(centralRegistry)),
            "Mock"
        );
        oracleManager.addApprovedAdaptor(address(mockAdaptor));
        mockAdaptor.addAsset(_DAI_ADDRESS);
        mockAdaptor.setPrice(_DAI_ADDRESS, 1e18, 1e18);

        oracleManager.addAssetPricingAdaptor(
            _DAI_ADDRESS,
            address(mockAdaptor),
            180,
            130,
            180,
            130
        );

        // Force zero price for collateral underlying
        mockAdaptor.setPrice(_DAI_ADDRESS, 1e18, 0);

        vm.expectRevert(OracleManager.OracleManager__ErrorCodeFlagged.selector);
        oracleManager.getPriceIsolatedPair(
            address(borrowableCDAI),
            address(borrowableCUSDC),
            2
        );
    }

    function test_getPriceIsolatedPair_revertsWithBadSource_whenDebtPriceZero() public {
        // Remove existing adaptors for USDC to allow using a mock adaptor
        oracleManager.removeAssetPricingAdaptor(_USDC_ADDRESS, address(chainlinkAdaptor));
        oracleManager.removeAssetPricingAdaptor(_USDC_ADDRESS, address(dualChainlinkAdaptor));

        // Set up mock adaptor that will be set to zero
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

        // Force zero price for debt underlying
        mockAdaptor.setPrice(_USDC_ADDRESS, 1e18, 0);

        vm.expectRevert(OracleManager.OracleManager__ErrorCodeFlagged.selector);
        oracleManager.getPriceIsolatedPair(
            address(borrowableCDAI),
            address(borrowableCUSDC),
            2
        );
    }
}
