// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { BaseZapper, SwapperLib, CommonLib, IPToken, SafeTransferLib, ICentralRegistry } from "contracts/plugins/BaseZapper.sol";

import { CurveLib } from "contracts/libraries/CurveLib.sol";
import { BalancerLib } from "contracts/libraries/BalancerLib.sol";
import { VelodromeLib } from "contracts/libraries/VelodromeLib.sol";
import { PendleLib } from "contracts/libraries/PendleLib.sol";

import { IVeloPair } from "contracts/interfaces/external/velodrome/IVeloPair.sol";
import { IPToken } from "contracts/interfaces/IPToken.sol";

contract ComplexZapper is BaseZapper {
    /// TYPES ///

    /// @param inputToken Address of input token to Zap from.
    /// @param inputAmount The amount of `inputToken` to Zap.
    /// @param outputToken Address of token Zapped into.
    /// @param minimumOut The minimum amount of `outputToken` acceptable
    ///                   from the Zap.
    /// @param depositAsWrappedNative Used only if `inputToken` is a chain's
    ///                               native token, dictates whether native
    ///                               should be deposited as native or wrapped
    ///                               native.
    struct ZapAction {
        address inputToken;
        uint256 inputAmount;
        address outputToken;
        uint256 minimumOut;
        bool depositAsWrappedNative;
    }

    /// @param balancerVault The Balancer vault address.
    /// @param balancerPoolId The BPT pool ID.
    /// @param underlyingTokens The underlying token addresses of the BPT.
    struct BalancerData {
        address balancerVault;
        bytes32 balancerPoolId;
        address[] underlyingTokens;
    }

    /// ERRORS ///

    error ComplexZapper__ExecutionError();
    error ComplexZapper__SlippageError();

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        address wrappedNative_
    ) BaseZapper(centralRegistry_, wrappedNative_) {}

    /// EXTERNAL FUNCTIONS ///

    /// @notice Swaps then deposits `zapAction.inputToken` into Curve lp token,
    ///         and enters into Curvance position.
    /// @dev Requires plugin approval for collateralization.
    /// @param pToken The Curvance pToken address.
    /// @param zapAction Zap instruction data to execute the Zap.
    /// @param swapActions Array of swap instruction data to execute the Zap.
    /// @param lpMinter The minter address of the Curve lp token.
    /// @param tokens The underlying coins of the Curve lp token.
    /// @param expectedShares The minimum expected amount of shares received
    ///                       from depositing `amount` of `swapActions.outputToken`
    ///                       into `pToken` position.
    /// @param collateralize Whether the zapped position deposit should be
    ///                      collateralized afterwards.
    /// @param recipient Address that should receive Zapped deposit.
    /// @return outAmount The output amount received from Zapping.
    function enterCurve(
        address pToken,
        ZapAction calldata zapAction,
        SwapperLib.Swap[] calldata swapActions,
        address lpMinter,
        address[] calldata tokens,
        uint256 expectedShares,
        bool collateralize,
        address recipient
    ) external payable nonReentrant returns (uint256 outAmount) {
        // Swap input token for underlyings.
        _swapForUnderlyings(
            zapAction.inputToken,
            zapAction.inputAmount,
            swapActions,
            zapAction.depositAsWrappedNative
        );

        // Enter Curve lp position.
        outAmount = CurveLib.enterCurve(
            lpMinter,
            zapAction.outputToken,
            tokens,
            zapAction.minimumOut
        );

        // Enter Curvance pToken position.
        outAmount = _enterCurvance(
            pToken,
            zapAction.outputToken,
            true,
            outAmount,
            expectedShares,
            collateralize,
            recipient
        );
    }

    /// @notice Exits a Curve lp, and zaps it into desired
    ///         token (zapAction.outputToken).
    /// @param lpMinter The minter address of the Curve lp token.
    /// @param zapAction Zap instruction data to execute the Zap.
    /// @param tokens The underlying token addresses of the Curve lp token.
    /// @param singleAssetWithdraw Whether lp should be unwrapped to a single
    ///                            token or not.
    ///                            0 = all tokens.
    ///                            1 = single token; uint256 interface.
    ///                            2+ = single token; int128 interface.
    /// @param singleAssetIndex Used if `singleAssetWithdraw` != 0, indicates
    ///                         the coin index inside the Curve lp
    ///                         to withdraw as.
    /// @param swapActions Array of swap instruction data to execute the Zap.
    /// @param recipient Address that should receive Zapped withdrawal.
    /// @return outAmount The output amount received from Zapping.
    function exitCurve(
        address lpMinter,
        ZapAction calldata zapAction,
        address[] calldata tokens,
        uint256 singleAssetWithdraw,
        uint256 singleAssetIndex,
        SwapperLib.Swap[] calldata swapActions,
        address recipient
    ) external nonReentrant returns (uint256 outAmount) {
        // Transfer Curve lp token to the Zapper.
        SafeTransferLib.safeTransferFrom(
            zapAction.inputToken,
            msg.sender,
            address(this),
            zapAction.inputAmount
        );

        // Exit Curve lp position.
        outAmount = _exitCurve(
            lpMinter,
            zapAction,
            tokens,
            singleAssetWithdraw,
            singleAssetIndex,
            swapActions,
            recipient
        );
    }

    /// @notice Withdraws a Curvance Curve lp position, and zaps it into
    ///         desired token (zapAction.outputToken).
    /// @param redeemAction Struct containing information on the desired
    ///                       redemption action to execute. Containing values:
    ///                       1. The address of the pToken corresponding to Curve lp
    ///                          token to be exited.
    ///                       2. The amount of shares to redeemed.
    ///                       3. Whether the collateral should be always
    ///                          reduced from callers collateralPosted.
    /// @param lpMinter The minter address of the Curve lp token.
    /// @param zapAction Zap instruction data to execute the Zap.
    /// @param tokens The underlying token addresses of the Curve lp token.
    /// @param singleAssetWithdraw Whether lp should be unwrapped to a single
    ///                            token or not.
    ///                            0 = all tokens.
    ///                            1 = single token; uint256 interface.
    ///                            2+ = single token; int128 interface.
    /// @param singleAssetIndex Used if `singleAssetWithdraw` != 0, indicates
    ///                         the coin index inside the Curve lp
    ///                         to withdraw as.
    /// @param swapActions Array of swap instruction data to execute the Zap.
    /// @param recipient Address that should receive Zapped withdrawal.
    /// @return outAmount The output amount received from Zapping.
    function redeemAndExitCurve(
        RedeemAction calldata redeemAction,
        address lpMinter,
        ZapAction calldata zapAction,
        address[] calldata tokens,
        uint256 singleAssetWithdraw,
        uint256 singleAssetIndex,
        SwapperLib.Swap[] calldata swapActions,
        address recipient
    ) external nonReentrant returns (uint256 outAmount) {
        // Exit Curvance position.
        _exitCurvance(
            redeemAction.mToken,
            zapAction.inputToken,
            redeemAction.shares,
            zapAction.inputAmount,
            redeemAction.forceRedeemCollateral,
            recipient
        );

        // Exit Curve lp position.
        outAmount = _exitCurve(
            lpMinter,
            zapAction,
            tokens,
            singleAssetWithdraw,
            singleAssetIndex,
            swapActions,
            recipient
        );
    }

    /// @notice Swaps then deposits `zapAction.inputToken` into a BPT, and
    ///         enters into Curvance position.
    /// @dev Requires plugin approval for collateralization.
    /// @param pToken The Curvance pToken address.
    /// @param balancerData Struct containing information on BPT redemption
    ///                       to execute. Containing values:
    ///                       1. The Balancer vault address.
    ///                       2. The BPT pool ID.
    ///                       3. The underlying tokens of the BPT.
    /// @param zapAction Zap instruction data to execute the Zap.
    /// @param swapActions Array of swap instruction data to execute the Zap.
    /// @param expectedShares The minimum expected amount of shares received
    ///                       from depositing `amount` of `swapActions.outputToken`
    ///                       into `pToken` position.
    /// @param collateralize Whether the zapped deposit should be
    ///                      collateralized afterwards.
    /// @param recipient Address that should receive Zapped deposit.
    /// @return outAmount The output amount received from Zapping.
    function enterBalancer(
        address pToken,
        BalancerData calldata balancerData,
        ZapAction calldata zapAction,
        SwapperLib.Swap[] calldata swapActions,
        uint256 expectedShares,
        bool collateralize,
        address recipient
    ) external payable nonReentrant returns (uint256 outAmount) {
        // Swap input token for underlyings.
        _swapForUnderlyings(
            zapAction.inputToken,
            zapAction.inputAmount,
            swapActions,
            zapAction.depositAsWrappedNative
        );

        // Enter BPT position.
        outAmount = BalancerLib.enterBalancer(
            balancerData.balancerVault,
            balancerData.balancerPoolId,
            zapAction.outputToken,
            balancerData.underlyingTokens,
            zapAction.minimumOut
        );

        // Enter Curvance pToken position.
        outAmount = _enterCurvance(
            pToken,
            zapAction.outputToken,
            true,
            outAmount,
            expectedShares,
            collateralize,
            recipient
        );
    }

    /// @notice Exits a BPT, and zaps it into desired
    ///         token (zapAction.outputToken).
    /// @param balancerData Struct containing information on the desired
    ///                     BPT redemption to execute. Containing values:
    ///                     1. The Balancer vault address.
    ///                     2. The BPT pool ID.
    ///                     3. The underlying tokens of the BPT.
    /// @param zapAction Zap instruction data to execute the Zap.
    /// @param singleAssetWithdraw Whether BPT should be unwrapped to a single
    ///                            token or not.
    ///                            false = all tokens.
    ///                            true = single token.
    /// @param singleAssetIndex Used if `singleAssetWithdraw` = true,
    ///                         indicates the coin index inside the Balancer
    ///                         BPT to withdraw as.
    /// @param swapActions Array of swap instruction data to execute the Zap.
    /// @param recipient Address that should receive Zapped withdrawal.
    /// @return outAmount The output amount received from Zapping.
    function exitBalancer(
        BalancerData calldata balancerData,
        ZapAction calldata zapAction,
        bool singleAssetWithdraw,
        uint256 singleAssetIndex,
        SwapperLib.Swap[] calldata swapActions,
        address recipient
    ) external nonReentrant returns (uint256 outAmount) {
        // Transfer the BPT to the Zapper.
        SafeTransferLib.safeTransferFrom(
            zapAction.inputToken,
            msg.sender,
            address(this),
            zapAction.inputAmount
        );

        // Exit Balancer lp position.
        outAmount = _exitBalancer(
            balancerData.balancerVault,
            balancerData.balancerPoolId,
            singleAssetWithdraw,
            singleAssetIndex,
            zapAction,
            balancerData.underlyingTokens,
            swapActions,
            recipient
        );
    }

    /// @notice Withdraws a Curvance BPT position, and zaps it into
    ///         desired token (zapAction.outputToken).
    /// @param redeemAction Struct containing information on the desired
    ///                       redemption action to execute. Containing values:
    ///                       1. The address of the pToken corresponding to Curve lp
    ///                          token to be exited.
    ///                       2. The amount of shares to redeemed.
    ///                       3. Whether the collateral should be always
    ///                          reduced from callers collateralPosted.
    /// @param balancerData Struct containing information on the desired
    ///                     BPT redemption to execute. Containing values:
    ///                     1. The Balancer vault address.
    ///                     2. The BPT pool ID.
    ///                     3. The underlying tokens of the BPT.
    /// @param zapAction Zap instruction data to execute the Zap.
    /// @param singleAssetWithdraw Whether BPT should be unwrapped to a single
    ///                            token or not.
    ///                            false = all tokens.
    ///                            true = single token.
    /// @param singleAssetIndex Used if `singleAssetWithdraw` = true,
    ///                         indicates the coin index inside the Balancer
    ///                         BPT to withdraw as.
    /// @param swapActions Array of swap instruction data to execute the Zap.
    /// @param recipient Address that should receive Zapped withdrawal.
    /// @return outAmount The output amount received from Zapping.
    function redeemAndExitBalancer(
        RedeemAction calldata redeemAction,
        BalancerData calldata balancerData,
        ZapAction calldata zapAction,
        bool singleAssetWithdraw,
        uint256 singleAssetIndex,
        SwapperLib.Swap[] calldata swapActions,
        address recipient
    ) external nonReentrant returns (uint256 outAmount) {
        // Exit Curvance position.
        _exitCurvance(
            redeemAction.mToken,
            zapAction.inputToken,
            redeemAction.shares,
            zapAction.inputAmount,
            redeemAction.forceRedeemCollateral,
            recipient
        );

        // Exit Balancer lp position.
        outAmount = _exitBalancer(
            balancerData.balancerVault,
            balancerData.balancerPoolId,
            singleAssetWithdraw,
            singleAssetIndex,
            zapAction,
            balancerData.underlyingTokens,
            swapActions,
            recipient
        );
    }

    /// @notice Swaps then deposits `zapAction.inputToken` into Velodrome
    ///         sAMM/vAMM, and enters into Curvance position.
    /// @dev Requires plugin approval for collateralization.
    /// @param pToken The Curvance pToken address.
    /// @param zapAction Zap instruction data to execute the Zap.
    /// @param swapActions Array of swap instruction data to execute the Zap.
    /// @param router The Velodrome router address.
    /// @param factory The Velodrome factory address.
    /// @param expectedShares The minimum expected amount of shares received
    ///                       from depositing `amount` of `swapActions.outputToken`
    ///                       into `pToken` position.
    /// @param collateralize Whether the zapped deposit should be
    ///                      collateralized afterwards.
    /// @param recipient Address that should receive Zapped deposit.
    /// @return outAmount The output amount received from Zapping.
    function enterVelodrome(
        address pToken,
        ZapAction calldata zapAction,
        SwapperLib.Swap[] calldata swapActions,
        address router,
        address factory,
        uint256 expectedShares,
        bool collateralize,
        address recipient
    ) external payable nonReentrant returns (uint256 outAmount) {
        // Swap input token for underlyings.
        _swapForUnderlyings(
            zapAction.inputToken,
            zapAction.inputAmount,
            swapActions,
            zapAction.depositAsWrappedNative
        );

        // Enter Velodrome sAMM/vAMM position.
        outAmount = VelodromeLib.enterVelodrome(
            router,
            factory,
            zapAction.outputToken,
            CommonLib._getBalanceOf(IVeloPair(zapAction.outputToken).token0()),
            CommonLib._getBalanceOf(IVeloPair(zapAction.outputToken).token1()),
            zapAction.minimumOut
        );

        // Enter Curvance pToken position.
        outAmount = _enterCurvance(
            pToken,
            zapAction.outputToken,
            true,
            outAmount,
            expectedShares,
            collateralize,
            recipient
        );
    }

    /// @notice Exits a Velodrome sAMM/vAMM, and zaps it into desired
    ///         token (zapAction.outputToken).
    /// @param router The Velodrome router address.
    /// @param zapAction Zap instruction data to execute the Zap.
    /// @param swapActions Array of swap instruction data to execute the Zap.
    /// @param recipient Address that should receive Zapped withdrawal.
    /// @return outAmount The output amount received from Zapping.
    function exitVelodrome(
        address router,
        ZapAction calldata zapAction,
        SwapperLib.Swap[] calldata swapActions,
        address recipient
    ) external nonReentrant returns (uint256 outAmount) {
        // Transfer the Velodrome sAMM/vAMM to the Zapper.
        SafeTransferLib.safeTransferFrom(
            zapAction.inputToken,
            msg.sender,
            address(this),
            zapAction.inputAmount
        );

        // Exit Velodrome lp position.
        outAmount = _exitVelodrome(router, zapAction, swapActions, recipient);
    }

    /// @notice Withdraws a Curvance Velodrome sAMM/vAMM position, and zaps it
    ///         into desired token (zapAction.outputToken).
    /// @param redeemAction Struct containing information on the desired
    ///                       redemption action to execute. Containing values:
    ///                       1. The address of the pToken corresponding to Curve lp
    ///                          token to be exited.
    ///                       2. The amount of shares to redeemed.
    ///                       3. Whether the collateral should be always
    ///                          reduced from callers collateralPosted.
    /// @param router The Velodrome router address.
    /// @param zapAction Zap instruction data to execute the Zap.
    /// @param swapActions Array of swap instruction data to execute the Zap.
    /// @param recipient Address that should receive Zapped withdrawal.
    /// @return outAmount The output amount received from Zapping.
    function redeemAndExitVelodrome(
        RedeemAction calldata redeemAction,
        address router,
        ZapAction calldata zapAction,
        SwapperLib.Swap[] calldata swapActions,
        address recipient
    ) external nonReentrant returns (uint256 outAmount) {
        // Exit Curvance position.
        _exitCurvance(
            redeemAction.mToken,
            zapAction.inputToken,
            redeemAction.shares,
            zapAction.inputAmount,
            redeemAction.forceRedeemCollateral,
            recipient
        );

        // Exit Velodrome lp position.
        outAmount = _exitVelodrome(router, zapAction, swapActions, recipient);
    }

    /// @notice Swaps then deposits `zapAction.inputToken` into Pendle
    ///         market, and enters into Curvance position.
    /// @dev Requires plugin approval for collateralization.
    /// @param pToken The Curvance pToken address.
    /// @param zapAction Zap instruction data to execute the Zap.
    /// @param swapActions Array of swap instruction data to execute the Zap.
    /// @param router The Pendle router address.
    /// @param isPt Whether lp token is PT or not.
    /// @param data Pendle specific execution data including input/output,
    ///             and limit order data.
    /// @param expectedShares The minimum expected amount of shares received
    ///                       from depositing `amount` of `swapActions.outputToken`
    ///                       into `pToken` position.
    /// @param collateralize Whether the zapped deposit should be
    ///                      collateralized afterwards.
    /// @param recipient Address that should receive Zapped deposit.
    /// @return outAmount The output amount received from Zapping.
    function enterPendle(
        address pToken,
        ZapAction calldata zapAction,
        SwapperLib.Swap[] calldata swapActions,
        address router,
        bool isPt,
        PendleLib.PendleAction calldata data,
        uint256 expectedShares,
        bool collateralize,
        address recipient
    ) external payable nonReentrant returns (uint256 outAmount) {
        // Swap input token for underlyings.
        _swapForUnderlyings(
            zapAction.inputToken,
            zapAction.inputAmount,
            swapActions,
            zapAction.depositAsWrappedNative
        );

        // Enter Pendle position.
        outAmount = PendleLib._enterPendle(
            router,
            isPt,
            data,
            zapAction.outputToken,
            zapAction.minimumOut
        );

        // Enter Curvance pToken position.
        outAmount = _enterCurvance(
            pToken,
            zapAction.outputToken,
            true,
            outAmount,
            expectedShares,
            collateralize,
            recipient
        );
    }

    /// @notice Exits a Pendle market, and zaps it into desired
    ///         token (zapAction.outputToken).
    /// @param router The Pendle router address.
    /// @param isPt Whether lp token is PT or not.
    /// @param token The underlying token address of the SY.
    /// @param data Pendle specific execution data including input/output,
    ///             and limit order data.
    /// @param zapAction Zap instruction data to execute the Zap.
    /// @param swapActions Array of swap instruction data to execute the Zap.
    /// @param recipient Address that should receive Zapped withdrawal.
    /// @return outAmount The output amount received from Zapping.
    function exitPendle(
        address router,
        bool isPt,
        address token,
        PendleLib.PendleAction calldata data,
        ZapAction calldata zapAction,
        SwapperLib.Swap[] calldata swapActions,
        address recipient
    ) external nonReentrant returns (uint256 outAmount) {
        // Transfer the Pendle market to the Zapper.
        SafeTransferLib.safeTransferFrom(
            zapAction.inputToken,
            msg.sender,
            address(this),
            zapAction.inputAmount
        );

        // Exit Pendle lp position.
        outAmount = _exitPendle(
            router,
            isPt,
            token,
            data,
            zapAction,
            swapActions,
            recipient
        );
    }

    /// @notice Withdraws a Curvance Pendle market position, and zaps it
    ///         into desired token (zapAction.outputToken).
    /// @param redeemAction Struct containing information on the desired
    ///                       redemption action to execute. Containing values:
    ///                       1. The address of the pToken corresponding to Curve lp
    ///                          token to be exited.
    ///                       2. The amount of shares to redeemed.
    ///                       3. Whether the collateral should be always
    ///                          reduced from callers collateralPosted.
    /// @param router The Pendle router address.
    /// @param isPt Whether lp token is PT or not.
    /// @param token The underlying token address of the SY.
    /// @param data Pendle specific execution data including input/output,
    ///             and limit order data.
    /// @param zapAction Zap instruction data to execute the Zap.
    /// @param swapActions Array of swap instruction data to execute the Zap.
    /// @param recipient Address that should receive Zapped withdrawal.
    /// @return outAmount The output amount received from Zapping.
    function redeemAndExitPendle(
        RedeemAction calldata redeemAction,
        address router,
        bool isPt,
        address token,
        PendleLib.PendleAction calldata data,
        ZapAction calldata zapAction,
        SwapperLib.Swap[] calldata swapActions,
        address recipient
    ) external nonReentrant returns (uint256 outAmount) {
        // Exit Curvance position.
        _exitCurvance(
            redeemAction.mToken,
            zapAction.inputToken,
            redeemAction.shares,
            zapAction.inputAmount,
            redeemAction.forceRedeemCollateral,
            recipient
        );

        // Exit Pendle lp position.
        outAmount = _exitPendle(
            router,
            isPt,
            token,
            data,
            zapAction,
            swapActions,
            recipient
        );
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Withdraws a Curvance Curve lp position, and zaps it into
    ///         desired token (zapAction.outputToken).
    /// @param lpMinter The minter address of the Curve lp token.
    /// @param zapAction Zap instruction data to execute the Zap.
    /// @param tokens The underlying token addresses of the Curve lp token.
    /// @param singleAssetWithdraw Whether lp should be unwrapped to a single
    ///                            token or not.
    ///                            0 = all tokens.
    ///                            1 = single token; uint256 interface.
    ///                            2+ = single token; int128 interface.
    /// @param singleAssetIndex Used if `singleAssetWithdraw` != 0, indicates
    ///                         the coin index inside the Curve lp
    ///                         to withdraw as.
    /// @param swapActions Array of swap instruction data to execute the Zap.
    /// @param recipient Address that should receive Zapped withdrawal.
    /// @return outAmount The output amount received from Zapping.
    function _exitCurve(
        address lpMinter,
        ZapAction calldata zapAction,
        address[] calldata tokens,
        uint256 singleAssetWithdraw,
        uint256 singleAssetIndex,
        SwapperLib.Swap[] calldata swapActions,
        address recipient
    ) internal returns (uint256 outAmount) {
        // Exit Curve lp position.
        CurveLib.exitCurve(
            lpMinter,
            zapAction.inputToken,
            tokens,
            zapAction.inputAmount,
            singleAssetWithdraw,
            singleAssetIndex
        );

        uint256 numTokenSwaps = swapActions.length;
        // Swap unwrapped token(s) into `zapAction.outputToken`.
        for (uint256 i; i < numTokenSwaps; ) {
            // Execute swap(s) into `zapAction.outputToken`.
            SwapperLib._swapUnsafe(centralRegistry, swapActions[i++]);
        }

        outAmount = CommonLib._getBalanceOf(zapAction.outputToken);
        // Validate zap output is sufficient.
        if (outAmount < zapAction.minimumOut) {
            revert ComplexZapper__SlippageError();
        }

        // Transfer output tokens to `recipient`.
        _transferToRecipient(zapAction.outputToken, recipient, outAmount);
    }

    /// @notice Withdraws a Curvance BPT position, and zaps it into
    ///         desired token (zapAction.outputToken).
    /// @param balancerVault The Balancer vault address.
    /// @param balancerPoolId The BPT pool ID.
    /// @param singleAssetWithdraw Whether BPT should be unwrapped to a single
    ///                            token or not.
    ///                            false = all tokens.
    ///                            true = single token.
    /// @param singleAssetIndex Used if `singleAssetWithdraw` = true,
    ///                         indicates the coin index inside the Balancer
    ///                         BPT to withdraw as.
    /// @param zapAction Zap instruction data to execute the Zap.
    /// @param tokens The underlying token addresses of the BPT.
    /// @param swapActions Array of swap instruction data to execute the Zap.
    /// @param recipient Address that should receive Zapped withdrawal.
    /// @return outAmount The output amount received from Zapping.
    function _exitBalancer(
        address balancerVault,
        bytes32 balancerPoolId,
        bool singleAssetWithdraw,
        uint256 singleAssetIndex,
        ZapAction calldata zapAction,
        address[] calldata tokens,
        SwapperLib.Swap[] calldata swapActions,
        address recipient
    ) internal returns (uint256 outAmount) {
        // Exit BPT position.
        BalancerLib.exitBalancer(
            balancerVault,
            balancerPoolId,
            zapAction.inputToken,
            tokens,
            zapAction.inputAmount,
            singleAssetWithdraw,
            singleAssetIndex
        );

        uint256 numTokenSwaps = swapActions.length;
        // Swap unwrapped token(s) into `zapAction.outputToken`.
        for (uint256 i; i < numTokenSwaps; ) {
            // Execute swap(s) into `zapAction.outputToken`.
            SwapperLib._swapUnsafe(centralRegistry, swapActions[i++]);
        }

        outAmount = CommonLib._getBalanceOf(zapAction.outputToken);
        // Validate zap output is sufficient.
        if (outAmount < zapAction.minimumOut) {
            revert ComplexZapper__SlippageError();
        }

        // Transfer output tokens to `recipient`.
        _transferToRecipient(zapAction.outputToken, recipient, outAmount);
    }

    /// @notice Withdraws a Curvance Velodrome sAMM/vAMM position, and zaps it
    ///         into desired token (zapAction.outputToken).
    /// @param router The Velodrome router address.
    /// @param zapAction Zap instruction data to execute the Zap.
    /// @param swapActions Array of swap instruction data to execute the Zap.
    /// @param recipient Address that should receive Zapped withdrawal.
    /// @return outAmount The output amount received from Zapping.
    function _exitVelodrome(
        address router,
        ZapAction calldata zapAction,
        SwapperLib.Swap[] calldata swapActions,
        address recipient
    ) internal returns (uint256 outAmount) {
        // Exit Velodrome sAMM/vAMM position.
        VelodromeLib.exitVelodrome(
            router,
            zapAction.inputToken,
            zapAction.inputAmount
        );

        uint256 numTokenSwaps = swapActions.length;
        // Swap unwrapped tokens into `zapAction.outputToken`.
        for (uint256 i; i < numTokenSwaps; ) {
            // Execute swap(s) into `zapAction.outputToken`.
            SwapperLib._swapUnsafe(centralRegistry, swapActions[i++]);
        }

        outAmount = CommonLib._getBalanceOf(zapAction.outputToken);
        // Validate zap output is sufficient.
        if (outAmount < zapAction.minimumOut) {
            revert ComplexZapper__SlippageError();
        }

        // Transfer output tokens to `recipient`.
        _transferToRecipient(zapAction.outputToken, recipient, outAmount);
    }

    /// @notice Withdraws a Curvance Pendle market position, and zaps it
    ///         into desired token (zapAction.outputToken).
    /// @param router The Pendle router address.
    /// @param isPt Whether lp token is PT or not.
    /// @param token The underlying token address of the SY.
    /// @param zapAction Zap instruction data to execute the Zap.
    /// @param swapActions Array of swap instruction data to execute the Zap.
    /// @param recipient Address that should receive Zapped withdrawal.
    /// @return outAmount The output amount received from Zapping.
    function _exitPendle(
        address router,
        bool isPt,
        address token,
        PendleLib.PendleAction calldata data,
        ZapAction calldata zapAction,
        SwapperLib.Swap[] calldata swapActions,
        address recipient
    ) internal returns (uint256 outAmount) {
        // Exit Pendle market position.
        PendleLib.exitPendle(
            router,
            isPt,
            token,
            data,
            zapAction.inputToken,
            zapAction.inputAmount,
            0
        );

        uint256 numTokenSwaps = swapActions.length;
        // Swap unwrapped tokens into `zapAction.outputToken`.
        for (uint256 i; i < numTokenSwaps; ) {
            // Execute swap(s) into `zapAction.outputToken`.
            SwapperLib._swapUnsafe(centralRegistry, swapActions[i++]);
        }

        outAmount = CommonLib._getBalanceOf(zapAction.outputToken);
        // Validate zap output is sufficient.
        if (outAmount < zapAction.minimumOut) {
            revert ComplexZapper__SlippageError();
        }

        // Transfer output tokens to `recipient`.
        _transferToRecipient(zapAction.outputToken, recipient, outAmount);
    }

    /// @notice Swap `inputToken` into desired pToken underlying tokens.
    /// @param inputToken The input token address.
    /// @param inputAmount The amount of `inputToken` to swap for underlying
    ///                    tokens.
    /// @param swapActions Array of swap instruction data
    /// @param depositAsWrappedNative Used when `inputToken` is chain gas token,
    ///                           indicates depositing gas token into wrapper
    ///                           contract.
    function _swapForUnderlyings(
        address inputToken,
        uint256 inputAmount,
        SwapperLib.Swap[] memory swapActions,
        bool depositAsWrappedNative
    ) internal {
        _prepareSwap(inputToken, inputAmount, depositAsWrappedNative);

        uint256 numTokenSwaps = swapActions.length;
        // Swap `inputToken` into desired pToken underlying tokens.
        for (uint256 i; i < numTokenSwaps; ) {
            if (
                CommonLib._isNative(swapActions[i].inputToken) &&
                depositAsWrappedNative
            ) {
                // Switch inputToken to wrapped native token address.
                swapActions[i].inputToken = address(wrappedNative);
            }

            // Execute swap into underlying(s).
            SwapperLib._swapUnsafe(centralRegistry, swapActions[i++]);
        }
    }
}
