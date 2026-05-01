// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { LendingOptimizerHarness } from "tests/market/optimizer/LendingOptimizerHarness.sol";
import { TestBaseLendingOptimizer } from "tests/market/optimizer/TestBaseLendingOptimizer.sol";

contract TestLendingOptimizerIdleDustMateriality is TestBaseLendingOptimizer {
    LendingOptimizerHarness internal harness;
    address internal depositor = makeAddr("idle dust depositor");

    function setUp() public override {
        super.setUp();

        address[] memory approvedCTokens = new address[](3);
        approvedCTokens[0] = cUSDC_WMON_MARKET;
        approvedCTokens[1] = cUSDC_WBTC_MARKET;
        approvedCTokens[2] = cUSDC_WETH_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](3);
        allocationCapsBps[0] = 10_000;
        allocationCapsBps[1] = 10_000;
        allocationCapsBps[2] = 10_000;

        harness = new LendingOptimizerHarness(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            1_000
        );

        deal(USDC_MONAD, address(this), 77777);
        IERC20(USDC_MONAD).approve(address(harness), 77777);
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );
        harness.initializeDeposits(cUSDC_WMON_MARKET);

        _depositToMarket(1_000_000e6, cUSDC_WMON_MARKET);
        _depositToMarket(1_000, cUSDC_WBTC_MARKET);
        _depositToMarket(1_000, cUSDC_WETH_MARKET);
    }

    function test_lendingOptimizer_idleDustFromSkippedZeroShareSlices_isBounded() public {
        uint256 depositAmount = 1e6;
        uint256[] memory perMarket = harness.exposed_calculateDepositProRata(depositAmount, false);
        uint256 skipped;
        for (uint256 i; i < perMarket.length; ++i) {
            if (
                perMarket[i] != 0 &&
                IBorrowableCToken(harness.approvedCTokensList(i)).convertToShares(perMarket[i]) == 0
            ) {
                skipped += perMarket[i];
            }
        }

        deal(USDC_MONAD, depositor, depositAmount);
        vm.startPrank(depositor);
        IERC20(USDC_MONAD).approve(address(harness), depositAmount);
        uint256 shares = harness.deposit(depositAmount, depositor);
        vm.stopPrank();

        uint256 idle = IERC20(USDC_MONAD).balanceOf(address(harness));

        assertGt(shares, 0, "deposit should still mint shares");
        assertEq(idle, skipped, "idle underlying should equal skipped zero-share slices");
        assertLe(idle, 2, "live-style dust setup should leave at most two USDC base units idle");
    }

    function test_lendingOptimizer_skimCanRecoverOnlyObservedIdleDust() public {
        uint256 depositAmount = 1e6;
        deal(USDC_MONAD, depositor, depositAmount);
        vm.startPrank(depositor);
        IERC20(USDC_MONAD).approve(address(harness), depositAmount);
        harness.deposit(depositAmount, depositor);
        vm.stopPrank();

        uint256 idle = IERC20(USDC_MONAD).balanceOf(address(harness));
        uint256 daoBefore = IERC20(USDC_MONAD).balanceOf(liveCentralRegistry.daoAddress());

        if (idle == 0) {
            vm.expectRevert();
            harness.skim();
            return;
        }

        harness.skim();

        assertEq(
            IERC20(USDC_MONAD).balanceOf(liveCentralRegistry.daoAddress()) - daoBefore,
            idle,
            "DAO skim should match observed idle dust"
        );
        assertEq(IERC20(USDC_MONAD).balanceOf(address(harness)), 0, "skim should clear idle dust");
    }

    function _depositToMarket(uint256 assets, address market) internal {
        deal(USDC_MONAD, address(this), assets);
        IERC20(USDC_MONAD).approve(address(harness), assets);
        harness.depositToMarket(assets, address(this), market);
    }
}
