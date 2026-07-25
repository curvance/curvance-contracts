// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {
    TestBaseBorrowableCToken
} from "tests/market/token/BorrowableCToken/TestBaseBorrowableCToken.sol";
import {BorrowableCToken} from "contracts/market/token/BorrowableCToken.sol";

/// @notice Production-path differential at the packed uint80 debt-index boundary.
contract BorrowableDebtIndexHorizonPoC is TestBaseBorrowableCToken {
    address internal lender;
    address internal borrower;

    uint256 internal constant PRINCIPAL = 500_000_000;
    uint256 internal constant LENDER_ASSETS = 1_000_000_000;
    uint256 internal constant VESTING_DATA_SLOT = 7;
    uint256 internal constant DEBT_OF_SLOT = 10;
    uint256 internal constant DEBT_INDEX_SHIFT = 176;

    function setUp() public override {
        super.setUp();

        lender = makeAddr("debt-index lender");
        borrower = makeAddr("debt-index borrower");

        // Keep the boundary accounting exact: the one-unit accrual belongs
        // entirely to lenders and does not mint protocol fee shares.
        borrowableCUSDC.setInterestFee(0);

        _prepareUSDC(lender, LENDER_ASSETS);
        vm.startPrank(lender);
        usdc.approve(address(borrowableCUSDC), LENDER_ASSETS);
        borrowableCUSDC.deposit(LENDER_ASSETS, lender);
        vm.stopPrank();

        deal(address(LP_wstETH_24Dec2025), borrower, 2_000e18);
        vm.startPrank(borrower);
        LP_wstETH_24Dec2025.approve(
            address(pendleStrategyCTokenSTETH), 2_000e18
        );
        pendleStrategyCTokenSTETH.depositAsCollateral(2_000e18, borrower);
        vm.stopPrank();

        // Clear the collateral hold period before opening debt, then clear
        // the repayment cooldown without calling an accrual entry point.
        skip(20 minutes);
        vm.prank(borrower);
        borrowableCUSDC.borrow(PRINCIPAL, borrower);
        skip(20 minutes);

        assertEq(borrowableCUSDC.marketOutstandingDebt(), PRINCIPAL);
        assertEq(borrowableCUSDC.debtBalance(borrower), PRINCIPAL);
    }

    function test_debtIndexImmediatelyBelowBoundaryPreservesCollectionAndLenderExit()
        public
    {
        uint256 maxIndex = type(uint80).max;
        uint256 maximumIncrement = _divUp(maxIndex, PRINCIPAL);
        uint80 startingIndex = uint80(maxIndex - maximumIncrement);

        _installOneUnitAccrual(startingIndex);
        borrowableCUSDC.accrueIfNeeded();

        (,,, uint256 storedIndex) = borrowableCUSDC.getYieldInformation();
        uint256 expectedIndex =
            uint256(startingIndex) + _divUp(uint256(startingIndex), PRINCIPAL);
        assertEq(
            storedIndex,
            expectedIndex,
            "full index stored below uint80 ceiling"
        );
        assertLe(storedIndex, maxIndex, "control must stay within uint80");

        uint256 collectibleDebt = borrowableCUSDC.debtBalance(borrower);
        uint256 expectedCollectibleDebt =
            _divUp(PRINCIPAL * expectedIndex, startingIndex);
        assertEq(
            collectibleDebt,
            expectedCollectibleDebt,
            "borrower row preserves full indexed collection"
        );
        assertEq(
            collectibleDebt,
            PRINCIPAL + 2,
            "per-account round-up remains protocol-favoring"
        );
        assertEq(
            borrowableCUSDC.marketOutstandingDebt(),
            PRINCIPAL + 1,
            "aggregate debt matches borrower debt"
        );

        _prepareUSDC(borrower, collectibleDebt);
        vm.startPrank(borrower);
        usdc.approve(address(borrowableCUSDC), collectibleDebt);
        borrowableCUSDC.repay(0);
        vm.stopPrank();

        assertEq(borrowableCUSDC.debtBalance(borrower), 0);
        assertEq(borrowableCUSDC.marketOutstandingDebt(), 0);

        uint256 lenderShares = borrowableCUSDC.balanceOf(lender);
        uint256 lenderClaim = borrowableCUSDC.previewRedeem(lenderShares);
        uint256 lenderBalanceBefore = usdc.balanceOf(lender);

        vm.prank(lender);
        uint256 assetsRedeemed =
            borrowableCUSDC.redeem(lenderShares, lender, lender);

        assertEq(
            assetsRedeemed, lenderClaim, "lender realizes full previewed claim"
        );
        assertEq(
            usdc.balanceOf(lender),
            lenderBalanceBefore + lenderClaim,
            "lender exit is fully funded"
        );
    }

    function test_debtIndexCrossingBoundarySilentlyWrapsAndOrphansDebt()
        public
    {
        uint80 startingIndex = type(uint80).max;
        uint256 computedIndex =
            uint256(startingIndex) + _divUp(uint256(startingIndex), PRINCIPAL);

        _installOneUnitAccrual(startingIndex);
        borrowableCUSDC.accrueIfNeeded();

        (,,, uint256 storedIndex) = borrowableCUSDC.getYieldInformation();
        assertGt(
            computedIndex, type(uint80).max, "fixture crosses uint80 ceiling"
        );
        assertEq(
            storedIndex,
            uint256(uint80(computedIndex)),
            "production assembly store silently keeps only low 80 bits"
        );

        uint256 collectibleDebt = borrowableCUSDC.debtBalance(borrower);
        assertEq(
            collectibleDebt,
            1,
            "coherent principal collapses to one collectible unit"
        );
        assertEq(
            borrowableCUSDC.marketOutstandingDebt(),
            PRINCIPAL + 1,
            "aggregate debt records the full accrual"
        );

        _prepareUSDC(borrower, collectibleDebt);
        vm.startPrank(borrower);
        usdc.approve(address(borrowableCUSDC), collectibleDebt);
        borrowableCUSDC.repay(0);
        vm.stopPrank();

        assertEq(borrowableCUSDC.debtBalance(borrower), 0);
        assertEq(
            borrowableCUSDC.marketOutstandingDebt(),
            PRINCIPAL,
            "full reported repayment leaves principal orphaned in aggregate debt"
        );

        uint256 lenderShares = borrowableCUSDC.balanceOf(lender);
        uint256 lenderClaim = borrowableCUSDC.previewRedeem(lenderShares);
        assertGt(
            lenderClaim,
            borrowableCUSDC.assetsHeld(),
            "booked lender claim exceeds realizable cash"
        );

        vm.prank(lender);
        vm.expectRevert(
            BorrowableCToken.BorrowableCToken__InsufficientAssetsHeld.selector
        );
        borrowableCUSDC.redeem(lenderShares, lender, lender);
    }

    /// @dev Installs a coherent account/market checkpoint and a one-second,
    ///      one-asset-unit vesting interval. Slots are asserted by the current
    ///      production storage layout: _vestingData=7 and _debtOf=10.
    function _installOneUnitAccrual(uint80 debtIndex) internal {
        uint256 ratePerSecond = 2_000_000_000; // PRINCIPAL * rate / 1e18 = 1.
        uint256 packedVestingData = ratePerSecond
            | ((block.timestamp + 1) << 96) | ((block.timestamp - 1) << 136)
            | (uint256(debtIndex) << DEBT_INDEX_SHIFT);

        vm.store(
            address(borrowableCUSDC),
            bytes32(VESTING_DATA_SLOT),
            bytes32(packedVestingData)
        );

        bytes32 debtSlot =
            keccak256(abi.encode(borrower, uint256(DEBT_OF_SLOT)));
        vm.store(
            address(borrowableCUSDC),
            debtSlot,
            bytes32(PRINCIPAL | (uint256(debtIndex) << DEBT_INDEX_SHIFT))
        );

        (,,, uint256 observedIndex) = borrowableCUSDC.getYieldInformation();
        assertEq(observedIndex, debtIndex, "installed market checkpoint");
        assertEq(borrowableCUSDC.debtBalance(borrower), PRINCIPAL);
    }

    function _divUp(uint256 x, uint256 y) internal pure returns (uint256) {
        return (x + y - 1) / y;
    }
}
