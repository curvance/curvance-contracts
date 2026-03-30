// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

import { CentralRegistryLib } from "contracts/libraries/CentralRegistryLib.sol";
import { ReentrancyGuard } from "contracts/libraries/ReentrancyGuardTransient.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

/// @title Curvance Protocol Manager - Mass Pause.
/// @notice Emergency pause/unpause across all markets in a single
///         transaction with three operational postures.
/// @dev Standalone protocol manager for emergency operations. Does not
///      inherit the base ProtocolManager since it needs no period-limit
///      tracking or managed-address accounting.
///
///      Requires `hasMarketPermissions` in the CentralRegistry to call
///      pause/unpause functions on the MarketManagerIsolated contracts.
///
///      Three postures:
///      - All:        Full lockdown / full recovery (all 6 action types).
///      - Supply:     Mint + Collateralization + Borrow (token-level).
///                    Stops new risk entering while exits + liquidations
///                    continue clearing positions.
///      - Redemption: Redeem + Transfer + Liquidation (market-wide).
///                    Locks all value-exit vectors during price
///                    manipulation threats or investigation.
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
        string posture,
        bool paused,
        uint256 marketsAttempted
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

        for (uint256 i; i < numMarkets; ++i) {
            MarketManagerIsolated mm = MarketManagerIsolated(resolved[i]);
            uint256 failed = _setExitPauses(mm, true)
                + _setEntryPauses(mm, true);

            if (failed > 0) {
                emit MarketPauseFailed(resolved[i]);
            }
        }

        emit MassPauseExecuted("All", true, numMarkets);
    }

    /// @notice Unpauses all 6 action types across the target markets.
    /// @dev Full recovery from emergency lockdown.
    /// @param markets The markets to unpause. Empty array = all markets.
    function unpauseAll(address[] calldata markets) external nonReentrant {
        _checkOwner();
        address[] memory resolved = _resolveMarkets(markets);
        uint256 numMarkets = resolved.length;

        for (uint256 i; i < numMarkets; ++i) {
            MarketManagerIsolated mm = MarketManagerIsolated(resolved[i]);
            uint256 failed = _setExitPauses(mm, false)
                + _setEntryPauses(mm, false);

            if (failed > 0) {
                emit MarketPauseFailed(resolved[i]);
            }
        }

        emit MassPauseExecuted("All", false, numMarkets);
    }

    /// @notice Pauses supply-side actions: Mint, Collateralization, Borrow.
    /// @dev Stops new risk from entering the system. Exits and liquidations
    ///      remain operational so positions can still unwind.
    /// @param markets The markets to pause supply on. Empty = all markets.
    function pauseSupply(address[] calldata markets) external nonReentrant {
        _checkOwner();
        address[] memory resolved = _resolveMarkets(markets);
        uint256 numMarkets = resolved.length;

        for (uint256 i; i < numMarkets; ++i) {
            uint256 failed = _setEntryPauses(
                MarketManagerIsolated(resolved[i]),
                true
            );

            if (failed > 0) {
                emit MarketPauseFailed(resolved[i]);
            }
        }

        emit MassPauseExecuted("Supply", true, numMarkets);
    }

    /// @notice Unpauses supply-side actions: Mint, Collateralization, Borrow.
    /// @param markets The markets to unpause supply on. Empty = all markets.
    function unpauseSupply(address[] calldata markets) external nonReentrant {
        _checkOwner();
        address[] memory resolved = _resolveMarkets(markets);
        uint256 numMarkets = resolved.length;

        for (uint256 i; i < numMarkets; ++i) {
            uint256 failed = _setEntryPauses(
                MarketManagerIsolated(resolved[i]),
                false
            );

            if (failed > 0) {
                emit MarketPauseFailed(resolved[i]);
            }
        }

        emit MassPauseExecuted("Supply", false, numMarkets);
    }

    /// @notice Pauses all value-exit vectors: Redeem, Transfer, Liquidation.
    /// @dev Use during price manipulation threats or active investigation.
    ///      No value can leave the protocol while this is active.
    /// @param markets The markets to pause exits on. Empty = all markets.
    function pauseRedemption(address[] calldata markets) external nonReentrant {
        _checkOwner();
        address[] memory resolved = _resolveMarkets(markets);
        uint256 numMarkets = resolved.length;

        for (uint256 i; i < numMarkets; ++i) {
            uint256 failed = _setExitPauses(
                MarketManagerIsolated(resolved[i]),
                true
            );

            if (failed > 0) {
                emit MarketPauseFailed(resolved[i]);
            }
        }

        emit MassPauseExecuted("Redemption", true, numMarkets);
    }

    /// @notice Unpauses all value-exit vectors: Redeem, Transfer, Liquidation.
    /// @param markets The markets to unpause exits on. Empty = all markets.
    function unpauseRedemption(address[] calldata markets) external nonReentrant {
        _checkOwner();
        address[] memory resolved = _resolveMarkets(markets);
        uint256 numMarkets = resolved.length;

        for (uint256 i; i < numMarkets; ++i) {
            uint256 failed = _setExitPauses(
                MarketManagerIsolated(resolved[i]),
                false
            );

            if (failed > 0) {
                emit MarketPauseFailed(resolved[i]);
            }
        }

        emit MassPauseExecuted("Redemption", false, numMarkets);
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
    function _setExitPauses(
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
    ///      entire entry pause for this market is skipped.
    /// @param mm The MarketManagerIsolated to configure.
    /// @param state True to pause, false to unpause.
    /// @return failed The number of setter calls that reverted.
    function _setEntryPauses(
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
