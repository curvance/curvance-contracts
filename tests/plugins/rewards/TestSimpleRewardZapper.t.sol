// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {ClaimAction} from "contracts/interfaces/IRewardManager.sol";
import {IERC20} from "contracts/interfaces/IERC20.sol";
import {ICToken} from "contracts/interfaces/ICToken.sol";
import {SwapperLib} from "contracts/libraries/SwapperLib.sol";
import {BaseZapper} from "contracts/plugins/BaseZapper.sol";
import {
    SimpleRewardZapper
} from "contracts/plugins/rewards/SimpleRewardZapper.sol";
import {MockCalldataChecker} from "contracts/mocks/MockCalldataChecker.sol";

import {TestBaseMarketIsolated} from "tests/market/TestBaseMarketIsolated.sol";

contract TC019_MockRewardSwapTarget {
    function swap(
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        address recipient
    ) external {
        IERC20(inputToken).transferFrom(msg.sender, address(this), inputAmount);
        IERC20(outputToken).transfer(recipient, outputAmount);
    }
}

contract TestSimpleRewardZapper is TestBaseMarketIsolated {
    TC019_MockRewardSwapTarget internal rewardSwapTarget;

    function setUp() public override {
        super.setUp();
        _skipRestrictionDuration();

        rewardSwapTarget = new TC019_MockRewardSwapTarget();

        centralRegistry.setExternalCalldataChecker(
            address(rewardSwapTarget),
            address(new MockCalldataChecker(address(rewardSwapTarget)))
        );

        oracleManager.addCTokenSupport(address(simpleCUSDC));
        _prepareUSDC(address(this), 100e6);
        usdc.approve(address(simpleCUSDC), 100e6);
        _prepareDAI(address(this), 1000e18);
        dai.approve(address(borrowableCDAI), 1000e18);
        marketManagerIsolated.listTokens(
            address(simpleCUSDC), address(borrowableCDAI)
        );
        _setCTokenConfigHighValues(address(simpleCUSDC), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCDAI), 100_000e18, 100_000e18);

        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareDAI(liquidityProvider, 1_000_000e18);

        vm.startPrank(liquidityProvider);
        dai.approve(address(borrowableCDAI), 1_000_000e18);
        borrowableCDAI.deposit(1_000_000e18, liquidityProvider);
        vm.stopPrank();

        simpleRewardZapper.addAuthorizedOutputToken(_DAI_ADDRESS);
    }

    function test_claimAndSwapClaimsCallerRewardsAndRoutesOutputToReceiver()
        public
    {
        uint256 expectedRewards = _seedClaimableRewards(user1);
        uint256 outputAmount = expectedRewards * 1e12;
        address receiver = makeAddr("receiver");

        _prepareDAI(address(rewardSwapTarget), outputAmount);

        SwapperLib.Swap memory swapAction =
            _buildRewardSwap(expectedRewards, outputAmount);

        vm.prank(user1);
        uint256 received =
            simpleRewardZapper.claimAndSwap(swapAction, receiver);

        assertEq(received, outputAmount, "claim swap returned output");
        assertEq(dai.balanceOf(receiver), outputAmount, "receiver DAI output");
        assertEq(usdc.balanceOf(user1), 0, "caller should not keep rewards");
        assertEq(rewardManager.epochsToClaim(user1), 0, "rewards claimed");
        _assertSimpleRewardZapperHasNoResidue();
    }

    function test_claimSwapAndDepositCreditsReceiverShares() public {
        uint256 expectedRewards = _seedClaimableRewards(user1);
        uint256 expectedShares = simpleCUSDC.previewDeposit(expectedRewards);
        address receiver = makeAddr("receiver");

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = expectedRewards;
        swapAction.outputToken = _USDC_ADDRESS;

        vm.prank(user1);
        uint256 shares = simpleRewardZapper.claimSwapAndDeposit(
            address(simpleCUSDC), swapAction, 0, false, receiver
        );

        assertEq(shares, expectedShares, "reward deposit returned shares");
        assertEq(
            simpleCUSDC.balanceOf(receiver),
            expectedShares,
            "receiver cUSDC shares"
        );
        assertEq(
            simpleCUSDC.balanceOf(user1), 0, "caller should hold no shares"
        );
        assertEq(rewardManager.epochsToClaim(user1), 0, "rewards claimed");
        _assertSimpleRewardZapperHasNoResidue();
    }

    function test_claimSwapAndDeposit_fail_expectedSharesTooHighRollsBackRewards()
        public
    {
        uint256 expectedRewards = _seedClaimableRewards(user1);
        uint256 epochsBefore = rewardManager.epochsToClaim(user1);
        uint256 receiverSharesBefore = simpleCUSDC.balanceOf(user1);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = expectedRewards;
        swapAction.outputToken = _USDC_ADDRESS;

        vm.prank(user1);
        vm.expectRevert(BaseZapper.BaseZapper__ExecutionError.selector);
        simpleRewardZapper.claimSwapAndDeposit(
            address(simpleCUSDC), swapAction, type(uint256).max, false, user1
        );

        assertEq(
            rewardManager.epochsToClaim(user1),
            epochsBefore,
            "failed reward deposit should keep rewards claimable"
        );
        assertEq(
            simpleCUSDC.balanceOf(user1),
            receiverSharesBefore,
            "failed reward deposit should not mint shares"
        );
        assertEq(
            usdc.balanceOf(address(simpleRewardZapper)),
            0,
            "failed reward deposit should not retain USDC"
        );
    }

    function test_claimSwapAndRepayRepaysReceiverDebtAndReturnsExcessToCaller()
        public
    {
        uint256 expectedRewards = _seedClaimableRewards(user1);
        uint256 debtAmount = 25e18;
        uint256 outputAmount = 50e18;
        _openDaiDebt(user2, debtAmount);
        _prepareDAI(address(rewardSwapTarget), outputAmount);

        SwapperLib.Swap memory swapAction =
            _buildRewardSwap(expectedRewards, outputAmount);

        skip(20 minutes);
        _refreshMockFeeds();
        uint256 debtBefore = borrowableCDAI.debtBalanceUpdated(user2);

        vm.prank(user1);
        uint256 excess = simpleRewardZapper.claimSwapAndRepay(
            swapAction, address(borrowableCDAI), outputAmount, user2
        );

        assertEq(borrowableCDAI.debtBalance(user2), 0, "receiver debt repaid");
        assertEq(excess, outputAmount - debtBefore, "returned excess amount");
        assertEq(dai.balanceOf(user1), excess, "caller DAI refund");
        assertEq(
            dai.balanceOf(user2), debtAmount, "receiver should not get DAI"
        );
        assertEq(rewardManager.epochsToClaim(user1), 0, "rewards claimed");
        _assertSimpleRewardZapperHasNoResidue();
    }

    function test_claimSwapAndRepay_fail_repayFloorTooHighRollsBackRewardsAndSwap()
        public
    {
        uint256 expectedRewards = _seedClaimableRewards(user1);
        uint256 debtAmount = 25e18;
        uint256 outputAmount = 50e18;
        _openDaiDebt(user2, debtAmount);
        _prepareDAI(address(rewardSwapTarget), outputAmount);

        SwapperLib.Swap memory swapAction =
            _buildRewardSwap(expectedRewards, outputAmount);

        skip(20 minutes);
        _refreshMockFeeds();
        uint256 debtBefore = borrowableCDAI.debtBalanceUpdated(user2);
        uint256 epochsBefore = rewardManager.epochsToClaim(user1);
        uint256 callerDaiBefore = dai.balanceOf(user1);
        uint256 receiverDaiBefore = dai.balanceOf(user2);
        uint256 targetDaiBefore = dai.balanceOf(address(rewardSwapTarget));

        vm.prank(user1);
        vm.expectRevert(
            BaseZapper.BaseZapper__InsufficientAssetsForRepayment.selector
        );
        simpleRewardZapper.claimSwapAndRepay(
            swapAction, address(borrowableCDAI), outputAmount + 1, user2
        );

        assertEq(
            rewardManager.epochsToClaim(user1),
            epochsBefore,
            "failed reward repay should keep rewards claimable"
        );
        assertEq(
            borrowableCDAI.debtBalance(user2),
            debtBefore,
            "failed reward repay should not change receiver debt"
        );
        assertEq(
            dai.balanceOf(user1),
            callerDaiBefore,
            "failed reward repay should not refund caller"
        );
        assertEq(
            dai.balanceOf(user2),
            receiverDaiBefore,
            "failed reward repay should not transfer to receiver"
        );
        assertEq(
            dai.balanceOf(address(rewardSwapTarget)),
            targetDaiBefore,
            "failed reward repay should roll back mock output"
        );
        _assertSimpleRewardZapperHasNoResidue();
    }

    function test_claimAndSwap_fail_zeroReceiverRollsBackRewardsAndSwap()
        public
    {
        uint256 expectedRewards = _seedClaimableRewards(user1);
        uint256 outputAmount = expectedRewards * 1e12;
        uint256 epochsBefore = rewardManager.epochsToClaim(user1);

        _prepareDAI(address(rewardSwapTarget), outputAmount);

        SwapperLib.Swap memory swapAction =
            _buildRewardSwap(expectedRewards, outputAmount);

        vm.prank(user1);
        vm.expectRevert(BaseZapper.BaseZapper__ExecutionError.selector);
        simpleRewardZapper.claimAndSwap(swapAction, address(0));

        assertEq(
            rewardManager.epochsToClaim(user1),
            epochsBefore,
            "failed reward swap should keep rewards claimable"
        );
        assertEq(
            dai.balanceOf(address(rewardSwapTarget)),
            outputAmount,
            "failed reward swap should roll back mock output"
        );
        assertEq(
            usdc.balanceOf(address(simpleRewardZapper)),
            0,
            "failed reward swap should not retain USDC"
        );
        assertEq(
            dai.balanceOf(address(simpleRewardZapper)),
            0,
            "failed reward swap should not retain DAI"
        );
    }

    function test_claimWithoutDelegateReverts() public {
        uint256 expectedRewards = _seedClaimableRewards(user1);
        vm.prank(user1);
        rewardManager.setDelegateApproval(address(simpleRewardZapper), false);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = expectedRewards;
        swapAction.outputToken = _USDC_ADDRESS;

        vm.prank(user1);
        vm.expectRevert();
        simpleRewardZapper.claimSwapAndDeposit(
            address(simpleCUSDC), swapAction, 0, false, user1
        );
    }

    function test_removedAuthorizedOutputTokenBlocksClaimAndSwapUntilReauthorized()
        public
    {
        uint256 expectedRewards = _seedClaimableRewards(user1);
        uint256 outputAmount = expectedRewards * 1e12;
        _prepareDAI(address(rewardSwapTarget), outputAmount);

        SwapperLib.Swap memory swapAction =
            _buildRewardSwap(expectedRewards, outputAmount);

        simpleRewardZapper.removeAuthorizedOutputToken(_DAI_ADDRESS);
        assertEq(
            simpleRewardZapper.authorizedOutputToken(_DAI_ADDRESS),
            1,
            "DAI should be marked removed"
        );

        vm.prank(user1);
        vm.expectRevert(
            SimpleRewardZapper.SimpleRewardZapper__UnknownOutputToken.selector
        );
        simpleRewardZapper.claimAndSwap(swapAction, user1);
        assertGt(
            rewardManager.epochsToClaim(user1),
            0,
            "blocked output should keep rewards claimable"
        );

        simpleRewardZapper.addAuthorizedOutputToken(_DAI_ADDRESS);
        assertEq(
            simpleRewardZapper.authorizedOutputToken(_DAI_ADDRESS),
            2,
            "DAI should be authorized again"
        );

        vm.prank(user1);
        uint256 received = simpleRewardZapper.claimAndSwap(swapAction, user1);

        assertEq(received, outputAmount, "claim swap returned output");
        assertEq(dai.balanceOf(user1), outputAmount, "caller DAI output");
        assertEq(rewardManager.epochsToClaim(user1), 0, "rewards claimed");
        _assertSimpleRewardZapperHasNoResidue();
    }

    function test_claimSwapAndRepay_fail_unlistedCTokenBeforeAssetLookup()
        public
    {
        uint256 expectedRewards = _seedClaimableRewards(user1);
        address fakeBorrowableCToken = address(0xBEEF);

        vm.mockCall(
            fakeBorrowableCToken,
            abi.encodeWithSelector(ICToken.marketManager.selector),
            abi.encode(address(marketManagerIsolated))
        );
        vm.mockCallRevert(
            fakeBorrowableCToken,
            abi.encodeWithSelector(ICToken.asset.selector),
            "asset called"
        );

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = expectedRewards;
        swapAction.outputToken = _DAI_ADDRESS;

        vm.prank(user1);
        vm.expectRevert(BaseZapper.BaseZapper__Unauthorized.selector);
        simpleRewardZapper.claimSwapAndRepay(
            swapAction, fakeBorrowableCToken, 1, user2
        );

        assertGt(
            rewardManager.epochsToClaim(user1),
            0,
            "unlisted cToken should not claim rewards"
        );
    }

    function test_claimRejectsMismatchedInputAmount() public {
        uint256 expectedRewards = _seedClaimableRewards(user1);
        uint256 epochsBefore = rewardManager.epochsToClaim(user1);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = expectedRewards + 1;
        swapAction.outputToken = _USDC_ADDRESS;

        vm.prank(user1);
        vm.expectRevert(
            SimpleRewardZapper.SimpleRewardZapper__InvalidInputAmount.selector
        );
        simpleRewardZapper.claimSwapAndDeposit(
            address(simpleCUSDC), swapAction, 0, false, user1
        );

        assertEq(
            rewardManager.epochsToClaim(user1),
            epochsBefore,
            "mismatched reward amount should keep rewards claimable"
        );
        _assertSimpleRewardZapperHasNoResidue();
    }

    function _seedClaimableRewards(address user)
        internal
        returns (uint256 expectedRewards)
    {
        uint256 lockAmount = 100e18;
        ClaimAction memory action;

        _prepareCVE(user, lockAmount);

        vm.startPrank(user);
        cve.approve(address(veCVE), lockAmount);
        veCVE.createLock(lockAmount, false, action, bytes(""), 0);
        rewardManager.setDelegateApproval(address(simpleRewardZapper), true);
        vm.stopPrank();

        deal(_USDC_ADDRESS, address(rewardManager), 1_000_000e6);
        vm.prank(address(messagingHub));
        rewardManager.recordEpochRewards(1e18);
        _skipEpochDuration(1);
        _refreshMockFeeds();

        expectedRewards = rewardManager.hypotheticalRewardsClaim(user);
        assertGt(expectedRewards, 0, "seeded reward amount");
    }

    function _openDaiDebt(address borrower, uint256 amount) internal {
        _prepareUSDC(borrower, 100e6);

        vm.startPrank(borrower);
        usdc.approve(address(simpleCUSDC), 100e6);
        simpleCUSDC.deposit(100e6, borrower);
        simpleCUSDC.postCollateral(100e6);
        borrowableCDAI.borrow(amount, borrower);
        vm.stopPrank();

        assertGt(borrowableCDAI.debtBalance(borrower), 0, "opened DAI debt");
    }

    function _buildRewardSwap(uint256 inputAmount, uint256 outputAmount)
        internal
        view
        returns (SwapperLib.Swap memory swapAction)
    {
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = inputAmount;
        swapAction.outputToken = _DAI_ADDRESS;
        swapAction.target = address(rewardSwapTarget);
        swapAction.slippage = 0.01e18;
        swapAction.call = abi.encodeWithSelector(
            TC019_MockRewardSwapTarget.swap.selector,
            _USDC_ADDRESS,
            _DAI_ADDRESS,
            inputAmount,
            outputAmount,
            address(simpleRewardZapper)
        );
    }

    function _assertSimpleRewardZapperHasNoResidue() internal view {
        assertEq(
            usdc.balanceOf(address(simpleRewardZapper)),
            0,
            "reward zapper USDC residue"
        );
        assertEq(
            dai.balanceOf(address(simpleRewardZapper)),
            0,
            "reward zapper DAI residue"
        );
    }
}
