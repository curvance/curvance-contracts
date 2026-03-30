// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { ProtocolManagerMassPause } from "contracts/architecture/ProtocolManagerMassPause.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
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

        deal(_USDC_ADDRESS, address(this), 77777);
        IERC20(_USDC_ADDRESS).approve(
            address(borrowableCUSDC_MONAD),
            type(uint256).max
        );

        deal(WMON_ADDRESS, address(this), 77777);
        IERC20(WMON_ADDRESS).approve(
            address(borrowableCWMON),
            type(uint256).max
        );

        // List tokens and set configs.
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

        // Deploy mass pause manager with address(this) as owner.
        massPause = new ProtocolManagerMassPause(
            ICentralRegistry(address(centralRegistry)),
            address(this)
        );

        // Grant market permissions.
        centralRegistry.addMarketPermissions(address(massPause));
    }

    /// HELPER FUNCTIONS ///

    function _assertAllPaused() internal view {
        // Market-wide pauses.
        assertEq(marketManagerIsolated.liquidationPaused(), 2, "liquidation should be paused");
        assertEq(marketManagerIsolated.redeemPaused(), 2, "redeem should be paused");
        assertEq(marketManagerIsolated.transferPaused(), 2, "transfer should be paused");

        // Token-level pauses.
        (bool mintPaused0, bool collPaused0, bool borrowPaused0) =
            marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertTrue(mintPaused0, "USDC mint should be paused");
        assertTrue(collPaused0, "USDC collateralization should be paused");
        assertTrue(borrowPaused0, "USDC borrow should be paused");

        (bool mintPaused1, bool collPaused1, bool borrowPaused1) =
            marketManagerIsolated.actionsPaused(address(borrowableCWMON));
        assertTrue(mintPaused1, "WMON mint should be paused");
        assertTrue(collPaused1, "WMON collateralization should be paused");
        assertTrue(borrowPaused1, "WMON borrow should be paused");
    }

    function _assertAllUnpaused() internal view {
        // Market-wide pauses.
        assertEq(marketManagerIsolated.liquidationPaused(), 1, "liquidation should be unpaused");
        assertEq(marketManagerIsolated.redeemPaused(), 1, "redeem should be unpaused");
        assertEq(marketManagerIsolated.transferPaused(), 1, "transfer should be unpaused");

        // Token-level pauses.
        (bool mintPaused0, bool collPaused0, bool borrowPaused0) =
            marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertFalse(mintPaused0, "USDC mint should be unpaused");
        assertFalse(collPaused0, "USDC collateralization should be unpaused");
        assertFalse(borrowPaused0, "USDC borrow should be unpaused");

        (bool mintPaused1, bool collPaused1, bool borrowPaused1) =
            marketManagerIsolated.actionsPaused(address(borrowableCWMON));
        assertFalse(mintPaused1, "WMON mint should be unpaused");
        assertFalse(collPaused1, "WMON collateralization should be unpaused");
        assertFalse(borrowPaused1, "WMON borrow should be unpaused");
    }

    function _assertExitsPaused() internal view {
        assertEq(marketManagerIsolated.liquidationPaused(), 2, "liquidation should be paused");
        assertEq(marketManagerIsolated.redeemPaused(), 2, "redeem should be paused");
        assertEq(marketManagerIsolated.transferPaused(), 2, "transfer should be paused");
    }

    function _assertExitsUnpaused() internal view {
        assertEq(marketManagerIsolated.liquidationPaused(), 1, "liquidation should be unpaused");
        assertEq(marketManagerIsolated.redeemPaused(), 1, "redeem should be unpaused");
        assertEq(marketManagerIsolated.transferPaused(), 1, "transfer should be unpaused");
    }

    function _assertEntryPaused() internal view {
        (bool mintPaused0, bool collPaused0, bool borrowPaused0) =
            marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertTrue(mintPaused0, "USDC mint should be paused");
        assertTrue(collPaused0, "USDC collateralization should be paused");
        assertTrue(borrowPaused0, "USDC borrow should be paused");

        (bool mintPaused1, bool collPaused1, bool borrowPaused1) =
            marketManagerIsolated.actionsPaused(address(borrowableCWMON));
        assertTrue(mintPaused1, "WMON mint should be paused");
        assertTrue(collPaused1, "WMON collateralization should be paused");
        assertTrue(borrowPaused1, "WMON borrow should be paused");
    }

    function _assertEntryUnpaused() internal view {
        (bool mintPaused0, bool collPaused0, bool borrowPaused0) =
            marketManagerIsolated.actionsPaused(address(borrowableCUSDC_MONAD));
        assertFalse(mintPaused0, "USDC mint should be unpaused");
        assertFalse(collPaused0, "USDC collateralization should be unpaused");
        assertFalse(borrowPaused0, "USDC borrow should be unpaused");

        (bool mintPaused1, bool collPaused1, bool borrowPaused1) =
            marketManagerIsolated.actionsPaused(address(borrowableCWMON));
        assertFalse(mintPaused1, "WMON mint should be unpaused");
        assertFalse(collPaused1, "WMON collateralization should be unpaused");
        assertFalse(borrowPaused1, "WMON borrow should be unpaused");
    }

    function _singleMarketArray()
        internal
        view
        returns (address[] memory markets)
    {
        markets = new address[](1);
        markets[0] = address(marketManagerIsolated);
    }

    function _emptyArray()
        internal
        pure
        returns (address[] memory markets)
    {
        markets = new address[](0);
    }

    /// TESTS - pauseAll / unpauseAll ///

    function test_pauseAll_explicitMarkets() public {
        massPause.pauseAll(_singleMarketArray());
        _assertAllPaused();
    }

    function test_pauseAll_autoDiscover() public {
        massPause.pauseAll(_emptyArray());
        _assertAllPaused();
    }

    function test_unpauseAll_explicitMarkets() public {
        // Pause first.
        massPause.pauseAll(_singleMarketArray());
        _assertAllPaused();

        // Unpause.
        massPause.unpauseAll(_singleMarketArray());
        _assertAllUnpaused();
    }

    function test_unpauseAll_autoDiscover() public {
        massPause.pauseAll(_emptyArray());
        _assertAllPaused();

        massPause.unpauseAll(_emptyArray());
        _assertAllUnpaused();
    }

    /// TESTS - pauseSupply / unpauseSupply ///

    function test_pauseSupply_onlyPausesEntry() public {
        massPause.pauseSupply(_singleMarketArray());

        // Entry should be paused.
        _assertEntryPaused();
        // Exits should remain unpaused.
        _assertExitsUnpaused();
    }

    function test_unpauseSupply() public {
        massPause.pauseSupply(_singleMarketArray());
        _assertEntryPaused();

        massPause.unpauseSupply(_singleMarketArray());
        _assertEntryUnpaused();
    }

    function test_pauseSupply_autoDiscover() public {
        massPause.pauseSupply(_emptyArray());
        _assertEntryPaused();
        _assertExitsUnpaused();
    }

    /// TESTS - pauseRedemption / unpauseRedemption ///

    function test_pauseRedemption_onlyPausesExits() public {
        massPause.pauseRedemption(_singleMarketArray());

        // Exits should be paused.
        _assertExitsPaused();
        // Entry should remain unpaused.
        _assertEntryUnpaused();
    }

    function test_unpauseRedemption() public {
        massPause.pauseRedemption(_singleMarketArray());
        _assertExitsPaused();

        massPause.unpauseRedemption(_singleMarketArray());
        _assertExitsUnpaused();
    }

    function test_pauseRedemption_autoDiscover() public {
        massPause.pauseRedemption(_emptyArray());
        _assertExitsPaused();
        _assertEntryUnpaused();
    }

    /// TESTS - Composability ///

    function test_pauseSupplyThenRedemption_equalsAll() public {
        massPause.pauseSupply(_singleMarketArray());
        massPause.pauseRedemption(_singleMarketArray());
        _assertAllPaused();
    }

    function test_unpauseSupplyOnly_afterPauseAll() public {
        massPause.pauseAll(_singleMarketArray());
        _assertAllPaused();

        // Unpause only supply — exits remain paused.
        massPause.unpauseSupply(_singleMarketArray());
        _assertEntryUnpaused();
        _assertExitsPaused();
    }

    function test_unpauseRedemptionOnly_afterPauseAll() public {
        massPause.pauseAll(_singleMarketArray());
        _assertAllPaused();

        // Unpause only exits — supply remains paused.
        massPause.unpauseRedemption(_singleMarketArray());
        _assertExitsUnpaused();
        _assertEntryPaused();
    }

    /// TESTS - Authorization ///

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

    /// TESTS - Events ///

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

    /// TESTS - Idempotency ///

    function test_pauseAll_idempotent() public {
        massPause.pauseAll(_singleMarketArray());
        _assertAllPaused();

        // Pausing again should not revert (1→2 or 2→2 SSTORE).
        massPause.pauseAll(_singleMarketArray());
        _assertAllPaused();
    }

    function test_unpauseAll_idempotent() public {
        // Unpause when already unpaused should not revert.
        massPause.unpauseAll(_singleMarketArray());
        _assertAllUnpaused();
    }
}
