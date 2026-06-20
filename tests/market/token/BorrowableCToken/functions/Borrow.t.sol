// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseBorrowableCToken } from "../TestBaseBorrowableCToken.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { SimpleCToken } from "contracts/market/token/SimpleCToken.sol";
import { MarketManagerIsolated, LiquidityManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { ReentrancyGuard } from "contracts/libraries/ReentrancyGuardTransient.sol";
import { ERC20 } from "contracts/libraries/external/ERC20.sol";
import { BAD_SOURCE } from "contracts/libraries/ConstantsLib.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";

contract BorrowableCTokenBorrowTest is TestBaseBorrowableCToken {
    event Borrow(uint256 assets, uint256 newDebtAssets, address account);

    function test_borrowableCTokenBorrow_fail_whenBorrowIsNotAllowed() public {
        address borrower = makeAddr("borrower");
        marketManagerIsolated.setBorrowPaused(address(borrowableCUSDC), true);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        borrowableCUSDC.borrow(100e6, borrower);
    }

    function test_borrowableCTokenBorrow_fail_whenBorrowAmountExceedsAssetsHeld() public {
        address liquidityProvider = makeAddr("liquidityProvider");

        _prepareUSDC(liquidityProvider, 100e6);
        // Mint borrowableCUSDC.
        vm.startPrank(liquidityProvider);
        usdc.approve(address(borrowableCUSDC), 100e6);
        borrowableCUSDC.deposit(100e6, liquidityProvider);
        vm.stopPrank();


        deal(address(LP_wstETH_24Dec2025), address(this), _ONE);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), _ONE);
        pendleStrategyCTokenSTETH.deposit(_ONE, address(this));
        pendleStrategyCTokenSTETH.postCollateral(_ONE);

        _harvestPendleLP(1 weeks);

        uint256 assetsHeld = borrowableCUSDC.assetsHeld();

        vm.expectRevert(
            BorrowableCToken.BorrowableCToken__InsufficientAssetsHeld.selector
        );
        borrowableCUSDC.borrow(assetsHeld + 1, address(this));
    }

    function test_borrowableCTokenBorrow_fail_whenBorrowAmountExceedsDebtCap() public {
        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareUSDC(liquidityProvider, 100e6);
        // mint borrowableCUSDC
        vm.startPrank(liquidityProvider);
        usdc.approve(address(borrowableCUSDC), 100e6);
        borrowableCUSDC.deposit(100e6, liquidityProvider);
        vm.stopPrank();

        deal(address(LP_wstETH_24Dec2025), address(this), _ONE);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), _ONE);
        pendleStrategyCTokenSTETH.deposit(_ONE, address(this));
        pendleStrategyCTokenSTETH.postCollateral(_ONE);

        skip(69 minutes);
        _harvestPendleLP(1 weeks);

        _setCTokenConfigBasic(address(borrowableCUSDC), 100_000e18, 0);

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__CapReached.selector
        );

        borrowableCUSDC.borrow(100e6, address(this));
    }

    function test_borrowableCTokenBorrow_fail_whenCollateralPostedInBorrowableCToken() public {

        borrowableCUSDC.deposit(200e6, address(this));

        pendleStrategyCTokenSTETH.postCollateral(1e18 - 1);
        borrowableCUSDC.postCollateral(100e6 - 1);

        vm.expectRevert(
            BorrowableCToken.BorrowableCToken__CollateralPositionActive.selector
        );

        borrowableCUSDC.borrow(20e6, address(this));
    }

    function test_borrowableCTokenBorrow_fail_whenFreshBorrowDebtOracleIsStale()
        public
    {
        _provideUsdcLiquidity(1_000e6);
        _postPendleCollateral(address(this), 10e18);

        address[] memory assetsBefore = marketManagerIsolated.assetsOf(address(this));
        assertEq(assetsBefore.length, 1, "fresh borrower should only have collateral row");
        assertEq(assetsBefore[0], address(pendleStrategyCTokenSTETH));

        uint256 usdcBefore = usdc.balanceOf(address(this));
        uint256 debtBefore = borrowableCUSDC.debtBalance(address(this));
        uint256 marketDebtBefore = borrowableCUSDC.marketOutstandingDebt();

        _makeUsdcDebtOracleStale();

        vm.expectRevert(LiquidityManagerIsolated.LiquidityManager__PriceError.selector);
        borrowableCUSDC.borrow(100e6, address(this));

        assertEq(usdc.balanceOf(address(this)), usdcBefore, "borrow should not transfer assets");
        assertEq(borrowableCUSDC.debtBalance(address(this)), debtBefore, "debt should not open");
        assertEq(borrowableCUSDC.marketOutstandingDebt(), marketDebtBefore, "market debt should not change");

        address[] memory assetsAfter = marketManagerIsolated.assetsOf(address(this));
        assertEq(assetsAfter.length, assetsBefore.length, "failed borrow should not retain debt row");
        assertEq(assetsAfter[0], assetsBefore[0]);
    }

    function test_borrowableCTokenBorrow_fail_whenFreshBorrowDebtOracleIsCaution()
        public
    {
        _provideUsdcLiquidity(1_000e6);
        _postPendleCollateral(address(this), 10e18);

        address[] memory assetsBefore = marketManagerIsolated.assetsOf(address(this));
        assertEq(assetsBefore.length, 1, "fresh borrower should only have collateral row");
        assertEq(assetsBefore[0], address(pendleStrategyCTokenSTETH));

        uint256 usdcBefore = usdc.balanceOf(address(this));
        uint256 debtBefore = borrowableCUSDC.debtBalance(address(this));
        uint256 marketDebtBefore = borrowableCUSDC.marketOutstandingDebt();

        _makeUsdcDebtOracleCaution();

        vm.expectRevert(LiquidityManagerIsolated.LiquidityManager__PriceError.selector);
        borrowableCUSDC.borrow(100e6, address(this));

        assertEq(usdc.balanceOf(address(this)), usdcBefore, "borrow should not transfer assets");
        assertEq(borrowableCUSDC.debtBalance(address(this)), debtBefore, "debt should not open");
        assertEq(borrowableCUSDC.marketOutstandingDebt(), marketDebtBefore, "market debt should not change");

        address[] memory assetsAfter = marketManagerIsolated.assetsOf(address(this));
        assertEq(assetsAfter.length, assetsBefore.length, "failed borrow should not retain debt row");
        assertEq(assetsAfter[0], assetsBefore[0]);
    }

    function test_borrowableCTokenBorrow_fail_whenRetainedZeroDebtRowReborrowDebtOracleIsStale()
        public
    {
        _provideUsdcLiquidity(2_000e6);
        _openAndFullyRepayUsdcDebt(user1, 100e6);

        assertEq(borrowableCUSDC.debtBalance(user1), 0, "debt should be closed");
        address[] memory assetsBefore = marketManagerIsolated.assetsOf(user1);
        assertEq(assetsBefore.length, 2, "V1 retains closed debt row");
        assertEq(assetsBefore[1], address(borrowableCUSDC), "retained row should be debt cToken");

        uint256 usdcBefore = usdc.balanceOf(user1);
        uint256 marketDebtBefore = borrowableCUSDC.marketOutstandingDebt();

        _makeUsdcDebtOracleStale();

        vm.expectRevert(LiquidityManagerIsolated.LiquidityManager__PriceError.selector);
        vm.prank(user1);
        borrowableCUSDC.borrow(100e6, user1);

        assertEq(usdc.balanceOf(user1), usdcBefore, "reborrow should not transfer assets");
        assertEq(borrowableCUSDC.debtBalance(user1), 0, "debt should remain closed");
        assertEq(borrowableCUSDC.marketOutstandingDebt(), marketDebtBefore, "market debt should not change");

        address[] memory assetsAfter = marketManagerIsolated.assetsOf(user1);
        assertEq(assetsAfter.length, assetsBefore.length, "retained row count should be unchanged");
        assertEq(assetsAfter[0], assetsBefore[0]);
        assertEq(assetsAfter[1], assetsBefore[1]);
    }

    function test_borrowableCTokenBorrow_fail_whenRetainedZeroDebtRowReborrowDebtOracleIsCaution()
        public
    {
        _provideUsdcLiquidity(2_000e6);
        _openAndFullyRepayUsdcDebt(user1, 100e6);

        assertEq(borrowableCUSDC.debtBalance(user1), 0, "debt should be closed");
        address[] memory assetsBefore = marketManagerIsolated.assetsOf(user1);
        assertEq(assetsBefore.length, 2, "V1 retains closed debt row");
        assertEq(assetsBefore[1], address(borrowableCUSDC), "retained row should be debt cToken");

        uint256 usdcBefore = usdc.balanceOf(user1);
        uint256 marketDebtBefore = borrowableCUSDC.marketOutstandingDebt();

        _makeUsdcDebtOracleCaution();

        vm.expectRevert(LiquidityManagerIsolated.LiquidityManager__PriceError.selector);
        vm.prank(user1);
        borrowableCUSDC.borrow(100e6, user1);

        assertEq(usdc.balanceOf(user1), usdcBefore, "reborrow should not transfer assets");
        assertEq(borrowableCUSDC.debtBalance(user1), 0, "debt should remain closed");
        assertEq(borrowableCUSDC.marketOutstandingDebt(), marketDebtBefore, "market debt should not change");

        address[] memory assetsAfter = marketManagerIsolated.assetsOf(user1);
        assertEq(assetsAfter.length, assetsBefore.length, "retained row count should be unchanged");
        assertEq(assetsAfter[0], assetsBefore[0]);
        assertEq(assetsAfter[1], assetsBefore[1]);
    }

    function test_borrowableCTokenBorrow_fail_whenLiveDebtOracleIsStale()
        public
    {
        _provideUsdcLiquidity(2_000e6);
        _postPendleCollateral(user1, 10e18);

        vm.prank(user1);
        borrowableCUSDC.borrow(100e6, user1);

        assertGt(borrowableCUSDC.debtBalance(user1), 0, "debt should be live");
        uint256 usdcBefore = usdc.balanceOf(user1);
        uint256 debtBefore = borrowableCUSDC.debtBalance(user1);
        uint256 marketDebtBefore = borrowableCUSDC.marketOutstandingDebt();

        _makeUsdcDebtOracleStale();

        vm.expectRevert(OracleManager.OracleManager__ErrorCodeFlagged.selector);
        vm.prank(user1);
        borrowableCUSDC.borrow(10e6, user1);

        assertEq(usdc.balanceOf(user1), usdcBefore, "second borrow should not transfer assets");
        assertEq(borrowableCUSDC.debtBalance(user1), debtBefore, "debt should not increase");
        assertEq(borrowableCUSDC.marketOutstandingDebt(), marketDebtBefore, "market debt should not change");
    }

    function test_borrowableCTokenBorrow_callbackUnderlyingCannotReenterDuringBorrowTransfer()
        public
    {
        BorrowTransferCallbackToken collateral =
            new BorrowTransferCallbackToken("Callback Collateral", "cCOL", 18);
        BorrowTransferCallbackToken debt =
            new BorrowTransferCallbackToken("Callback Debt", "cDEBT", 6);

        MarketManagerIsolated callbackMarket = new MarketManagerIsolated(
            ICentralRegistry(address(centralRegistry)),
            10e18,
            false
        );
        centralRegistry.addMarketManager(address(callbackMarket));

        SimpleCToken callbackCollateralCToken = new SimpleCToken(
            ICentralRegistry(address(centralRegistry)),
            IERC20(address(collateral)),
            address(callbackMarket)
        );
        BorrowableCToken callbackDebtCToken = new BorrowableCToken(
            ICentralRegistry(address(centralRegistry)),
            IERC20(address(debt)),
            address(callbackMarket),
            _deployDynamicIRM(address(debt))
        );
        IRMs[block.chainid][address(debt)].setLinkedToken(
            address(callbackDebtCToken)
        );

        MockV3Aggregator collateralFeed = new MockV3Aggregator(8, 1e8);
        MockV3Aggregator debtFeed = new MockV3Aggregator(8, 1e8);
        chainlinkAdaptor.addAsset(
            address(collateral),
            true,
            address(collateralFeed),
            0
        );
        chainlinkAdaptor.addAsset(address(debt), true, address(debtFeed), 0);
        oracleManager.addAssetPricingAdaptor(
            address(collateral),
            address(chainlinkAdaptor),
            150,
            180,
            150,
            180
        );
        oracleManager.addAssetPricingAdaptor(
            address(debt),
            address(chainlinkAdaptor),
            150,
            180,
            150,
            180
        );
        oracleManager.addCTokenSupport(address(callbackCollateralCToken));
        oracleManager.addCTokenSupport(address(callbackDebtCToken));

        collateral.mint(address(this), 1_000e18 + 77777);
        debt.mint(address(this), 1_000e6 + 77777);
        collateral.approve(address(callbackCollateralCToken), type(uint256).max);
        debt.approve(address(callbackDebtCToken), type(uint256).max);

        callbackMarket.listTokens(
            address(callbackCollateralCToken),
            address(callbackDebtCToken)
        );
        _setCTokenConfigBasic(
            callbackMarket,
            address(callbackCollateralCToken),
            100_000e18,
            0
        );
        _setCTokenConfigBasic(
            callbackMarket,
            address(callbackDebtCToken),
            100_000e18,
            100_000e6
        );

        callbackDebtCToken.deposit(1_000e6, address(this));
        callbackCollateralCToken.depositAsCollateral(1_000e18, address(this));

        debt.configureBorrowCallback(
            callbackDebtCToken,
            address(this),
            1
        );
        debt.setBorrowCallbackEnabled(true);

        callbackDebtCToken.borrow(100e6, address(this));

        assertTrue(debt.callbackAttempted(), "borrow transfer should callback");
        assertFalse(debt.reentrySucceeded(), "same-cToken reentry should fail");
        assertEq(
            debt.reentryRevertSelector(),
            ReentrancyGuard.Reentrancy.selector,
            "same-cToken reentry should hit transient guard"
        );
        assertEq(
            debt.debtDuringCallback(),
            100e6,
            "debt should be recorded before transfer callback"
        );
        assertEq(
            debt.marketDebtDuringCallback(),
            100e6,
            "market debt should be recorded before transfer callback"
        );
        assertEq(
            debt.balanceDuringCallback(),
            100e6,
            "receiver balance should be updated before transfer callback"
        );
        assertEq(callbackDebtCToken.debtBalance(address(this)), 100e6);
        assertEq(callbackDebtCToken.marketOutstandingDebt(), 100e6);
        assertEq(debt.balanceOf(address(this)), 100e6);
    }
    function test_borrowableCTokenBorrow_success() public {
        borrowableCUSDC.deposit(200e6, address(this));
        pendleStrategyCTokenSTETH.postCollateral(1e18 - 1);

        uint256 underlyingBalance = usdc.balanceOf(address(this));
        uint256 balance = borrowableCUSDC.balanceOf(address(this));
        uint256 totalSupply = borrowableCUSDC.totalSupply();
        uint256 totalBorrows = borrowableCUSDC.marketOutstandingDebt();

        vm.expectEmit(true, true, true, true, address(borrowableCUSDC));
        emit Borrow(100e6, 100e6, address(this));

        borrowableCUSDC.borrow(100e6, address(this));

        // Initial assertions
        assertEq(usdc.balanceOf(address(this)), underlyingBalance + 100e6);
        assertEq(borrowableCUSDC.balanceOf(address(this)), balance);
        assertEq(borrowableCUSDC.totalSupply(), totalSupply);
        assertEq(borrowableCUSDC.marketOutstandingDebt(), totalBorrows + 100e6);

        // Test interest accrual over time
        _harvestPendleLP(1 weeks);

        uint256 debtBeforeAccrual = borrowableCUSDC.debtBalance(address(this));
        uint256 totalAssetsBeforeAccrual = borrowableCUSDC.totalAssets();

        borrowableCUSDC.accrueIfNeeded();

        uint256 debtAfterAccrual = borrowableCUSDC.debtBalance(address(this));
        uint256 totalAssetsAfterAccrual = borrowableCUSDC.totalAssets();

        assertGt(debtAfterAccrual, 100e6, "Debt should include accrued interest");
        assertGt(debtAfterAccrual, debtBeforeAccrual, "Debt should increase after accrual");

        uint256 debtIncrease = debtAfterAccrual - debtBeforeAccrual;
        uint256 assetsIncrease = totalAssetsAfterAccrual - totalAssetsBeforeAccrual;
        assertEq(debtIncrease, assetsIncrease, "Debt increase must equal assets increase");
    }

    function test_borrow_UpToAssetsHeld() public {
        
        _setCTokenConfigBasic(address(borrowableCUSDC), 1_000_000_000e18, 1_000_000_000e18);
        
        // Provide liquidity
        address lp = makeAddr("lpAssetsHeld");
        _prepareUSDC(lp, 100e6);
        vm.startPrank(lp);
        usdc.approve(address(borrowableCUSDC), 100e6);
        borrowableCUSDC.deposit(100e6, lp);
        vm.stopPrank();

        deal(address(LP_wstETH_24Dec2025), address(this), _ONE);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), _ONE);
        pendleStrategyCTokenSTETH.depositAsCollateral(_ONE, address(this));

        _harvestPendleLP(1 weeks);

        uint256 assetsHeld = borrowableCUSDC.assetsHeld();
        uint256 debtBefore = borrowableCUSDC.marketOutstandingDebt();

        // Borrow exactly assetsHeld, which does not include the base reserve
        borrowableCUSDC.borrow(assetsHeld, address(this));

        // After borrowing, assetsHeld should be 0
        assertEq(borrowableCUSDC.assetsHeld(), 0, "assetsHeld should be zero after full borrowable extraction");

        uint256 debtAfter = borrowableCUSDC.marketOutstandingDebt();
        uint256 util = borrowableCUSDC.IRM().utilizationRate(0, debtAfter);
        assertEq(util, 1e18, "Utilization should be WAD");

        // Attempting to borrow 1 wei more should revert
        vm.expectRevert(BorrowableCToken.BorrowableCToken__InsufficientAssetsHeld.selector);
        borrowableCUSDC.borrow(1, address(this));
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

    function _setCTokenConfigBasic(
        MarketManagerIsolated manager,
        address cToken,
        uint256 collateralCap,
        uint256 debtCap
    ) internal {
        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = cToken;
        tokenConfig.collRatio = 7000;
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

        manager.updateTokenConfig(tokenConfig);
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

}

contract BorrowTransferCallbackToken is ERC20 {
    string internal _name;
    string internal _symbol;
    uint8 internal _decimals;

    BorrowableCToken public borrowTarget;
    address public inspectOwner;
    uint256 public reenterAmount;
    bool public callbackEnabled;
    bool public callbackAttempted;
    bool public reentrySucceeded;
    bytes4 public reentryRevertSelector;
    uint256 public debtDuringCallback;
    uint256 public marketDebtDuringCallback;
    uint256 public balanceDuringCallback;

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_
    ) {
        _name = name_;
        _symbol = symbol_;
        _decimals = decimals_;
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function configureBorrowCallback(
        BorrowableCToken borrowTarget_,
        address inspectOwner_,
        uint256 reenterAmount_
    ) external {
        borrowTarget = borrowTarget_;
        inspectOwner = inspectOwner_;
        reenterAmount = reenterAmount_;
    }

    function setBorrowCallbackEnabled(bool enabled) external {
        callbackEnabled = enabled;
    }

    function _afterTokenTransfer(
        address from,
        address to,
        uint256
    ) internal override {
        if (
            !callbackEnabled ||
            callbackAttempted ||
            from != address(borrowTarget) ||
            to != inspectOwner
        ) {
            return;
        }

        callbackAttempted = true;
        debtDuringCallback = borrowTarget.debtBalance(inspectOwner);
        marketDebtDuringCallback = borrowTarget.marketOutstandingDebt();
        balanceDuringCallback = balanceOf(inspectOwner);

        (bool success, bytes memory data) = address(borrowTarget).call(
            abi.encodeWithSelector(
                BorrowableCToken.borrow.selector,
                reenterAmount,
                inspectOwner
            )
        );

        reentrySucceeded = success;
        if (!success && data.length >= 4) {
            reentryRevertSelector = bytes4(data);
        }
    }
}
