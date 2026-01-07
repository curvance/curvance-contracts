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

    function setUp() public override {
        super.setUp();
    }

    function test_lendingOptimizer_initializeDeposits_success() public {
        address[] memory approvedCTokens = new address[](1);
        approvedCTokens[0] = cUSDC_WMON_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](1);
        allocationCapsBps[0] = 10_000;

        optimizer = new LendingOptimizer(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            1_000,
            1 days
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

    function test_lendingOptimizer_initializeDeposits_fail_whenAlreadyInitialized() public {
        address[] memory approvedCTokens = new address[](1);
        approvedCTokens[0] = cUSDC_WMON_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](1);
        allocationCapsBps[0] = 10_000;

        optimizer = new LendingOptimizer(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            1_000,
            1 days
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

    function test_lendingOptimizer_initializeDeposits_fail_whenInvalidMarket() public {
        address[] memory approvedCTokens = new address[](1);
        approvedCTokens[0] = cUSDC_WMON_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](1);
        allocationCapsBps[0] = 10_000;

        optimizer = new LendingOptimizer(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            1_000,
            1 days
        );

        uint256 initAssets = 77777;
        deal(USDC_MONAD, address(this), initAssets);
        IERC20(USDC_MONAD).approve(address(optimizer), initAssets);

        // Invalid market index
        vm.expectRevert(LendingOptimizer.LendingOptimizer__MarketNotApproved.selector);
        optimizer.initializeDeposits(1);
    }

    function test_lendingOptimizer_deposit_fail_whenNotInitialized() public {
        address[] memory approvedCTokens = new address[](1);
        approvedCTokens[0] = cUSDC_WMON_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](1);
        allocationCapsBps[0] = 10_000;

        optimizer = new LendingOptimizer(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            1_000,
            1 days
        );

        uint256 depositAmount = 1000e6;
        deal(USDC_MONAD, address(this), depositAmount);
        IERC20(USDC_MONAD).approve(address(optimizer), depositAmount);

        // Deposit should fail before initialization
        vm.expectRevert(LendingOptimizer.LendingOptimizer__NotInitialized.selector);
        optimizer.deposit(depositAmount, address(this));
    }

    function test_lendingOptimizer_mint_fail_whenNotInitialized() public {
        address[] memory approvedCTokens = new address[](1);
        approvedCTokens[0] = cUSDC_WMON_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](1);
        allocationCapsBps[0] = 10_000;

        optimizer = new LendingOptimizer(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            1_000,
            1 days
        );

        uint256 depositAmount = 1000e6;
        deal(USDC_MONAD, address(this), depositAmount);
        IERC20(USDC_MONAD).approve(address(optimizer), depositAmount);

        // Mint should fail before initialization
        vm.expectRevert(LendingOptimizer.LendingOptimizer__NotInitialized.selector);
        optimizer.mint(1000e6, address(this));
    }

    function test_lendingOptimizer_initializeDeposits_withMultipleMarkets_targetFirst() public {
        address[] memory approvedCTokens = new address[](3);
        approvedCTokens[0] = cUSDC_WMON_MARKET;
        approvedCTokens[1] = cUSDC_WBTC_MARKET;
        approvedCTokens[2] = cUSDC_WETH_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](3);
        allocationCapsBps[0] = 4_000;
        allocationCapsBps[1] = 3_000;
        allocationCapsBps[2] = 3_000;

        optimizer = new LendingOptimizer(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            1_000,
            1 days
        );

        uint256 initAssets = 77777;
        deal(USDC_MONAD, address(this), initAssets);
        IERC20(USDC_MONAD).approve(address(optimizer), initAssets);

        // Initialize with first market (index 0)
        optimizer.initializeDeposits(0);

        assertEq(optimizer.totalSupply(), initAssets);
        assertEq(optimizer.balanceOf(address(0)), initAssets);
    }

    function test_lendingOptimizer_initializeDeposits_withMultipleMarkets_targetSecond() public {
        address[] memory approvedCTokens = new address[](3);
        approvedCTokens[0] = cUSDC_WMON_MARKET;
        approvedCTokens[1] = cUSDC_WBTC_MARKET;
        approvedCTokens[2] = cUSDC_WETH_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](3);
        allocationCapsBps[0] = 4_000;
        allocationCapsBps[1] = 3_000;
        allocationCapsBps[2] = 3_000;

        optimizer = new LendingOptimizer(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            1_000,
            1 days
        );

        uint256 initAssets = 77777;
        deal(USDC_MONAD, address(this), initAssets);
        IERC20(USDC_MONAD).approve(address(optimizer), initAssets);

        // Initialize with second market (index 1)
        optimizer.initializeDeposits(1);

        assertEq(optimizer.totalSupply(), initAssets);
        assertEq(optimizer.balanceOf(address(0)), initAssets);
    }

    function test_lendingOptimizer_initializeDeposits_withMultipleMarkets_targetLast() public {
        address[] memory approvedCTokens = new address[](3);
        approvedCTokens[0] = cUSDC_WMON_MARKET;
        approvedCTokens[1] = cUSDC_WBTC_MARKET;
        approvedCTokens[2] = cUSDC_WETH_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](3);
        allocationCapsBps[0] = 4_000;
        allocationCapsBps[1] = 3_000;
        allocationCapsBps[2] = 3_000;

        optimizer = new LendingOptimizer(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            1_000,
            1 days
        );

        uint256 initAssets = 77777;
        deal(USDC_MONAD, address(this), initAssets);
        IERC20(USDC_MONAD).approve(address(optimizer), initAssets);

        // Initialize with last market (index 2)
        optimizer.initializeDeposits(2);

        assertEq(optimizer.totalSupply(), initAssets);
        assertEq(optimizer.balanceOf(address(0)), initAssets);
    }

    event Deposit(address indexed caller, address indexed owner, uint256 assets, uint256 shares);

    function test_lendingOptimizer_initializeDeposits_emitsDepositEvent() public {
        address[] memory approvedCTokens = new address[](1);
        approvedCTokens[0] = cUSDC_WMON_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](1);
        allocationCapsBps[0] = 10_000;

        optimizer = new LendingOptimizer(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            1_000,
            1 days
        );

        uint256 initAssets = 77777;
        deal(USDC_MONAD, address(this), initAssets);
        IERC20(USDC_MONAD).approve(address(optimizer), initAssets);

        // Expect the Deposit event with correct parameters
        vm.expectEmit(true, true, true, true);
        emit Deposit(address(this), address(0), initAssets, initAssets);

        optimizer.initializeDeposits(0);
    }

    function test_lendingOptimizer_initializeDeposits_fail_whenOutOfBoundsIndex() public {
        address[] memory approvedCTokens = new address[](1);
        approvedCTokens[0] = cUSDC_WMON_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](1);
        allocationCapsBps[0] = 10_000;

        optimizer = new LendingOptimizer(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            1_000,
            1 days
        );

        uint256 initAssets = 77777;
        deal(USDC_MONAD, address(this), initAssets);
        IERC20(USDC_MONAD).approve(address(optimizer), initAssets);

        // Out of bounds index should revert with array out of bounds (panic)
        vm.expectRevert();
        optimizer.initializeDeposits(99);
    }

    function test_lendingOptimizer_initializeDeposits_fail_whenInsufficientBalance() public {
        address[] memory approvedCTokens = new address[](1);
        approvedCTokens[0] = cUSDC_WMON_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](1);
        allocationCapsBps[0] = 10_000;

        optimizer = new LendingOptimizer(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            1_000,
            1 days
        );

        // Only deal half the required amount
        uint256 initAssets = 77777;
        deal(USDC_MONAD, address(this), initAssets / 2);
        IERC20(USDC_MONAD).approve(address(optimizer), initAssets);

        // Should revert due to insufficient balance
        vm.expectRevert();
        optimizer.initializeDeposits(0);
    }

    function test_lendingOptimizer_initializeDeposits_fail_whenInsufficientAllowance() public {
        address[] memory approvedCTokens = new address[](1);
        approvedCTokens[0] = cUSDC_WMON_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](1);
        allocationCapsBps[0] = 10_000;

        optimizer = new LendingOptimizer(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            1_000,
            1 days
        );

        uint256 initAssets = 77777;
        deal(USDC_MONAD, address(this), initAssets);
        // Only approve half the required amount
        IERC20(USDC_MONAD).approve(address(optimizer), initAssets / 2);

        // Should revert due to insufficient allowance
        vm.expectRevert();
        optimizer.initializeDeposits(0);
    }

    function test_lendingOptimizer_initializeDeposits_fail_whenNoAllowance() public {
        address[] memory approvedCTokens = new address[](1);
        approvedCTokens[0] = cUSDC_WMON_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](1);
        allocationCapsBps[0] = 10_000;

        optimizer = new LendingOptimizer(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            1_000,
            1 days
        );

        uint256 initAssets = 77777;
        deal(USDC_MONAD, address(this), initAssets);
        // No approval given

        // Should revert due to no allowance
        vm.expectRevert();
        optimizer.initializeDeposits(0);
    }

    function test_lendingOptimizer_initializeDeposits_anyoneCanCall() public {
        address[] memory approvedCTokens = new address[](1);
        approvedCTokens[0] = cUSDC_WMON_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](1);
        allocationCapsBps[0] = 10_000;

        optimizer = new LendingOptimizer(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            1_000,
            1 days
        );

        uint256 initAssets = 77777;
        address randomUser = makeAddr("randomUser");

        deal(USDC_MONAD, randomUser, initAssets);

        vm.startPrank(randomUser);
        IERC20(USDC_MONAD).approve(address(optimizer), initAssets);
        optimizer.initializeDeposits(0);
        vm.stopPrank();

        // Verify initialization succeeded
        assertEq(optimizer.totalSupply(), initAssets);
        assertEq(optimizer.balanceOf(address(0)), initAssets);
    }

    function test_lendingOptimizer_initializeDeposits_transfersExactAmount() public {
        address[] memory approvedCTokens = new address[](1);
        approvedCTokens[0] = cUSDC_WMON_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](1);
        allocationCapsBps[0] = 10_000;

        optimizer = new LendingOptimizer(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            1_000,
            1 days
        );

        uint256 initAssets = 77777;
        uint256 extraBalance = 1000e6;
        deal(USDC_MONAD, address(this), initAssets + extraBalance);
        IERC20(USDC_MONAD).approve(address(optimizer), initAssets);

        uint256 balanceBefore = IERC20(USDC_MONAD).balanceOf(address(this));

        optimizer.initializeDeposits(0);

        uint256 balanceAfter = IERC20(USDC_MONAD).balanceOf(address(this));

        // Verify exactly 77777 was transferred
        assertEq(balanceBefore - balanceAfter, initAssets);
        // Verify remaining balance is intact
        assertEq(balanceAfter, extraBalance);
    }

    function test_lendingOptimizer_initializeDeposits_depositsToCorrectMarket() public {
        address[] memory approvedCTokens = new address[](3);
        approvedCTokens[0] = cUSDC_WMON_MARKET;
        approvedCTokens[1] = cUSDC_WBTC_MARKET;
        approvedCTokens[2] = cUSDC_WETH_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](3);
        allocationCapsBps[0] = 4_000;
        allocationCapsBps[1] = 3_000;
        allocationCapsBps[2] = 3_000;

        optimizer = new LendingOptimizer(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            1_000,
            1 days
        );

        uint256 initAssets = 77777;
        deal(USDC_MONAD, address(this), initAssets);
        IERC20(USDC_MONAD).approve(address(optimizer), initAssets);

        // Initialize with second market (index 1)
        optimizer.initializeDeposits(1);

        // Verify cToken balance is only in the targeted market
        assertGt(IERC20(cUSDC_WBTC_MARKET).balanceOf(address(optimizer)), 0);
        assertEq(IERC20(cUSDC_WMON_MARKET).balanceOf(address(optimizer)), 0);
        assertEq(IERC20(cUSDC_WETH_MARKET).balanceOf(address(optimizer)), 0);
    }

    function test_lendingOptimizer_initializeDeposits_setsCorrectExchangeRate() public {
        address[] memory approvedCTokens = new address[](1);
        approvedCTokens[0] = cUSDC_WMON_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](1);
        allocationCapsBps[0] = 10_000;

        optimizer = new LendingOptimizer(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            1_000,
            1 days
        );

        uint256 initAssets = 77777;
        deal(USDC_MONAD, address(this), initAssets);
        IERC20(USDC_MONAD).approve(address(optimizer), initAssets);

        optimizer.initializeDeposits(0);

        // Exchange rate should be approximately 1:1 (WAD) after initialization
        // May vary slightly due to market exchange rates
        uint256 exchangeRate = optimizer.exchangeRate();
        assertGt(exchangeRate, 0);
    }

    function test_lendingOptimizer_initializeDeposits_exchangeRateHighWatermarkIsWAD() public {
        address[] memory approvedCTokens = new address[](1);
        approvedCTokens[0] = cUSDC_WMON_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](1);
        allocationCapsBps[0] = 10_000;

        optimizer = new LendingOptimizer(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            1_000,
            1 days
        );

        // Verify high watermark is WAD before initialization
        assertEq(optimizer.exchangeRateHighWatermark(), WAD);

        uint256 initAssets = 77777;
        deal(USDC_MONAD, address(this), initAssets);
        IERC20(USDC_MONAD).approve(address(optimizer), initAssets);

        optimizer.initializeDeposits(0);

        // High watermark should still be WAD after initialization
        // (no performance fee accrual on first deposit)
        assertEq(optimizer.exchangeRateHighWatermark(), WAD);
    }

    function testFuzz_lendingOptimizer_initializeDeposits_validMarketIndex(uint256 targetMarket) public {
        address[] memory approvedCTokens = new address[](3);
        approvedCTokens[0] = cUSDC_WMON_MARKET;
        approvedCTokens[1] = cUSDC_WBTC_MARKET;
        approvedCTokens[2] = cUSDC_WETH_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](3);
        allocationCapsBps[0] = 4_000;
        allocationCapsBps[1] = 3_000;
        allocationCapsBps[2] = 3_000;

        optimizer = new LendingOptimizer(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            1_000,
            1 days
        );

        uint256 initAssets = 77777;
        deal(USDC_MONAD, address(this), initAssets);
        IERC20(USDC_MONAD).approve(address(optimizer), initAssets);

        // Bound to valid market indices
        targetMarket = bound(targetMarket, 0, 2);

        optimizer.initializeDeposits(targetMarket);

        // Verify initialization succeeded
        assertEq(optimizer.totalSupply(), initAssets);
        assertEq(optimizer.balanceOf(address(0)), initAssets);
    }
    
    function test_lendingOptimizer_targetedDeposit_fail_whenNotInitialized() public {
        address[] memory approvedCTokens = new address[](1);
        approvedCTokens[0] = cUSDC_WMON_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](1);
        allocationCapsBps[0] = 10_000;

        optimizer = new LendingOptimizer(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            1_000,
            1 days
        );

        uint256 depositAmount = 1000e6;
        deal(USDC_MONAD, address(this), depositAmount);
        IERC20(USDC_MONAD).approve(address(optimizer), depositAmount);

        // Targeted deposit should fail before initialization
        vm.expectRevert(LendingOptimizer.LendingOptimizer__NotInitialized.selector);
        optimizer.deposit(depositAmount, address(this), cUSDC_WMON_MARKET);
    }

    function test_lendingOptimizer_targetedMint_fail_whenNotInitialized() public {
        address[] memory approvedCTokens = new address[](1);
        approvedCTokens[0] = cUSDC_WMON_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](1);
        allocationCapsBps[0] = 10_000;

        optimizer = new LendingOptimizer(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            1_000,
            1 days
        );

        uint256 depositAmount = 1000e6;
        deal(USDC_MONAD, address(this), depositAmount);
        IERC20(USDC_MONAD).approve(address(optimizer), depositAmount);

        // Targeted mint should fail before initialization
        vm.expectRevert(LendingOptimizer.LendingOptimizer__NotInitialized.selector);
        optimizer.mint(1000e6, address(this), cUSDC_WMON_MARKET);
    }

}