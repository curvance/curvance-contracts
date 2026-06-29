// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { Multicall } from "contracts/libraries/Multicall.sol";
import { LiquidityManagerIsolated } from "contracts/market/isolated/LiquidityManagerIsolated.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { BAD_SOURCE } from "contracts/libraries/ConstantsLib.sol";

interface IERC20Like {
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IAtomicCollateralCToken {
    function removeCollateralFor(uint256 shares, address owner) external;
    function transferFrom(
        address owner,
        address receiver,
        uint256 shares
    ) external returns (bool);
}

contract AtomicCollateralBorrowHarness {
    function approveAsset(address asset, address spender) external {
        IERC20Like(asset).approve(spender, type(uint256).max);
    }

    function removeCollateralThenBorrow(
        IAtomicCollateralCToken collateralToken,
        IBorrowableCToken debtToken,
        uint256 shares,
        uint256 borrowAssets,
        address owner
    ) external {
        collateralToken.removeCollateralFor(shares, owner);
        debtToken.borrowFor(borrowAssets, owner, owner);
    }

    function transferCollateralThenBorrow(
        IAtomicCollateralCToken collateralToken,
        IBorrowableCToken debtToken,
        uint256 shares,
        address receiver,
        uint256 borrowAssets,
        address owner
    ) external {
        collateralToken.transferFrom(owner, receiver, shares);
        debtToken.borrowFor(borrowAssets, owner, owner);
    }

    function repayThenBorrow(
        IBorrowableCToken debtToken,
        uint256 repayAssets,
        uint256 borrowAssets,
        address owner
    ) external {
        debtToken.repayFor(repayAssets, owner);
        debtToken.borrowFor(borrowAssets, owner, owner);
    }
}

contract BorrowableCTokenMulticallTest is TestBaseMarketIsolated {
    function setUp() public override {
        super.setUp();

        _prepareUSDC(address(this), _ONE + 77777);
        _prepareDAI(address(this), 10e18 + 77777);

        usdc.approve(address(borrowableCUSDC), _ONE + 77777);
        dai.approve(address(borrowableCDAI), 10e18 + 77777);

        marketManagerIsolated.listTokens(
            address(borrowableCDAI),
            address(borrowableCUSDC)
        );

        _setCTokenConfigBasic(address(borrowableCDAI), 100_000e18, 100_000e18);
        _setCTokenConfigBasic(address(borrowableCUSDC), 100_000e18, 100_000e6);

        borrowableCDAI.mint(_ONE, address(this));
    }

    function test_borrowableCTokenMulticall_fail_nonPriceCallCannotTargetExternalContract()
        public
    {
        Multicall.MulticallAction[] memory calls =
            new Multicall.MulticallAction[](1);

        calls[0] = Multicall.MulticallAction({
            target: address(usdc),
            isPriceUpdate: false,
            data: abi.encodeWithSelector(usdc.balanceOf.selector, user1)
        });

        vm.expectRevert(Multicall.Multicall__InvalidTarget.selector);
        borrowableCUSDC.multicall(calls);
    }

    function test_borrowableCTokenMulticall_fail_delegatedWithdrawStillChecksCollateral()
        public
    {
        _prepareUSDC(address(this), 2000e6);
        usdc.approve(address(borrowableCUSDC), 2000e6);
        borrowableCUSDC.deposit(2000e6, address(this));

        _prepareDAI(user1, 2000e18);

        vm.startPrank(user1);
        dai.approve(address(borrowableCDAI), 2000e18);
        borrowableCDAI.depositAsCollateral(2000e18, user1);
        borrowableCUSDC.borrow(1000e6, user1);
        vm.stopPrank();

        skip(20 minutes);

        Multicall.MulticallAction[] memory calls =
            new Multicall.MulticallAction[](1);

        calls[0] = Multicall.MulticallAction({
            target: address(borrowableCDAI),
            isPriceUpdate: false,
            data: abi.encodeWithSelector(
                borrowableCDAI.withdrawCollateral.selector,
                1900e18,
                user1,
                user1
            )
        });

        uint256 underlyingBalance = dai.balanceOf(user1);
        uint256 balance = borrowableCDAI.balanceOf(user1);
        uint256 collateral = borrowableCDAI.collateralPosted(user1);
        uint256 totalSupply = borrowableCDAI.totalSupply();
        uint256 totalCollateral = borrowableCDAI.marketCollateralPosted();
        uint256 debt = borrowableCUSDC.debtBalance(user1);

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__InsufficientCollateral.selector
        );
        vm.prank(user1);
        borrowableCDAI.multicall(calls);

        assertEq(dai.balanceOf(user1), underlyingBalance);
        assertEq(borrowableCDAI.balanceOf(user1), balance);
        assertEq(borrowableCDAI.collateralPosted(user1), collateral);
        assertEq(borrowableCDAI.totalSupply(), totalSupply);
        assertEq(borrowableCDAI.marketCollateralPosted(), totalCollateral);
        assertEq(borrowableCUSDC.debtBalance(user1), debt);
    }

    function test_borrowableCTokenBatch_fail_removeCollateralThenBorrowRollsBack()
        public
    {
        AtomicCollateralBorrowHarness harness =
            new AtomicCollateralBorrowHarness();
        _provideUsdcLiquidity(2_000e6);
        _postDaiCollateral(user1, 2_000e18);

        vm.startPrank(user1);
        borrowableCDAI.setDelegateApproval(address(harness), true);
        borrowableCUSDC.setDelegateApproval(address(harness), true);
        vm.stopPrank();

        skip(20 minutes);

        uint256 userDaiBefore = dai.balanceOf(user1);
        uint256 userUsdcBefore = usdc.balanceOf(user1);
        uint256 cDaiBalanceBefore = borrowableCDAI.balanceOf(user1);
        uint256 cDaiCollateralBefore = borrowableCDAI.collateralPosted(user1);
        uint256 cDaiMarketCollateralBefore =
            borrowableCDAI.marketCollateralPosted();
        uint256 cUsdcDebtBefore = borrowableCUSDC.debtBalance(user1);
        uint256 cUsdcMarketDebtBefore = borrowableCUSDC.marketOutstandingDebt();

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__InsufficientCollateral.selector
        );
        harness.removeCollateralThenBorrow(
            IAtomicCollateralCToken(address(borrowableCDAI)),
            IBorrowableCToken(address(borrowableCUSDC)),
            1_500e18,
            1_000e6,
            user1
        );

        assertEq(dai.balanceOf(user1), userDaiBefore);
        assertEq(usdc.balanceOf(user1), userUsdcBefore);
        assertEq(borrowableCDAI.balanceOf(user1), cDaiBalanceBefore);
        assertEq(
            borrowableCDAI.collateralPosted(user1),
            cDaiCollateralBefore
        );
        assertEq(
            borrowableCDAI.marketCollateralPosted(),
            cDaiMarketCollateralBefore
        );
        assertEq(borrowableCUSDC.debtBalance(user1), cUsdcDebtBefore);
        assertEq(
            borrowableCUSDC.marketOutstandingDebt(),
            cUsdcMarketDebtBefore
        );
    }

    function test_borrowableCTokenBatch_fail_transferCollateralThenBorrowRollsBack()
        public
    {
        AtomicCollateralBorrowHarness harness =
            new AtomicCollateralBorrowHarness();
        _provideUsdcLiquidity(2_000e6);
        _postDaiCollateral(user1, 2_000e18);

        vm.startPrank(user1);
        borrowableCDAI.approve(address(harness), 1_500e18);
        borrowableCUSDC.setDelegateApproval(address(harness), true);
        vm.stopPrank();

        skip(20 minutes);

        uint256 userDaiBefore = dai.balanceOf(user1);
        uint256 userUsdcBefore = usdc.balanceOf(user1);
        uint256 user1CDaiBefore = borrowableCDAI.balanceOf(user1);
        uint256 user2CDaiBefore = borrowableCDAI.balanceOf(user2);
        uint256 cDaiCollateralBefore = borrowableCDAI.collateralPosted(user1);
        uint256 cDaiMarketCollateralBefore =
            borrowableCDAI.marketCollateralPosted();
        uint256 cUsdcDebtBefore = borrowableCUSDC.debtBalance(user1);
        uint256 cUsdcMarketDebtBefore = borrowableCUSDC.marketOutstandingDebt();

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__InsufficientCollateral.selector
        );
        harness.transferCollateralThenBorrow(
            IAtomicCollateralCToken(address(borrowableCDAI)),
            IBorrowableCToken(address(borrowableCUSDC)),
            1_500e18,
            user2,
            1_000e6,
            user1
        );

        assertEq(dai.balanceOf(user1), userDaiBefore);
        assertEq(usdc.balanceOf(user1), userUsdcBefore);
        assertEq(borrowableCDAI.balanceOf(user1), user1CDaiBefore);
        assertEq(borrowableCDAI.balanceOf(user2), user2CDaiBefore);
        assertEq(
            borrowableCDAI.collateralPosted(user1),
            cDaiCollateralBefore
        );
        assertEq(
            borrowableCDAI.marketCollateralPosted(),
            cDaiMarketCollateralBefore
        );
        assertEq(borrowableCUSDC.debtBalance(user1), cUsdcDebtBefore);
        assertEq(
            borrowableCUSDC.marketOutstandingDebt(),
            cUsdcMarketDebtBefore
        );
    }

    function test_borrowableCTokenBatch_fail_repayToZeroThenStaleOracleReborrowRollsBack()
        public
    {
        AtomicCollateralBorrowHarness harness =
            new AtomicCollateralBorrowHarness();
        _provideUsdcLiquidity(2_000e6);
        _postDaiCollateral(user1, 2_000e18);

        vm.startPrank(user1);
        borrowableCUSDC.borrow(100e6, user1);
        borrowableCUSDC.setDelegateApproval(address(harness), true);
        vm.stopPrank();

        skip(20 minutes);
        borrowableCUSDC.accrueIfNeeded();

        uint256 debtBefore = borrowableCUSDC.debtBalance(user1);
        _prepareUSDC(address(harness), debtBefore);
        harness.approveAsset(address(usdc), address(borrowableCUSDC));

        uint256 harnessUsdcBefore = usdc.balanceOf(address(harness));
        uint256 userUsdcBefore = usdc.balanceOf(user1);
        uint256 marketDebtBefore = borrowableCUSDC.marketOutstandingDebt();
        address[] memory assetsBefore = marketManagerIsolated.assetsOf(user1);

        _makeUsdcDebtOracleStale();

        vm.expectRevert(
            LiquidityManagerIsolated.LiquidityManager__PriceError.selector
        );
        harness.repayThenBorrow(
            IBorrowableCToken(address(borrowableCUSDC)),
            0,
            100e6,
            user1
        );

        assertEq(usdc.balanceOf(address(harness)), harnessUsdcBefore);
        assertEq(usdc.balanceOf(user1), userUsdcBefore);
        assertEq(borrowableCUSDC.debtBalance(user1), debtBefore);
        assertEq(borrowableCUSDC.marketOutstandingDebt(), marketDebtBefore);

        address[] memory assetsAfter = marketManagerIsolated.assetsOf(user1);
        assertEq(assetsAfter.length, assetsBefore.length);
        for (uint256 i; i < assetsBefore.length; ++i) {
            assertEq(assetsAfter[i], assetsBefore[i]);
        }
    }

    function _provideUsdcLiquidity(uint256 assets) internal {
        _prepareUSDC(address(this), assets);
        usdc.approve(address(borrowableCUSDC), assets);
        borrowableCUSDC.deposit(assets, address(this));
    }

    function _postDaiCollateral(address account, uint256 assets) internal {
        _prepareDAI(account, assets);

        vm.startPrank(account);
        dai.approve(address(borrowableCDAI), assets);
        borrowableCDAI.depositAsCollateral(assets, account);
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
}
