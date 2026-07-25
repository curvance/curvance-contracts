// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {
    TestBaseBorrowableCToken
} from "tests/market/token/BorrowableCToken/TestBaseBorrowableCToken.sol";
import {BorrowableCToken} from "contracts/market/token/BorrowableCToken.sol";
import {DynamicIRM} from "contracts/market/DynamicIRM.sol";
import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";
import {IERC20} from "contracts/interfaces/IERC20.sol";

/// @notice Executable migration ordering and recovery differential for V1 IRMs.
contract IRMMigrationLinkagePoC is TestBaseBorrowableCToken {
    address internal borrower;
    uint256 internal constant TOTAL_ASSETS_SLOT = 4;

    function setUp() public override {
        super.setUp();
        borrower = makeAddr("irm migration borrower");
    }

    function test_correctUnlinkedReplacementHasCachedWindowAndLateLinkRecovers()
        public
    {
        _openDebtPosition();
        DynamicIRM replacement = _newIRM();

        borrowableCUSDC.setIRM(address(replacement));
        assertEq(address(borrowableCUSDC.IRM()), address(replacement));
        assertEq(replacement.linkedToken(), address(0));

        // Before the cached vesting boundary no reverse-link call is needed.
        uint256 receiverBalanceBefore = usdc.balanceOf(borrower);
        vm.prank(borrower);
        borrowableCUSDC.borrow(1e6, borrower);
        assertEq(usdc.balanceOf(borrower), receiverBalanceBefore + 1e6);

        (, uint256 vestingEnd,,) = borrowableCUSDC.getYieldInformation();
        vm.warp(vestingEnd + 600);
        vm.expectRevert(DynamicIRM.DynamicIRM__Unauthorized.selector);
        borrowableCUSDC.accrueIfNeeded();

        replacement.setLinkedToken(address(borrowableCUSDC));
        uint256 debtBeforeRecovery = borrowableCUSDC.debtBalance(borrower);
        uint256 aggregateBeforeRecovery =
            borrowableCUSDC.marketOutstandingDebt();
        uint256 assetsBeforeRecovery = _cachedTotalAssets();
        borrowableCUSDC.accrueIfNeeded();

        assertEq(replacement.linkedToken(), address(borrowableCUSDC));
        assertGt(borrowableCUSDC.debtBalance(borrower), debtBeforeRecovery);
        uint256 borrowerDebtIncrease =
            borrowableCUSDC.debtBalance(borrower) - debtBeforeRecovery;
        uint256 aggregateDebtIncrease =
            borrowableCUSDC.marketOutstandingDebt() - aggregateBeforeRecovery;
        uint256 lenderNavIncrease = _cachedTotalAssets() - assetsBeforeRecovery;
        assertApproxEqAbs(
            borrowerDebtIncrease,
            aggregateDebtIncrease,
            1,
            "account round-up stays within one unit of aggregate debt"
        );
        assertEq(
            aggregateDebtIncrease,
            lenderNavIncrease,
            "late-link recovery preserves aggregate debt/NAV accounting"
        );

        receiverBalanceBefore = usdc.balanceOf(borrower);
        vm.prank(borrower);
        borrowableCUSDC.borrow(1e6, borrower);
        assertEq(usdc.balanceOf(borrower), receiverBalanceBefore + 1e6);
    }

    function test_occupiedReplacementSelfLocksAfterCachedBoundary() public {
        _openDebtPosition();
        DynamicIRM occupied = _newIRM();
        BorrowableCToken occupant = _newBorrowable(occupied);
        occupied.setLinkedToken(address(occupant));
        DynamicIRM oldIRM = DynamicIRM(address(borrowableCUSDC.IRM()));

        borrowableCUSDC.setIRM(address(occupied));
        (, uint256 vestingEnd,,) = borrowableCUSDC.getYieldInformation();
        vm.warp(vestingEnd + 1);

        vm.expectRevert(DynamicIRM.DynamicIRM__Unauthorized.selector);
        borrowableCUSDC.accrueIfNeeded();

        vm.expectRevert(DynamicIRM.DynamicIRM__Unauthorized.selector);
        occupied.setLinkedToken(address(borrowableCUSDC));

        // setIRM pre-accrues through the currently installed model, so even
        // an otherwise valid rollback target is unreachable natively.
        vm.expectRevert(DynamicIRM.DynamicIRM__Unauthorized.selector);
        borrowableCUSDC.setIRM(address(oldIRM));
        assertEq(address(borrowableCUSDC.IRM()), address(occupied));
        assertEq(occupied.linkedToken(), address(occupant));
    }

    function test_realTimelockOrderedBatchRestoresPostBoundaryService()
        public
    {
        _openDebtPosition();
        DynamicIRM replacement = _newIRM();

        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory payloads
        ) = _migrationBatch(replacement);
        bytes32 salt = keccak256("ordered irm migration");
        uint256 delay = daoTimelock.getMinDelay();

        daoTimelock.scheduleBatch(
            targets, values, payloads, bytes32(0), salt, delay
        );
        skip(delay);
        daoTimelock.executeBatch(targets, values, payloads, bytes32(0), salt);

        assertEq(address(borrowableCUSDC.IRM()), address(replacement));
        assertEq(replacement.linkedToken(), address(borrowableCUSDC));

        (, uint256 vestingEnd,,) = borrowableCUSDC.getYieldInformation();
        vm.warp(vestingEnd + 600);
        uint256 debtBefore = borrowableCUSDC.debtBalance(borrower);
        uint256 aggregateDebtBefore = borrowableCUSDC.marketOutstandingDebt();
        uint256 assetsBefore = _cachedTotalAssets();
        borrowableCUSDC.accrueIfNeeded();
        uint256 debtIncrease =
            borrowableCUSDC.debtBalance(borrower) - debtBefore;
        uint256 aggregateDebtIncrease =
            borrowableCUSDC.marketOutstandingDebt() - aggregateDebtBefore;
        uint256 lenderNavIncrease = _cachedTotalAssets() - assetsBefore;
        assertGt(debtIncrease, 0, "ordinary post-boundary accrual resumes");
        assertApproxEqAbs(
            debtIncrease,
            aggregateDebtIncrease,
            1,
            "account round-up stays within one unit of aggregate debt"
        );
        assertEq(
            aggregateDebtIncrease,
            lenderNavIncrease,
            "aggregate debt and lender NAV stay aligned"
        );

        // The real timelock delay outlives the unit fixture's mock-feed
        // heartbeat; refresh only those local timestamps before testing the
        // ordinary borrow path.
        _refreshMockFeeds();
        uint256 receiverBalanceBefore = usdc.balanceOf(borrower);
        vm.prank(borrower);
        borrowableCUSDC.borrow(1e6, borrower);
        assertEq(usdc.balanceOf(borrower), receiverBalanceBefore + 1e6);
    }

    function test_occupiedTargetTimelockBatchRollsBackPointerAndAccounting()
        public
    {
        _openDebtPosition();
        DynamicIRM occupied = _newIRM();
        BorrowableCToken occupant = _newBorrowable(occupied);
        occupied.setLinkedToken(address(occupant));
        address oldIRM = address(borrowableCUSDC.IRM());

        (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory payloads
        ) = _migrationBatch(occupied);
        bytes32 salt = keccak256("occupied irm migration");
        uint256 delay = daoTimelock.getMinDelay();

        daoTimelock.scheduleBatch(
            targets, values, payloads, bytes32(0), salt, delay
        );
        skip(delay);

        uint256 debtBefore = borrowableCUSDC.debtBalance(borrower);
        uint256 marketDebtBefore = borrowableCUSDC.marketOutstandingDebt();
        uint256 assetsBefore = borrowableCUSDC.totalAssets();
        (
            uint256 rateBefore,
            uint256 endBefore,
            uint256 lastBefore,
            uint256 indexBefore
        ) = borrowableCUSDC.getYieldInformation();

        vm.expectRevert();
        daoTimelock.executeBatch(targets, values, payloads, bytes32(0), salt);

        assertEq(
            address(borrowableCUSDC.IRM()),
            oldIRM,
            "first batch call rolled back"
        );
        assertEq(borrowableCUSDC.debtBalance(borrower), debtBefore);
        assertEq(borrowableCUSDC.marketOutstandingDebt(), marketDebtBefore);
        assertEq(borrowableCUSDC.totalAssets(), assetsBefore);
        (
            uint256 rateAfter,
            uint256 endAfter,
            uint256 lastAfter,
            uint256 indexAfter
        ) = borrowableCUSDC.getYieldInformation();
        assertEq(rateAfter, rateBefore);
        assertEq(endAfter, endBefore);
        assertEq(lastAfter, lastBefore);
        assertEq(indexAfter, indexBefore);

        // The old linked model remains usable; accounting can advance once
        // the reverted batch is out of the call stack.
        borrowableCUSDC.accrueIfNeeded();
        assertGt(borrowableCUSDC.debtBalance(borrower), debtBefore);
        assertGt(borrowableCUSDC.totalAssets(), assetsBefore);
    }

    function _openDebtPosition() internal {
        _prepareUSDC(address(this), 1_000e6);
        usdc.approve(address(borrowableCUSDC), 1_000e6);
        borrowableCUSDC.deposit(1_000e6, address(this));

        deal(address(LP_wstETH_24Dec2025), borrower, 10e18);
        vm.startPrank(borrower);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 10e18);
        pendleStrategyCTokenSTETH.depositAsCollateral(10e18, borrower);
        vm.stopPrank();

        skip(20 minutes);
        vm.prank(borrower);
        borrowableCUSDC.borrow(100e6, borrower);
    }

    function _newIRM() internal returns (DynamicIRM) {
        return new DynamicIRM(
            ICentralRegistry(address(centralRegistry)),
            1_000,
            1_000,
            5_000,
            1_000,
            100,
            100_000
        );
    }

    function _newBorrowable(DynamicIRM irm)
        internal
        returns (BorrowableCToken)
    {
        return new BorrowableCToken(
            ICentralRegistry(address(centralRegistry)),
            IERC20(address(usdc)),
            address(marketManagerIsolated),
            address(irm)
        );
    }

    function _migrationBatch(DynamicIRM replacement)
        internal
        view
        returns (
            address[] memory targets,
            uint256[] memory values,
            bytes[] memory payloads
        )
    {
        targets = new address[](2);
        targets[0] = address(borrowableCUSDC);
        targets[1] = address(replacement);

        values = new uint256[](2);

        payloads = new bytes[](2);
        payloads[0] =
            abi.encodeCall(BorrowableCToken.setIRM, (address(replacement)));
        payloads[1] = abi.encodeCall(
            DynamicIRM.setLinkedToken, (address(borrowableCUSDC))
        );
    }

    function _cachedTotalAssets() internal view returns (uint256) {
        return
            uint256(
                vm.load(address(borrowableCUSDC), bytes32(TOTAL_ASSETS_SLOT))
            );
    }
}
