// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { TestBaseLendingOptimizer } from "./TestBaseLendingOptimizer.sol";
import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { WAD } from "contracts/libraries/ConstantsLib.sol";

/// @title Bad Debt Handling Analysis Tests
/// @notice Scrutinizes the roundingBuffer system for cToken rounding tolerance
/// @dev Tests edge cases and potential issues with the bad debt detection system
contract TestBadDebtAnalysis is TestBaseLendingOptimizer {

    function setUp() public override {
        super.setUp();
        _setUpThreeMarkets();
    }

    // =========================================================================
    // ISSUE 1: Buffer only applies DURING vesting, not after
    // =========================================================================

    /// @notice Demonstrates that losses after vesting are silently absorbed
    /// @dev When vesting ends and rawTa < ta, loss is absorbed with no threshold check
    function test_analysis_lossAfterVesting_silentlyAbsorbed() public {
        // Deposit
        deal(USDC_MONAD, address(this), 1_000_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 1_000_000e6);
        optimizer.deposit(1_000_000e6, address(this), cUSDC_WMON_MARKET);

        // Start vesting
        skip(1 days);
        optimizer.exchangeRateUpdated();

        uint256 totalAssetsDuringVesting = optimizer.totalAssets();

        // Skip past vesting
        skip(2 days);

        // At this point, if rawTa < totalAssets(), the loss is absorbed silently
        // in Step 3's else branch with NO threshold check

        // Trigger accrual
        optimizer.exchangeRateUpdated();

        uint256 totalAssetsAfterVesting = optimizer.totalAssets();

        // Log the difference (if any)
        emit log_named_uint("Total assets during vesting", totalAssetsDuringVesting);
        emit log_named_uint("Total assets after vesting", totalAssetsAfterVesting);

        // NOTE: In practice, this test shows normal behavior, but the CONCERN is:
        // If actual bad debt occurred exactly when vesting ends, it would be
        // silently absorbed in the else branch without any event or threshold.
    }

    // =========================================================================
    // ISSUE 2: Buffer is absolute (wei), not relative to vault size
    // =========================================================================

    /// @notice Shows the buffer doesn't scale with vault size
    /// @dev 1000 wei buffer on a $1B vault vs $100 vault has very different meaning
    function test_analysis_bufferScaling_smallVault() public {
        // Small vault: 100 USDC
        deal(USDC_MONAD, address(this), 100e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 100e6);
        optimizer.deposit(100e6, address(this), cUSDC_WMON_MARKET);

        uint256 totalAssets = optimizer.totalAssets();
        uint256 buffer = optimizer.roundingBuffer();

        // What percentage of the vault is the buffer?
        uint256 bufferPercentWad = (buffer * WAD) / totalAssets;

        emit log_named_uint("Small vault total assets", totalAssets);
        emit log_named_uint("Buffer (wei)", buffer);
        emit log_named_uint("Buffer as % of vault (WAD)", bufferPercentWad);

        // For 100 USDC (100e6 wei), buffer of 1000 wei = 0.001%
        // This is negligible - probably fine
    }

    function test_analysis_bufferScaling_largeVault() public {
        // Large vault: 1B USDC
        deal(USDC_MONAD, address(this), 1_000_000_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 1_000_000_000e6);
        optimizer.deposit(1_000_000_000e6, address(this), cUSDC_WMON_MARKET);

        uint256 totalAssets = optimizer.totalAssets();
        uint256 buffer = optimizer.roundingBuffer();

        // What percentage of the vault is the buffer?
        uint256 bufferPercentWad = (buffer * WAD) / totalAssets;

        emit log_named_uint("Large vault total assets", totalAssets);
        emit log_named_uint("Buffer (wei)", buffer);
        emit log_named_uint("Buffer as % of vault (WAD)", bufferPercentWad);

        // For 1B USDC (1e15 wei), buffer of 1000 wei = 0.0000000001%
        // This is extremely small - could trigger false positives with heavy rebalancing
    }

    // =========================================================================
    // ISSUE 3: Asymmetric handling during vs after vesting
    // =========================================================================

    /// @notice Compare behavior during vesting vs after vesting
    function test_analysis_asymmetricHandling() public {
        // Setup: Deposit and mock permissions
        deal(USDC_MONAD, address(this), 1_000_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 1_000_000e6);
        optimizer.deposit(1_000_000e6, address(this), cUSDC_WMON_MARKET);

        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasHarvestPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Start vesting
        skip(1 days);
        optimizer.exchangeRateUpdated();

        uint256 totalAssetsMidVest = optimizer.totalAssets();

        // DURING VESTING:
        // - If rawTa + buffer < totalAssets: BAD DEBT (triggers handling)
        // - If rawTa + buffer >= totalAssets: OK (return early)
        emit log_named_string("During vesting", "Buffer check applies");

        // Skip past vesting
        skip(2 days);

        // AFTER VESTING:
        // - If rawTa > totalAssets: NEW YIELD (start vesting)
        // - If rawTa <= totalAssets: SYNC (absorb loss silently, NO buffer check)
        emit log_named_string("After vesting", "NO buffer check - losses absorbed silently");

        optimizer.exchangeRateUpdated();
    }

    // =========================================================================
    // ISSUE 4: Max buffer might be too small for high-frequency rebalancing
    // =========================================================================

    /// @notice Tests if max buffer (10,000 wei) is sufficient for heavy rebalancing
    function test_analysis_maxBufferSufficiency() public {
        // Set max buffer
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasHarvestPermissions.selector, address(this)),
            abi.encode(true)
        );
        optimizer.setRoundingBuffer(10_000); // Max

        // Deposit
        deal(USDC_MONAD, address(this), 10_000_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 10_000_000e6);
        optimizer.deposit(10_000_000e6, address(this), cUSDC_WMON_MARKET);

        // Each rebalance can lose ~2 wei (deposit rounds down, withdraw rounds down)
        // With max buffer of 10,000 wei, we can do ~5,000 rebalances before hitting limit
        // This seems sufficient for normal operation

        // But what if someone does automated rebalancing every block?
        // 5000 rebalances / 12 second blocks = ~16 hours of continuous rebalancing
        // After that, any rebalance during vesting could trigger false bad debt

        emit log_named_uint("Max buffer (wei)", optimizer.roundingBuffer());
        emit log_named_uint("Max rebalances before limit", 5000);
        emit log_named_uint("Hours of continuous rebalancing (12s blocks)", 16);
    }

    // =========================================================================
    // EDGE CASE: What happens with zero buffer?
    // =========================================================================

    /// @notice Tests that setting buffer below minimum reverts, and minimum buffer behavior.
    function test_analysis_minimumBuffer() public {
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasHarvestPermissions.selector, address(this)),
            abi.encode(true)
        );

        // Setting below minimum should revert.
        vm.expectRevert(LendingOptimizer.LendingOptimizer__InvalidParameter.selector);
        optimizer.setRoundingBuffer(0);

        // Setting to minimum should succeed.
        optimizer.setRoundingBuffer(1000); // _MINIMUM_ROUNDING_BUFFER

        // Deposit
        deal(USDC_MONAD, address(this), 1_000_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 1_000_000e6);
        optimizer.deposit(1_000_000e6, address(this), cUSDC_WMON_MARKET);

        // Start vesting
        skip(1 days);
        optimizer.exchangeRateUpdated();

        // With minimum buffer, only losses > 1000 wei trigger bad debt handling.
        // This prevents a harvester from weaponizing 1-wei rounding losses
        // to cancel active vesting periods.

        emit log_named_uint("Buffer", optimizer.roundingBuffer());
        emit log_named_string("Mode", "Minimum - enforced floor prevents vesting denial");
    }

    // =========================================================================
    // ANALYSIS: When does cToken rounding actually occur?
    // =========================================================================

    /// @notice Documents when cToken rounding losses happen
    function test_analysis_whenRoundingOccurs() public {
        deal(USDC_MONAD, address(this), 1_000_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 1_000_000e6);

        // Deposit - may lose 1 wei due to assets → shares → trackedAssets rounding
        uint256 shares = optimizer.deposit(100_000e6, address(this), cUSDC_WMON_MARKET);

        // Withdraw - may lose 1 wei due to shares → assets rounding
        uint256 assetsOut = optimizer.redeem(shares, address(this), address(this));

        emit log_named_uint("Deposited", 100_000e6);
        emit log_named_uint("Withdrawn", assetsOut);
        emit log_named_int("Round-trip loss", int256(100_000e6) - int256(assetsOut));

        // Rounding losses occur:
        // 1. On deposit: assets → cToken shares → tracked assets (up to 1 wei loss)
        // 2. On withdraw: shares → cToken assets (up to 1 wei loss)
        // 3. On rebalance: withdraw from one market, deposit to another (up to 2 wei loss)
    }

    // =========================================================================
    // RECOMMENDATION TEST: What if we had percentage-based buffer?
    // =========================================================================

    /// @notice Conceptual test showing how percentage-based buffer would work
    function test_analysis_conceptualPercentageBuffer() public {
        deal(USDC_MONAD, address(this), 1_000_000e6);
        IERC20(USDC_MONAD).approve(address(optimizer), 1_000_000e6);
        optimizer.deposit(1_000_000e6, address(this), cUSDC_WMON_MARKET);

        uint256 totalAssets = optimizer.totalAssets();

        // Current: fixed buffer of 1000 wei
        uint256 fixedBuffer = optimizer.roundingBuffer();

        // Alternative: 0.0001% (1 BPS of 1 BPS) buffer
        uint256 percentageBuffer = totalAssets / 1_000_000; // 0.0001%

        // Hybrid: max of both
        uint256 hybridBuffer = fixedBuffer > percentageBuffer ? fixedBuffer : percentageBuffer;

        emit log_named_uint("Total assets", totalAssets);
        emit log_named_uint("Fixed buffer (current)", fixedBuffer);
        emit log_named_uint("Percentage buffer (0.0001%)", percentageBuffer);
        emit log_named_uint("Hybrid buffer (max of both)", hybridBuffer);

        // For 1M USDC:
        // Fixed: 1000 wei
        // Percentage: 1,000,000e6 / 1,000,000 = 1e6 = 1 USDC
        // Hybrid: 1 USDC

        // This might be too high for percentage approach
        // Need to tune the percentage carefully
    }

    // =========================================================================
    // SUMMARY: Key observations about the buffer system
    // =========================================================================

    /// @notice Summary of observations about the bad debt buffer system
    function test_analysis_summary() public pure {
        // OBSERVATIONS:
        //
        // 1. ASYMMETRIC HANDLING
        //    - During vesting: buffer check applies (rawTa + buffer < ta triggers bad debt)
        //    - After vesting: NO buffer check (losses silently absorbed)
        //    - CONCERN: Real bad debt at vesting end is treated same as rounding
        //
        // 2. ABSOLUTE VS RELATIVE BUFFER
        //    - Buffer is fixed wei amount (default 1000, max 10,000)
        //    - Doesn't scale with vault size
        //    - For large vaults: buffer is negligible (false positives possible)
        //    - For small vaults: buffer is reasonable
        //
        // 3. MAX BUFFER LIMITS
        //    - 10,000 wei max covers ~5,000 rebalance operations
        //    - Should be sufficient for normal operation
        //    - Could be problematic for very high-frequency rebalancing
        //
        // 4. SILENT LOSS ABSORPTION
        //    - Losses after vesting are absorbed with no event
        //    - No way to distinguish rounding loss from actual bad debt
        //
        // POTENTIAL IMPROVEMENTS:
        //
        // A. Add buffer check to Step 3 (after vesting) too
        //    - Emit event if loss exceeds buffer even after vesting
        //    - Still sync _totalAssets, but alert operators
        //
        // B. Consider hybrid buffer (max of fixed and percentage)
        //    - Scales better with vault size
        //    - More complex to reason about
        //
        // C. Track cumulative rounding losses
        //    - More precise but adds storage/gas overhead
        //
        // CURRENT SYSTEM VERDICT:
        // - Reasonable for normal operation
        // - Edge cases around vesting boundaries could be improved
        // - Consider emitting events for any loss > buffer, even after vesting
    }
}
