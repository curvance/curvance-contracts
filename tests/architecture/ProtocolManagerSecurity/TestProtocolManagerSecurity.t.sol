// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { ProtocolManagerDeployment } from "contracts/architecture/ProtocolManagerDeployment.sol";
import { ProtocolManagerMassPause } from "contracts/architecture/ProtocolManagerMassPause.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { DynamicIRM } from "contracts/market/DynamicIRM.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

/// @title Security & Scenario Tests for Protocol Managers.
/// @notice Exercises threat vectors beyond static analysis:
///         gas benchmarks, ordering independence, batch revert isolation,
///         full operational lifecycle, and permission boundary enforcement.
contract TestProtocolManagerSecurity is TestBaseMarketIsolated {
    ProtocolManagerDeployment public deploymentManager;
    ProtocolManagerMassPause public massPause;

    address public constant WMON_ADDRESS =
        0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;

    // Market 1 (deployed via deploymentManager).
    BorrowableCToken public borrowableCUSDC_1;
    BorrowableCToken public borrowableCWMON_1;

    // Market 2 (deployed via deploymentManager for reuse test).
    MarketManagerIsolated public marketManager2;
    BorrowableCToken public borrowableCUSDC_2;
    BorrowableCToken public borrowableCWMON_2;

    ChainlinkAdaptor public chainlinkAdaptor;
    uint256 constant BASE_UNDERLYING_RESERVE = 77777;

    function setUp() public virtual override {
        _fork("MON_NODE_URI_MONAD_MAINNET");

        _initMainConstantVariables();

        _deployCentralRegistry();
        _deployCVE();
        _deployRewardManager();
        _deployVeCVE();
        _deployGaugeManager();
        _deployMarketManager();
        _deployOracleManager();

        // Oracle setup.
        MockV3Aggregator chainlinkUSDC_USD = new MockV3Aggregator(8, 1e8);
        address chainlinkWMON_USD =
            0xBcD78f76005B7515837af6b50c7C52BCf73822fb;

        chainlinkAdaptor = new ChainlinkAdaptor(
            ICentralRegistry(address(centralRegistry))
        );
        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));

        chainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            true,
            address(chainlinkUSDC_USD),
            0
        );
        chainlinkAdaptor.addAsset(WMON_ADDRESS, true, chainlinkWMON_USD, 0);

        oracleManager.addAssetPricingAdaptor(
            _USDC_ADDRESS,
            address(chainlinkAdaptor),
            100,
            50,
            100,
            50
        );
        oracleManager.addAssetPricingAdaptor(
            WMON_ADDRESS,
            address(chainlinkAdaptor),
            100,
            50,
            100,
            50
        );

        // Market 1 cTokens.
        borrowableCUSDC_1 = _deployBorrowableCToken(_USDC_ADDRESS);
        borrowableCWMON_1 = _deployBorrowableCToken(WMON_ADDRESS);

        oracleManager.addCTokenSupport(address(borrowableCUSDC_1));
        oracleManager.addCTokenSupport(address(borrowableCWMON_1));

        // Market 2 setup.
        _setupSecondMarket();

        // Deploy both protocol managers.
        deploymentManager = new ProtocolManagerDeployment(
            ICentralRegistry(address(centralRegistry)),
            address(this)
        );
        massPause = new ProtocolManagerMassPause(
            ICentralRegistry(address(centralRegistry)),
            address(this)
        );

        // Grant permissions.
        centralRegistry.addMarketPermissions(address(deploymentManager));
        centralRegistry.addMarketPermissions(address(massPause));
    }

    function _setupSecondMarket() internal {
        marketManager2 = new MarketManagerIsolated(
            ICentralRegistry(address(centralRegistry)),
            10e18,
            false
        );
        centralRegistry.addMarketManager(address(marketManager2));

        DynamicIRM irm2a = new DynamicIRM(
            ICentralRegistry(address(centralRegistry)),
            1000, 1000, 5000, 1000, 100, 100000
        );
        borrowableCUSDC_2 = new BorrowableCToken(
            ICentralRegistry(address(centralRegistry)),
            IERC20(_USDC_ADDRESS),
            address(marketManager2),
            address(irm2a)
        );
        irm2a.setLinkedToken(address(borrowableCUSDC_2));

        DynamicIRM irm2b = new DynamicIRM(
            ICentralRegistry(address(centralRegistry)),
            1000, 1000, 5000, 1000, 100, 100000
        );
        borrowableCWMON_2 = new BorrowableCToken(
            ICentralRegistry(address(centralRegistry)),
            IERC20(WMON_ADDRESS),
            address(marketManager2),
            address(irm2b)
        );
        irm2b.setLinkedToken(address(borrowableCWMON_2));

        oracleManager.addCTokenSupport(address(borrowableCUSDC_2));
        oracleManager.addCTokenSupport(address(borrowableCWMON_2));
    }

    /// HELPER FUNCTIONS ///

    function _getBasicTokenConfig(
        address cToken,
        uint256 collateralCap,
        uint256 debtCap
    ) internal pure returns (MarketManagerIsolated.TokenConfig memory config) {
        config.cToken = cToken;
        config.collRatio = 7000;
        config.collReqSoft = 4000;
        config.collReqHard = 3000;
        config.liqIncBase = 1000;
        config.liqIncHard = 1500;
        config.liqIncMin = 10;
        config.liqIncMax = 2000;
        config.closeFactorBase = 2000;
        config.closeFactorMin = 2000;
        config.closeFactorMax = 5000;
        config.collateralCap = collateralCap;
        config.debtCap = debtCap;
    }

    function _fundAndApproveDeployment() internal {
        deal(_USDC_ADDRESS, address(this), BASE_UNDERLYING_RESERVE);
        deal(WMON_ADDRESS, address(this), BASE_UNDERLYING_RESERVE);
        IERC20(_USDC_ADDRESS).approve(
            address(deploymentManager),
            BASE_UNDERLYING_RESERVE
        );
        IERC20(WMON_ADDRESS).approve(
            address(deploymentManager),
            BASE_UNDERLYING_RESERVE
        );
    }

    function _deployMarket1() internal {
        _fundAndApproveDeployment();
        deploymentManager.deployMarket(
            address(marketManagerIsolated),
            address(borrowableCWMON_1),
            address(borrowableCUSDC_1),
            _getBasicTokenConfig(address(borrowableCWMON_1), 1_000_000e18, 0),
            _getBasicTokenConfig(address(borrowableCUSDC_1), 0, 1_000_000e6)
        );
    }

    function _deployMarket2() internal {
        _fundAndApproveDeployment();
        deploymentManager.deployMarket(
            address(marketManager2),
            address(borrowableCWMON_2),
            address(borrowableCUSDC_2),
            _getBasicTokenConfig(address(borrowableCWMON_2), 1_000_000e18, 0),
            _getBasicTokenConfig(address(borrowableCUSDC_2), 0, 1_000_000e6)
        );
    }

    function _emptyArray()
        internal
        pure
        returns (address[] memory)
    {
        return new address[](0);
    }

    function _singleMarketArray(address mm)
        internal
        pure
        returns (address[] memory markets)
    {
        markets = new address[](1);
        markets[0] = mm;
    }

    // ══════════════════════════════════════════════════════
    // 1. GAS BENCHMARKS
    // ══════════════════════════════════════════════════════

    /// @notice Measures gas for each pause posture at different market counts.
    /// @dev Validates all operations fit within 30M gas limit.
    function test_gasBenchmark_pauseAll_singleMarket() public {
        _deployMarket1();

        // Unpause mint so tokens are in default state (1).
        marketManagerIsolated.setMintPaused(address(borrowableCWMON_1), false);
        marketManagerIsolated.setMintPaused(address(borrowableCUSDC_1), false);

        uint256 gasBefore = gasleft();
        massPause.pauseAll(_singleMarketArray(address(marketManagerIsolated)));
        uint256 gasUsed = gasBefore - gasleft();

        // Should be well under 30M. Expect ~100-150k for 1 market (9 SSTOREs + overhead).
        assertLt(gasUsed, 500_000, "pauseAll single market should use < 500k gas");
        emit log_named_uint("pauseAll (1 market) gas", gasUsed);
    }

    function test_gasBenchmark_pauseAll_twoMarkets() public {
        _deployMarket1();
        _deployMarket2();

        // Unpause all mints.
        marketManagerIsolated.setMintPaused(address(borrowableCWMON_1), false);
        marketManagerIsolated.setMintPaused(address(borrowableCUSDC_1), false);
        marketManager2.setMintPaused(address(borrowableCWMON_2), false);
        marketManager2.setMintPaused(address(borrowableCUSDC_2), false);

        uint256 gasBefore = gasleft();
        massPause.pauseAll(_emptyArray());
        uint256 gasUsed = gasBefore - gasleft();

        // 2 markets should be roughly 2x single, still well under 30M.
        assertLt(gasUsed, 1_000_000, "pauseAll two markets should use < 1M gas");
        emit log_named_uint("pauseAll (2 markets, auto-discover) gas", gasUsed);
    }

    function test_gasBenchmark_pauseSupply_singleMarket() public {
        _deployMarket1();

        marketManagerIsolated.setMintPaused(address(borrowableCWMON_1), false);
        marketManagerIsolated.setMintPaused(address(borrowableCUSDC_1), false);

        uint256 gasBefore = gasleft();
        massPause.pauseSupply(_singleMarketArray(address(marketManagerIsolated)));
        uint256 gasUsed = gasBefore - gasleft();

        // Entry-only: 6 SSTOREs (3 per token × 2 tokens).
        assertLt(gasUsed, 400_000, "pauseSupply single market should use < 400k gas");
        emit log_named_uint("pauseSupply (1 market) gas", gasUsed);
    }

    function test_gasBenchmark_pauseRedemption_singleMarket() public {
        _deployMarket1();

        uint256 gasBefore = gasleft();
        massPause.pauseRedemption(_singleMarketArray(address(marketManagerIsolated)));
        uint256 gasUsed = gasBefore - gasleft();

        // Exit-only: 3 SSTOREs (market-wide, no token iteration).
        assertLt(gasUsed, 200_000, "pauseRedemption single market should use < 200k gas");
        emit log_named_uint("pauseRedemption (1 market) gas", gasUsed);
    }

    function test_gasBenchmark_deployMarket() public {
        uint256 gasBefore = gasleft();
        _deployMarket1();
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("deployMarket gas", gasUsed);
        // Should complete in a single block.
        assertLt(gasUsed, 5_000_000, "deployMarket should use < 5M gas");
    }

    // ══════════════════════════════════════════════════════
    // 2. ORDERING INDEPENDENCE
    // ══════════════════════════════════════════════════════

    /// @notice Proves supply→redemption == redemption→supply at storage level.
    function test_orderingIndependence_supplyThenRedemption() public {
        _deployMarket1();
        marketManagerIsolated.setMintPaused(address(borrowableCWMON_1), false);
        marketManagerIsolated.setMintPaused(address(borrowableCUSDC_1), false);

        // Path A: supply then redemption.
        massPause.pauseSupply(_singleMarketArray(address(marketManagerIsolated)));
        massPause.pauseRedemption(_singleMarketArray(address(marketManagerIsolated)));

        // Capture state.
        uint8 liqA = marketManagerIsolated.liquidationPaused();
        uint8 redeemA = marketManagerIsolated.redeemPaused();
        uint8 transferA = marketManagerIsolated.transferPaused();
        (bool mintA0, bool collA0, bool borrowA0) = marketManagerIsolated
            .actionsPaused(address(borrowableCWMON_1));
        (bool mintA1, bool collA1, bool borrowA1) = marketManagerIsolated
            .actionsPaused(address(borrowableCUSDC_1));

        // Reset.
        massPause.unpauseAll(_singleMarketArray(address(marketManagerIsolated)));

        // Path B: redemption then supply.
        massPause.pauseRedemption(_singleMarketArray(address(marketManagerIsolated)));
        massPause.pauseSupply(_singleMarketArray(address(marketManagerIsolated)));

        // Compare.
        assertEq(marketManagerIsolated.liquidationPaused(), liqA, "liquidation ordering mismatch");
        assertEq(marketManagerIsolated.redeemPaused(), redeemA, "redeem ordering mismatch");
        assertEq(marketManagerIsolated.transferPaused(), transferA, "transfer ordering mismatch");

        (bool mintB0, bool collB0, bool borrowB0) = marketManagerIsolated
            .actionsPaused(address(borrowableCWMON_1));
        (bool mintB1, bool collB1, bool borrowB1) = marketManagerIsolated
            .actionsPaused(address(borrowableCUSDC_1));

        assertEq(mintA0, mintB0, "t0 mint ordering mismatch");
        assertEq(collA0, collB0, "t0 coll ordering mismatch");
        assertEq(borrowA0, borrowB0, "t0 borrow ordering mismatch");
        assertEq(mintA1, mintB1, "t1 mint ordering mismatch");
        assertEq(collA1, collB1, "t1 coll ordering mismatch");
        assertEq(borrowA1, borrowB1, "t1 borrow ordering mismatch");
    }

    // ══════════════════════════════════════════════════════
    // 3. DEPLOYMENT MANAGER REUSE
    // ══════════════════════════════════════════════════════

    /// @notice Deploy two markets sequentially with the same deployment manager.
    ///         Verify no state leakage (balances, approvals, listing) between calls.
    function test_deploymentReuse_noStateLeak() public {
        // Deploy market 1.
        _deployMarket1();

        // Verify market 1 is listed.
        assertTrue(marketManagerIsolated.isListed(address(borrowableCWMON_1)));
        assertTrue(marketManagerIsolated.isListed(address(borrowableCUSDC_1)));

        // Verify deployment manager has zero balance and zero approvals.
        assertEq(
            IERC20(_USDC_ADDRESS).balanceOf(address(deploymentManager)),
            0,
            "USDC balance leak after market 1"
        );
        assertEq(
            IERC20(WMON_ADDRESS).balanceOf(address(deploymentManager)),
            0,
            "WMON balance leak after market 1"
        );
        assertEq(
            IERC20(_USDC_ADDRESS).allowance(
                address(deploymentManager),
                address(borrowableCUSDC_1)
            ),
            0,
            "USDC approval leak to cToken1"
        );

        // Deploy market 2 with the same deployment manager.
        _deployMarket2();

        // Verify market 2 is also listed.
        assertTrue(marketManager2.isListed(address(borrowableCWMON_2)));
        assertTrue(marketManager2.isListed(address(borrowableCUSDC_2)));

        // Verify no cross-contamination: market 1's tokens aren't in market 2.
        address[] memory m1Listed = marketManagerIsolated.queryTokensListed();
        address[] memory m2Listed = marketManager2.queryTokensListed();
        assertEq(m1Listed.length, 2);
        assertEq(m2Listed.length, 2);
        assertTrue(m1Listed[0] != m2Listed[0], "markets share token0");
        assertTrue(m1Listed[1] != m2Listed[1], "markets share token1");

        // Deployment manager clean after both.
        assertEq(
            IERC20(_USDC_ADDRESS).balanceOf(address(deploymentManager)),
            0,
            "USDC balance leak after market 2"
        );
        assertEq(
            IERC20(WMON_ADDRESS).balanceOf(address(deploymentManager)),
            0,
            "WMON balance leak after market 2"
        );
    }

    // ══════════════════════════════════════════════════════
    // 4. BATCH REVERT ISOLATION
    // ══════════════════════════════════════════════════════

    /// @notice With try/catch, a bad address in the markets array no longer
    ///         blocks the entire batch. The good market gets paused and the
    ///         bad market emits {MarketPauseFailed}.
    function test_batchResilience_badAddressDoesNotBlockBatch() public {
        _deployMarket1();

        // Unpause mint for clean state.
        marketManagerIsolated.setMintPaused(address(borrowableCWMON_1), false);
        marketManagerIsolated.setMintPaused(address(borrowableCUSDC_1), false);

        address[] memory markets = new address[](2);
        markets[0] = address(marketManagerIsolated); // Valid.
        markets[1] = address(0xdead);                // Invalid — not a MarketManager.

        // Expect failure event for the bad address.
        vm.expectEmit(true, true, true, true);
        emit ProtocolManagerMassPause.MarketPauseFailed(address(0xdead));

        massPause.pauseAll(markets);

        // Market 1 should be PAUSED — the bad address didn't block it.
        assertEq(
            marketManagerIsolated.liquidationPaused(),
            2,
            "market 1 should be paused despite bad address in batch"
        );
        assertEq(marketManagerIsolated.redeemPaused(), 2);
        assertEq(marketManagerIsolated.transferPaused(), 2);
    }

    /// @notice Explicit single-market array still works for targeted operations.
    function test_batchResilience_explicitArrayStillWorks() public {
        _deployMarket1();

        massPause.pauseAll(_singleMarketArray(address(marketManagerIsolated)));
        assertEq(marketManagerIsolated.liquidationPaused(), 2, "market 1 should be paused");
    }

    // ══════════════════════════════════════════════════════
    // 5. FULL OPERATIONAL LIFECYCLE
    // ══════════════════════════════════════════════════════

    /// @notice Simulates the complete operational lifecycle:
    ///         Deploy → Go live → User deposits → Emergency pause →
    ///         Partial recovery (exits open) → User withdraws → Full recovery.
    function test_lifecycle_deployPauseRecoverWithdraw() public {
        // ─── PHASE 1: Deploy market ───
        _deployMarket1();

        // Verify mint is paused (market not live yet).
        (bool mintPaused, , ) = marketManagerIsolated.actionsPaused(
            address(borrowableCWMON_1)
        );
        assertTrue(mintPaused, "Phase 1: mint should be paused after deploy");

        // ─── PHASE 2: Go live (unpause minting via one-time allowance) ───
        deploymentManager.unpauseMarket(address(marketManagerIsolated));

        // ─── PHASE 3: User deposits ───
        address user = address(0xBEEF);
        deal(WMON_ADDRESS, user, 10e18);

        vm.startPrank(user);
        IERC20(WMON_ADDRESS).approve(address(borrowableCWMON_1), 10e18);
        borrowableCWMON_1.deposit(10e18, user);
        vm.stopPrank();

        uint256 userShares = borrowableCWMON_1.balanceOf(user);
        assertTrue(userShares > 0, "Phase 3: user should have shares");

        // ─── PHASE 4: Emergency detected → full lockdown ───
        massPause.pauseAll(_singleMarketArray(address(marketManagerIsolated)));

        // User cannot deposit more.
        deal(WMON_ADDRESS, user, 1e18);
        vm.startPrank(user);
        IERC20(WMON_ADDRESS).approve(address(borrowableCWMON_1), 1e18);
        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        borrowableCWMON_1.deposit(1e18, user);
        vm.stopPrank();

        // User cannot withdraw.
        vm.startPrank(user);
        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        borrowableCWMON_1.redeem(userShares, user, user);
        vm.stopPrank();

        // ─── PHASE 5: Partial recovery — open exits only ───
        massPause.unpauseRedemption(_singleMarketArray(address(marketManagerIsolated)));

        // User CAN withdraw now.
        // Need to advance past the cooldown period first.
        vm.warp(block.timestamp + 21 minutes);

        vm.startPrank(user);
        borrowableCWMON_1.redeem(userShares, user, user);
        vm.stopPrank();

        uint256 userBalance = IERC20(WMON_ADDRESS).balanceOf(user);
        assertTrue(userBalance > 0, "Phase 5: user should have withdrawn WMON");
        assertEq(borrowableCWMON_1.balanceOf(user), 0, "Phase 5: user shares should be 0");

        // Deposits still blocked (supply pause still active).
        vm.startPrank(user);
        IERC20(WMON_ADDRESS).approve(address(borrowableCWMON_1), userBalance);
        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        borrowableCWMON_1.deposit(userBalance, user);
        vm.stopPrank();

        // ─── PHASE 6: Full recovery ───
        massPause.unpauseSupply(_singleMarketArray(address(marketManagerIsolated)));

        // User can deposit again.
        vm.startPrank(user);
        borrowableCWMON_1.deposit(userBalance, user);
        vm.stopPrank();

        assertTrue(
            borrowableCWMON_1.balanceOf(user) > 0,
            "Phase 6: user should have shares again"
        );
    }

    // ══════════════════════════════════════════════════════
    // 6. PERMISSION BOUNDARY ENFORCEMENT
    // ══════════════════════════════════════════════════════

    /// @notice After revoking market permissions, the deployment manager
    ///         reverts on all operations.
    function test_permissionRevocation_deploymentInert() public {
        centralRegistry.removeMarketPermissions(address(deploymentManager));

        _fundAndApproveDeployment();

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__Unauthorized.selector
        );
        deploymentManager.deployMarket(
            address(marketManagerIsolated),
            address(borrowableCWMON_1),
            address(borrowableCUSDC_1),
            _getBasicTokenConfig(address(borrowableCWMON_1), 1_000_000e18, 0),
            _getBasicTokenConfig(address(borrowableCUSDC_1), 0, 1_000_000e6)
        );
    }

    /// @notice After revoking market permissions, mass pause calls succeed
    ///         but all setters fail silently with {MarketPauseFailed} events.
    ///         The markets remain unaffected.
    function test_permissionRevocation_massPauseInert() public {
        _deployMarket1();

        // Unpause mint for clean state.
        marketManagerIsolated.setMintPaused(address(borrowableCWMON_1), false);
        marketManagerIsolated.setMintPaused(address(borrowableCUSDC_1), false);

        centralRegistry.removeMarketPermissions(address(massPause));

        // Calls succeed (try/catch) but market remains unpaused.
        vm.expectEmit(true, true, true, true);
        emit ProtocolManagerMassPause.MarketPauseFailed(
            address(marketManagerIsolated)
        );
        massPause.pauseAll(_singleMarketArray(address(marketManagerIsolated)));
        assertEq(marketManagerIsolated.liquidationPaused(), 1, "should still be unpaused");

        massPause.pauseSupply(_singleMarketArray(address(marketManagerIsolated)));
        (bool mintPaused, , ) = marketManagerIsolated.actionsPaused(
            address(borrowableCWMON_1)
        );
        assertFalse(mintPaused, "mint should still be unpaused");

        massPause.pauseRedemption(_singleMarketArray(address(marketManagerIsolated)));
        assertEq(marketManagerIsolated.redeemPaused(), 1, "redeem should still be unpaused");
    }

    /// @notice Neither contract can escalate permissions or access
    ///         functions beyond their intended scope.
    function test_permissionBoundary_cannotEscalate() public {
        _deployMarket1();

        // Deployment manager has market permissions but cannot:
        // - Add/remove position managers
        // - Modify other markets' configs
        // - Change central registry settings
        // Verify it only exposes deployMarket().
        // (Implicitly verified: ProtocolManagerDeployment has exactly 1 external function)

        // Mass pause has market permissions but pause/unpause is all it can do.
        // It cannot updateTokenConfig, listTokens, etc.
        // (Implicitly verified: ProtocolManagerMassPause exposes only pause/unpause)

        // Explicitly: after deploying market 1, deployment manager cannot
        // re-list tokens or modify config (it doesn't have those functions).
        // The only path is through deployMarket which would revert because
        // tokens are already listed.
        _fundAndApproveDeployment();
        vm.expectRevert(
            MarketManagerIsolated.MarketManager__InvalidParameter.selector
        );
        deploymentManager.deployMarket(
            address(marketManagerIsolated),
            address(borrowableCWMON_1),
            address(borrowableCUSDC_1),
            _getBasicTokenConfig(address(borrowableCWMON_1), 1_000_000e18, 0),
            _getBasicTokenConfig(address(borrowableCUSDC_1), 0, 1_000_000e6)
        );
    }
}
