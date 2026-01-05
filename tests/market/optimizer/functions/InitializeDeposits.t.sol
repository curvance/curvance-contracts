// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { TestBaseLendingOptimizer } from "../TestBaseLendingOptimizer.sol";
import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IERC165 } from "contracts/interfaces/IERC165.sol";
import { IPluginDelegable } from "contracts/interfaces/IPluginDelegable.sol";
import { ERC4626 } from "contracts/libraries/external/ERC4626.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { WAD, BPS } from "contracts/libraries/ConstantsLib.sol";

contract TestLendingOptimizerInitializeDeposits is TestBaseLendingOptimizer {

    LendingOptimizer optimizer;

    function setUp() public override {
        super.setUp();
    }

    function test_initializeDeposits_success() public {
        address[] memory approvedCTokens = new address[](1);
        approvedCTokens[0] = cUSDC_WMON_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](1);
        allocationCapsBps[0] = 10_000;

        optimizer = new LendingOptimizer(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            1_000
        );

        // Verify not initialized (totalSupply == 0)
        assertEq(optimizer.totalSupply(), 0);

        // Get initial assets amount (77777)
        uint256 initAssets = 77777;

        // Deal USDC to this contract and approve
        deal(USDC_MONAD, address(this), initAssets);
        IERC20(USDC_MONAD).approve(address(optimizer), initAssets);

        // Initialize
        optimizer.initializeDeposits(0);

        // Verify initialized (totalSupply > 0)
        assertGt(optimizer.totalSupply(), 0);

        // Verify dead shares minted to address(0)
        assertEq(optimizer.balanceOf(address(0)), initAssets);
        assertEq(optimizer.totalSupply(), initAssets);

        // Verify assets deposited to market
        assertGt(optimizer.totalAssets(), 0);
    }

    function test_initializeDeposits_fail_whenAlreadyInitialized() public {
        address[] memory approvedCTokens = new address[](1);
        approvedCTokens[0] = cUSDC_WMON_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](1);
        allocationCapsBps[0] = 10_000;

        optimizer = new LendingOptimizer(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            1_000
        );

        uint256 initAssets = 77777;
        deal(USDC_MONAD, address(this), initAssets * 2);
        IERC20(USDC_MONAD).approve(address(optimizer), initAssets * 2);

        // First initialization succeeds
        optimizer.initializeDeposits(0);

        // Second initialization fails
        vm.expectRevert(LendingOptimizer.LendingOptimizer__AlreadyInitialized.selector);
        optimizer.initializeDeposits(0);
    }

    function test_initializeDeposits_fail_whenInvalidMarket() public {
        address[] memory approvedCTokens = new address[](1);
        approvedCTokens[0] = cUSDC_WMON_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](1);
        allocationCapsBps[0] = 10_000;

        optimizer = new LendingOptimizer(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            1_000
        );

        uint256 initAssets = 77777;
        deal(USDC_MONAD, address(this), initAssets);
        IERC20(USDC_MONAD).approve(address(optimizer), initAssets);

        // Invalid market index
        vm.expectRevert(LendingOptimizer.LendingOptimizer__MarketNotApproved.selector);
        optimizer.initializeDeposits(1);
    }

    function test_deposit_fail_whenNotInitialized() public {
        address[] memory approvedCTokens = new address[](1);
        approvedCTokens[0] = cUSDC_WMON_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](1);
        allocationCapsBps[0] = 10_000;

        optimizer = new LendingOptimizer(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            1_000
        );

        uint256 depositAmount = 1000e6;
        deal(USDC_MONAD, address(this), depositAmount);
        IERC20(USDC_MONAD).approve(address(optimizer), depositAmount);

        // Deposit should fail before initialization
        vm.expectRevert(LendingOptimizer.LendingOptimizer__NotInitialized.selector);
        optimizer.deposit(depositAmount, address(this));
    }

    function test_mint_fail_whenNotInitialized() public {
        address[] memory approvedCTokens = new address[](1);
        approvedCTokens[0] = cUSDC_WMON_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](1);
        allocationCapsBps[0] = 10_000;

        optimizer = new LendingOptimizer(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            1_000
        );

        uint256 depositAmount = 1000e6;
        deal(USDC_MONAD, address(this), depositAmount);
        IERC20(USDC_MONAD).approve(address(optimizer), depositAmount);

        // Mint should fail before initialization
        vm.expectRevert(LendingOptimizer.LendingOptimizer__NotInitialized.selector);
        optimizer.mint(1000e6, address(this));
    }

}