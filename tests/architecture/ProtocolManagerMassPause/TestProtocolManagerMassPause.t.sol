// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { ProtocolManagerMassPause } from "contracts/architecture/ProtocolManagerMassPause.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
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

        // Deploy mass pause manager with address(this) as owner.
        massPause = new ProtocolManagerMassPause(
            ICentralRegistry(address(centralRegistry)),
            address(this)
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

    function _assertExitsPaused(MarketManagerIsolated mm) internal view {
        assertEq(mm.liquidationPaused(), 2, "liquidation should be paused");
        assertEq(mm.redeemPaused(), 2, "redeem should be paused");
        assertEq(mm.transferPaused(), 2, "transfer should be paused");
    }

    function _assertExitsUnpaused(MarketManagerIsolated mm) internal view {
        assertEq(mm.liquidationPaused(), 1, "liquidation should be unpaused");
        assertEq(mm.redeemPaused(), 1, "redeem should be unpaused");
        assertEq(mm.transferPaused(), 1, "transfer should be unpaused");
    }

    function _assertEntryPaused(MarketManagerIsolated mm, address t0, address t1) internal view {
        (bool mintP0, bool collP0, bool borrowP0) = mm.actionsPaused(t0);
        assertTrue(mintP0, "t0 mint should be paused");
        assertTrue(collP0, "t0 collateralization should be paused");
        assertTrue(borrowP0, "t0 borrow should be paused");

        (bool mintP1, bool collP1, bool borrowP1) = mm.actionsPaused(t1);
        assertTrue(mintP1, "t1 mint should be paused");
        assertTrue(collP1, "t1 collateralization should be paused");
        assertTrue(borrowP1, "t1 borrow should be paused");
    }

    function _assertEntryUnpaused(MarketManagerIsolated mm, address t0, address t1) internal view {
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
    function _assertM1ExitsPaused() internal view {
        _assertExitsPaused(marketManagerIsolated);
    }
    function _assertM1ExitsUnpaused() internal view {
        _assertExitsUnpaused(marketManagerIsolated);
    }
    function _assertM1EntryPaused() internal view {
        _assertEntryPaused(marketManagerIsolated, address(borrowableCUSDC_MONAD), address(borrowableCWMON));
    }
    function _assertM1EntryUnpaused() internal view {
        _assertEntryUnpaused(marketManagerIsolated, address(borrowableCUSDC_MONAD), address(borrowableCWMON));
    }

    // Market 2 shorthand helpers.
    function _assertM2AllPaused() internal view {
        _assertAllPaused(marketManager2, address(borrowableCUSDC_2), address(borrowableCWMON_2));
    }
    function _assertM2AllUnpaused() internal view {
        _assertAllUnpaused(marketManager2, address(borrowableCUSDC_2), address(borrowableCWMON_2));
    }
    function _assertM2ExitsPaused() internal view {
        _assertExitsPaused(marketManager2);
    }
    function _assertM2ExitsUnpaused() internal view {
        _assertExitsUnpaused(marketManager2);
    }
    function _assertM2EntryPaused() internal view {
        _assertEntryPaused(marketManager2, address(borrowableCUSDC_2), address(borrowableCWMON_2));
    }
    function _assertM2EntryUnpaused() internal view {
        _assertEntryUnpaused(marketManager2, address(borrowableCUSDC_2), address(borrowableCWMON_2));
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

    /// ==================== pauseSupply / unpauseSupply ==================== ///

    function test_pauseSupply_onlyPausesEntry() public {
        massPause.pauseSupply(_singleMarketArray());
        _assertM1EntryPaused();
        _assertM1ExitsUnpaused();
    }

    function test_unpauseSupply() public {
        massPause.pauseSupply(_singleMarketArray());
        massPause.unpauseSupply(_singleMarketArray());
        _assertM1EntryUnpaused();
    }

    function test_pauseSupply_autoDiscover() public {
        massPause.pauseSupply(_emptyArray());
        _assertM1EntryPaused();
        _assertM1ExitsUnpaused();
        _assertM2EntryPaused();
        _assertM2ExitsUnpaused();
    }

    /// ==================== pauseRedemption / unpauseRedemption ==================== ///

    function test_pauseRedemption_onlyPausesExits() public {
        massPause.pauseRedemption(_singleMarketArray());
        _assertM1ExitsPaused();
        _assertM1EntryUnpaused();
    }

    function test_unpauseRedemption() public {
        massPause.pauseRedemption(_singleMarketArray());
        massPause.unpauseRedemption(_singleMarketArray());
        _assertM1ExitsUnpaused();
    }

    function test_pauseRedemption_autoDiscover() public {
        massPause.pauseRedemption(_emptyArray());
        _assertM1ExitsPaused();
        _assertM1EntryUnpaused();
        _assertM2ExitsPaused();
        _assertM2EntryUnpaused();
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

    function test_pauseSupply_multipleMarkets() public {
        massPause.pauseSupply(_bothMarketsArray());
        _assertM1EntryPaused();
        _assertM1ExitsUnpaused();
        _assertM2EntryPaused();
        _assertM2ExitsUnpaused();
    }

    function test_pauseRedemption_multipleMarkets() public {
        massPause.pauseRedemption(_bothMarketsArray());
        _assertM1ExitsPaused();
        _assertM1EntryUnpaused();
        _assertM2ExitsPaused();
        _assertM2EntryUnpaused();
    }

    function test_pauseAll_singleMarket_doesNotAffectOther() public {
        massPause.pauseAll(_singleMarketArray());
        _assertM1AllPaused();
        // Market 2 should be untouched.
        _assertM2AllUnpaused();
    }

    /// ==================== COMPOSABILITY ==================== ///

    function test_pauseSupplyThenRedemption_equalsAll() public {
        massPause.pauseSupply(_singleMarketArray());
        massPause.pauseRedemption(_singleMarketArray());
        _assertM1AllPaused();
    }

    function test_unpauseSupplyOnly_afterPauseAll() public {
        massPause.pauseAll(_singleMarketArray());
        _assertM1AllPaused();

        massPause.unpauseSupply(_singleMarketArray());
        _assertM1EntryUnpaused();
        _assertM1ExitsPaused();
    }

    function test_unpauseRedemptionOnly_afterPauseAll() public {
        massPause.pauseAll(_singleMarketArray());
        _assertM1AllPaused();

        massPause.unpauseRedemption(_singleMarketArray());
        _assertM1ExitsUnpaused();
        _assertM1EntryPaused();
    }

    function test_pauseAll_unpauseSupply_unpauseRedemption_fullRecovery()
        public
    {
        massPause.pauseAll(_singleMarketArray());
        _assertM1AllPaused();

        massPause.unpauseSupply(_singleMarketArray());
        massPause.unpauseRedemption(_singleMarketArray());
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

    function test_pauseSupply_revertsUnauthorized() public {
        address unauthorized = address(0xdead);
        vm.prank(unauthorized);
        vm.expectRevert(
            ProtocolManagerMassPause
                .ProtocolManagerMassPause__Unauthorized
                .selector
        );
        massPause.pauseSupply(_singleMarketArray());
    }

    function test_unpauseSupply_revertsUnauthorized() public {
        address unauthorized = address(0xdead);
        vm.prank(unauthorized);
        vm.expectRevert(
            ProtocolManagerMassPause
                .ProtocolManagerMassPause__Unauthorized
                .selector
        );
        massPause.unpauseSupply(_singleMarketArray());
    }

    function test_pauseRedemption_revertsUnauthorized() public {
        address unauthorized = address(0xdead);
        vm.prank(unauthorized);
        vm.expectRevert(
            ProtocolManagerMassPause
                .ProtocolManagerMassPause__Unauthorized
                .selector
        );
        massPause.pauseRedemption(_singleMarketArray());
    }

    function test_unpauseRedemption_revertsUnauthorized() public {
        address unauthorized = address(0xdead);
        vm.prank(unauthorized);
        vm.expectRevert(
            ProtocolManagerMassPause
                .ProtocolManagerMassPause__Unauthorized
                .selector
        );
        massPause.unpauseRedemption(_singleMarketArray());
    }

    function test_pauseAll_revertsWithoutMarketPermissions() public {
        centralRegistry.removeMarketPermissions(address(massPause));

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__Unauthorized.selector
        );
        massPause.pauseAll(_singleMarketArray());
    }

    /// ==================== EVENTS ==================== ///

    function test_pauseAll_emitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit ProtocolManagerMassPause.MassPauseExecuted("All", true, 1);
        massPause.pauseAll(_singleMarketArray());
    }

    function test_unpauseAll_emitsEvent() public {
        massPause.pauseAll(_singleMarketArray());

        vm.expectEmit(true, true, true, true);
        emit ProtocolManagerMassPause.MassPauseExecuted("All", false, 1);
        massPause.unpauseAll(_singleMarketArray());
    }

    function test_pauseSupply_emitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit ProtocolManagerMassPause.MassPauseExecuted("Supply", true, 1);
        massPause.pauseSupply(_singleMarketArray());
    }

    function test_unpauseSupply_emitsEvent() public {
        massPause.pauseSupply(_singleMarketArray());

        vm.expectEmit(true, true, true, true);
        emit ProtocolManagerMassPause.MassPauseExecuted("Supply", false, 1);
        massPause.unpauseSupply(_singleMarketArray());
    }

    function test_pauseRedemption_emitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit ProtocolManagerMassPause.MassPauseExecuted("Redemption", true, 1);
        massPause.pauseRedemption(_singleMarketArray());
    }

    function test_unpauseRedemption_emitsEvent() public {
        massPause.pauseRedemption(_singleMarketArray());

        vm.expectEmit(true, true, true, true);
        emit ProtocolManagerMassPause.MassPauseExecuted(
            "Redemption",
            false,
            1
        );
        massPause.unpauseRedemption(_singleMarketArray());
    }

    function test_pauseAll_autoDiscover_emitsCorrectCount() public {
        // Auto-discover should find 2 markets (m1 + m2).
        vm.expectEmit(true, true, true, true);
        emit ProtocolManagerMassPause.MassPauseExecuted("All", true, 2);
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

    function test_pauseSupply_idempotent() public {
        massPause.pauseSupply(_singleMarketArray());
        massPause.pauseSupply(_singleMarketArray());
        _assertM1EntryPaused();
    }

    function test_pauseRedemption_idempotent() public {
        massPause.pauseRedemption(_singleMarketArray());
        massPause.pauseRedemption(_singleMarketArray());
        _assertM1ExitsPaused();
    }

    /// ==================== INTEGRATION ==================== ///

    function test_pauseSupply_mintActuallyReverts() public {
        massPause.pauseSupply(_singleMarketArray());

        address user = address(0xBEEF);
        deal(WMON_ADDRESS, user, 1e18);

        vm.startPrank(user);
        IERC20(WMON_ADDRESS).approve(address(borrowableCWMON), 1e18);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        borrowableCWMON.deposit(1e18, user);
        vm.stopPrank();
    }

    function test_pauseRedemption_mintStillWorks() public {
        massPause.pauseRedemption(_singleMarketArray());

        // Minting should still work when only redemption is paused.
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
    }

    function test_autoDiscover_returnsAllRegisteredMarkets() public view {
        address[] memory registered = centralRegistry.marketManagers();
        assertEq(registered.length, 2);
        assertEq(registered[0], address(marketManagerIsolated));
        assertEq(registered[1], address(marketManager2));
    }
}
