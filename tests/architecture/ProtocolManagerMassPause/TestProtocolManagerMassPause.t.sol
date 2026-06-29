// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { ProtocolManagerMassPause } from "contracts/architecture/ProtocolManagerMassPause.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { CentralRegistryLib } from "contracts/libraries/CentralRegistryLib.sol";
import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { DynamicIRM } from "contracts/market/DynamicIRM.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

contract TestProtocolManagerMassPause is TestBaseMarketIsolated {
    ProtocolManagerMassPause public massPause;

    address public constant WMON_ADDRESS =
        0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;

    BorrowableCToken public borrowableCUSDC_MONAD;
    BorrowableCToken public borrowableCWMON;

    // Second market for multi-market tests.
    MarketManagerIsolated public marketManager2;
    BorrowableCToken public borrowableCUSDC_2;
    BorrowableCToken public borrowableCWMON_2;

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

        borrowableCUSDC_MONAD = _deployBorrowableCToken(_USDC_ADDRESS);
        borrowableCWMON = _deployBorrowableCToken(WMON_ADDRESS);

        MockV3Aggregator chainlinkUSDC_USD = new MockV3Aggregator(8, 1e8);
        address chainlinkWMON_USD =
            0xBcD78f76005B7515837af6b50c7C52BCf73822fb;

        ChainlinkAdaptor chainlinkAdaptor = new ChainlinkAdaptor(
            ICentralRegistry(address(centralRegistry))
        );

        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));

        chainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            true,
            address(chainlinkUSDC_USD),
            0
        );
        chainlinkAdaptor.addAsset(
            WMON_ADDRESS,
            true,
            chainlinkWMON_USD,
            0
        );

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

        oracleManager.addCTokenSupport(address(borrowableCUSDC_MONAD));
        oracleManager.addCTokenSupport(address(borrowableCWMON));

        deal(_USDC_ADDRESS, address(this), 77777 * 2);
        IERC20(_USDC_ADDRESS).approve(
            address(borrowableCUSDC_MONAD),
            type(uint256).max
        );

        deal(WMON_ADDRESS, address(this), 77777 * 2);
        IERC20(WMON_ADDRESS).approve(
            address(borrowableCWMON),
            type(uint256).max
        );

        // List tokens and set configs for market 1.
        marketManagerIsolated.listTokens(
            address(borrowableCUSDC_MONAD),
            address(borrowableCWMON)
        );
        _setCTokenConfigBasic(address(borrowableCWMON), 1_000_000e18, 0);
        _setCTokenConfigBasic(
            address(borrowableCUSDC_MONAD),
            0,
            1_000_000e6
        );

        // Deploy second market manager for multi-market tests.
        _setupSecondMarket();

        // Deploy mass pause manager with address(this) as owner and full
        // unpause authority (canUnpause = true).
        massPause = new ProtocolManagerMassPause(
            ICentralRegistry(address(centralRegistry)),
            address(this),
            true
        );

        // Grant market permissions.
        centralRegistry.addMarketPermissions(address(massPause));
    }

    function _setupSecondMarket() internal {
        marketManager2 = new MarketManagerIsolated(
            ICentralRegistry(address(centralRegistry)),
            10e18,
            false
        );
        centralRegistry.addMarketManager(address(marketManager2));

        // Deploy cTokens for market 2 (reuse same underlyings + oracles).
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

        IERC20(_USDC_ADDRESS).approve(
            address(borrowableCUSDC_2),
            type(uint256).max
        );
        IERC20(WMON_ADDRESS).approve(
            address(borrowableCWMON_2),
            type(uint256).max
        );

        marketManager2.listTokens(
            address(borrowableCUSDC_2),
            address(borrowableCWMON_2)
        );

        // Set configs on market 2.
        MarketManagerIsolated.TokenConfig memory tc;
        tc.cToken = address(borrowableCWMON_2);
        tc.collRatio = 7000;
        tc.collReqSoft = 4000;
        tc.collReqHard = 3000;
        tc.liqIncBase = 1000;
        tc.liqIncHard = 1500;
        tc.liqIncMin = 10;
        tc.liqIncMax = 2000;
        tc.closeFactorBase = 2000;
        tc.closeFactorMin = 2000;
        tc.closeFactorMax = 5000;
        tc.collateralCap = 1_000_000e18;
        marketManager2.updateTokenConfig(tc);

        tc.cToken = address(borrowableCUSDC_2);
        tc.collateralCap = 0;
        tc.debtCap = 1_000_000e6;
        marketManager2.updateTokenConfig(tc);
    }

    /// HELPER FUNCTIONS ///

    function _assertAllPaused(MarketManagerIsolated mm, address t0, address t1) internal view {
        assertEq(mm.liquidationPaused(), 2, "liquidation should be paused");
        assertEq(mm.redeemPaused(), 2, "redeem should be paused");
        assertEq(mm.transferPaused(), 2, "transfer should be paused");

        (bool mintP0, bool collP0, bool borrowP0) = mm.actionsPaused(t0);
        assertTrue(mintP0, "t0 mint should be paused");
        assertTrue(collP0, "t0 collateralization should be paused");
        assertTrue(borrowP0, "t0 borrow should be paused");

        (bool mintP1, bool collP1, bool borrowP1) = mm.actionsPaused(t1);
        assertTrue(mintP1, "t1 mint should be paused");
        assertTrue(collP1, "t1 collateralization should be paused");
        assertTrue(borrowP1, "t1 borrow should be paused");
    }

    function _assertAllUnpaused(MarketManagerIsolated mm, address t0, address t1) internal view {
        assertEq(mm.liquidationPaused(), 1, "liquidation should be unpaused");
        assertEq(mm.redeemPaused(), 1, "redeem should be unpaused");
        assertEq(mm.transferPaused(), 1, "transfer should be unpaused");

        (bool mintP0, bool collP0, bool borrowP0) = mm.actionsPaused(t0);
        assertFalse(mintP0, "t0 mint should be unpaused");
        assertFalse(collP0, "t0 collateralization should be unpaused");
        assertFalse(borrowP0, "t0 borrow should be unpaused");

        (bool mintP1, bool collP1, bool borrowP1) = mm.actionsPaused(t1);
        assertFalse(mintP1, "t1 mint should be unpaused");
        assertFalse(collP1, "t1 collateralization should be unpaused");
        assertFalse(borrowP1, "t1 borrow should be unpaused");
    }

    function _assertMarketWideExitPaused(MarketManagerIsolated mm) internal view {
        assertEq(mm.liquidationPaused(), 2, "liquidation should be paused");
        assertEq(mm.redeemPaused(), 2, "redeem should be paused");
        assertEq(mm.transferPaused(), 2, "transfer should be paused");
    }

    function _assertMarketWideExitUnpaused(MarketManagerIsolated mm) internal view {
        assertEq(mm.liquidationPaused(), 1, "liquidation should be unpaused");
        assertEq(mm.redeemPaused(), 1, "redeem should be unpaused");
        assertEq(mm.transferPaused(), 1, "transfer should be unpaused");
    }

    function _assertTokenLevelEntryPaused(MarketManagerIsolated mm, address t0, address t1) internal view {
        (bool mintP0, bool collP0, bool borrowP0) = mm.actionsPaused(t0);
        assertTrue(mintP0, "t0 mint should be paused");
        assertTrue(collP0, "t0 collateralization should be paused");
        assertTrue(borrowP0, "t0 borrow should be paused");

        (bool mintP1, bool collP1, bool borrowP1) = mm.actionsPaused(t1);
        assertTrue(mintP1, "t1 mint should be paused");
        assertTrue(collP1, "t1 collateralization should be paused");
        assertTrue(borrowP1, "t1 borrow should be paused");
    }

    function _assertTokenLevelEntryUnpaused(MarketManagerIsolated mm, address t0, address t1) internal view {
        (bool mintP0, bool collP0, bool borrowP0) = mm.actionsPaused(t0);
        assertFalse(mintP0, "t0 mint should be unpaused");
        assertFalse(collP0, "t0 collateralization should be unpaused");
        assertFalse(borrowP0, "t0 borrow should be unpaused");

        (bool mintP1, bool collP1, bool borrowP1) = mm.actionsPaused(t1);
        assertFalse(mintP1, "t1 mint should be unpaused");
        assertFalse(collP1, "t1 collateralization should be unpaused");
        assertFalse(borrowP1, "t1 borrow should be unpaused");
    }

    // Market 1 shorthand helpers.
    function _assertM1AllPaused() internal view {
        _assertAllPaused(marketManagerIsolated, address(borrowableCUSDC_MONAD), address(borrowableCWMON));
    }
    function _assertM1AllUnpaused() internal view {
        _assertAllUnpaused(marketManagerIsolated, address(borrowableCUSDC_MONAD), address(borrowableCWMON));
    }
    function _assertM1MarketWideExitPaused() internal view {
        _assertMarketWideExitPaused(marketManagerIsolated);
    }
    function _assertM1MarketWideExitUnpaused() internal view {
        _assertMarketWideExitUnpaused(marketManagerIsolated);
    }
    function _assertM1TokenLevelEntryPaused() internal view {
        _assertTokenLevelEntryPaused(marketManagerIsolated, address(borrowableCUSDC_MONAD), address(borrowableCWMON));
    }
    function _assertM1TokenLevelEntryUnpaused() internal view {
        _assertTokenLevelEntryUnpaused(marketManagerIsolated, address(borrowableCUSDC_MONAD), address(borrowableCWMON));
    }

    // Market 2 shorthand helpers.
    function _assertM2AllPaused() internal view {
        _assertAllPaused(marketManager2, address(borrowableCUSDC_2), address(borrowableCWMON_2));
    }
    function _assertM2AllUnpaused() internal view {
        _assertAllUnpaused(marketManager2, address(borrowableCUSDC_2), address(borrowableCWMON_2));
    }
    function _assertM2MarketWideExitPaused() internal view {
        _assertMarketWideExitPaused(marketManager2);
    }
    function _assertM2MarketWideExitUnpaused() internal view {
        _assertMarketWideExitUnpaused(marketManager2);
    }
    function _assertM2TokenLevelEntryPaused() internal view {
        _assertTokenLevelEntryPaused(marketManager2, address(borrowableCUSDC_2), address(borrowableCWMON_2));
    }
    function _assertM2TokenLevelEntryUnpaused() internal view {
        _assertTokenLevelEntryUnpaused(marketManager2, address(borrowableCUSDC_2), address(borrowableCWMON_2));
    }

    function _singleMarketArray()
        internal
        view
        returns (address[] memory markets)
    {
        markets = new address[](1);
        markets[0] = address(marketManagerIsolated);
    }

    function _bothMarketsArray()
        internal
        view
        returns (address[] memory markets)
    {
        markets = new address[](2);
        markets[0] = address(marketManagerIsolated);
        markets[1] = address(marketManager2);
    }

    function _emptyArray()
        internal
        pure
        returns (address[] memory markets)
    {
        markets = new address[](0);
    }

    /// @dev Deploys a mass-pause manager with the given unpause authority
    ///      and grants it market permissions.
    function _deployMassPause(bool canUnpause_)
        internal
        returns (ProtocolManagerMassPause pm)
    {
        pm = new ProtocolManagerMassPause(
            ICentralRegistry(address(centralRegistry)),
            address(this),
            canUnpause_
        );
        centralRegistry.addMarketPermissions(address(pm));
    }

    /// ==================== pauseAll / unpauseAll ==================== ///

    function test_pauseAll_explicitMarkets() public {
        massPause.pauseAll(_singleMarketArray());
        _assertM1AllPaused();
    }

    function test_pauseAll_autoDiscover() public {
        massPause.pauseAll(_emptyArray());
        _assertM1AllPaused();
        _assertM2AllPaused();
    }

    function test_unpauseAll_explicitMarkets() public {
        massPause.pauseAll(_singleMarketArray());
        _assertM1AllPaused();

        massPause.unpauseAll(_singleMarketArray());
        _assertM1AllUnpaused();
    }

    function test_unpauseAll_autoDiscover() public {
        massPause.pauseAll(_emptyArray());
        massPause.unpauseAll(_emptyArray());
        _assertM1AllUnpaused();
        _assertM2AllUnpaused();
    }

    /// ========== pauseTokenLevelEntryActions / unpauseTokenLevelEntryActions ========== ///

    function test_pauseTokenLevelEntryActions_onlyPausesTokenLevelEntry() public {
        massPause.pauseTokenLevelEntryActions(_singleMarketArray());
        _assertM1TokenLevelEntryPaused();
        _assertM1MarketWideExitUnpaused();
    }

    function test_unpauseTokenLevelEntryActions() public {
        massPause.pauseTokenLevelEntryActions(_singleMarketArray());
        massPause.unpauseTokenLevelEntryActions(_singleMarketArray());
        _assertM1TokenLevelEntryUnpaused();
    }

    function test_pauseTokenLevelEntryActions_autoDiscover() public {
        massPause.pauseTokenLevelEntryActions(_emptyArray());
        _assertM1TokenLevelEntryPaused();
        _assertM1MarketWideExitUnpaused();
        _assertM2TokenLevelEntryPaused();
        _assertM2MarketWideExitUnpaused();
    }

    /// ========== pauseMarketWideExitActions / unpauseMarketWideExitActions ========== ///

    function test_pauseMarketWideExitActions_onlyPausesMarketWideExit() public {
        massPause.pauseMarketWideExitActions(_singleMarketArray());
        _assertM1MarketWideExitPaused();
        _assertM1TokenLevelEntryUnpaused();
    }

    function test_unpauseMarketWideExitActions() public {
        massPause.pauseMarketWideExitActions(_singleMarketArray());
        massPause.unpauseMarketWideExitActions(_singleMarketArray());
        _assertM1MarketWideExitUnpaused();
    }

    function test_pauseMarketWideExitActions_autoDiscover() public {
        massPause.pauseMarketWideExitActions(_emptyArray());
        _assertM1MarketWideExitPaused();
        _assertM1TokenLevelEntryUnpaused();
        _assertM2MarketWideExitPaused();
        _assertM2TokenLevelEntryUnpaused();
    }

    /// ==================== MULTI-MARKET ==================== ///

    function test_pauseAll_multipleMarkets_explicit() public {
        massPause.pauseAll(_bothMarketsArray());
        _assertM1AllPaused();
        _assertM2AllPaused();
    }

    function test_unpauseAll_multipleMarkets_explicit() public {
        massPause.pauseAll(_bothMarketsArray());
        massPause.unpauseAll(_bothMarketsArray());
        _assertM1AllUnpaused();
        _assertM2AllUnpaused();
    }

    function test_pauseTokenLevelEntryActions_multipleMarkets() public {
        massPause.pauseTokenLevelEntryActions(_bothMarketsArray());
        _assertM1TokenLevelEntryPaused();
        _assertM1MarketWideExitUnpaused();
        _assertM2TokenLevelEntryPaused();
        _assertM2MarketWideExitUnpaused();
    }

    function test_pauseMarketWideExitActions_multipleMarkets() public {
        massPause.pauseMarketWideExitActions(_bothMarketsArray());
        _assertM1MarketWideExitPaused();
        _assertM1TokenLevelEntryUnpaused();
        _assertM2MarketWideExitPaused();
        _assertM2TokenLevelEntryUnpaused();
    }

    function test_pauseAll_singleMarket_doesNotAffectOther() public {
        massPause.pauseAll(_singleMarketArray());
        _assertM1AllPaused();
        // Market 2 should be untouched.
        _assertM2AllUnpaused();
    }

    /// ==================== COMPOSABILITY ==================== ///

    function test_pauseTokenLevelEntryThenMarketWideExit_equalsAll() public {
        massPause.pauseTokenLevelEntryActions(_singleMarketArray());
        massPause.pauseMarketWideExitActions(_singleMarketArray());
        _assertM1AllPaused();
    }

    function test_unpauseTokenLevelEntryOnly_afterPauseAll() public {
        massPause.pauseAll(_singleMarketArray());
        _assertM1AllPaused();

        massPause.unpauseTokenLevelEntryActions(_singleMarketArray());
        _assertM1TokenLevelEntryUnpaused();
        _assertM1MarketWideExitPaused();
    }

    function test_unpauseMarketWideExitOnly_afterPauseAll() public {
        massPause.pauseAll(_singleMarketArray());
        _assertM1AllPaused();

        massPause.unpauseMarketWideExitActions(_singleMarketArray());
        _assertM1MarketWideExitUnpaused();
        _assertM1TokenLevelEntryPaused();
    }

    function test_pauseAll_unpauseTokenLevelEntry_unpauseMarketWideExit_fullRecovery()
        public
    {
        massPause.pauseAll(_singleMarketArray());
        _assertM1AllPaused();

        massPause.unpauseTokenLevelEntryActions(_singleMarketArray());
        massPause.unpauseMarketWideExitActions(_singleMarketArray());
        _assertM1AllUnpaused();
    }

    /// ==================== AUTHORIZATION ==================== ///

    function test_pauseAll_revertsUnauthorized() public {
        address unauthorized = address(0xdead);
        vm.prank(unauthorized);
        vm.expectRevert(
            ProtocolManagerMassPause
                .ProtocolManagerMassPause__Unauthorized
                .selector
        );
        massPause.pauseAll(_singleMarketArray());
    }

    function test_unpauseAll_revertsUnauthorized() public {
        address unauthorized = address(0xdead);
        vm.prank(unauthorized);
        vm.expectRevert(
            ProtocolManagerMassPause
                .ProtocolManagerMassPause__Unauthorized
                .selector
        );
        massPause.unpauseAll(_singleMarketArray());
    }

    function test_pauseTokenLevelEntryActions_revertsUnauthorized() public {
        address unauthorized = address(0xdead);
        vm.prank(unauthorized);
        vm.expectRevert(
            ProtocolManagerMassPause
                .ProtocolManagerMassPause__Unauthorized
                .selector
        );
        massPause.pauseTokenLevelEntryActions(_singleMarketArray());
    }

    function test_unpauseTokenLevelEntryActions_revertsUnauthorized() public {
        address unauthorized = address(0xdead);
        vm.prank(unauthorized);
        vm.expectRevert(
            ProtocolManagerMassPause
                .ProtocolManagerMassPause__Unauthorized
                .selector
        );
        massPause.unpauseTokenLevelEntryActions(_singleMarketArray());
    }

    function test_pauseMarketWideExitActions_revertsUnauthorized() public {
        address unauthorized = address(0xdead);
        vm.prank(unauthorized);
        vm.expectRevert(
            ProtocolManagerMassPause
                .ProtocolManagerMassPause__Unauthorized
                .selector
        );
        massPause.pauseMarketWideExitActions(_singleMarketArray());
    }

    function test_unpauseMarketWideExitActions_revertsUnauthorized() public {
        address unauthorized = address(0xdead);
        vm.prank(unauthorized);
        vm.expectRevert(
            ProtocolManagerMassPause
                .ProtocolManagerMassPause__Unauthorized
                .selector
        );
        massPause.unpauseMarketWideExitActions(_singleMarketArray());
    }

    function test_pauseAll_withoutMarketPermissions_emitsFailure() public {
        centralRegistry.removeMarketPermissions(address(massPause));

        // With try/catch, the tx succeeds but emits MarketPauseFailed.
        vm.expectEmit(true, true, true, true);
        emit ProtocolManagerMassPause.MarketPauseFailed(
            address(marketManagerIsolated)
        );
        massPause.pauseAll(_singleMarketArray());

        // Market should remain unpaused — all setters failed silently.
        _assertM1AllUnpaused();
    }

    /// ==================== EVENTS ==================== ///

    function test_pauseAll_emitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit ProtocolManagerMassPause.MassPauseExecuted("All", true, 1, 0);
        massPause.pauseAll(_singleMarketArray());
    }

    function test_unpauseAll_emitsEvent() public {
        massPause.pauseAll(_singleMarketArray());

        vm.expectEmit(true, true, true, true);
        emit ProtocolManagerMassPause.MassPauseExecuted("All", false, 1, 0);
        massPause.unpauseAll(_singleMarketArray());
    }

    function test_pauseTokenLevelEntryActions_emitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit ProtocolManagerMassPause.MassPauseExecuted("TokenLevelEntry", true, 1, 0);
        massPause.pauseTokenLevelEntryActions(_singleMarketArray());
    }

    function test_unpauseTokenLevelEntryActions_emitsEvent() public {
        massPause.pauseTokenLevelEntryActions(_singleMarketArray());

        vm.expectEmit(true, true, true, true);
        emit ProtocolManagerMassPause.MassPauseExecuted("TokenLevelEntry", false, 1, 0);
        massPause.unpauseTokenLevelEntryActions(_singleMarketArray());
    }

    function test_pauseMarketWideExitActions_emitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit ProtocolManagerMassPause.MassPauseExecuted("MarketWideExit", true, 1, 0);
        massPause.pauseMarketWideExitActions(_singleMarketArray());
    }

    function test_unpauseMarketWideExitActions_emitsEvent() public {
        massPause.pauseMarketWideExitActions(_singleMarketArray());

        vm.expectEmit(true, true, true, true);
        emit ProtocolManagerMassPause.MassPauseExecuted(
            "MarketWideExit",
            false,
            1,
            0
        );
        massPause.unpauseMarketWideExitActions(_singleMarketArray());
    }

    function test_pauseAll_autoDiscover_emitsCorrectCount() public {
        // Auto-discover should find 2 markets (m1 + m2).
        vm.expectEmit(true, true, true, true);
        emit ProtocolManagerMassPause.MassPauseExecuted("All", true, 2, 0);
        massPause.pauseAll(_emptyArray());
    }

    /// ==================== IDEMPOTENCY ==================== ///

    function test_pauseAll_idempotent() public {
        massPause.pauseAll(_singleMarketArray());
        _assertM1AllPaused();

        // Pausing again should not revert.
        massPause.pauseAll(_singleMarketArray());
        _assertM1AllPaused();
    }

    function test_unpauseAll_idempotent() public {
        // Unpause when already unpaused should not revert.
        massPause.unpauseAll(_singleMarketArray());
        _assertM1AllUnpaused();
    }

    function test_pauseTokenLevelEntryActions_idempotent() public {
        massPause.pauseTokenLevelEntryActions(_singleMarketArray());
        massPause.pauseTokenLevelEntryActions(_singleMarketArray());
        _assertM1TokenLevelEntryPaused();
    }

    function test_pauseMarketWideExitActions_idempotent() public {
        massPause.pauseMarketWideExitActions(_singleMarketArray());
        massPause.pauseMarketWideExitActions(_singleMarketArray());
        _assertM1MarketWideExitPaused();
    }

    /// ==================== INTEGRATION ==================== ///

    function test_pauseTokenLevelEntryActions_mintActuallyReverts() public {
        massPause.pauseTokenLevelEntryActions(_singleMarketArray());

        address user = address(0xBEEF);
        deal(WMON_ADDRESS, user, 1e18);

        vm.startPrank(user);
        IERC20(WMON_ADDRESS).approve(address(borrowableCWMON), 1e18);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        borrowableCWMON.deposit(1e18, user);
        vm.stopPrank();
    }

    function test_pauseMarketWideExitActions_mintStillWorks() public {
        massPause.pauseMarketWideExitActions(_singleMarketArray());

        // Minting should still work when only market-wide exit actions are paused.
        address user = address(0xBEEF);
        deal(WMON_ADDRESS, user, 1e18);

        vm.startPrank(user);
        IERC20(WMON_ADDRESS).approve(address(borrowableCWMON), 1e18);
        borrowableCWMON.deposit(1e18, user);
        vm.stopPrank();

        // User should have cToken shares.
        assertTrue(borrowableCWMON.balanceOf(user) > 0, "user should have shares");
    }

    /// ==================== CONSTRUCTOR ==================== ///

    function test_constructor_setsImmutables() public view {
        assertEq(
            address(massPause.centralRegistry()),
            address(centralRegistry)
        );
        assertEq(massPause.owner(), address(this));
        // setUp deploys with full unpause authority.
        assertTrue(massPause.canUnpause(), "canUnpause should be true");
    }

    function test_constructor_canUnpause_false() public {
        ProtocolManagerMassPause pm = new ProtocolManagerMassPause(
            ICentralRegistry(address(centralRegistry)),
            address(this),
            false
        );
        assertFalse(pm.canUnpause(), "canUnpause should be false");
        assertEq(pm.owner(), address(this));
    }

    function test_constructor_revertsZeroOwner() public {
        vm.expectRevert(
            ProtocolManagerMassPause
                .ProtocolManagerMassPause__Unauthorized
                .selector
        );
        new ProtocolManagerMassPause(
            ICentralRegistry(address(centralRegistry)),
            address(0),
            true
        );
    }

    function test_constructor_revertsInvalidCentralRegistry() public {
        // A no-code address does not support the ICentralRegistry interface.
        vm.expectRevert(
            CentralRegistryLib
                .CentralRegistryLib__InvalidCentralRegistry
                .selector
        );
        new ProtocolManagerMassPause(
            ICentralRegistry(address(0xBAD)),
            address(this),
            true
        );
    }

    function test_autoDiscover_returnsAllRegisteredMarkets() public view {
        address[] memory registered = centralRegistry.marketManagers();
        assertEq(registered.length, 2);
        assertEq(registered[0], address(marketManagerIsolated));
        assertEq(registered[1], address(marketManager2));
    }

    /// ==================== UNPAUSE AUTHORITY ==================== ///

    function test_canUnpause_false_pauseAllStillWorks() public {
        ProtocolManagerMassPause pm = _deployMassPause(false);
        pm.pauseAll(_singleMarketArray());
        _assertM1AllPaused();
    }

    function test_canUnpause_false_unpauseAllReverts() public {
        ProtocolManagerMassPause pm = _deployMassPause(false);
        pm.pauseAll(_singleMarketArray());

        vm.expectRevert(
            ProtocolManagerMassPause
                .ProtocolManagerMassPause__Unauthorized
                .selector
        );
        pm.unpauseAll(_singleMarketArray());

        // Markets remain paused — the revert left state untouched.
        _assertM1AllPaused();
    }

    function test_canUnpause_false_unpauseTokenLevelEntryReverts() public {
        ProtocolManagerMassPause pm = _deployMassPause(false);
        vm.expectRevert(
            ProtocolManagerMassPause
                .ProtocolManagerMassPause__Unauthorized
                .selector
        );
        pm.unpauseTokenLevelEntryActions(_singleMarketArray());
    }

    function test_canUnpause_false_unpauseMarketWideExitReverts() public {
        ProtocolManagerMassPause pm = _deployMassPause(false);
        vm.expectRevert(
            ProtocolManagerMassPause
                .ProtocolManagerMassPause__Unauthorized
                .selector
        );
        pm.unpauseMarketWideExitActions(_singleMarketArray());
    }

    function test_canUnpause_false_nonOwnerReverts() public {
        // Both the capability gate and the owner gate surface the same
        // __Unauthorized error (mirroring base ProtocolManager), so a
        // non-owner calling unpause on a pause-only contract reverts.
        ProtocolManagerMassPause pm = _deployMassPause(false);
        vm.prank(address(0xdead));
        vm.expectRevert(
            ProtocolManagerMassPause
                .ProtocolManagerMassPause__Unauthorized
                .selector
        );
        pm.unpauseAll(_singleMarketArray());
    }

    function test_canUnpause_true_unpauseAllWorks() public {
        ProtocolManagerMassPause pm = _deployMassPause(true);
        pm.pauseAll(_singleMarketArray());
        pm.unpauseAll(_singleMarketArray());
        _assertM1AllUnpaused();
    }

    /// ==================== FAILURE HANDLING ==================== ///

    function test_pauseAll_noCodeMarket_emitsFailureAndCountsIt() public {
        address[] memory markets = new address[](1);
        markets[0] = address(0xDEAD); // No code at this address.

        vm.expectEmit(true, true, true, true);
        emit ProtocolManagerMassPause.MarketPauseFailed(address(0xDEAD));
        vm.expectEmit(true, true, true, true);
        emit ProtocolManagerMassPause.MassPauseExecuted("All", true, 1, 1);
        massPause.pauseAll(markets);
    }

    function test_pauseMarketWideExit_noCodeMarket_counted() public {
        address[] memory markets = new address[](1);
        markets[0] = address(0xDEAD);

        vm.expectEmit(true, true, true, true);
        emit ProtocolManagerMassPause.MassPauseExecuted(
            "MarketWideExit",
            true,
            1,
            1
        );
        massPause.pauseMarketWideExitActions(markets);
    }

    function test_pauseTokenLevelEntry_noCodeMarket_counted() public {
        address[] memory markets = new address[](1);
        markets[0] = address(0xDEAD);

        vm.expectEmit(true, true, true, true);
        emit ProtocolManagerMassPause.MassPauseExecuted(
            "TokenLevelEntry",
            true,
            1,
            1
        );
        massPause.pauseTokenLevelEntryActions(markets);
    }

    function test_pauseTokenLevelEntry_queryTokensRevert_counted() public {
        // Market has code and working setters but reverts on token
        // discovery — token-level entry is skipped and counted as failed.
        RevertingTokenQueryMarket bad = new RevertingTokenQueryMarket();
        address[] memory markets = new address[](1);
        markets[0] = address(bad);

        vm.expectEmit(true, true, true, true);
        emit ProtocolManagerMassPause.MarketPauseFailed(address(bad));
        vm.expectEmit(true, true, true, true);
        emit ProtocolManagerMassPause.MassPauseExecuted(
            "TokenLevelEntry",
            true,
            1,
            1
        );
        massPause.pauseTokenLevelEntryActions(markets);
    }

    function test_pauseAll_oneGoodOneBadMarket_onlyBadCounted() public {
        // A healthy market alongside a no-code one: the good market is
        // paused, only the bad market is counted as failed.
        address[] memory markets = new address[](2);
        markets[0] = address(marketManagerIsolated);
        markets[1] = address(0xDEAD);

        vm.expectEmit(true, true, true, true);
        emit ProtocolManagerMassPause.MarketPauseFailed(address(0xDEAD));
        vm.expectEmit(true, true, true, true);
        emit ProtocolManagerMassPause.MassPauseExecuted("All", true, 2, 1);
        massPause.pauseAll(markets);

        _assertM1AllPaused();
    }

    function test_unpauseAll_noCodeMarket_countsFailure() public {
        // Exercises the failure-counting branch in the unpause direction.
        address[] memory markets = new address[](1);
        markets[0] = address(0xDEAD);

        vm.expectEmit(true, true, true, true);
        emit ProtocolManagerMassPause.MarketPauseFailed(address(0xDEAD));
        vm.expectEmit(true, true, true, true);
        emit ProtocolManagerMassPause.MassPauseExecuted("All", false, 1, 1);
        massPause.unpauseAll(markets);
    }

    function test_unpauseTokenLevelEntry_noCodeMarket_countsFailure() public {
        // Failure-counting branch of the scoped token-level unpause.
        address[] memory markets = new address[](1);
        markets[0] = address(0xDEAD);

        vm.expectEmit(true, true, true, true);
        emit ProtocolManagerMassPause.MarketPauseFailed(address(0xDEAD));
        vm.expectEmit(true, true, true, true);
        emit ProtocolManagerMassPause.MassPauseExecuted(
            "TokenLevelEntry",
            false,
            1,
            1
        );
        massPause.unpauseTokenLevelEntryActions(markets);
    }

    function test_unpauseMarketWideExit_noCodeMarket_countsFailure() public {
        // Failure-counting branch of the scoped market-wide unpause.
        address[] memory markets = new address[](1);
        markets[0] = address(0xDEAD);

        vm.expectEmit(true, true, true, true);
        emit ProtocolManagerMassPause.MarketPauseFailed(address(0xDEAD));
        vm.expectEmit(true, true, true, true);
        emit ProtocolManagerMassPause.MassPauseExecuted(
            "MarketWideExit",
            false,
            1,
            1
        );
        massPause.unpauseMarketWideExitActions(markets);
    }

    /// ==================== AUTO-DISCOVER EDGE ==================== ///

    function test_pauseAll_autoDiscover_emptyRegistry() public {
        // With no registered markets, auto-discover resolves to an empty
        // set: the loop is skipped and a 0/0 event is emitted.
        centralRegistry.removeMarketManager(address(marketManagerIsolated));
        centralRegistry.removeMarketManager(address(marketManager2));
        assertEq(centralRegistry.marketManagers().length, 0);

        vm.expectEmit(true, true, true, true);
        emit ProtocolManagerMassPause.MassPauseExecuted("All", true, 0, 0);
        massPause.pauseAll(_emptyArray());
    }

    function test_pauseAll_autoDiscoverSkipsRemovedMarketButExplicitCanReachIt()
        public
    {
        centralRegistry.removeMarketManager(address(marketManager2));
        assertFalse(centralRegistry.isMarketManager(address(marketManager2)));

        address[] memory registered = centralRegistry.marketManagers();
        assertEq(registered.length, 1);
        assertEq(registered[0], address(marketManagerIsolated));

        vm.expectEmit(true, true, true, true);
        emit ProtocolManagerMassPause.MassPauseExecuted("All", true, 1, 0);
        massPause.pauseAll(_emptyArray());
        _assertM1AllPaused();
        _assertM2AllUnpaused();

        address[] memory removedMarket = new address[](1);
        removedMarket[0] = address(marketManager2);

        vm.expectEmit(true, true, true, true);
        emit ProtocolManagerMassPause.MassPauseExecuted("All", true, 1, 0);
        massPause.pauseAll(removedMarket);
        _assertM2AllPaused();
    }

    /// ==================== IDEMPOTENCY (UNPAUSE) ==================== ///

    function test_unpauseTokenLevelEntryActions_idempotent() public {
        massPause.unpauseTokenLevelEntryActions(_singleMarketArray());
        massPause.unpauseTokenLevelEntryActions(_singleMarketArray());
        _assertM1TokenLevelEntryUnpaused();
    }

    function test_unpauseMarketWideExitActions_idempotent() public {
        massPause.unpauseMarketWideExitActions(_singleMarketArray());
        massPause.unpauseMarketWideExitActions(_singleMarketArray());
        _assertM1MarketWideExitUnpaused();
    }
}

/// @notice Market mock that has code and working pause setters but reverts
///         on token discovery, exercising the `queryTokensListed` catch path.
contract RevertingTokenQueryMarket {
    function queryTokensListed() external pure returns (address[] memory) {
        revert("queryTokensListed reverted");
    }

    function setLiquidationPaused(bool) external {}
    function setRedeemPaused(bool) external {}
    function setTransferPaused(bool) external {}
    function setMintPaused(address, bool) external {}
    function setCollateralizationPaused(address, bool) external {}
    function setBorrowPaused(address, bool) external {}
}
