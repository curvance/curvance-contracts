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
    function deposit(uint256 assets, address receiver)
        external
        returns (uint256);
    function depositAsCollateral(uint256 assets, address receiver)
        external
        returns (uint256);
    function removeCollateral(uint256 shares) external;
    function transfer(address to, uint256 amount) external returns (bool);
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
            user2
        );

        bytes4[] memory selectors = new bytes4[](12);
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
    OracleMode public debtOracleMode;
    OracleMode public collateralOracleMode;
    bool public badOracleBorrowMovedValue;

    uint256 public borrowAttempts;
    uint256 public badOracleBorrowAttempts;
    uint256 public successfulBorrows;
    uint256 public receiverBorrows;

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
        address receiver_
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

        _syncOracles();
    }

    function setDebtOracleMode(uint256 modeSeed) external {
        debtOracleMode = OracleMode(modeSeed % 3);
        _syncOracles();
    }

    function setCollateralOracleMode(uint256 modeSeed) external {
        collateralOracleMode = OracleMode(modeSeed % 3);
        _syncOracles();
    }

    function skipTime(uint256 secondsSeed) external {
        skip(bound(secondsSeed, 1, 1 hours));
    }

    function postCollateral(uint256 assets) external {
        assets = bound(assets, 1e15, 100e18);
        deal(address(collateralAsset), borrower, assets);

        vm.startPrank(borrower);
        collateralAsset.approve(address(collateralCToken), assets);
        try collateralCToken.depositAsCollateral(assets, borrower) {} catch {}
        vm.stopPrank();
    }

    function depositIdleCollateral(uint256 assets) external {
        assets = bound(assets, 1e15, 100e18);
        deal(address(collateralAsset), borrower, assets);

        vm.startPrank(borrower);
        collateralAsset.approve(address(collateralCToken), assets);
        try collateralCToken.deposit(assets, borrower) {} catch {}
        vm.stopPrank();
    }

    function removeCollateral(uint256 sharesSeed) external {
        uint256 posted = collateralCToken.collateralPosted(borrower);
        if (posted == 0) {
            return;
        }

        uint256 shares = bound(sharesSeed, 1, posted);
        vm.prank(borrower);
        try collateralCToken.removeCollateral(shares) {} catch {}
    }

    function transferIdleCollateralShares(uint256 sharesSeed) external {
        uint256 balance = collateralCToken.balanceOf(borrower);
        uint256 posted = collateralCToken.collateralPosted(borrower);
        if (balance <= posted) {
            return;
        }

        uint256 shares = bound(sharesSeed, 1, balance - posted);
        vm.prank(borrower);
        try collateralCToken.transfer(receiver, shares) {} catch {}
    }

    function seedDebtRowWithCanBorrow(uint256 assets) external {
        assets = bound(assets, 1, 500e6);
        _syncOracles();

        try marketManager.canBorrow(
            address(debtCToken),
            assets,
            borrower,
            debtCToken.marketOutstandingDebt() + assets
        ) {}
            catch {}
    }

    function seedDebtRowWithCanBorrowWithNotify(uint256 assets) external {
        assets = bound(assets, 1, 500e6);
        _syncOracles();

        try marketManager.canBorrowWithNotify(
            address(debtCToken),
            assets,
            borrower,
            debtCToken.marketOutstandingDebt() + assets
        ) {}
            catch {}
    }

    function borrow(uint256 assets) external {
        _attemptBorrow(assets, false);
    }

    function borrowFor(uint256 assets) external {
        _attemptBorrow(assets, true);
    }

    function repay(uint256 repaySeed) external {
        try debtCToken.accrueIfNeeded() {} catch {}

        uint256 debt = debtCToken.debtBalance(borrower);
        if (debt == 0) {
            return;
        }

        uint256 repayAssets =
            repaySeed % 4 == 0 ? 0 : bound(repaySeed, 1, debt);
        uint256 assetsToFund = repayAssets == 0 ? debt : repayAssets;

        deal(address(debtAsset), borrower, assetsToFund);
        vm.startPrank(borrower);
        debtAsset.approve(address(debtCToken), assetsToFund);
        try debtCToken.repay(repayAssets) {} catch {}
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
        uint256 borrowerBalanceBefore = debtAsset.balanceOf(borrower);
        uint256 receiverBalanceBefore = debtAsset.balanceOf(receiver);
        uint256 debtBefore = debtCToken.debtBalance(borrower);
        uint256 marketDebtBefore = debtCToken.marketOutstandingDebt();

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

        uint256 borrowerBalanceAfter = debtAsset.balanceOf(borrower);
        uint256 receiverBalanceAfter = debtAsset.balanceOf(receiver);
        uint256 debtAfter = debtCToken.debtBalance(borrower);
        uint256 marketDebtAfter = debtCToken.marketOutstandingDebt();

        if (badOracle) {
            if (
                success || borrowerBalanceAfter > borrowerBalanceBefore
                    || receiverBalanceAfter > receiverBalanceBefore
                    || debtAfter > debtBefore
                    || marketDebtAfter > marketDebtBefore
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
