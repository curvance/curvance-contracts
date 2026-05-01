// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

import { CentralRegistryLib } from "contracts/libraries/CentralRegistryLib.sol";
import { ReentrancyGuard } from "contracts/libraries/ReentrancyGuardTransient.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

/// @title Curvance Protocol Manager - Mass Pause.
/// @notice Emergency pause/unpause across all markets in a single
///         transaction with three pause scopes.
/// @dev Standalone protocol manager for emergency operations. Does not
///      inherit the base ProtocolManager since it needs no period-limit
///      tracking or managed-address accounting.
///
///      Trust model: `owner` is expected to be the Emergency Council,
///      which has elevated and market permissions in the CentralRegistry.
///
///      Requires `hasMarketPermissions` in the CentralRegistry to call
///      pause/unpause functions on the MarketManagerIsolated contracts.
///
///      Three scopes:
///      - All:          Full lockdown / full recovery (all 6 action types).
///      - Token-level entry: Mint + Collateralization + Borrow, applied per
///                           listed token.
///      - Market-wide exit:  Liquidation + Redeem + Transfer, applied once
///                           per market.
///
///      If an empty `markets` array is passed, the contract auto-discovers
///      all registered markets from `centralRegistry.marketManagers()`.
///
///      All setter calls are wrapped in try/catch to prevent one
///      misbehaving market from blocking the entire batch. Failed markets
///      emit {MarketPauseFailed} for operator monitoring.
///
///      Gas: Per market with 2 tokens, worst case is ~9 SSTOREs at 5,000
///      gas each (warm nonzero→nonzero) + ~1,800 try/catch overhead
///      ≈ 50-65k per market. Comfortably handles 250+ markets within
///      a 30M gas limit.
contract ProtocolManagerMassPause is ReentrancyGuard {
    /// CONSTANTS ///

    /// @notice Curvance DAO hub.
    ICentralRegistry public immutable centralRegistry;

    /// @notice The address authorized to call pause functions.
    address public immutable owner;

    /// ERRORS ///

    error ProtocolManagerMassPause__Unauthorized();

    /// EVENTS ///

    event MassPauseExecuted(
        string scope,
        bool paused,
        uint256 marketsAttempted,
        uint256 marketsFailed
    );

    /// @notice Emitted when any pause/unpause call fails for a market.
    /// @dev Indicates a market is in an unexpected state — operator should
    ///      investigate. Remaining markets in the batch are unaffected.
    event MarketPauseFailed(address indexed market);

    /// CONSTRUCTOR ///

    /// @param cr The Curvance Central Registry address.
    /// @param _owner The authorized caller (operations multisig).
    constructor(ICentralRegistry cr, address _owner) {
        CentralRegistryLib._isCentralRegistry(cr);
        if (_owner == address(0)) {
            revert ProtocolManagerMassPause__Unauthorized();
        }
        centralRegistry = cr;
        owner = _owner;
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Pauses all 6 action types across the target markets.
    /// @dev Full emergency lockdown. No deposits, borrows, redemptions,
    ///      transfers, collateralization, or liquidations.
    ///      Individual market failures are caught and logged — they do not
    ///      block other markets from being paused.
    /// @param markets The markets to pause. Empty array = all markets.
    function pauseAll(address[] calldata markets) external nonReentrant {
        _checkOwner();
        address[] memory resolved = _resolveMarkets(markets);
        uint256 numMarkets = resolved.length;
        uint256 marketsFailed;

        for (uint256 i; i < numMarkets; ++i) {
            MarketManagerIsolated mm = MarketManagerIsolated(resolved[i]);
            uint256 failed = _setMarketWideExitPauses(mm, true)
                + _setTokenLevelEntryPauses(mm, true);

            if (failed > 0) {
                emit MarketPauseFailed(resolved[i]);
                ++marketsFailed;
            }
        }

        emit MassPauseExecuted("All", true, numMarkets, marketsFailed);
    }

    /// @notice Unpauses all 6 action types across the target markets.
    /// @dev Full recovery from emergency lockdown.
    ///      WARNING: This clears ALL pause flags regardless of who set them.
    ///      If other actors (emergencyCouncil, ProtocolManagerDeployment,
    ///      base ProtocolManager) have individually paused specific tokens,
    ///      those pauses are also cleared. After a mass unpause, verify
    ///      whether any ProtocolManagerDeployment.pendingUnpause flags are
    ///      still active and re-apply individual pauses as needed.
    /// @param markets The markets to unpause. Empty array = all markets.
    function unpauseAll(address[] calldata markets) external nonReentrant {
        _checkOwner();
        address[] memory resolved = _resolveMarkets(markets);
        uint256 numMarkets = resolved.length;
        uint256 marketsFailed;

        for (uint256 i; i < numMarkets; ++i) {
            MarketManagerIsolated mm = MarketManagerIsolated(resolved[i]);
            uint256 failed = _setMarketWideExitPauses(mm, false)
                + _setTokenLevelEntryPauses(mm, false);

            if (failed > 0) {
                emit MarketPauseFailed(resolved[i]);
                ++marketsFailed;
            }
        }

        emit MassPauseExecuted("All", false, numMarkets, marketsFailed);
    }

    /// @notice Pauses token-level entry actions: Mint, Collateralization, Borrow.
    /// @dev Applies to every listed token in each target market. Market-wide
    ///      exit pause flags are unaffected.
    /// @param markets The markets to pause token-level entry actions on. Empty
    ///                = all markets.
    function pauseTokenLevelEntryActions(
        address[] calldata markets
    ) external nonReentrant {
        _checkOwner();
        address[] memory resolved = _resolveMarkets(markets);
        uint256 numMarkets = resolved.length;
        uint256 marketsFailed;

        for (uint256 i; i < numMarkets; ++i) {
            uint256 failed = _setTokenLevelEntryPauses(
                MarketManagerIsolated(resolved[i]),
                true
            );

            if (failed > 0) {
                emit MarketPauseFailed(resolved[i]);
                ++marketsFailed;
            }
        }

        emit MassPauseExecuted("TokenLevelEntry", true, numMarkets, marketsFailed);
    }

    /// @notice Unpauses token-level entry actions: Mint, Collateralization, Borrow.
    /// @dev WARNING: Clears token-level entry pauses regardless of origin. See
    ///      `unpauseAll` documentation for individual-pause interaction.
    /// @param markets The markets to unpause token-level entry actions on.
    ///                Empty = all markets.
    function unpauseTokenLevelEntryActions(
        address[] calldata markets
    ) external nonReentrant {
        _checkOwner();
        address[] memory resolved = _resolveMarkets(markets);
        uint256 numMarkets = resolved.length;
        uint256 marketsFailed;

        for (uint256 i; i < numMarkets; ++i) {
            uint256 failed = _setTokenLevelEntryPauses(
                MarketManagerIsolated(resolved[i]),
                false
            );

            if (failed > 0) {
                emit MarketPauseFailed(resolved[i]);
                ++marketsFailed;
            }
        }

        emit MassPauseExecuted("TokenLevelEntry", false, numMarkets, marketsFailed);
    }

    /// @notice Pauses market-wide exit actions: Liquidation, Redeem, Transfer.
    /// @dev Applies once per target market. Token-level entry pause flags are
    ///      unaffected.
    /// @param markets The markets to pause market-wide exit actions on. Empty
    ///                = all markets.
    function pauseMarketWideExitActions(
        address[] calldata markets
    ) external nonReentrant {
        _checkOwner();
        address[] memory resolved = _resolveMarkets(markets);
        uint256 numMarkets = resolved.length;
        uint256 marketsFailed;

        for (uint256 i; i < numMarkets; ++i) {
            uint256 failed = _setMarketWideExitPauses(
                MarketManagerIsolated(resolved[i]),
                true
            );

            if (failed > 0) {
                emit MarketPauseFailed(resolved[i]);
                ++marketsFailed;
            }
        }

        emit MassPauseExecuted("MarketWideExit", true, numMarkets, marketsFailed);
    }

    /// @notice Unpauses market-wide exit actions: Liquidation, Redeem, Transfer.
    /// @dev WARNING: Clears market-wide exit pauses regardless of origin. See
    ///      `unpauseAll` documentation for individual-pause interaction.
    /// @param markets The markets to unpause market-wide exit actions on.
    ///                Empty = all markets.
    function unpauseMarketWideExitActions(
        address[] calldata markets
    ) external nonReentrant {
        _checkOwner();
        address[] memory resolved = _resolveMarkets(markets);
        uint256 numMarkets = resolved.length;
        uint256 marketsFailed;

        for (uint256 i; i < numMarkets; ++i) {
            uint256 failed = _setMarketWideExitPauses(
                MarketManagerIsolated(resolved[i]),
                false
            );

            if (failed > 0) {
                emit MarketPauseFailed(resolved[i]);
                ++marketsFailed;
            }
        }

        emit MassPauseExecuted("MarketWideExit", false, numMarkets, marketsFailed);
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Resolves the target markets array.
    /// @dev If `markets` is empty, fetches all registered markets from
    ///      the CentralRegistry. Otherwise returns a memory copy of the
    ///      calldata array.
    /// @param markets The caller-provided markets array.
    /// @return resolved The resolved markets to operate on.
    function _resolveMarkets(
        address[] calldata markets
    ) internal view returns (address[] memory resolved) {
        if (markets.length == 0) {
            resolved = centralRegistry.marketManagers();
        } else {
            resolved = markets;
        }
    }

    /// @notice Sets market-wide exit pauses: Liquidation, Redeem, Transfer.
    /// @dev Each call is independently try/caught. Returns the number of
    ///      failed calls so the caller can emit failure events.
    /// @param mm The MarketManagerIsolated to configure.
    /// @param state True to pause, false to unpause.
    /// @return failed The number of setter calls that reverted.
    function _setMarketWideExitPauses(
        MarketManagerIsolated mm,
        bool state
    ) internal returns (uint256 failed) {
        // Solidity's try/catch does not catch the compiler-generated
        // EXTCODESIZE revert for no-code addresses. Guard explicitly.
        if (address(mm).code.length == 0) return 3;

        try mm.setLiquidationPaused(state) {} catch { ++failed; }
        try mm.setRedeemPaused(state) {} catch { ++failed; }
        try mm.setTransferPaused(state) {} catch { ++failed; }
    }

    /// @notice Sets token-level entry pauses: Mint, Collateralization, Borrow
    ///         for all tokens listed in the market.
    /// @dev Auto-discovers tokens via `queryTokensListed()`. Each call is
    ///      independently try/caught. If token discovery itself fails, the
    ///      entire token-level entry pause for this market is skipped.
    /// @param mm The MarketManagerIsolated to configure.
    /// @param state True to pause, false to unpause.
    /// @return failed The number of setter calls that reverted.
    function _setTokenLevelEntryPauses(
        MarketManagerIsolated mm,
        bool state
    ) internal returns (uint256 failed) {
        // Solidity's try/catch does not catch the compiler-generated
        // EXTCODESIZE revert for no-code addresses. Guard explicitly.
        if (address(mm).code.length == 0) return 1;

        address[] memory tokens;
        try mm.queryTokensListed() returns (address[] memory t) {
            tokens = t;
        } catch {
            return 1;
        }

        uint256 numTokens = tokens.length;
        for (uint256 j; j < numTokens; ++j) {
            try mm.setMintPaused(tokens[j], state) {} catch { ++failed; }
            try mm.setCollateralizationPaused(tokens[j], state) {} catch { ++failed; }
            try mm.setBorrowPaused(tokens[j], state) {} catch { ++failed; }
        }
    }

    /// @notice Validates the caller is the authorized owner.
    function _checkOwner() internal view {
        if (msg.sender != owner) {
            revert ProtocolManagerMassPause__Unauthorized();
        }
    }
}
