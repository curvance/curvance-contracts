// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {
    TestBaseLendingOptimizer
} from "tests/market/optimizer/TestBaseLendingOptimizer.sol";
import {
    LendingOptimizer
} from "contracts/market/optimizer/LendingOptimizer.sol";
import {
    LendingOptimizerHarness
} from "tests/market/optimizer/LendingOptimizerHarness.sol";
import {IBorrowableCToken} from "contracts/interfaces/IBorrowableCToken.sol";
import {IERC20} from "contracts/interfaces/IERC20.sol";
import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";
import {OptimizerReader} from "contracts/views/OptimizerReader.sol";

contract TestLendingOptimizerMaxExitLiquidity is TestBaseLendingOptimizer {
    LendingOptimizerHarness internal harness;

    function setUp() public override {
        super.setUp();

        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(
                ICentralRegistry.hasMarketPermissions.selector, address(this)
            ),
            abi.encode(true)
        );
    }

    function test_lendingOptimizer_maxExitViews_recomputeCurrentLiquidityAfterMarketsBecomeIlliquid()
        public
    {
        _deployThreeMarketHarness();

        _depositToHarness(user1, 30_000e6);

        uint256 reportedMaxWithdraw = harness.maxWithdraw(user1);
        uint256 reportedMaxRedeem = harness.maxRedeem(user1);

        assertGt(
            reportedMaxWithdraw, 0, "precondition: maxWithdraw reports assets"
        );
        assertGt(
            reportedMaxRedeem, 0, "precondition: maxRedeem reports shares"
        );

        _mockAllMarketsIlliquid();

        assertEq(
            harness.maxWithdraw(user1),
            0,
            "maxWithdraw caps by current liquidity"
        );
        assertEq(
            harness.maxRedeem(user1), 0, "maxRedeem caps by current liquidity"
        );

        vm.startPrank(user1);
        vm.expectRevert();
        harness.withdraw(reportedMaxWithdraw, user1, user1);

        vm.expectRevert();
        harness.redeem(reportedMaxRedeem, user1, user1);
        vm.stopPrank();
    }

    function test_lendingOptimizer_maxRedeem_usesConservativeLiquidityShareCap()
        public
    {
        _deployThreeMarketHarness();

        _depositToHarness(user1, 30_000e6);

        uint256 redeemableShares = 2;
        assertGt(
            harness.balanceOf(user1),
            redeemableShares,
            "precondition: user needs enough shares"
        );

        harness.exposed_setTotalAssets((harness.totalSupply() * 5) / 3);

        uint256 availableAssets = harness.convertToAssets(redeemableShares);
        uint256 conservativeShares = harness.convertToShares(availableAssets);
        assertLt(
            conservativeShares,
            redeemableShares,
            "precondition: floor share quote should underreport"
        );
        assertGt(
            harness.convertToAssets(redeemableShares + 1),
            availableAssets,
            "precondition: next share should exceed available liquidity"
        );

        _mockAvailableLiquidity(availableAssets);

        assertEq(
            harness.maxRedeem(user1),
            conservativeShares,
            "maxRedeem should use conservative liquidity share cap"
        );
    }

    function test_lendingOptimizer_maxRedeem_zeroLiquidityAfterDrawdown()
        public
    {
        _deployThreeMarketHarness();

        _depositToHarness(user1, 30_000e6);

        harness.exposed_setTotalAssets(harness.totalSupply() / 2);
        assertGt(
            harness.convertToAssets(harness.balanceOf(user1)),
            0,
            "precondition: owner should still have nonzero asset value"
        );
        assertGt(
            harness.previewWithdraw(1),
            1,
            "precondition: one asset should require multiple shares"
        );

        _mockAvailableLiquidity(0);

        assertEq(
            harness.maxRedeem(user1),
            0,
            "maxRedeem should be zero when no market liquidity is available"
        );
    }

    function test_optimizerReader_redeemableReportsShareValueNotLiquidityCap()
        public
    {
        _deployThreeMarketHarness();

        _depositToHarness(user1, 30_000e6);
        _mockAllMarketsIlliquid();

        OptimizerReader reader = new OptimizerReader();
        address[] memory optimizers = new address[](1);
        optimizers[0] = address(harness);

        OptimizerReader.OptimizerUserData[] memory data =
            reader.getOptimizerUserData(optimizers, user1);
        uint256 shareValue = harness.convertToAssets(harness.balanceOf(user1));

        assertEq(data[0]._address, address(harness), "optimizer address");
        assertEq(
            data[0].shareBalance, harness.balanceOf(user1), "share balance"
        );
        assertEq(data[0].redeemable, shareValue, "estimated share value");
        assertEq(
            harness.maxWithdraw(user1), 0, "no current withdraw liquidity"
        );
        assertEq(harness.maxRedeem(user1), 0, "no current redeem liquidity");
        assertGt(
            data[0].redeemable,
            harness.maxWithdraw(user1),
            "reader value is not settlement capped"
        );
    }

    function test_lendingOptimizer_maxExitViews_skipZeroPositionMarketsThatRevertAssetsHeld()
        public
    {
        _deployThreeMarketHarness();

        _depositToHarness(user1, 30_000e6);

        _mockZeroPositionMarketThatRevertsAssetsHeld(cUSDC_WBTC_MARKET);
        _mockZeroPositionMarketThatRevertsAssetsHeld(cUSDC_WETH_MARKET);

        assertGt(
            harness.maxWithdraw(user1),
            0,
            "maxWithdraw should ignore zero-position markets"
        );
        assertGt(
            harness.maxRedeem(user1),
            0,
            "maxRedeem should ignore zero-position markets"
        );

        uint256 userBalanceBefore = IERC20(USDC_MONAD).balanceOf(user1);

        vm.prank(user1);
        harness.withdraw(1, user1, user1);

        assertEq(
            IERC20(USDC_MONAD).balanceOf(user1),
            userBalanceBefore + 1,
            "withdraw should ignore zero-position markets"
        );

        uint256 redeemShares = harness.previewWithdraw(1e6);
        uint256 redeemAssets = harness.previewRedeem(redeemShares);
        assertGt(redeemAssets, 0, "precondition: shares should redeem assets");

        userBalanceBefore = IERC20(USDC_MONAD).balanceOf(user1);

        vm.prank(user1);
        uint256 assets = harness.redeem(redeemShares, user1, user1);

        assertGt(assets, 0, "redeem should return nonzero assets");
        assertLe(
            assets, redeemAssets, "redeem should not exceed previewed assets"
        );
        assertEq(
            IERC20(USDC_MONAD).balanceOf(user1),
            userBalanceBefore + assets,
            "redeem should ignore zero-position markets"
        );
    }

    function _deployThreeMarketHarness() internal {
        address[] memory approvedCTokens = new address[](3);
        approvedCTokens[0] = cUSDC_WMON_MARKET;
        approvedCTokens[1] = cUSDC_WBTC_MARKET;
        approvedCTokens[2] = cUSDC_WETH_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](3);
        allocationCapsBps[0] = 6_000;
        allocationCapsBps[1] = 5_000;
        allocationCapsBps[2] = 2_000;

        harness = new LendingOptimizerHarness(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            0
        );

        deal(USDC_MONAD, address(this), 77777);
        IERC20(USDC_MONAD).approve(address(harness), 77777);
        harness.initializeDeposits(cUSDC_WMON_MARKET);
    }

    function _depositToHarness(address user, uint256 assets) internal {
        deal(USDC_MONAD, user, assets);
        vm.startPrank(user);
        IERC20(USDC_MONAD).approve(address(harness), assets);
        harness.deposit(assets, user);
        vm.stopPrank();
    }

    function _mockAllMarketsIlliquid() internal {
        _mockAvailableLiquidity(0);
    }

    function _mockAvailableLiquidity(uint256 assets) internal {
        vm.mockCall(
            cUSDC_WMON_MARKET,
            abi.encodeWithSelector(IBorrowableCToken.assetsHeld.selector),
            abi.encode(assets)
        );
        vm.mockCall(
            cUSDC_WBTC_MARKET,
            abi.encodeWithSelector(IBorrowableCToken.assetsHeld.selector),
            abi.encode(uint256(0))
        );
        vm.mockCall(
            cUSDC_WETH_MARKET,
            abi.encodeWithSelector(IBorrowableCToken.assetsHeld.selector),
            abi.encode(uint256(0))
        );
    }

    function _mockZeroPositionMarketThatRevertsAssetsHeld(address cToken)
        internal
    {
        vm.mockCall(
            cToken,
            abi.encodeWithSelector(
                IERC20.balanceOf.selector, address(harness)
            ),
            abi.encode(uint256(0))
        );
        vm.mockCallRevert(
            cToken,
            abi.encodeWithSelector(IBorrowableCToken.assetsHeld.selector),
            "assetsHeld called for zero-position market"
        );
    }
}
