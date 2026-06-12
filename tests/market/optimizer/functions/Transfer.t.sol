// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { TestBaseLendingOptimizer } from "../TestBaseLendingOptimizer.sol";
import { LendingOptimizerHarness } from "../LendingOptimizerHarness.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract TestLendingOptimizerTransfer is TestBaseLendingOptimizer {

    uint256 constant BASE_RESERVE = 77777;
    uint256 constant DEPOSIT_AMOUNT = 100_000e6;

    function setUp() public override {
        super.setUp();
    }

    function _setUpOneMarketWithFee(uint256 feeBps) internal {
        address[] memory approvedCTokens = new address[](1);
        approvedCTokens[0] = cUSDC_WMON_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](1);
        allocationCapsBps[0] = 10_000;

        optimizer = new LendingOptimizerHarness(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            feeBps
        );

        deal(USDC_MONAD, address(this), BASE_RESERVE);
        IERC20(USDC_MONAD).approve(address(optimizer), BASE_RESERVE);

        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );
        optimizer.initializeDeposits(cUSDC_WMON_MARKET);
    }

    function _depositAs(address account, uint256 assets) internal returns (uint256 shares) {
        deal(USDC_MONAD, account, assets, true);

        vm.startPrank(account);
        IERC20(USDC_MONAD).approve(address(optimizer), assets);
        shares = optimizer.deposit(assets, account);
        vm.stopPrank();
    }

    function test_lendingOptimizer_transfer_success_accruesBeforeTransfer() public {
        _setUpOneMarketWithFee(0);

        uint256 shares = _depositAs(user1, DEPOSIT_AMOUNT);
        uint256 transferAmount = shares / 2;

        skip(2 days);
        uint256 totalAssetsBefore = optimizer.totalAssets();
        uint256 user1BalanceBefore = optimizer.balanceOf(user1);

        vm.prank(user1);
        bool success = optimizer.transfer(user2, transferAmount);

        assertTrue(success, "Transfer should succeed");
        assertEq(optimizer.balanceOf(user1), user1BalanceBefore - transferAmount, "Sender shares should decrease");
        assertEq(optimizer.balanceOf(user2), transferAmount, "Receiver should get shares");
        assertGt(optimizer.totalAssets(), totalAssetsBefore, "Transfer should accrue pending market yield");
    }

    function test_lendingOptimizer_transferFrom_success_accruesBeforeTransfer() public {
        _setUpOneMarketWithFee(0);

        uint256 shares = _depositAs(user1, DEPOSIT_AMOUNT);
        uint256 transferAmount = shares / 2;

        vm.prank(user1);
        optimizer.approve(user3, transferAmount);

        skip(2 days);
        uint256 totalAssetsBefore = optimizer.totalAssets();
        uint256 user1BalanceBefore = optimizer.balanceOf(user1);

        vm.prank(user3);
        bool success = optimizer.transferFrom(user1, user2, transferAmount);

        assertTrue(success, "TransferFrom should succeed");
        assertEq(optimizer.balanceOf(user1), user1BalanceBefore - transferAmount, "Owner shares should decrease");
        assertEq(optimizer.balanceOf(user2), transferAmount, "Receiver should get shares");
        assertEq(optimizer.allowance(user1, user3), 0, "Allowance should be spent");
        assertGt(optimizer.totalAssets(), totalAssetsBefore, "TransferFrom should accrue pending market yield");
    }

    function test_lendingOptimizer_transfer_success_chargesPerformanceFee() public {
        _setUpOneMarketWithFee(1_000);

        uint256 shares = _depositAs(user1, DEPOSIT_AMOUNT);
        uint256 transferAmount = shares / 2;
        address dao = liveCentralRegistry.daoAddress();

        skip(2 days);
        uint256 daoBalanceBefore = optimizer.balanceOf(dao);

        vm.prank(user1);
        optimizer.transfer(user2, transferAmount);

        assertGt(optimizer.balanceOf(dao), daoBalanceBefore, "Transfer should charge performance fees on yield");
    }
}
