// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";

import { WAD, CAUTION, BAD_SOURCE } from "contracts/libraries/ConstantsLib.sol";

import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";

import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";
import "forge-std/console2.sol";

contract CanLiquidateTest is TestBaseMarketIsolated {
    
    address[] accounts = new address[](1);
    uint256[] debtAmounts = new uint256[](1);

    uint256 borrowableCTokenUnderlyingPrice = 1e18;

    function setUp() public override {
        super.setUp();

        accounts[0] = user1;
        debtAmounts[0] = 1000e6;
    }
    
    function test_canLiquidate_fail_whenBorrowableCTokenNotListed() public {
        IMarketManager.LiqAction memory action = IMarketManager.LiqAction({
            collateralToken: address(pendleStrategyCTokenSTETH),
            debtToken: address(borrowableCUSDC),
            numAccounts: 1,
            liquidateExact: false,
            liquidatedShares: 0,
            debtRepaid: 0,
            badDebt: 0
        });

        vm.prank(address(borrowableCUSDC));

        vm.expectRevert(MarketManagerIsolated.MarketManager__TokenNotListed.selector);
        marketManagerIsolated.canLiquidate(
            debtAmounts,
            address(this),
            accounts,
            action
        );
    }

    function test_canLiquidate_fail_whenCTokenNotListed() public {
        // marketManager.listToken(address(borrowableCUSDC));
        IMarketManager.LiqAction memory action = IMarketManager.LiqAction({
            collateralToken: address(pendleStrategyCTokenSTETH),
            debtToken: address(borrowableCUSDC),
            numAccounts: 1,
            liquidateExact: false,
            liquidatedShares: 0,
            debtRepaid: 0,
            badDebt: 0
        });

        vm.prank(address(borrowableCUSDC));

        vm.expectRevert(MarketManagerIsolated.MarketManager__TokenNotListed.selector);
        marketManagerIsolated.canLiquidate(
            debtAmounts,
            address(this),
            accounts,
            action
        );
    }

    function test_canLiquidate_fail_whenCollRatioZero() public {
        deal(address(LP_wstETH_24Dec2025), address(this), 77777);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 77777);

        deal(address(_USDC_ADDRESS), address(this), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);

        marketManagerIsolated.listTokens(address(pendleStrategyCTokenSTETH), address(borrowableCUSDC));

        IMarketManager.LiqAction memory action = IMarketManager.LiqAction({
            collateralToken: address(pendleStrategyCTokenSTETH),
            debtToken: address(borrowableCUSDC),
            numAccounts: 1,
            liquidateExact: false,
            liquidatedShares: 0,
            debtRepaid: 0,
            badDebt: 0
        });

        vm.prank(address(borrowableCUSDC));

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__InvalidParameter.selector
        );
        marketManagerIsolated.canLiquidate(
            debtAmounts,
            address(this),
            accounts,
            action
        );
    }

    function test_canLiquidate_fail_whenUserHasNotEnteredAnyMarket() public {
        deal(address(LP_wstETH_24Dec2025), address(this), 77777);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 77777);

        deal(address(_USDC_ADDRESS), address(this), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);

        marketManagerIsolated.listTokens(address(pendleStrategyCTokenSTETH), address(borrowableCUSDC));
        _setCTokenConfigBasic(address(pendleStrategyCTokenSTETH), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 0, 1_000_000e6);

        IMarketManager.LiqAction memory action = IMarketManager.LiqAction({
            collateralToken: address(pendleStrategyCTokenSTETH),
            debtToken: address(borrowableCUSDC),
            numAccounts: 1,
            liquidateExact: false,
            liquidatedShares: 0,
            debtRepaid: 0,
            badDebt: 0
        });

        vm.prank(address(borrowableCUSDC));

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__NoLiquidationAvailable.selector
        );
        marketManagerIsolated.canLiquidate(
            debtAmounts,
            address(this),
            accounts,
            action
        );
    }

    function test_canLiquidate_fail_whenAccountHasNoBorrowsAndCollateralPosted()
        public
    {
        deal(address(LP_wstETH_24Dec2025), address(this), 77777);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 77777);

        deal(address(_USDC_ADDRESS), address(this), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);

        marketManagerIsolated.listTokens(address(pendleStrategyCTokenSTETH), address(borrowableCUSDC));
        _setCTokenConfigBasic(address(pendleStrategyCTokenSTETH), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 0, 1_000_000e6);

        IMarketManager.LiqAction memory action = IMarketManager.LiqAction({
            collateralToken: address(pendleStrategyCTokenSTETH),
            debtToken: address(borrowableCUSDC),
            numAccounts: 1,
            liquidateExact: false,
            liquidatedShares: 0,
            debtRepaid: 0,
            badDebt: 0
        });

        vm.prank(address(borrowableCUSDC));

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__NoLiquidationAvailable.selector
        );
        marketManagerIsolated.canLiquidate(
            debtAmounts,
            address(this),
            accounts,
            action
        );
    }

    function test_canLiquidate_fail_whenShortfallInsufficient() public {
        skip(gaugeManager.gaugeStartTime() - block.timestamp);

        chainlinkEthUsd.updateRoundData(
            0,
            1500e8,
            block.timestamp,
            block.timestamp
        );
        chainlinkUsdcUsd.updateRoundData(
            0,
            1e8,
            block.timestamp,
            block.timestamp
        );
        chainlinkUsdcEth.updateRoundData(
            0,
            1500e18,
            block.timestamp,
            block.timestamp
        );
        deal(address(LP_wstETH_24Dec2025), address(this), 77777);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 77777);

        deal(address(_USDC_ADDRESS), address(this), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);

        marketManagerIsolated.listTokens(address(pendleStrategyCTokenSTETH), address(borrowableCUSDC));

        _setCTokenConfigBasic(address(pendleStrategyCTokenSTETH), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 0, 1_000_000e6);

        deal(address(LP_wstETH_24Dec2025), user1, 10_000e18);
        vm.startPrank(user1);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 1_000e18);
        pendleStrategyCTokenSTETH.deposit(1_000e18, user1);
        pendleStrategyCTokenSTETH.postCollateral(999e18);
        vm.stopPrank();

        IMarketManager.LiqAction memory action = IMarketManager.LiqAction({
            collateralToken: address(pendleStrategyCTokenSTETH),
            debtToken: address(borrowableCUSDC),
            numAccounts: 1,
            liquidateExact: false,
            liquidatedShares: 0,
            debtRepaid: 0,
            badDebt: 0
        });

        vm.prank(address(borrowableCUSDC));

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__NoLiquidationAvailable.selector
        );
        marketManagerIsolated.canLiquidate(
            debtAmounts,
            address(this),
            accounts,
            action
        );
    }

    function test_canLiquidate_success() public {
        deal(address(LP_wstETH_24Dec2025), address(this), 77777);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 77777);

        deal(address(_USDC_ADDRESS), address(this), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);

        marketManagerIsolated.listTokens(address(pendleStrategyCTokenSTETH), address(borrowableCUSDC));

        _setCTokenConfigBasic(address(pendleStrategyCTokenSTETH), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 0, 100_000e6);

        // provide liquidity
        deal(_USDC_ADDRESS, address(this), 100_000e6);
        usdc.approve(address(borrowableCUSDC), 100_000e6);
        borrowableCUSDC.deposit(100_000e6, address(this));

        _setupUserPositionAndOracles();

        IMarketManager.LiqAction memory action = IMarketManager.LiqAction({
            collateralToken: address(pendleStrategyCTokenSTETH),
            debtToken: address(borrowableCUSDC),
            numAccounts: 1,
            liquidateExact: false,
            liquidatedShares: 0,
            debtRepaid: 0,
            badDebt: 0
        });
        _setPendleStEthLpPrice(1100e8);
        
        vm.prank(address(borrowableCUSDC));

        // =================== RESULTS ==================
        (
            IMarketManager.LiqResult memory result,
            uint256[] memory debtAmountsReturned
        ) = marketManagerIsolated.canLiquidate(
            debtAmounts,
            address(this),
            accounts,
            action
        );

        // print out all values returned by canLiquidate
        console2.log("==== CanLiquidate Results ====");
        console2.log("result.liquidatedShares[0]", result.liquidatedShares[0]);
        console2.log("result.debtRepaid", result.debtRepaid);
        console2.log("result.badDebtRealized", result.badDebtRealized);
        console2.log("debtAmounts", debtAmountsReturned[0]);

        uint256 collateralAvailable = 1e18 - 1;
        
        ExpectedLiquidationValues memory expectedLiqValues = 
            _calculateExpectedLiquidationValues(
                LiquidationParams ({
                    borrower: user1,
                    collateralToken: address(pendleStrategyCTokenSTETH),
                    borrowedToken: address(borrowableCUSDC),
                    isLiquidateExact: false,
                    liquidateExactAmount: 0,
                    isAuction: false,
                    isMultiMarketTest: false,
                    marketManagerId: 0
                })
            );


        // Validate result.liquidatedShares[0]
        assertEq(
            result.liquidatedShares[0],
            collateralAvailable, 
            "liquidatedShares = collateralAvailable mismatch"
        );

        assertEq(
            result.liquidatedShares[0],
            expectedLiqValues.collateralLiquidated,
            "liquidatedShares[0] = expectedCollateralSeized mismatch"
        );

        // validate result.debtRepaid
        assertEq(
            result.debtRepaid,
            expectedLiqValues.debtRepaid, 
            "debtRepaid = expectedRepayAmount mismatch"
        );

        // Should have bad debt
        assertEq(result.badDebtRealized, expectedLiqValues.badDebt, "badDebtRealized mismatch");

        // validate debtAmountsReturned, debt cleared
        assertEq(debtAmountsReturned[0], 1e9, "debtAmountsReturned mismatch");
    }

    function test_canLiquidate_success_whenDebtOracleInCaution() public {
        _setupLiquidationFixture();
        _setPendleStEthLpPrice(1100e8);
        _setUsdcDualFeedAnswer(1.016e8, CAUTION);

        IMarketManager.LiqAction memory action = _defaultLiqAction();

        vm.prank(address(borrowableCUSDC));
        (IMarketManager.LiqResult memory result, ) = marketManagerIsolated.canLiquidate(
            debtAmounts,
            address(this),
            accounts,
            action
        );

        assertGt(result.debtRepaid, 0, "CAUTION should not block liquidation");
    }

    function test_canLiquidate_fail_whenDebtOracleBadSource() public {
        _setupLiquidationFixture();
        _setPendleStEthLpPrice(1100e8);
        _setUsdcDualFeedAnswer(1.03e8, BAD_SOURCE);

        IMarketManager.LiqAction memory action = _defaultLiqAction();

        vm.expectRevert(OracleManager.OracleManager__ErrorCodeFlagged.selector);
        vm.prank(address(borrowableCUSDC));
        marketManagerIsolated.canLiquidate(
            debtAmounts,
            address(this),
            accounts,
            action
        );
    }

    function test_canLiquidate_fail_whenDebtOracleIsStale() public {
        _setupLiquidationFixture();
        _setPendleStEthLpPrice(1100e8);
        _makeDefaultUsdcFeedsStale(BAD_SOURCE);

        IMarketManager.LiqAction memory action = _defaultLiqAction();

        vm.expectRevert(OracleManager.OracleManager__ErrorCodeFlagged.selector);
        vm.prank(address(borrowableCUSDC));
        marketManagerIsolated.canLiquidate(
            debtAmounts,
            address(this),
            accounts,
            action
        );
    }

    function _setupUserPositionAndOracles() internal {
        skip(gaugeManager.gaugeStartTime() - block.timestamp);

        chainlinkUsdcUsd.updateRoundData(
            0,
            1e8,
            block.timestamp,
            block.timestamp
        );

        // Mint pendleStrategyCTokenSTETH for collateral
        deal(address(LP_wstETH_24Dec2025), user1, 10_000e18);
        vm.startPrank(user1);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 1_000e18);
        pendleStrategyCTokenSTETH.deposit(1e18, user1);
        pendleStrategyCTokenSTETH.postCollateral(1e18 - 1);

        // Borrow eUSDC with pendleStrategyCTokenSTETH as collateral
        _prepareUSDC(address(borrowableCUSDC), 100_000e6);
        borrowableCUSDC.borrow(1000e6, user1);
        vm.stopPrank();

        assertEq(usdc.balanceOf(user1), 1000e6);
    }

    function _setupLiquidationFixture() internal {
        deal(address(LP_wstETH_24Dec2025), address(this), 77777);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 77777);

        deal(address(_USDC_ADDRESS), address(this), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);

        marketManagerIsolated.listTokens(address(pendleStrategyCTokenSTETH), address(borrowableCUSDC));

        _setCTokenConfigBasic(address(pendleStrategyCTokenSTETH), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 0, 100_000e6);

        deal(_USDC_ADDRESS, address(this), 100_000e6);
        usdc.approve(address(borrowableCUSDC), 100_000e6);
        borrowableCUSDC.deposit(100_000e6, address(this));

        _setupUserPositionAndOracles();
    }

    function _defaultLiqAction()
        internal
        view
        returns (IMarketManager.LiqAction memory action)
    {
        action = IMarketManager.LiqAction({
            collateralToken: address(pendleStrategyCTokenSTETH),
            debtToken: address(borrowableCUSDC),
            numAccounts: 1,
            liquidateExact: false,
            liquidatedShares: 0,
            debtRepaid: 0,
            badDebt: 0
        });
    }

    function _setUsdcDualFeedAnswer(
        int256 answer,
        uint256 expectedErrorCode
    ) internal {
        MockV3Aggregator usdcFeed = new MockV3Aggregator(8, answer);
        dualChainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            true,
            address(usdcFeed),
            0
        );

        (, uint256 errorCode) =
            oracleManager.getPrice(_USDC_ADDRESS, true, true);
        assertEq(errorCode, expectedErrorCode, "unexpected USDC oracle status");
    }

    function _makeDefaultUsdcFeedsStale(
        uint256 expectedErrorCode
    ) internal {
        uint256 staleTimestamp =
            block.timestamp - chainlinkAdaptor.DEFAULT_HEARTBEAT() - 1;
        mockUsdcFeed.setMockUpdatedAt(staleTimestamp);

        (, uint256 errorCode) =
            oracleManager.getPrice(_USDC_ADDRESS, true, true);
        assertEq(errorCode, expectedErrorCode, "unexpected stale USDC status");
    }

}
