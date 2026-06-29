// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseBorrowableCToken } from "../TestBaseBorrowableCToken.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { PluginDelegable } from "contracts/libraries/PluginDelegable.sol";
import { MarketManagerIsolated, LiquidityManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { BAD_SOURCE } from "contracts/libraries/ConstantsLib.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { ICToken } from "contracts/interfaces/ICToken.sol";
import { IPositionManager } from "contracts/interfaces/IPositionManager.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { MockPositionManager } from "contracts/mocks/MockPositionManager.sol";
import { Multicall } from "contracts/libraries/Multicall.sol";
import { ReentrancyGuard } from "contracts/libraries/ReentrancyGuardTransient.sol";
import { ERC165 } from "contracts/libraries/external/ERC165.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";

contract BorrowableCTokenBorrowTest is TestBaseBorrowableCToken {
    event Borrow(uint256 assets, uint256 newDebtAssets, address account);

    function test_borrowableCTokenBorrowFor_fail_whenBorrowIsNotAllowed() public {
        marketManagerIsolated.setBorrowPaused(address(borrowableCUSDC), true);

        _delegateToUser();

        vm.startPrank(user2);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        borrowableCUSDC.borrowFor(100e6, user2, user1);

        vm.stopPrank();
    }

    function test_borrowableCTokenBorrowFor_fail_whenNotDelegated() public {
        _setCTokenConfigBasic(address(pendleStrategyCTokenSTETH), 100_000e18, 0);

        _provideLiquidity();
        _depositCollateral();

        vm.startPrank(user2);

        vm.expectRevert(PluginDelegable.PluginDelegable__Unauthorized.selector);
        borrowableCUSDC.borrowFor(100e6, user1, user1);

        vm.stopPrank();
    }

    function test_borrowableCTokenBorrowFor_fail_whenBorrowAmountExceedsAssetsHeld() public {
        _setCTokenConfigBasic(address(pendleStrategyCTokenSTETH), 100_000e18, 0);

        _provideLiquidity();
        _depositCollateral();
        _delegateToUser();

        _harvestPendleLP(1 weeks);

        uint256 assetsHeld = borrowableCUSDC.assetsHeld();

        vm.startPrank(user2);

        vm.expectRevert(
            BorrowableCToken.BorrowableCToken__InsufficientAssetsHeld.selector
        );
        borrowableCUSDC.borrowFor(assetsHeld + 1, user2, user1);

        vm.stopPrank();
    }

    function test_borrowableCTokenBorrowFor_fail_whenBorrowAmountExceedsDebtCap() public {
        _setCTokenConfigBasic(address(pendleStrategyCTokenSTETH), 100_000e18, 0);

        _provideLiquidity();
        _depositCollateral();
        _delegateToUser();

        skip(69 minutes);
        _harvestPendleLP(1 weeks);

        _setCTokenConfigBasic(address(borrowableCUSDC), 100_000e18, 0);

        vm.startPrank(user2);

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__CapReached.selector
        );

        borrowableCUSDC.borrowFor(100e6, user2, user1);
        vm.stopPrank();
    }

    function test_borrowableCTokenBorrowFor_fail_whenCollateralPostedInBorrowableCToken() public {
        _setCTokenConfigBasic(address(pendleStrategyCTokenSTETH), 100_000e18, 0);

        _provideLiquidity();
        _depositCollateral();
        _delegateToUser();

        // Provide liquidity in borrowable cUSDC.
        vm.startPrank(user1);
        _prepareUSDC(user1, 10e6);
        usdc.approve(address(borrowableCUSDC), 10e6);
        borrowableCUSDC.depositAsCollateral(10e6, user1);
        vm.stopPrank();

        _delegateToUser();
        vm.stopPrank();
        vm.startPrank(user2);

        vm.expectRevert(
            BorrowableCToken.BorrowableCToken__CollateralPositionActive.selector
        );

        borrowableCUSDC.borrowFor(20e6, user2, user1);
        vm.stopPrank();
    }

    function test_borrowableCTokenBorrowFor_fail_whenFreshBorrowDebtOracleIsStale()
        public
    {
        _provideUsdcLiquidity(1_000e6);
        _postPendleCollateral(user1, 10e18);
        _delegateToUser();

        address[] memory assetsBefore = marketManagerIsolated.assetsOf(user1);
        assertEq(assetsBefore.length, 1, "fresh borrower should only have collateral row");
        assertEq(assetsBefore[0], address(pendleStrategyCTokenSTETH));

        uint256 receiverUsdcBefore = usdc.balanceOf(user2);
        uint256 debtBefore = borrowableCUSDC.debtBalance(user1);
        uint256 marketDebtBefore = borrowableCUSDC.marketOutstandingDebt();

        _makeUsdcDebtOracleStale();

        vm.expectRevert(LiquidityManagerIsolated.LiquidityManager__PriceError.selector);
        vm.prank(user2);
        borrowableCUSDC.borrowFor(100e6, user2, user1);

        assertEq(usdc.balanceOf(user2), receiverUsdcBefore, "delegated borrow should not transfer assets");
        assertEq(borrowableCUSDC.debtBalance(user1), debtBefore, "debt should not open");
        assertEq(borrowableCUSDC.marketOutstandingDebt(), marketDebtBefore, "market debt should not change");

        address[] memory assetsAfter = marketManagerIsolated.assetsOf(user1);
        assertEq(assetsAfter.length, assetsBefore.length, "failed borrowFor should not retain debt row");
        assertEq(assetsAfter[0], assetsBefore[0]);
    }

    function test_borrowableCTokenBorrowFor_fail_whenFreshBorrowDebtOracleIsCaution()
        public
    {
        _provideUsdcLiquidity(1_000e6);
        _postPendleCollateral(user1, 10e18);
        _delegateToUser();

        address[] memory assetsBefore = marketManagerIsolated.assetsOf(user1);
        assertEq(assetsBefore.length, 1, "fresh borrower should only have collateral row");
        assertEq(assetsBefore[0], address(pendleStrategyCTokenSTETH));

        uint256 receiverUsdcBefore = usdc.balanceOf(user2);
        uint256 debtBefore = borrowableCUSDC.debtBalance(user1);
        uint256 marketDebtBefore = borrowableCUSDC.marketOutstandingDebt();

        _makeUsdcDebtOracleCaution();

        vm.expectRevert(LiquidityManagerIsolated.LiquidityManager__PriceError.selector);
        vm.prank(user2);
        borrowableCUSDC.borrowFor(100e6, user2, user1);

        assertEq(usdc.balanceOf(user2), receiverUsdcBefore, "delegated borrow should not transfer assets");
        assertEq(borrowableCUSDC.debtBalance(user1), debtBefore, "debt should not open");
        assertEq(borrowableCUSDC.marketOutstandingDebt(), marketDebtBefore, "market debt should not change");

        address[] memory assetsAfter = marketManagerIsolated.assetsOf(user1);
        assertEq(assetsAfter.length, assetsBefore.length, "failed borrowFor should not retain debt row");
        assertEq(assetsAfter[0], assetsBefore[0]);
    }

    function test_borrowableCTokenBorrowFor_fail_whenRetainedZeroDebtRowReborrowDebtOracleIsStale()
        public
    {
        _provideUsdcLiquidity(2_000e6);
        _openAndFullyRepayUsdcDebt(user1, 100e6);
        _delegateToUser();

        assertEq(borrowableCUSDC.debtBalance(user1), 0, "debt should be closed");
        address[] memory assetsBefore = marketManagerIsolated.assetsOf(user1);
        assertEq(assetsBefore.length, 2, "V1 retains closed debt row");
        assertEq(assetsBefore[1], address(borrowableCUSDC), "retained row should be debt cToken");

        uint256 receiverUsdcBefore = usdc.balanceOf(user2);
        uint256 marketDebtBefore = borrowableCUSDC.marketOutstandingDebt();

        _makeUsdcDebtOracleStale();

        vm.expectRevert(LiquidityManagerIsolated.LiquidityManager__PriceError.selector);
        vm.prank(user2);
        borrowableCUSDC.borrowFor(100e6, user2, user1);

        assertEq(usdc.balanceOf(user2), receiverUsdcBefore, "reborrow should not transfer assets");
        assertEq(borrowableCUSDC.debtBalance(user1), 0, "debt should remain closed");
        assertEq(borrowableCUSDC.marketOutstandingDebt(), marketDebtBefore, "market debt should not change");

        address[] memory assetsAfter = marketManagerIsolated.assetsOf(user1);
        assertEq(assetsAfter.length, assetsBefore.length, "retained row count should be unchanged");
        assertEq(assetsAfter[0], assetsBefore[0]);
        assertEq(assetsAfter[1], assetsBefore[1]);
    }

    function test_borrowableCTokenBorrowFor_fail_whenRetainedZeroDebtRowReborrowDebtOracleIsCaution()
        public
    {
        _provideUsdcLiquidity(2_000e6);
        _openAndFullyRepayUsdcDebt(user1, 100e6);
        _delegateToUser();

        assertEq(borrowableCUSDC.debtBalance(user1), 0, "debt should be closed");
        address[] memory assetsBefore = marketManagerIsolated.assetsOf(user1);
        assertEq(assetsBefore.length, 2, "V1 retains closed debt row");
        assertEq(assetsBefore[1], address(borrowableCUSDC), "retained row should be debt cToken");

        uint256 receiverUsdcBefore = usdc.balanceOf(user2);
        uint256 marketDebtBefore = borrowableCUSDC.marketOutstandingDebt();

        _makeUsdcDebtOracleCaution();

        vm.expectRevert(LiquidityManagerIsolated.LiquidityManager__PriceError.selector);
        vm.prank(user2);
        borrowableCUSDC.borrowFor(100e6, user2, user1);

        assertEq(usdc.balanceOf(user2), receiverUsdcBefore, "reborrow should not transfer assets");
        assertEq(borrowableCUSDC.debtBalance(user1), 0, "debt should remain closed");
        assertEq(borrowableCUSDC.marketOutstandingDebt(), marketDebtBefore, "market debt should not change");

        address[] memory assetsAfter = marketManagerIsolated.assetsOf(user1);
        assertEq(assetsAfter.length, assetsBefore.length, "retained row count should be unchanged");
        assertEq(assetsAfter[0], assetsBefore[0]);
        assertEq(assetsAfter[1], assetsBefore[1]);
    }

    function test_borrowableCTokenBorrowFor_fail_whenLiveDebtOracleIsStale()
        public
    {
        _provideUsdcLiquidity(2_000e6);
        _postPendleCollateral(user1, 10e18);
        _delegateToUser();

        vm.prank(user2);
        borrowableCUSDC.borrowFor(100e6, user2, user1);

        assertGt(borrowableCUSDC.debtBalance(user1), 0, "debt should be live");
        uint256 receiverUsdcBefore = usdc.balanceOf(user2);
        uint256 debtBefore = borrowableCUSDC.debtBalance(user1);
        uint256 marketDebtBefore = borrowableCUSDC.marketOutstandingDebt();

        _makeUsdcDebtOracleStale();

        vm.expectRevert(OracleManager.OracleManager__ErrorCodeFlagged.selector);
        vm.prank(user2);
        borrowableCUSDC.borrowFor(10e6, user2, user1);

        assertEq(usdc.balanceOf(user2), receiverUsdcBefore, "second borrow should not transfer assets");
        assertEq(borrowableCUSDC.debtBalance(user1), debtBefore, "debt should not increase");
        assertEq(borrowableCUSDC.marketOutstandingDebt(), marketDebtBefore, "market debt should not change");
    }

    function test_borrowableCTokenBorrowForPositionManager_fail_whenTerminalDebtOracleIsStaleAndRollsBackBorrow()
        public
    {
        MockPositionManager mockPositionManager = new MockPositionManager();
        marketManagerIsolated.addPositionManager(address(mockPositionManager));

        _provideUsdcLiquidity(1_000e6);
        _postPendleCollateral(user1, 10e18);

        IPositionManager.LeverageAction memory action;
        action.borrowableCToken = IBorrowableCToken(address(borrowableCUSDC));
        action.borrowAssets = 100e6;
        action.cToken = ICToken(address(pendleStrategyCTokenSTETH));

        uint256 ownerUsdcBefore = usdc.balanceOf(user1);
        uint256 pmUsdcBefore = usdc.balanceOf(address(mockPositionManager));
        uint256 debtBefore = borrowableCUSDC.debtBalance(user1);
        uint256 marketDebtBefore = borrowableCUSDC.marketOutstandingDebt();

        _makeUsdcDebtOracleStale();

        vm.expectRevert(OracleManager.OracleManager__ErrorCodeFlagged.selector);
        vm.prank(address(mockPositionManager));
        borrowableCUSDC.borrowForPositionManager(100e6, user1, action);

        assertEq(usdc.balanceOf(user1), ownerUsdcBefore, "owner should not receive rollback assets");
        assertEq(usdc.balanceOf(address(mockPositionManager)), pmUsdcBefore, "PM should not retain borrowed assets");
        assertEq(borrowableCUSDC.debtBalance(user1), debtBefore, "PM borrow debt should roll back");
        assertEq(borrowableCUSDC.marketOutstandingDebt(), marketDebtBefore, "market debt should roll back");
    }

    function test_borrowableCTokenBorrowForPositionManager_fail_whenTerminalDebtOracleIsCautionAndRollsBackBorrow()
        public
    {
        MockPositionManager mockPositionManager = new MockPositionManager();
        marketManagerIsolated.addPositionManager(address(mockPositionManager));

        _provideUsdcLiquidity(1_000e6);
        _postPendleCollateral(user1, 10e18);

        IPositionManager.LeverageAction memory action;
        action.borrowableCToken = IBorrowableCToken(address(borrowableCUSDC));
        action.borrowAssets = 100e6;
        action.cToken = ICToken(address(pendleStrategyCTokenSTETH));

        uint256 ownerUsdcBefore = usdc.balanceOf(user1);
        uint256 pmUsdcBefore = usdc.balanceOf(address(mockPositionManager));
        uint256 debtBefore = borrowableCUSDC.debtBalance(user1);
        uint256 marketDebtBefore = borrowableCUSDC.marketOutstandingDebt();

        _makeUsdcDebtOracleCaution();

        vm.expectRevert(OracleManager.OracleManager__ErrorCodeFlagged.selector);
        vm.prank(address(mockPositionManager));
        borrowableCUSDC.borrowForPositionManager(100e6, user1, action);

        assertEq(usdc.balanceOf(user1), ownerUsdcBefore, "owner should not receive rollback assets");
        assertEq(usdc.balanceOf(address(mockPositionManager)), pmUsdcBefore, "PM should not retain borrowed assets");
        assertEq(borrowableCUSDC.debtBalance(user1), debtBefore, "PM borrow debt should roll back");
        assertEq(borrowableCUSDC.marketOutstandingDebt(), marketDebtBefore, "market debt should roll back");
    }

    function test_borrowableCTokenBorrowForPositionManager_fail_whenRetainedZeroDebtRowReborrowTerminalDebtOracleIsCautionAndRollsBackBorrow()
        public
    {
        MockPositionManager mockPositionManager = new MockPositionManager();
        marketManagerIsolated.addPositionManager(address(mockPositionManager));

        _provideUsdcLiquidity(1_000e6);
        _openAndFullyRepayUsdcDebt(user1, 100e6);

        assertEq(borrowableCUSDC.debtBalance(user1), 0, "debt should be closed");
        address[] memory assetsBefore = marketManagerIsolated.assetsOf(user1);
        assertEq(assetsBefore.length, 2, "V1 retains closed debt row");
        assertEq(assetsBefore[1], address(borrowableCUSDC), "retained row should be debt cToken");

        IPositionManager.LeverageAction memory action;
        action.borrowableCToken = IBorrowableCToken(address(borrowableCUSDC));
        action.borrowAssets = 100e6;
        action.cToken = ICToken(address(pendleStrategyCTokenSTETH));

        uint256 ownerUsdcBefore = usdc.balanceOf(user1);
        uint256 pmUsdcBefore = usdc.balanceOf(address(mockPositionManager));
        uint256 marketDebtBefore = borrowableCUSDC.marketOutstandingDebt();

        _makeUsdcDebtOracleCaution();

        vm.expectRevert(OracleManager.OracleManager__ErrorCodeFlagged.selector);
        vm.prank(address(mockPositionManager));
        borrowableCUSDC.borrowForPositionManager(100e6, user1, action);

        assertEq(usdc.balanceOf(user1), ownerUsdcBefore, "owner should not receive rollback assets");
        assertEq(usdc.balanceOf(address(mockPositionManager)), pmUsdcBefore, "PM should not retain borrowed assets");
        assertEq(borrowableCUSDC.debtBalance(user1), 0, "PM reborrow debt should roll back");
        assertEq(borrowableCUSDC.marketOutstandingDebt(), marketDebtBefore, "market debt should roll back");

        address[] memory assetsAfter = marketManagerIsolated.assetsOf(user1);
        assertEq(assetsAfter.length, assetsBefore.length, "retained row count should be unchanged");
        assertEq(assetsAfter[0], assetsBefore[0]);
        assertEq(assetsAfter[1], assetsBefore[1]);
    }
    function test_borrowableCTokenBorrowForPositionManager_hostileCallbackActionsAreConstrainedBeforeTerminalCheck()
        public
    {
        _provideUsdcLiquidity(1_000e6);
        _postPendleCollateral(user1, 10e18);

        uint256 collateralBefore = pendleStrategyCTokenSTETH.collateralPosted(user1);
        HostileBorrowCallbackPositionManager hostilePM =
            _prepareHostileBorrowCallbackPositionManager(collateralBefore / 2);

        IPositionManager.LeverageAction memory action = _leverageAction(100e6);

        vm.prank(address(hostilePM));
        borrowableCUSDC.borrowForPositionManager(100e6, user1, action);

        assertTrue(hostilePM.callbackEntered(), "PM callback should execute");
        assertEq(
            hostilePM.debtDuringCallback(),
            100e6,
            "borrow debt should be stored before callback"
        );
        assertEq(
            hostilePM.marketDebtDuringCallback(),
            100e6,
            "market debt should be stored before callback"
        );
        assertEq(
            hostilePM.debtAssetBalanceDuringCallback(),
            100e6,
            "PM should receive borrowed assets before callback logic"
        );

        assertFalse(hostilePM.sameBorrowSucceeded(), "same-token borrow reentry should fail");
        assertEq(hostilePM.sameBorrowRevertSelector(), ReentrancyGuard.Reentrancy.selector);
        assertFalse(hostilePM.sameRepaySucceeded(), "same-token repay reentry should fail");
        assertEq(hostilePM.sameRepayRevertSelector(), ReentrancyGuard.Reentrancy.selector);
        assertFalse(hostilePM.sameMulticallSucceeded(), "same-token multicall reentry should fail");
        assertEq(hostilePM.sameMulticallRevertSelector(), ReentrancyGuard.Reentrancy.selector);
        assertFalse(hostilePM.removeCollateralSucceeded(), "collateral removal should fail in borrow cooldown");
        assertEq(
            hostilePM.removeCollateralRevertSelector(),
            MarketManagerIsolated.MarketManager__MinimumHoldPeriod.selector
        );
        assertFalse(hostilePM.redeemCollateralSucceeded(), "collateral redemption should fail in borrow cooldown");
        assertEq(
            hostilePM.redeemCollateralRevertSelector(),
            MarketManagerIsolated.MarketManager__MinimumHoldPeriod.selector
        );

        assertEq(borrowableCUSDC.debtBalance(user1), 100e6);
        assertEq(borrowableCUSDC.marketOutstandingDebt(), 100e6);
        assertEq(usdc.balanceOf(address(hostilePM)), 100e6);
        assertEq(
            pendleStrategyCTokenSTETH.collateralPosted(user1),
            collateralBefore,
            "callback should not remove collateral"
        );
    }

    function test_borrowableCTokenBorrowForPositionManager_hostileCallbackActionsRollBackWhenTerminalCheckFails()
        public
    {
        _provideUsdcLiquidity(1_000e6);
        _postPendleCollateral(user1, 10e18);

        uint256 collateralBefore = pendleStrategyCTokenSTETH.collateralPosted(user1);
        uint256 ownerUsdcBefore = usdc.balanceOf(user1);
        uint256 marketDebtBefore = borrowableCUSDC.marketOutstandingDebt();
        HostileBorrowCallbackPositionManager hostilePM =
            _prepareHostileBorrowCallbackPositionManager(collateralBefore / 2);
        IPositionManager.LeverageAction memory action = _leverageAction(100e6);

        _makeUsdcDebtOracleStale();

        vm.expectRevert(OracleManager.OracleManager__ErrorCodeFlagged.selector);
        vm.prank(address(hostilePM));
        borrowableCUSDC.borrowForPositionManager(100e6, user1, action);

        assertFalse(hostilePM.callbackEntered(), "callback records should roll back");
        assertEq(usdc.balanceOf(user1), ownerUsdcBefore, "owner balance should roll back");
        assertEq(usdc.balanceOf(address(hostilePM)), 0, "PM should not retain borrowed assets");
        assertEq(borrowableCUSDC.debtBalance(user1), 0, "debt should roll back");
        assertEq(borrowableCUSDC.marketOutstandingDebt(), marketDebtBefore, "market debt should roll back");
        assertEq(
            pendleStrategyCTokenSTETH.collateralPosted(user1),
            collateralBefore,
            "collateral should roll back"
        );
    }
    function test_borrowableCTokenBorrowForSendToDelegater_success() public {
        _setCTokenConfigBasic(address(pendleStrategyCTokenSTETH), 100_000e18, 0);

        _provideLiquidity();
        _depositCollateral();
        _delegateToUser();

        uint256 underlyingBalance = usdc.balanceOf(user1);
        uint256 balance = borrowableCUSDC.balanceOf(user1);
        uint256 totalSupply = borrowableCUSDC.totalSupply();
        uint256 totalDebt = borrowableCUSDC.marketOutstandingDebt();

        vm.expectEmit(true, true, true, true, address(borrowableCUSDC));
        emit Borrow(100e6, 100e6, user1);

        vm.startPrank(user2);
        borrowableCUSDC.borrowFor(100e6, user1, user1);
        vm.stopPrank();

        assertEq(usdc.balanceOf(user1), underlyingBalance + 100e6);
        assertEq(borrowableCUSDC.balanceOf(user1), balance);
        assertEq(borrowableCUSDC.totalSupply(), totalSupply);
        assertEq(borrowableCUSDC.marketOutstandingDebt(), totalDebt + 100e6);

        skip(1 hours);
        _harvestPendleLP(1 weeks);

        uint256 debtBeforeAccrual = borrowableCUSDC.debtBalance(user1);
        uint256 totalAssetsBeforeAccrual = borrowableCUSDC.totalAssets();

        borrowableCUSDC.accrueIfNeeded();

        uint256 debtAfterAccrual = borrowableCUSDC.debtBalance(user1);
        uint256 totalAssetsAfterAccrual = borrowableCUSDC.totalAssets();

        assertGt(debtAfterAccrual, 100e6, "Debt should include accrued interest");
        assertGt(debtAfterAccrual, debtBeforeAccrual, "Debt should increase after accrual");

        // Critical invariant
        uint256 debtIncrease = debtAfterAccrual - debtBeforeAccrual;
        uint256 assetsIncrease = totalAssetsAfterAccrual - totalAssetsBeforeAccrual;
        assertEq(debtIncrease, assetsIncrease, "Debt increase must equal assets increase");
    }

    function test_borrowableCTokenBorrowForSendToDelegatee_success() public {
        _setCTokenConfigBasic(address(pendleStrategyCTokenSTETH), 100_000e18, 0);

        _provideLiquidity();
        _depositCollateral();
        _delegateToUser();

        uint256 underlyingBalance = usdc.balanceOf(user2);
        uint256 balance = borrowableCUSDC.balanceOf(user2);
        uint256 totalSupply = borrowableCUSDC.totalSupply();
        uint256 totalDebt = borrowableCUSDC.marketOutstandingDebt();

        vm.expectEmit(true, true, true, true, address(borrowableCUSDC));
        emit Borrow(100e6, 100e6, user1);

        vm.startPrank(user2);
        borrowableCUSDC.borrowFor(100e6, user2, user1);
        vm.stopPrank();

        assertEq(usdc.balanceOf(user2), underlyingBalance + 100e6);
        assertEq(borrowableCUSDC.balanceOf(user2), balance);
        assertEq(borrowableCUSDC.totalSupply(), totalSupply);
        assertEq(borrowableCUSDC.marketOutstandingDebt(), totalDebt + 100e6);

        // Test interest accrual over time
        skip(1 hours);
        _harvestPendleLP(1 weeks);

        uint256 debtBeforeAccrual = borrowableCUSDC.debtBalance(user1);
        uint256 totalAssetsBeforeAccrual = borrowableCUSDC.totalAssets();

        borrowableCUSDC.accrueIfNeeded();

        uint256 debtAfterAccrual = borrowableCUSDC.debtBalance(user1);
        uint256 totalAssetsAfterAccrual = borrowableCUSDC.totalAssets();

        // Verify interest accrued
        assertGt(debtAfterAccrual, 100e6, "Debt should include accrued interest");
        assertGt(debtAfterAccrual, debtBeforeAccrual, "Debt should increase after accrual");

        // Critical invariant
        uint256 debtIncrease = debtAfterAccrual - debtBeforeAccrual;
        uint256 assetsIncrease = totalAssetsAfterAccrual - totalAssetsBeforeAccrual;
        assertEq(debtIncrease, assetsIncrease, "Debt increase must equal assets increase");
    }

    function _provideUsdcLiquidity(uint256 assets) internal {
        _prepareUSDC(address(this), assets);
        usdc.approve(address(borrowableCUSDC), assets);
        borrowableCUSDC.deposit(assets, address(this));
    }

    function _postPendleCollateral(address account, uint256 assets) internal {
        deal(address(LP_wstETH_24Dec2025), account, assets);

        vm.startPrank(account);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), assets);
        pendleStrategyCTokenSTETH.depositAsCollateral(assets, account);
        vm.stopPrank();
    }

    function _openAndFullyRepayUsdcDebt(address account, uint256 assets) internal {
        _postPendleCollateral(account, 10e18);

        vm.prank(account);
        borrowableCUSDC.borrow(assets, account);

        skip(20 minutes);
        borrowableCUSDC.accrueIfNeeded();

        _prepareUSDC(account, borrowableCUSDC.debtBalance(account));
        vm.startPrank(account);
        usdc.approve(address(borrowableCUSDC), type(uint256).max);
        borrowableCUSDC.repay(0);
        vm.stopPrank();
    }

    function _makeUsdcDebtOracleStale() internal {
        uint256 staleTimestamp =
            block.timestamp - chainlinkAdaptor.DEFAULT_HEARTBEAT() - 1;
        mockUsdcFeed.setMockUpdatedAt(staleTimestamp);

        (, uint256 errorCode) =
            oracleManager.getPrice(_USDC_ADDRESS, true, false);
        assertEq(errorCode, BAD_SOURCE, "test setup should make USDC debt oracle stale");
    }

    function _makeUsdcDebtOracleCaution() internal {
        MockV3Aggregator deviatedUsdcFeed = new MockV3Aggregator(8, 102e6);
        dualChainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            true,
            address(deviatedUsdcFeed),
            0
        );

        (, uint256 errorCode) =
            oracleManager.getPrice(_USDC_ADDRESS, true, false);
        assertEq(errorCode, 1, "test setup should make USDC debt oracle CAUTION");
    }

    function _prepareHostileBorrowCallbackPositionManager(
        uint256 collateralSharesToMove
    ) internal returns (HostileBorrowCallbackPositionManager hostilePM) {
        hostilePM = new HostileBorrowCallbackPositionManager();
        marketManagerIsolated.addPositionManager(address(hostilePM));

        vm.prank(user1);
        pendleStrategyCTokenSTETH.setDelegateApproval(address(hostilePM), true);

        hostilePM.configure(
            borrowableCUSDC,
            ICToken(address(pendleStrategyCTokenSTETH)),
            IERC20(_USDC_ADDRESS),
            user1,
            1,
            1,
            collateralSharesToMove
        );
    }

    function _leverageAction(
        uint256 borrowAssets
    ) internal view returns (IPositionManager.LeverageAction memory action) {
        action.borrowableCToken = IBorrowableCToken(address(borrowableCUSDC));
        action.borrowAssets = borrowAssets;
        action.cToken = ICToken(address(pendleStrategyCTokenSTETH));
    }
    function _delegateToUser() internal {
        vm.startPrank(user1);
        borrowableCUSDC.setDelegateApproval(user2, true);
        vm.stopPrank();
    }

    function _provideLiquidity() internal {
        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareUSDC(liquidityProvider, 100e6);

        // Mint borrowableCUSDC.
        vm.startPrank(liquidityProvider);
        usdc.approve(address(borrowableCUSDC), 100e6);
        borrowableCUSDC.deposit(100e6, liquidityProvider);
        vm.stopPrank();
    }

    function _depositCollateral() internal {
        deal(address(LP_wstETH_24Dec2025), user1, 10e18);

        // Mint and collateralize pendleStrategyCTokenSTETH.
        vm.startPrank(user1);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 1e18);
        pendleStrategyCTokenSTETH.depositAsCollateral(1e18,  user1);
        vm.stopPrank();
    }
}

contract HostileBorrowCallbackPositionManager is IPositionManager, ERC165 {
    BorrowableCToken public debtToken;
    ICToken public collateralToken;
    IERC20 public debtAsset;
    address public owner;
    uint256 public sameBorrowAmount;
    uint256 public sameRepayAmount;
    uint256 public collateralSharesToMove;

    bool public callbackEntered;
    bool public sameBorrowSucceeded;
    bool public sameRepaySucceeded;
    bool public sameMulticallSucceeded;
    bool public removeCollateralSucceeded;
    bool public redeemCollateralSucceeded;
    bytes4 public sameBorrowRevertSelector;
    bytes4 public sameRepayRevertSelector;
    bytes4 public sameMulticallRevertSelector;
    bytes4 public removeCollateralRevertSelector;
    bytes4 public redeemCollateralRevertSelector;
    uint256 public debtDuringCallback;
    uint256 public marketDebtDuringCallback;
    uint256 public debtAssetBalanceDuringCallback;

    bool internal inCallback;

    function configure(
        BorrowableCToken debtToken_,
        ICToken collateralToken_,
        IERC20 debtAsset_,
        address owner_,
        uint256 sameBorrowAmount_,
        uint256 sameRepayAmount_,
        uint256 collateralSharesToMove_
    ) external {
        debtToken = debtToken_;
        collateralToken = collateralToken_;
        debtAsset = debtAsset_;
        owner = owner_;
        sameBorrowAmount = sameBorrowAmount_;
        sameRepayAmount = sameRepayAmount_;
        collateralSharesToMove = collateralSharesToMove_;
    }

    function onBorrow(
        address,
        uint256,
        address,
        LeverageAction memory
    ) external override {
        if (inCallback) {
            return;
        }

        inCallback = true;
        callbackEntered = true;
        debtDuringCallback = debtToken.debtBalance(owner);
        marketDebtDuringCallback = debtToken.marketOutstandingDebt();
        debtAssetBalanceDuringCallback = debtAsset.balanceOf(address(this));

        (sameBorrowSucceeded, sameBorrowRevertSelector) = _attempt(
            address(debtToken),
            abi.encodeWithSelector(
                BorrowableCToken.borrow.selector,
                sameBorrowAmount,
                address(this)
            )
        );

        debtAsset.approve(address(debtToken), type(uint256).max);
        (sameRepaySucceeded, sameRepayRevertSelector) = _attempt(
            address(debtToken),
            abi.encodeWithSelector(
                BorrowableCToken.repayFor.selector,
                sameRepayAmount,
                owner
            )
        );

        Multicall.MulticallAction[] memory calls = new Multicall.MulticallAction[](1);
        calls[0] = Multicall.MulticallAction({
            target: address(debtToken),
            isPriceUpdate: false,
            data: abi.encodeWithSelector(
                BorrowableCToken.borrow.selector,
                sameBorrowAmount,
                address(this)
            )
        });
        (sameMulticallSucceeded, sameMulticallRevertSelector) = _attempt(
            address(debtToken),
            abi.encodeWithSelector(ICToken.multicall.selector, calls)
        );

        (removeCollateralSucceeded, removeCollateralRevertSelector) = _attempt(
            address(collateralToken),
            abi.encodeWithSignature(
                "removeCollateralFor(uint256,address)",
                collateralSharesToMove,
                owner
            )
        );
        (redeemCollateralSucceeded, redeemCollateralRevertSelector) = _attempt(
            address(collateralToken),
            abi.encodeWithSelector(
                ICToken.redeemCollateralFor.selector,
                collateralSharesToMove,
                address(this),
                owner
            )
        );

        inCallback = false;
    }

    function onRedeem(
        address,
        uint256,
        address,
        DeleverageAction memory
    ) external override {}

    function supportsInterface(
        bytes4 interfaceId
    ) public view override returns (bool) {
        return
            interfaceId == type(IPositionManager).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    function _attempt(
        address target,
        bytes memory callData
    ) internal returns (bool success, bytes4 selector) {
        bytes memory data;
        (success, data) = target.call(callData);
        if (!success && data.length >= 4) {
            selector = bytes4(data);
        }
    }
}
