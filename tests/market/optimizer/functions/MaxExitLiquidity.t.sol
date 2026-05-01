// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { TestBaseLendingOptimizer } from "tests/market/optimizer/TestBaseLendingOptimizer.sol";
import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";
import { LendingOptimizerHarness } from "tests/market/optimizer/LendingOptimizerHarness.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract TestLendingOptimizerMaxExitLiquidity is TestBaseLendingOptimizer {
    LendingOptimizerHarness internal harness;

    function setUp() public override {
        super.setUp();

        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );
    }

    function test_lendingOptimizer_maxExitViews_canOverreportCurrentMarketLiquidity() public {
        _deployThreeMarketHarness();

        _depositToHarness(user1, 30_000e6);

        uint256 reportedMaxWithdraw = harness.maxWithdraw(user1);
        uint256 reportedMaxRedeem = harness.maxRedeem(user1);

        assertGt(reportedMaxWithdraw, 0, "precondition: maxWithdraw reports assets");
        assertGt(reportedMaxRedeem, 0, "precondition: maxRedeem reports shares");

        _mockAllMarketsIlliquid();

        assertEq(harness.maxWithdraw(user1), reportedMaxWithdraw, "maxWithdraw is share-value based");
        assertEq(harness.maxRedeem(user1), reportedMaxRedeem, "maxRedeem is share-balance based");

        vm.startPrank(user1);
        vm.expectRevert();
        harness.withdraw(reportedMaxWithdraw, user1, user1);

        vm.expectRevert();
        harness.redeem(reportedMaxRedeem, user1, user1);
        vm.stopPrank();
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
        vm.mockCall(
            cUSDC_WMON_MARKET,
            abi.encodeWithSelector(IBorrowableCToken.assetsHeld.selector),
            abi.encode(uint256(0))
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
}
