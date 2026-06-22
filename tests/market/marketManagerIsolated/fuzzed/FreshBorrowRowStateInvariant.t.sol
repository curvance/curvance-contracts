// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {
    TestBaseBorrowableCToken
} from "tests/market/token/BorrowableCToken/TestBaseBorrowableCToken.sol";
import {BorrowableCToken} from "contracts/market/token/BorrowableCToken.sol";
import {
    MarketManagerIsolated
} from "contracts/market/isolated/MarketManagerIsolated.sol";
import {IERC20} from "contracts/interfaces/IERC20.sol";
import {MockDataFeed} from "contracts/mocks/MockDataFeed.sol";

interface IRowStateCollateralCToken {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function collateralPosted(address account) external view returns (uint256);
    function marketCollateralPosted() external view returns (uint256);
    function deposit(uint256 assets, address receiver)
        external
        returns (uint256);
    function depositAsCollateral(uint256 assets, address receiver)
        external
        returns (uint256);
    function removeCollateral(uint256 shares) external;
    function transfer(address to, uint256 amount) external returns (bool);
    function totalAssets() external view returns (uint256);
}

contract FreshBorrowRowStateInvariant is TestBaseBorrowableCToken {
    FreshBorrowRowStateHandler public handler;

    function setUp() public override {
        super.setUp();

        _setCTokenConfigBasic(
            address(pendleStrategyCTokenSTETH), 1_000_000e18, 0
        );
        _setCTokenConfigBasic(
            address(borrowableCUSDC), 1_000_000e18, 1_000_000e6
        );

        _prepareUSDC(address(this), 1_000_000e6);
        usdc.approve(address(borrowableCUSDC), 1_000_000e6);
        borrowableCUSDC.deposit(1_000_000e6, address(this));

        handler = new FreshBorrowRowStateHandler(
            IERC20(address(LP_wstETH_24Dec2025)),
            IERC20(address(usdc)),
            IRowStateCollateralCToken(address(pendleStrategyCTokenSTETH)),
            borrowableCUSDC,
            marketManagerIsolated,
            mockUsdcFeed,
            mockStethFeed,
            chainlinkAdaptor.DEFAULT_HEARTBEAT(),
            user1,
            user2,
            user3
        );

        bytes4[] memory selectors = _targetSelectors();
        targetContract(address(handler));
        targetSelector(
            FuzzSelector({addr: address(handler), selectors: selectors})
        );

        excludeSender(address(0));
        excludeSender(address(handler));
    }

    function invariant_badOracleNeverAllowsBorrowValue() public view {
        assertFalse(
            handler.badOracleBorrowMovedValue(),
            "bad oracle allowed borrow value movement"
        );
    }

    function test_freshBorrowRowStateHandler_selectorCoverageSmokeSequence()
        public
    {
        handler.setDebtOracleMode(0);
        handler.setCollateralOracleMode(0);
        handler.skipTime(1);
        handler.postCollateral(10 ether);
        handler.depositIdleCollateral(5 ether);
        handler.depositSecondaryCollateral(3 ether);
        handler.removeSecondaryCollateral(1e18);
        handler.transferIdleCollateralShares(1e18);
        handler.seedDebtRowWithCanBorrow(1);
        handler.seedDebtRowWithCanBorrowWithNotify(1);
        handler.borrow(1e6);
        handler.borrowFor(1e6);
        handler.repay(0);
        handler.removeCollateral(1e18);

        bytes4[] memory selectors = _targetSelectors();
        for (uint256 i; i < selectors.length; ++i) {
            assertGt(
                handler.selectorHitCount(selectors[i]),
                0,
                "selector not hit in smoke sequence"
            );
        }
    }

    function _targetSelectors()
        internal
        pure
        returns (bytes4[] memory selectors)
    {
        selectors = new bytes4[](14);
        selectors[0] = FreshBorrowRowStateHandler.setDebtOracleMode.selector;
        selectors[1] =
        FreshBorrowRowStateHandler.setCollateralOracleMode.selector;
        selectors[2] = FreshBorrowRowStateHandler.skipTime.selector;
        selectors[3] = FreshBorrowRowStateHandler.postCollateral.selector;
        selectors[4] =
        FreshBorrowRowStateHandler.depositIdleCollateral.selector;
        selectors[5] = FreshBorrowRowStateHandler.removeCollateral.selector;
        selectors[6] =
        FreshBorrowRowStateHandler.transferIdleCollateralShares.selector;
        selectors[7] =
        FreshBorrowRowStateHandler.seedDebtRowWithCanBorrow.selector;
        selectors[8] =
        FreshBorrowRowStateHandler.seedDebtRowWithCanBorrowWithNotify.selector;
        selectors[9] = FreshBorrowRowStateHandler.borrow.selector;
        selectors[10] = FreshBorrowRowStateHandler.borrowFor.selector;
        selectors[11] = FreshBorrowRowStateHandler.repay.selector;
        selectors[12] =
        FreshBorrowRowStateHandler.depositSecondaryCollateral.selector;
        selectors[13] =
        FreshBorrowRowStateHandler.removeSecondaryCollateral.selector;
    }
}

contract FreshBorrowRowStateHandler is Test {
    enum OracleMode {
        Normal,
        Stale,
        Zero
    }

    IERC20 public collateralAsset;
    IERC20 public debtAsset;
    IRowStateCollateralCToken public collateralCToken;
    BorrowableCToken public debtCToken;
    MarketManagerIsolated public marketManager;
    MockDataFeed public debtFeed;
    MockDataFeed public collateralFeed;

    uint256 public heartbeat;
    address public borrower;
    address public receiver;
    address public secondaryCollateralOwner;
    OracleMode public debtOracleMode;
    OracleMode public collateralOracleMode;
    bool public badOracleBorrowMovedValue;

    uint256 public borrowAttempts;
    uint256 public badOracleBorrowAttempts;
    uint256 public successfulBorrows;
    uint256 public receiverBorrows;
    uint256 public totalSelectorHits;
    mapping(bytes4 => uint256) public selectorHitCount;

    constructor(
        IERC20 collateralAsset_,
        IERC20 debtAsset_,
        IRowStateCollateralCToken collateralCToken_,
        BorrowableCToken debtCToken_,
        MarketManagerIsolated marketManager_,
        MockDataFeed debtFeed_,
        MockDataFeed collateralFeed_,
        uint256 heartbeat_,
        address borrower_,
        address receiver_,
        address secondaryCollateralOwner_
    ) {
        collateralAsset = collateralAsset_;
        debtAsset = debtAsset_;
        collateralCToken = collateralCToken_;
        debtCToken = debtCToken_;
        marketManager = marketManager_;
        debtFeed = debtFeed_;
        collateralFeed = collateralFeed_;
        heartbeat = heartbeat_;
        borrower = borrower_;
        receiver = receiver_;
        secondaryCollateralOwner = secondaryCollateralOwner_;

        _syncOracles();
    }

    struct CollateralSnapshot {
        uint256 borrowerBalance;
        uint256 receiverBalance;
        uint256 secondaryBalance;
        uint256 borrowerPosted;
        uint256 secondaryPosted;
        uint256 marketPosted;
    }

    struct DebtSnapshot {
        uint256 borrowerDebt;
        uint256 marketDebt;
        uint256 marketCash;
        uint256 borrowerCash;
        uint256 receiverCash;
    }

    modifier checkPostActionInvariants() {
        ++selectorHitCount[msg.sig];
        ++totalSelectorHits;
        _;
        _assertPostActionInvariants();
    }

    function setDebtOracleMode(uint256 modeSeed)
        external
        checkPostActionInvariants
    {
        debtOracleMode = OracleMode(modeSeed % 3);
        _syncOracles();
    }

    function setCollateralOracleMode(uint256 modeSeed)
        external
        checkPostActionInvariants
    {
        collateralOracleMode = OracleMode(modeSeed % 3);
        _syncOracles();
    }

    function skipTime(uint256 secondsSeed) external checkPostActionInvariants {
        skip(bound(secondsSeed, 1, 1 hours));
        _syncOracles();
    }

    function postCollateral(uint256 assets)
        external
        checkPostActionInvariants
    {
        assets = bound(assets, 1e15, 100e18);
        deal(address(collateralAsset), borrower, assets);

        CollateralSnapshot memory beforeAction = _collateralSnapshot();
        vm.startPrank(borrower);
        collateralAsset.approve(address(collateralCToken), assets);
        try collateralCToken.depositAsCollateral(assets, borrower) returns (
            uint256 shares
        ) {
            _assertCollateralDepositDelta(beforeAction, shares, true);
        } catch {}
        vm.stopPrank();
    }

    function depositIdleCollateral(uint256 assets)
        external
        checkPostActionInvariants
    {
        assets = bound(assets, 1e15, 100e18);
        deal(address(collateralAsset), borrower, assets);

        CollateralSnapshot memory beforeAction = _collateralSnapshot();
        vm.startPrank(borrower);
        collateralAsset.approve(address(collateralCToken), assets);
        try collateralCToken.deposit(assets, borrower) returns (
            uint256 shares
        ) {
            _assertCollateralDepositDelta(beforeAction, shares, false);
        } catch {}
        vm.stopPrank();
    }

    function depositSecondaryCollateral(uint256 assets)
        external
        checkPostActionInvariants
    {
        assets = bound(assets, 1e15, 100e18);
        deal(address(collateralAsset), secondaryCollateralOwner, assets);

        CollateralSnapshot memory beforeAction = _collateralSnapshot();
        vm.startPrank(secondaryCollateralOwner);
        collateralAsset.approve(address(collateralCToken), assets);
        try collateralCToken.depositAsCollateral(
            assets, secondaryCollateralOwner
        ) returns (
            uint256 shares
        ) {
            _assertSecondaryCollateralDepositDelta(beforeAction, shares);
        } catch {}
        vm.stopPrank();
    }

    function removeCollateral(uint256 sharesSeed)
        external
        checkPostActionInvariants
    {
        uint256 posted = collateralCToken.collateralPosted(borrower);
        if (posted == 0) {
            return;
        }

        uint256 shares = bound(sharesSeed, 1, posted);
        CollateralSnapshot memory beforeAction = _collateralSnapshot();
        vm.prank(borrower);
        try collateralCToken.removeCollateral(shares) {
            _assertRemoveCollateralDelta(beforeAction, shares);
        } catch {}
    }

    function removeSecondaryCollateral(uint256 sharesSeed)
        external
        checkPostActionInvariants
    {
        uint256 posted = collateralCToken.collateralPosted(
            secondaryCollateralOwner
        );
        if (posted == 0) {
            return;
        }

        uint256 shares = bound(sharesSeed, 1, posted);
        CollateralSnapshot memory beforeAction = _collateralSnapshot();
        vm.prank(secondaryCollateralOwner);
        try collateralCToken.removeCollateral(shares) {
            _assertSecondaryRemoveCollateralDelta(beforeAction, shares);
        } catch {}
    }

    function transferIdleCollateralShares(uint256 sharesSeed)
        external
        checkPostActionInvariants
    {
        uint256 balance = collateralCToken.balanceOf(borrower);
        uint256 posted = collateralCToken.collateralPosted(borrower);
        if (balance <= posted) {
            return;
        }

        uint256 shares = bound(sharesSeed, 1, balance - posted);
        CollateralSnapshot memory beforeAction = _collateralSnapshot();
        vm.prank(borrower);
        try collateralCToken.transfer(receiver, shares) returns (
            bool success
        ) {
            if (success) {
                _assertTransferCollateralDelta(beforeAction, shares);
            }
        } catch {}
    }

    function seedDebtRowWithCanBorrow(uint256 assets)
        external
        checkPostActionInvariants
    {
        assets = bound(assets, 1, 500e6);
        _syncOracles();

        DebtSnapshot memory beforeAction = _debtSnapshot();
        vm.prank(address(debtCToken));
        try marketManager.canBorrow(
            address(debtCToken),
            assets,
            borrower,
            debtCToken.marketOutstandingDebt() + assets
        ) {
            _assertDebtSnapshotUnchanged(beforeAction, _debtSnapshot());
        } catch {}
    }

    function seedDebtRowWithCanBorrowWithNotify(uint256 assets)
        external
        checkPostActionInvariants
    {
        assets = bound(assets, 1, 500e6);
        _syncOracles();

        DebtSnapshot memory beforeAction = _debtSnapshot();
        vm.prank(address(debtCToken));
        try marketManager.canBorrowWithNotify(
            address(debtCToken),
            assets,
            borrower,
            debtCToken.marketOutstandingDebt() + assets
        ) {
            _assertDebtSnapshotUnchanged(beforeAction, _debtSnapshot());
        } catch {}
    }

    function borrow(uint256 assets) external checkPostActionInvariants {
        _attemptBorrow(assets, false);
    }

    function borrowFor(uint256 assets) external checkPostActionInvariants {
        _attemptBorrow(assets, true);
    }

    function repay(uint256 repaySeed) external checkPostActionInvariants {
        try debtCToken.accrueIfNeeded() {} catch {}

        uint256 debt = debtCToken.debtBalance(borrower);
        if (debt == 0) {
            return;
        }

        uint256 repayAssets =
            repaySeed % 4 == 0 ? 0 : bound(repaySeed, 1, debt);
        uint256 assetsToFund = repayAssets == 0 ? debt : repayAssets;

        deal(address(debtAsset), borrower, assetsToFund);
        DebtSnapshot memory beforeAction = _debtSnapshot();
        vm.startPrank(borrower);
        debtAsset.approve(address(debtCToken), assetsToFund);
        try debtCToken.repay(repayAssets) {
            DebtSnapshot memory afterAction = _debtSnapshot();
            assertEq(
                afterAction.borrowerDebt,
                beforeAction.borrowerDebt - assetsToFund,
                "POST REPAY: borrower debt delta"
            );
            assertEq(
                afterAction.marketDebt,
                beforeAction.marketDebt < assetsToFund
                    ? 0
                    : beforeAction.marketDebt - assetsToFund,
                "POST REPAY: market debt delta"
            );
            assertEq(
                afterAction.marketCash,
                beforeAction.marketCash + assetsToFund,
                "POST REPAY: market cash delta"
            );
            assertEq(
                afterAction.borrowerCash,
                beforeAction.borrowerCash - assetsToFund,
                "POST REPAY: borrower cash delta"
            );
        } catch {}
        vm.stopPrank();
    }

    function _attemptBorrow(uint256 assets, bool delegated) internal {
        assets = bound(assets, 1, 500e6);
        borrowAttempts++;
        _syncOracles();

        try debtCToken.accrueIfNeeded() {} catch {}

        bool badOracle = debtOracleMode != OracleMode.Normal
            || collateralOracleMode != OracleMode.Normal;
        if (badOracle) {
            badOracleBorrowAttempts++;
        }

        address selectedReceiver = assets % 2 == 0 ? receiver : borrower;
        DebtSnapshot memory beforeAction = _debtSnapshot();

        bool success;
        if (delegated) {
            vm.prank(borrower);
            debtCToken.setDelegateApproval(address(this), true);
            try debtCToken.borrowFor(assets, selectedReceiver, borrower) {
                success = true;
            } catch {}
        } else {
            vm.prank(borrower);
            try debtCToken.borrow(assets, selectedReceiver) {
                success = true;
            } catch {}
        }

        DebtSnapshot memory afterAction = _debtSnapshot();

        if (badOracle) {
            if (
                success || afterAction.borrowerCash > beforeAction.borrowerCash
                    || afterAction.receiverCash > beforeAction.receiverCash
                    || afterAction.borrowerDebt > beforeAction.borrowerDebt
                    || afterAction.marketDebt > beforeAction.marketDebt
                    || afterAction.marketCash < beforeAction.marketCash
            ) {
                badOracleBorrowMovedValue = true;
            }
            return;
        }

        if (success) {
            successfulBorrows++;
            if (selectedReceiver == receiver) {
                receiverBorrows++;
            }
            _assertBorrowDelta(
                beforeAction, afterAction, assets, selectedReceiver
            );
        }
    }

    function _assertPostActionInvariants() internal view {
        uint256 borrowerPosted = collateralCToken.collateralPosted(borrower);
        uint256 secondaryPosted =
            collateralCToken.collateralPosted(secondaryCollateralOwner);
        assertLe(
            borrowerPosted,
            collateralCToken.balanceOf(borrower),
            "POST ACTION: borrower posted exceeds balance"
        );
        assertLe(
            secondaryPosted,
            collateralCToken.balanceOf(secondaryCollateralOwner),
            "POST ACTION: secondary posted exceeds balance"
        );
        assertEq(
            collateralCToken.marketCollateralPosted(),
            borrowerPosted + secondaryPosted,
            "POST ACTION: market collateral differs from actor sum"
        );
        assertEq(
            debtCToken.debtBalance(receiver), 0, "POST ACTION: receiver debt"
        );
        assertEq(
            debtCToken.debtBalance(secondaryCollateralOwner),
            0,
            "POST ACTION: secondary debt"
        );

        uint256 borrowerDebt = debtCToken.debtBalance(borrower);
        uint256 marketDebt = debtCToken.marketOutstandingDebt();
        if (borrowerDebt == 0) {
            assertEq(marketDebt, 0, "POST ACTION: zero borrower market debt");
        }
        assertGe(
            borrowerDebt,
            marketDebt,
            "POST ACTION: borrower debt below market debt"
        );
        assertLe(
            marketDebt,
            debtCToken.totalAssets(),
            "POST ACTION: market debt exceeds total assets"
        );
    }

    function _collateralSnapshot()
        internal
        view
        returns (CollateralSnapshot memory snapshot)
    {
        snapshot.borrowerBalance = collateralCToken.balanceOf(borrower);
        snapshot.receiverBalance = collateralCToken.balanceOf(receiver);
        snapshot.secondaryBalance =
            collateralCToken.balanceOf(secondaryCollateralOwner);
        snapshot.borrowerPosted = collateralCToken.collateralPosted(borrower);
        snapshot.secondaryPosted =
            collateralCToken.collateralPosted(secondaryCollateralOwner);
        snapshot.marketPosted = collateralCToken.marketCollateralPosted();
    }

    function _debtSnapshot()
        internal
        view
        returns (DebtSnapshot memory snapshot)
    {
        snapshot.borrowerDebt = debtCToken.debtBalance(borrower);
        snapshot.marketDebt = debtCToken.marketOutstandingDebt();
        snapshot.marketCash = debtAsset.balanceOf(address(debtCToken));
        snapshot.borrowerCash = debtAsset.balanceOf(borrower);
        snapshot.receiverCash = debtAsset.balanceOf(receiver);
    }

    function _assertCollateralDepositDelta(
        CollateralSnapshot memory beforeAction,
        uint256 shares,
        bool posted
    ) internal view {
        assertEq(
            collateralCToken.balanceOf(borrower),
            beforeAction.borrowerBalance + shares,
            "POST COLLATERAL DEPOSIT: borrower balance delta"
        );
        assertEq(
            collateralCToken.collateralPosted(borrower),
            posted
                ? beforeAction.borrowerPosted + shares
                : beforeAction.borrowerPosted,
            "POST COLLATERAL DEPOSIT: borrower posted delta"
        );
        assertEq(
            collateralCToken.marketCollateralPosted(),
            posted
                ? beforeAction.marketPosted + shares
                : beforeAction.marketPosted,
            "POST COLLATERAL DEPOSIT: market posted delta"
        );
        assertEq(
            collateralCToken.balanceOf(secondaryCollateralOwner),
            beforeAction.secondaryBalance,
            "POST COLLATERAL DEPOSIT: secondary balance changed"
        );
        assertEq(
            collateralCToken.collateralPosted(secondaryCollateralOwner),
            beforeAction.secondaryPosted,
            "POST COLLATERAL DEPOSIT: secondary posted changed"
        );
    }

    function _assertSecondaryCollateralDepositDelta(
        CollateralSnapshot memory beforeAction,
        uint256 shares
    ) internal view {
        assertEq(
            collateralCToken.balanceOf(secondaryCollateralOwner),
            beforeAction.secondaryBalance + shares,
            "POST SECONDARY DEPOSIT: secondary balance delta"
        );
        assertEq(
            collateralCToken.collateralPosted(secondaryCollateralOwner),
            beforeAction.secondaryPosted + shares,
            "POST SECONDARY DEPOSIT: secondary posted delta"
        );
        assertEq(
            collateralCToken.marketCollateralPosted(),
            beforeAction.marketPosted + shares,
            "POST SECONDARY DEPOSIT: market posted delta"
        );
        assertEq(
            collateralCToken.balanceOf(borrower),
            beforeAction.borrowerBalance,
            "POST SECONDARY DEPOSIT: borrower balance changed"
        );
        assertEq(
            collateralCToken.collateralPosted(borrower),
            beforeAction.borrowerPosted,
            "POST SECONDARY DEPOSIT: borrower posted changed"
        );
    }

    function _assertRemoveCollateralDelta(
        CollateralSnapshot memory beforeAction,
        uint256 shares
    ) internal view {
        assertEq(
            collateralCToken.balanceOf(borrower),
            beforeAction.borrowerBalance,
            "POST REMOVE COLLATERAL: borrower balance changed"
        );
        assertEq(
            collateralCToken.collateralPosted(borrower),
            beforeAction.borrowerPosted - shares,
            "POST REMOVE COLLATERAL: borrower posted delta"
        );
        assertEq(
            collateralCToken.marketCollateralPosted(),
            beforeAction.marketPosted - shares,
            "POST REMOVE COLLATERAL: market posted delta"
        );
        assertEq(
            collateralCToken.balanceOf(secondaryCollateralOwner),
            beforeAction.secondaryBalance,
            "POST REMOVE COLLATERAL: secondary balance changed"
        );
        assertEq(
            collateralCToken.collateralPosted(secondaryCollateralOwner),
            beforeAction.secondaryPosted,
            "POST REMOVE COLLATERAL: secondary posted changed"
        );
    }

    function _assertSecondaryRemoveCollateralDelta(
        CollateralSnapshot memory beforeAction,
        uint256 shares
    ) internal view {
        assertEq(
            collateralCToken.balanceOf(secondaryCollateralOwner),
            beforeAction.secondaryBalance,
            "POST SECONDARY REMOVE: secondary balance changed"
        );
        assertEq(
            collateralCToken.collateralPosted(secondaryCollateralOwner),
            beforeAction.secondaryPosted - shares,
            "POST SECONDARY REMOVE: secondary posted delta"
        );
        assertEq(
            collateralCToken.marketCollateralPosted(),
            beforeAction.marketPosted - shares,
            "POST SECONDARY REMOVE: market posted delta"
        );
        assertEq(
            collateralCToken.balanceOf(borrower),
            beforeAction.borrowerBalance,
            "POST SECONDARY REMOVE: borrower balance changed"
        );
        assertEq(
            collateralCToken.collateralPosted(borrower),
            beforeAction.borrowerPosted,
            "POST SECONDARY REMOVE: borrower posted changed"
        );
    }

    function _assertTransferCollateralDelta(
        CollateralSnapshot memory beforeAction,
        uint256 shares
    ) internal view {
        assertEq(
            collateralCToken.balanceOf(borrower),
            beforeAction.borrowerBalance - shares,
            "POST TRANSFER: borrower balance delta"
        );
        assertEq(
            collateralCToken.balanceOf(receiver),
            beforeAction.receiverBalance + shares,
            "POST TRANSFER: receiver balance delta"
        );
        assertEq(
            collateralCToken.collateralPosted(borrower),
            beforeAction.borrowerPosted,
            "POST TRANSFER: borrower posted changed"
        );
        assertEq(
            collateralCToken.marketCollateralPosted(),
            beforeAction.marketPosted,
            "POST TRANSFER: market posted changed"
        );
    }

    function _assertDebtSnapshotUnchanged(
        DebtSnapshot memory beforeAction,
        DebtSnapshot memory afterAction
    ) internal pure {
        assertEq(
            afterAction.borrowerDebt,
            beforeAction.borrowerDebt,
            "POST SEED ROW: borrower debt changed"
        );
        assertEq(
            afterAction.marketDebt,
            beforeAction.marketDebt,
            "POST SEED ROW: market debt changed"
        );
        assertEq(
            afterAction.marketCash,
            beforeAction.marketCash,
            "POST SEED ROW: market cash changed"
        );
        assertEq(
            afterAction.borrowerCash,
            beforeAction.borrowerCash,
            "POST SEED ROW: borrower cash changed"
        );
        assertEq(
            afterAction.receiverCash,
            beforeAction.receiverCash,
            "POST SEED ROW: receiver cash changed"
        );
    }

    function _assertBorrowDelta(
        DebtSnapshot memory beforeAction,
        DebtSnapshot memory afterAction,
        uint256 assets,
        address selectedReceiver
    ) internal view {
        assertEq(
            afterAction.borrowerDebt,
            beforeAction.borrowerDebt + assets,
            "POST BORROW: borrower debt delta"
        );
        assertEq(
            afterAction.marketDebt,
            beforeAction.marketDebt + assets,
            "POST BORROW: market debt delta"
        );
        assertEq(
            afterAction.marketCash,
            beforeAction.marketCash - assets,
            "POST BORROW: market cash delta"
        );

        if (selectedReceiver == receiver) {
            assertEq(
                afterAction.receiverCash,
                beforeAction.receiverCash + assets,
                "POST BORROW: receiver cash delta"
            );
            assertEq(
                afterAction.borrowerCash,
                beforeAction.borrowerCash,
                "POST BORROW: borrower cash changed"
            );
        } else {
            assertEq(
                afterAction.borrowerCash,
                beforeAction.borrowerCash + assets,
                "POST BORROW: borrower cash delta"
            );
            assertEq(
                afterAction.receiverCash,
                beforeAction.receiverCash,
                "POST BORROW: receiver cash changed"
            );
        }
    }

    function _syncOracles() internal {
        _syncFeed(debtFeed, debtOracleMode, 1e8);
        _syncFeed(collateralFeed, collateralOracleMode, 2_000e8);
    }

    function _syncFeed(MockDataFeed feed, OracleMode mode, int256 normalAnswer)
        internal
    {
        if (mode == OracleMode.Normal) {
            feed.setMockAnswer(normalAnswer);
            feed.setMockUpdatedAt(block.timestamp);
        } else if (mode == OracleMode.Stale) {
            feed.setMockAnswer(normalAnswer);
            feed.setMockUpdatedAt(block.timestamp - heartbeat - 1);
        } else {
            feed.setMockAnswer(-1);
            feed.setMockUpdatedAt(block.timestamp);
        }
    }
}
