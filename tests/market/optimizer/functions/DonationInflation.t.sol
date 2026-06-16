// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { TestBaseLendingOptimizer } from "tests/market/optimizer/TestBaseLendingOptimizer.sol";
import { LendingOptimizerHarness } from "tests/market/optimizer/LendingOptimizerHarness.sol";
import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";
import { OptimizerReader } from "contracts/views/OptimizerReader.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";
import { WAD } from "contracts/libraries/ConstantsLib.sol";

contract TestLendingOptimizerDonationInflation is TestBaseLendingOptimizer {
    LendingOptimizerHarness internal harness;
    address internal attacker = makeAddr("attacker");
    address internal victim = makeAddr("victim");

    function setUp() public override {
        super.setUp();

        address[] memory approvedCTokens = new address[](1);
        approvedCTokens[0] = cUSDC_WMON_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](1);
        allocationCapsBps[0] = 10_000;

        harness = new LendingOptimizerHarness(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            0
        );

        deal(USDC_MONAD, address(this), 77777);
        IERC20(USDC_MONAD).approve(address(harness), 77777);
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );
        harness.initializeDeposits(cUSDC_WMON_MARKET);
    }

    function test_lendingOptimizer_cTokenShareDonationInflation_isUnprofitableWithDeadShares() public {
        uint256 attackerDeposit = 1e6;
        uint256 victimDeposit = 1e6;
        uint256 cTokenDonationAssets = 77_777e6;

        deal(USDC_MONAD, attacker, attackerDeposit + cTokenDonationAssets);
        vm.startPrank(attacker);
        IERC20(USDC_MONAD).approve(address(harness), attackerDeposit);
        uint256 attackerShares = harness.deposit(attackerDeposit, attacker);

        IERC20(USDC_MONAD).approve(cUSDC_WMON_MARKET, cTokenDonationAssets);
        uint256 donatedCTokenShares = IBorrowableCToken(cUSDC_WMON_MARKET).deposit(
            cTokenDonationAssets,
            attacker
        );
        IERC20(cUSDC_WMON_MARKET).transfer(address(harness), donatedCTokenShares);
        vm.stopPrank();

        harness.accrueIfNeeded();

        uint256 victimPreview = harness.previewDeposit(victimDeposit);
        deal(USDC_MONAD, victim, victimDeposit);
        vm.startPrank(victim);
        IERC20(USDC_MONAD).approve(address(harness), victimDeposit);
        uint256 victimShares = harness.deposit(victimDeposit, victim);
        vm.stopPrank();

        vm.prank(attacker);
        uint256 attackerAssetsOut = harness.redeem(attackerShares, attacker, attacker);

        uint256 attackerCost = attackerDeposit + cTokenDonationAssets;
        assertLt(attackerAssetsOut, attackerCost, "dead shares should make donation inflation unprofitable");
        assertGt(victimShares, 0, "victim deposit should not round to zero");

        uint256 attackerLoss = attackerCost - attackerAssetsOut;
        uint256 victimRoundingLossAssets;
        if (victimPreview > victimShares) {
            victimRoundingLossAssets = FixedPointMathLib.fullMulDiv(
                victimPreview - victimShares,
                harness.totalAssets(),
                harness.totalSupply()
            );
        }
        assertGt(attackerLoss, victimRoundingLossAssets * 77_777, "attacker capital loss should dominate victim rounding");
    }

    function testFuzz_lendingOptimizer_cTokenShareDonationInflationDoesNotProfit(
        uint256 attackerDeposit,
        uint256 cTokenDonationAssets,
        uint256 victimDeposit
    ) public {
        attackerDeposit = bound(attackerDeposit, 1e6, 1_000_000e6);
        cTokenDonationAssets = bound(cTokenDonationAssets, 1e6, 100_000_000e6);
        victimDeposit = bound(victimDeposit, 1, 10_000_000e6);

        deal(USDC_MONAD, attacker, attackerDeposit + cTokenDonationAssets);
        vm.startPrank(attacker);
        IERC20(USDC_MONAD).approve(address(harness), attackerDeposit);
        uint256 attackerShares = harness.deposit(attackerDeposit, attacker);

        IERC20(USDC_MONAD).approve(cUSDC_WMON_MARKET, cTokenDonationAssets);
        uint256 donatedCTokenShares = IBorrowableCToken(cUSDC_WMON_MARKET).deposit(
            cTokenDonationAssets,
            attacker
        );
        IERC20(cUSDC_WMON_MARKET).transfer(address(harness), donatedCTokenShares);
        vm.stopPrank();

        harness.accrueIfNeeded();

        deal(USDC_MONAD, victim, victimDeposit);
        vm.startPrank(victim);
        IERC20(USDC_MONAD).approve(address(harness), victimDeposit);
        try harness.deposit(victimDeposit, victim) {}
        catch {
            vm.stopPrank();
            vm.prank(attacker);
            uint256 attackerAssetsOutOnRevert = harness.redeem(attackerShares, attacker, attacker);
            assertLe(
                attackerAssetsOutOnRevert,
                attackerDeposit + cTokenDonationAssets,
                "attacker should not profit if victim deposit reverts"
            );
            return;
        }
        vm.stopPrank();

        vm.prank(attacker);
        uint256 attackerAssetsOut = harness.redeem(attackerShares, attacker, attacker);

        assertLe(
            attackerAssetsOut,
            attackerDeposit + cTokenDonationAssets,
            "attacker should not profit from cToken-share donation inflation"
        );
    }

    function test_lendingOptimizer_cTokenShareDonationCanBeRebalancedBackUnderCaps() public {
        address[] memory approvedCTokens = new address[](2);
        approvedCTokens[0] = cUSDC_WMON_MARKET;
        approvedCTokens[1] = cUSDC_WBTC_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](2);
        allocationCapsBps[0] = 6_000;
        allocationCapsBps[1] = 10_000;

        harness = new LendingOptimizerHarness(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            0
        );

        deal(USDC_MONAD, address(this), 600_000e6 + 77777);
        IERC20(USDC_MONAD).approve(address(harness), 600_000e6 + 77777);
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasHarvestPermissions.selector, address(this)),
            abi.encode(true)
        );

        harness.initializeDeposits(cUSDC_WMON_MARKET);
        harness.depositToMarket(300_000e6, address(this), cUSDC_WMON_MARKET);
        harness.depositToMarket(300_000e6, address(this), cUSDC_WBTC_MARKET);

        uint256 donationAssets = 200_000e6;
        deal(USDC_MONAD, attacker, donationAssets);
        vm.startPrank(attacker);
        IERC20(USDC_MONAD).approve(cUSDC_WMON_MARKET, donationAssets);
        uint256 donatedCTokenShares = IBorrowableCToken(cUSDC_WMON_MARKET).deposit(
            donationAssets,
            attacker
        );
        IERC20(cUSDC_WMON_MARKET).transfer(address(harness), donatedCTokenShares);
        vm.stopPrank();

        harness.accrueIfNeeded();

        uint256 market0Assets = IBorrowableCToken(cUSDC_WMON_MARKET).convertToAssets(
            IBorrowableCToken(cUSDC_WMON_MARKET).balanceOf(address(harness))
        );
        uint256 preRebalanceAllocation = FixedPointMathLib.fullMulDiv(
            market0Assets,
            WAD,
            harness.totalAssets()
        );

        assertGt(
            preRebalanceAllocation,
            harness.allocationCaps(cUSDC_WMON_MARKET),
            "donation should push market above cap"
        );

        OptimizerReader reader = new OptimizerReader(
            ICentralRegistry(address(liveCentralRegistry)),
            0
        );
        (
            LendingOptimizer.ReallocationAction[] memory actions,
            LendingOptimizer.AllocationBound[] memory bounds
        ) = reader.optimalRebalance(address(harness), 500);

        harness.rebalance(actions, bounds);

        market0Assets = IBorrowableCToken(cUSDC_WMON_MARKET).convertToAssets(
            IBorrowableCToken(cUSDC_WMON_MARKET).balanceOf(address(harness))
        );
        uint256 postRebalanceAllocation = FixedPointMathLib.fullMulDiv(
            market0Assets,
            WAD,
            harness.totalAssets()
        );

        assertLe(
            postRebalanceAllocation,
            harness.allocationCaps(cUSDC_WMON_MARKET),
            "keeper should be able to repair donation-driven cap drift"
        );
    }
}
