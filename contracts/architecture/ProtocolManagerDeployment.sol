// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

import { CentralRegistryLib } from "contracts/libraries/CentralRegistryLib.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";
import { ReentrancyGuard } from "contracts/libraries/ReentrancyGuardTransient.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { ICToken } from "contracts/interfaces/ICToken.sol";

/// @title Curvance Protocol Manager - Deployment.
/// @notice Atomic market deployment: lists a token pair, pauses minting,
///         and sets risk parameters in a single transaction. Includes a
///         one-time unpause allowance per deployed market.
/// @dev Standalone protocol manager for initial market setup. Does not
///      inherit the base ProtocolManager since it needs no period-limit
///      tracking or managed-address accounting.
///
///      Trust model: `owner` is expected to be an untrusted deployer hot
///      wallet. Its authority should be limited to deployment-phase setup
///      and any still-pending one-time unpause allowances.
///
///      Requires `hasMarketPermissions` in the CentralRegistry to call
///      `listTokens`, `setMintPaused`, and `updateTokenConfig` on the
///      MarketManagerIsolated.
///
///      Token flow during `deployMarket`:
///      1. Caller approves this contract for both underlying assets.
///      2. This contract pulls 77777 of each underlying from the caller.
///      3. This contract approves each cToken to spend its underlying.
///      4. `listTokens` internally calls `initializeDeposits(this)` which
///         pulls the approved underlying into the cToken.
///      5. Minting is paused on both tokens.
///      6. Token configs (risk parameters) are set for both tokens.
///      7. A one-time unpause allowance is recorded for this market.
///
///      The `unpauseMarket` function consumes the one-time allowance,
///      unpausing only the mint action on the deployed tokens. This
///      scopes the unpause exactly to what `deployMarket` paused and
///      prevents the contract from being used as a general unpause tool.
contract ProtocolManagerDeployment is ReentrancyGuard {
    /// CONSTANTS ///

    /// @notice The amount of underlying each cToken requires for
    ///         initialization to prevent rounding attacks.
    /// @dev Must match `_BASE_UNDERLYING_RESERVE` in BaseCToken.
    uint256 public constant BASE_UNDERLYING_RESERVE = 77777;

    /// @notice Curvance DAO hub.
    ICentralRegistry public immutable centralRegistry;

    /// @notice The address authorized to call deployment functions.
    address public immutable owner;

    /// STORAGE ///

    /// @notice One-time unpause allowance per deployed market.
    /// @dev Set to true by `deployMarket`, consumed by `unpauseMarket`.
    ///      Scopes unpause authority to markets this contract deployed.
    mapping(address => bool) public pendingUnpause;

    /// ERRORS ///

    error ProtocolManagerDeployment__Unauthorized();
    error ProtocolManagerDeployment__ParametersAreInvalid();
    error ProtocolManagerDeployment__NoPendingUnpause();

    /// CONSTRUCTOR ///

    /// @param cr The Curvance Central Registry address.
    /// @param _owner The authorized caller (deployer multisig).
    constructor(ICentralRegistry cr, address _owner) {
        CentralRegistryLib._isCentralRegistry(cr);
        if (_owner == address(0)) {
            revert ProtocolManagerDeployment__ParametersAreInvalid();
        }
        centralRegistry = cr;
        owner = _owner;
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Atomically deploys a market: lists tokens, pauses minting,
    ///         and configures risk parameters.
    /// @dev Caller must have approved this contract for 77777 of each
    ///      underlying asset before calling. The tokens are burned into
    ///      the cToken vaults to prevent rounding attacks.
    ///
    ///      After this call, the market exists with minting paused.
    ///      Call `unpauseMarket` to consume the one-time allowance and
    ///      open the market for deposits.
    ///
    /// @param marketManager The MarketManagerIsolated to deploy into.
    /// @param token0 The first cToken address to list.
    /// @param token1 The second cToken address to list.
    /// @param config0 Risk parameters for token0.
    /// @param config1 Risk parameters for token1.
    function deployMarket(
        address marketManager,
        address token0,
        address token1,
        MarketManagerIsolated.TokenConfig memory config0,
        MarketManagerIsolated.TokenConfig memory config1
    ) external nonReentrant {
        if (msg.sender != owner) {
            revert ProtocolManagerDeployment__Unauthorized();
        }

        // Validate config cToken addresses match the listed tokens.
        if (config0.cToken != token0 || config1.cToken != token1) {
            revert ProtocolManagerDeployment__ParametersAreInvalid();
        }

        if (!centralRegistry.isMarketManager(marketManager)) {
            revert ProtocolManagerDeployment__ParametersAreInvalid();
        }

        MarketManagerIsolated mm = MarketManagerIsolated(marketManager);

        // Pull underlying assets from the caller for initialization.
        // initializeDeposits requires 77777 of each underlying to be
        // available at this contract, approved to the cToken.
        address underlying0 = ICToken(token0).asset();
        address underlying1 = ICToken(token1).asset();

        // SafeTransferLib does not verify code existence —
        // calls to codeless addresses succeed silently, which would
        // defeat the dead-share reserve protection.
        if (underlying0.code.length == 0 || underlying1.code.length == 0) {
            revert ProtocolManagerDeployment__ParametersAreInvalid();
        }

        SafeTransferLib.safeTransferFrom(
            underlying0,
            msg.sender,
            address(this),
            BASE_UNDERLYING_RESERVE
        );
        SafeTransferLib.safeTransferFrom(
            underlying1,
            msg.sender,
            address(this),
            BASE_UNDERLYING_RESERVE
        );

        // Approve cTokens to pull underlying during initializeDeposits.
        SafeTransferLib.safeApprove(underlying0, token0, BASE_UNDERLYING_RESERVE);
        SafeTransferLib.safeApprove(underlying1, token1, BASE_UNDERLYING_RESERVE);

        // 1. List the token pair. This calls initializeDeposits on each
        //    cToken, pulling 77777 underlying from this contract.
        mm.listTokens(token0, token1);

        // 2. Pause minting on both tokens immediately.
        //    Since no depositors exist yet, mintPaused locks out all
        //    activity until the market is ready.
        mm.setMintPaused(token0, true);
        mm.setMintPaused(token1, true);

        // 3. Set risk parameters for both tokens.
        mm.updateTokenConfig(config0);
        mm.updateTokenConfig(config1);

        // 4. Grant one-time unpause allowance for this market.
        pendingUnpause[marketManager] = true;
    }

    /// @notice Unpauses minting on a market that was deployed by this
    ///         contract, consuming the one-time allowance.
    /// @dev Can only be called once per market. Only unpauses the mint
    ///      action — the same action that `deployMarket` paused. Does not
    ///      affect collateralization, borrow, or market-wide pause states.
    ///      Discovers tokens via `queryTokensListed()` on the market.
    /// @param marketManager The MarketManagerIsolated to unpause.
    function unpauseMarket(
        address marketManager
    ) external nonReentrant {
        if (msg.sender != owner) {
            revert ProtocolManagerDeployment__Unauthorized();
        }

        if (!pendingUnpause[marketManager]) {
            revert ProtocolManagerDeployment__NoPendingUnpause();
        }

        // Consume the one-time allowance.
        delete pendingUnpause[marketManager];

        // Discover and unpause all listed tokens.
        MarketManagerIsolated mm = MarketManagerIsolated(marketManager);
        address[] memory tokens = mm.queryTokensListed();
        uint256 numTokens = tokens.length;

        for (uint256 i; i < numTokens; ++i) {
            mm.setMintPaused(tokens[i], false);
        }
    }

    /// @notice Revokes a market's pending one-time unpause allowance.
    /// @dev Callable by the deployment owner or any address with market
    ///      permissions. This is idempotent and may be called even when no
    ///      allowance is pending.
    /// @param marketManager The MarketManagerIsolated whose allowance is cleared.
    function revokeUnpause(address marketManager) external nonReentrant {
        if (
            msg.sender != owner &&
            !centralRegistry.hasMarketPermissions(msg.sender)
        ) {
            revert ProtocolManagerDeployment__Unauthorized();
        }

        delete pendingUnpause[marketManager];
    }
}
