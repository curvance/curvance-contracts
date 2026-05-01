// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { TestBaseLendingOptimizer } from "tests/market/optimizer/TestBaseLendingOptimizer.sol";

contract TestLendingOptimizerPreviewParity is TestBaseLendingOptimizer {
    address internal depositor = address(0x12012);

    function setUp() public override {
        super.setUp();
        _setUpThreeMarkets();
        _depositToAllMarkets(500_000e6);
    }

    function test_lendingOptimizer_previewMint_canUnderquoteActualAssets() public {
        uint256 shares = 100_000_000;
        uint256 previewedAssets = optimizer.previewMint(shares);

        deal(USDC_MONAD, depositor, previewedAssets + 10);
        vm.startPrank(depositor);
        IERC20(USDC_MONAD).approve(address(optimizer), previewedAssets + 10);
        uint256 actualAssets = optimizer.mint(shares, depositor);
        vm.stopPrank();

        assertGt(actualAssets, previewedAssets, "expected mint to require more assets than previewMint");
    }

    function test_lendingOptimizer_previewRedeem_canOverquoteActualAssets() public {
        uint256 depositAmount = 5_000_000e6;
        deal(USDC_MONAD, depositor, depositAmount);
        vm.startPrank(depositor);
        IERC20(USDC_MONAD).approve(address(optimizer), depositAmount);
        optimizer.deposit(depositAmount, depositor);

        uint256 shares = 200_000_000_000;
        uint256 previewedAssets = optimizer.previewRedeem(shares);
        uint256 actualAssets = optimizer.redeem(shares, depositor, depositor);
        vm.stopPrank();

        assertLt(actualAssets, previewedAssets, "expected redeem to return fewer assets than previewRedeem");
    }
}
