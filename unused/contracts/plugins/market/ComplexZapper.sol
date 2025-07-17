// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { ZapperBase, SwapperLib, CommonLib, IPToken, SafeTransferLib, ICentralRegistry } from "contracts/plugins/ZapperBase.sol";

import { CurveLib } from "contracts/libraries/CurveLib.sol";
import { BalancerLib } from "contracts/libraries/BalancerLib.sol";
import { VelodromeLib } from "contracts/libraries/VelodromeLib.sol";
import { PendleLib } from "contracts/libraries/PendleLib.sol";

import { IVeloPair } from "contracts/interfaces/external/velodrome/IVeloPair.sol";
import { IPToken } from "contracts/interfaces/IPToken.sol";

contract ComplexZapper is ZapperBase {
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
    struct ZapperData {
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
    ) ZapperBase(centralRegistry_, wrappedNative_) {}

    /// EXTERNAL FUNCTIONS ///

    /// @notice Swaps then deposits `zapData.inputToken` into Curve lp token,
    ///         and enters into Curvance position.
    /// @dev Requires plugin approval for collateralization.
    /// @param pToken The Curvance pToken address.
    /// @param zapData Zap instruction data to execute the Zap.
    /// @param swapData Array of swap instruction data to execute the Zap.
    /// @param lpMinter The minter address of the Curve lp token.
    /// @param tokens The underlying coins of the Curve lp token.
    /// @param expectedShares The minimum expected amount of shares received
    ///                       from depositing `amount` of `swapData.outputToken`
    ///                       into `pToken` position.
    /// @param collateralize Whether the zapped position deposit should be
    ///                      collateralized afterwards.
    /// @param recipient Address that should receive Zapped deposit.
    /// @return outAmount The output amount received from Zapping.
    function enterCurve(
        address pToken,
        ZapperData calldata zapData,
        SwapperLib.Swap[] calldata swapData,
        address lpMinter,
        address[] calldata tokens,
        uint256 expectedShares,
        bool collateralize,
        address recipient
    ) external payable nonReentrant returns (uint256 outAmount) {
        // Swap input token for underlyings.
        _swapForUnderlyings(
            zapData.inputToken,
            zapData.inputAmount,
            swapData,
            zapData.depositAsWrappedNative
        );

        // Enter Curve lp position.
        outAmount = CurveLib.enterCurve(
            lpMinter,
            zapData.outputToken,
            tokens,
            zapData.minimumOut
        );

        // Enter Curvance pToken position.
        outAmount = _enterCurvance(
            pToken,
            zapData.outputToken,
            true,
            outAmount,
            expectedShares,
            collateralize,
            recipient
        );
    }

    /// @notice Exits a Curve lp, and zaps it into desired
    ///         token (zapData.outputToken).
    /// @param lpMinter The minter address of the Curve lp token.
    /// @param zapData Zap instruction data to execute the Zap.
    /// @param tokens The underlying token addresses of the Curve lp token.
    /// @param singleAssetWithdraw Whether lp should be unwrapped to a single
    ///                            token or not.
    ///                            0 = all tokens.
    ///                            1 = single token; uint256 interface.
    ///                            2+ = single token; int128 interface.
    /// @param singleAssetIndex Used if `singleAssetWithdraw` != 0, indicates
    ///                         the coin index inside the Curve lp
    ///                         to withdraw as.
    /// @param swapData Array of swap instruction data to execute the Zap.
    /// @param recipient Address that should receive Zapped withdrawal.
    /// @return outAmount The output amount received from Zapping.
    function exitCurve(
        address lpMinter,
        ZapperData calldata zapData,
        address[] calldata tokens,
        uint256 singleAssetWithdraw,
        uint256 singleAssetIndex,
        SwapperLib.Swap[] calldata swapData,
        address recipient
    ) external nonReentrant returns (uint256 outAmount) {
        // Transfer Curve lp token to the Zapper.
        SafeTransferLib.safeTransferFrom(
            zapData.inputToken,
            msg.sender,
            address(this),
            zapData.inputAmount
        );

        // Exit Curve lp position.
        outAmount = _exitCurve(
            lpMinter,
            zapData,
            tokens,
            singleAssetWithdraw,
            singleAssetIndex,
            swapData,
            recipient
        );
    }

    /// @notice Withdraws a Curvance Curve lp position, and zaps it into
    ///         desired token (zapData.outputToken).
    /// @param redemptionData Struct containing information on the desired
    ///                       redemption action to execute. Containing values:
    ///                       1. The address of the pToken corresponding to Curve lp
    ///                          token to be exited.
    ///                       2. The amount of shares to redeemed.
    ///                       3. Whether the collateral should be always
    ///                          reduced from callers collateralPosted.
    /// @param lpMinter The minter address of the Curve lp token.
    /// @param zapData Zap instruction data to execute the Zap.
    /// @param tokens The underlying token addresses of the Curve lp token.
    /// @param singleAssetWithdraw Whether lp should be unwrapped to a single
    ///                            token or not.
    ///                            0 = all tokens.
    ///                            1 = single token; uint256 interface.
    ///                            2+ = single token; int128 interface.
    /// @param singleAssetIndex Used if `singleAssetWithdraw` != 0, indicates
    ///                         the coin index inside the Curve lp
    ///                         to withdraw as.
    /// @param swapData Array of swap instruction data to execute the Zap.
    /// @param recipient Address that should receive Zapped withdrawal.
    /// @return outAmount The output amount received from Zapping.
    function redeemAndExitCurve(
        RedemptionData calldata redemptionData,
        address lpMinter,
        ZapperData calldata zapData,
        address[] calldata tokens,
        uint256 singleAssetWithdraw,
        uint256 singleAssetIndex,
        SwapperLib.Swap[] calldata swapData,
        address recipient
    ) external nonReentrant returns (uint256 outAmount) {
        // Exit Curvance position.
        _exitCurvance(
            redemptionData.mToken,
            zapData.inputToken,
            redemptionData.shares,
            zapData.inputAmount,
            redemptionData.forceRedeemCollateral,
            recipient
        );

        // Exit Curve lp position.
        outAmount = _exitCurve(
            lpMinter,
            zapData,
            tokens,
            singleAssetWithdraw,
            singleAssetIndex,
            swapData,
            recipient
        );
    }

    /// @notice Swaps then deposits `zapData.inputToken` into a BPT, and
    ///         enters into Curvance position.
    /// @dev Requires plugin approval for collateralization.
    /// @param pToken The Curvance pToken address.
    /// @param balancerData Struct containing information on BPT redemption
    ///                       to execute. Containing values:
    ///                       1. The Balancer vault address.
    ///                       2. The BPT pool ID.
    ///                       3. The underlying tokens of the BPT.
    /// @param zapData Zap instruction data to execute the Zap.
    /// @param swapData Array of swap instruction data to execute the Zap.
    /// @param expectedShares The minimum expected amount of shares received
    ///                       from depositing `amount` of `swapData.outputToken`
    ///                       into `pToken` position.
    /// @param collateralize Whether the zapped deposit should be
    ///                      collateralized afterwards.
    /// @param recipient Address that should receive Zapped deposit.
    /// @return outAmount The output amount received from Zapping.
    function enterBalancer(
        address pToken,
        BalancerData calldata balancerData,
        ZapperData calldata zapData,
        SwapperLib.Swap[] calldata swapData,
        uint256 expectedShares,
        bool collateralize,
        address recipient
    ) external payable nonReentrant returns (uint256 outAmount) {
        // Swap input token for underlyings.
        _swapForUnderlyings(
            zapData.inputToken,
            zapData.inputAmount,
            swapData,
            zapData.depositAsWrappedNative
        );

        // Enter BPT position.
        outAmount = BalancerLib.enterBalancer(
            balancerData.balancerVault,
            balancerData.balancerPoolId,
            zapData.outputToken,
            balancerData.underlyingTokens,
            zapData.minimumOut
        );

        // Enter Curvance pToken position.
        outAmount = _enterCurvance(
            pToken,
            zapData.outputToken,
            true,
            outAmount,
            expectedShares,
            collateralize,
            recipient
        );
    }

    /// @notice Exits a BPT, and zaps it into desired
    ///         token (zapData.outputToken).
    /// @param balancerData Struct containing information on the desired
    ///                     BPT redemption to execute. Containing values:
    ///                     1. The Balancer vault address.
    ///                     2. The BPT pool ID.
    ///                     3. The underlying tokens of the BPT.
    /// @param zapData Zap instruction data to execute the Zap.
    /// @param singleAssetWithdraw Whether BPT should be unwrapped to a single
    ///                            token or not.
    ///                            false = all tokens.
    ///                            true = single token.
    /// @param singleAssetIndex Used if `singleAssetWithdraw` = true,
    ///                         indicates the coin index inside the Balancer
    ///                         BPT to withdraw as.
    /// @param swapData Array of swap instruction data to execute the Zap.
    /// @param recipient Address that should receive Zapped withdrawal.
    /// @return outAmount The output amount received from Zapping.
    function exitBalancer(
        BalancerData calldata balancerData,
        ZapperData calldata zapData,
        bool singleAssetWithdraw,
        uint256 singleAssetIndex,
        SwapperLib.Swap[] calldata swapData,
        address recipient
    ) external nonReentrant returns (uint256 outAmount) {
        // Transfer the BPT to the Zapper.
        SafeTransferLib.safeTransferFrom(
            zapData.inputToken,
            msg.sender,
            address(this),
            zapData.inputAmount
        );

        // Exit Balancer lp position.
        outAmount = _exitBalancer(
            balancerData.balancerVault,
            balancerData.balancerPoolId,
            singleAssetWithdraw,
            singleAssetIndex,
            zapData,
            balancerData.underlyingTokens,
            swapData,
            recipient
        );
    }

    /// @notice Withdraws a Curvance BPT position, and zaps it into
    ///         desired token (zapData.outputToken).
    /// @param redemptionData Struct containing information on the desired
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
    /// @param zapData Zap instruction data to execute the Zap.
    /// @param singleAssetWithdraw Whether BPT should be unwrapped to a single
    ///                            token or not.
    ///                            false = all tokens.
    ///                            true = single token.
    /// @param singleAssetIndex Used if `singleAssetWithdraw` = true,
    ///                         indicates the coin index inside the Balancer
    ///                         BPT to withdraw as.
    /// @param swapData Array of swap instruction data to execute the Zap.
    /// @param recipient Address that should receive Zapped withdrawal.
    /// @return outAmount The output amount received from Zapping.
    function redeemAndExitBalancer(
        RedemptionData calldata redemptionData,
        BalancerData calldata balancerData,
        ZapperData calldata zapData,
        bool singleAssetWithdraw,
        uint256 singleAssetIndex,
        SwapperLib.Swap[] calldata swapData,
        address recipient
    ) external nonReentrant returns (uint256 outAmount) {
        // Exit Curvance position.
        _exitCurvance(
            redemptionData.mToken,
            zapData.inputToken,
            redemptionData.shares,
            zapData.inputAmount,
            redemptionData.forceRedeemCollateral,
            recipient
        );

        // Exit Balancer lp position.
        outAmount = _exitBalancer(
            balancerData.balancerVault,
            balancerData.balancerPoolId,
            singleAssetWithdraw,
            singleAssetIndex,
            zapData,
            balancerData.underlyingTokens,
            swapData,
            recipient
        );
    }

    /// @notice Swaps then deposits `zapData.inputToken` into Velodrome
    ///         sAMM/vAMM, and enters into Curvance position.
    /// @dev Requires plugin approval for collateralization.
    /// @param pToken The Curvance pToken address.
    /// @param zapData Zap instruction data to execute the Zap.
    /// @param swapData Array of swap instruction data to execute the Zap.
    /// @param router The Velodrome router address.
    /// @param factory The Velodrome factory address.
    /// @param expectedShares The minimum expected amount of shares received
    ///                       from depositing `amount` of `swapData.outputToken`
    ///                       into `pToken` position.
    /// @param collateralize Whether the zapped deposit should be
    ///                      collateralized afterwards.
    /// @param recipient Address that should receive Zapped deposit.
    /// @return outAmount The output amount received from Zapping.
    function enterVelodrome(
        address pToken,
        ZapperData calldata zapData,
        SwapperLib.Swap[] calldata swapData,
        address router,
        address factory,
        uint256 expectedShares,
        bool collateralize,
        address recipient
    ) external payable nonReentrant returns (uint256 outAmount) {
        // Swap input token for underlyings.
        _swapForUnderlyings(
            zapData.inputToken,
            zapData.inputAmount,
            swapData,
            zapData.depositAsWrappedNative
        );

        // Enter Velodrome sAMM/vAMM position.
        outAmount = VelodromeLib.enterVelodrome(
            router,
            factory,
            zapData.outputToken,
            CommonLib._getTokenBalance(IVeloPair(zapData.outputToken).token0()),
            CommonLib._getTokenBalance(IVeloPair(zapData.outputToken).token1()),
            zapData.minimumOut
        );

        // Enter Curvance pToken position.
        outAmount = _enterCurvance(
            pToken,
            zapData.outputToken,
            true,
            outAmount,
            expectedShares,
            collateralize,
            recipient
        );
    }

    /// @notice Exits a Velodrome sAMM/vAMM, and zaps it into desired
    ///         token (zapData.outputToken).
    /// @param router The Velodrome router address.
    /// @param zapData Zap instruction data to execute the Zap.
    /// @param swapData Array of swap instruction data to execute the Zap.
    /// @param recipient Address that should receive Zapped withdrawal.
    /// @return outAmount The output amount received from Zapping.
    function exitVelodrome(
        address router,
        ZapperData calldata zapData,
        SwapperLib.Swap[] calldata swapData,
        address recipient
    ) external nonReentrant returns (uint256 outAmount) {
        // Transfer the Velodrome sAMM/vAMM to the Zapper.
        SafeTransferLib.safeTransferFrom(
            zapData.inputToken,
            msg.sender,
            address(this),
            zapData.inputAmount
        );

        // Exit Velodrome lp position.
        outAmount = _exitVelodrome(router, zapData, swapData, recipient);
    }

    /// @notice Withdraws a Curvance Velodrome sAMM/vAMM position, and zaps it
    ///         into desired token (zapData.outputToken).
    /// @param redemptionData Struct containing information on the desired
    ///                       redemption action to execute. Containing values:
    ///                       1. The address of the pToken corresponding to Curve lp
    ///                          token to be exited.
    ///                       2. The amount of shares to redeemed.
    ///                       3. Whether the collateral should be always
    ///                          reduced from callers collateralPosted.
    /// @param router The Velodrome router address.
    /// @param zapData Zap instruction data to execute the Zap.
    /// @param swapData Array of swap instruction data to execute the Zap.
    /// @param recipient Address that should receive Zapped withdrawal.
    /// @return outAmount The output amount received from Zapping.
    function redeemAndExitVelodrome(
        RedemptionData calldata redemptionData,
        address router,
        ZapperData calldata zapData,
        SwapperLib.Swap[] calldata swapData,
        address recipient
    ) external nonReentrant returns (uint256 outAmount) {
        // Exit Curvance position.
        _exitCurvance(
            redemptionData.mToken,
            zapData.inputToken,
            redemptionData.shares,
            zapData.inputAmount,
            redemptionData.forceRedeemCollateral,
            recipient
        );

        // Exit Velodrome lp position.
        outAmount = _exitVelodrome(router, zapData, swapData, recipient);
    }

    /// @notice Swaps then deposits `zapData.inputToken` into Pendle
    ///         market, and enters into Curvance position.
    /// @dev Requires plugin approval for collateralization.
    /// @param pToken The Curvance pToken address.
    /// @param zapData Zap instruction data to execute the Zap.
    /// @param swapData Array of swap instruction data to execute the Zap.
    /// @param router The Pendle router address.
    /// @param isPt Whether lp token is PT or not.
    /// @param data Pendle specific execution data including input/output,
    ///             and limit order data.
    /// @param expectedShares The minimum expected amount of shares received
    ///                       from depositing `amount` of `swapData.outputToken`
    ///                       into `pToken` position.
    /// @param collateralize Whether the zapped deposit should be
    ///                      collateralized afterwards.
    /// @param recipient Address that should receive Zapped deposit.
    /// @return outAmount The output amount received from Zapping.
    function enterPendle(
        address pToken,
        ZapperData calldata zapData,
        SwapperLib.Swap[] calldata swapData,
        address router,
        bool isPt,
        PendleLib.PendleData calldata data,
        uint256 expectedShares,
        bool collateralize,
        address recipient
    ) external payable nonReentrant returns (uint256 outAmount) {
        // Swap input token for underlyings.
        _swapForUnderlyings(
            zapData.inputToken,
            zapData.inputAmount,
            swapData,
            zapData.depositAsWrappedNative
        );

        // Enter Pendle position.
        outAmount = PendleLib._enterPendle(
            router,
            isPt,
            data,
            zapData.outputToken,
            zapData.minimumOut
        );

        // Enter Curvance pToken position.
        outAmount = _enterCurvance(
            pToken,
            zapData.outputToken,
            true,
            outAmount,
            expectedShares,
            collateralize,
            recipient
        );
    }

    /// @notice Exits a Pendle market, and zaps it into desired
    ///         token (zapData.outputToken).
    /// @param router The Pendle router address.
    /// @param isPt Whether lp token is PT or not.
    /// @param token The underlying token address of the SY.
    /// @param data Pendle specific execution data including input/output,
    ///             and limit order data.
    /// @param zapData Zap instruction data to execute the Zap.
    /// @param swapData Array of swap instruction data to execute the Zap.
    /// @param recipient Address that should receive Zapped withdrawal.
    /// @return outAmount The output amount received from Zapping.
    function exitPendle(
        address router,
        bool isPt,
        address token,
        PendleLib.PendleData calldata data,
        ZapperData calldata zapData,
        SwapperLib.Swap[] calldata swapData,
        address recipient
    ) external nonReentrant returns (uint256 outAmount) {
        // Transfer the Pendle market to the Zapper.
        SafeTransferLib.safeTransferFrom(
            zapData.inputToken,
            msg.sender,
            address(this),
            zapData.inputAmount
        );

        // Exit Pendle lp position.
        outAmount = _exitPendle(
            router,
            isPt,
            token,
            data,
            zapData,
            swapData,
            recipient
        );
    }

    /// @notice Withdraws a Curvance Pendle market position, and zaps it
    ///         into desired token (zapData.outputToken).
    /// @param redemptionData Struct containing information on the desired
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
    /// @param zapData Zap instruction data to execute the Zap.
    /// @param swapData Array of swap instruction data to execute the Zap.
    /// @param recipient Address that should receive Zapped withdrawal.
    /// @return outAmount The output amount received from Zapping.
    function redeemAndExitPendle(
        RedemptionData calldata redemptionData,
        address router,
        bool isPt,
        address token,
        PendleLib.PendleData calldata data,
        ZapperData calldata zapData,
        SwapperLib.Swap[] calldata swapData,
        address recipient
    ) external nonReentrant returns (uint256 outAmount) {
        // Exit Curvance position.
        _exitCurvance(
            redemptionData.mToken,
            zapData.inputToken,
            redemptionData.shares,
            zapData.inputAmount,
            redemptionData.forceRedeemCollateral,
            recipient
        );

        // Exit Pendle lp position.
        outAmount = _exitPendle(
            router,
            isPt,
            token,
            data,
            zapData,
            swapData,
            recipient
        );
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Withdraws a Curvance Curve lp position, and zaps it into
    ///         desired token (zapData.outputToken).
    /// @param lpMinter The minter address of the Curve lp token.
    /// @param zapData Zap instruction data to execute the Zap.
    /// @param tokens The underlying token addresses of the Curve lp token.
    /// @param singleAssetWithdraw Whether lp should be unwrapped to a single
    ///                            token or not.
    ///                            0 = all tokens.
    ///                            1 = single token; uint256 interface.
    ///                            2+ = single token; int128 interface.
    /// @param singleAssetIndex Used if `singleAssetWithdraw` != 0, indicates
    ///                         the coin index inside the Curve lp
    ///                         to withdraw as.
    /// @param swapData Array of swap instruction data to execute the Zap.
    /// @param recipient Address that should receive Zapped withdrawal.
    /// @return outAmount The output amount received from Zapping.
    function _exitCurve(
        address lpMinter,
        ZapperData calldata zapData,
        address[] calldata tokens,
        uint256 singleAssetWithdraw,
        uint256 singleAssetIndex,
        SwapperLib.Swap[] calldata swapData,
        address recipient
    ) internal returns (uint256 outAmount) {
        // Exit Curve lp position.
        CurveLib.exitCurve(
            lpMinter,
            zapData.inputToken,
            tokens,
            zapData.inputAmount,
            singleAssetWithdraw,
            singleAssetIndex
        );

        uint256 numTokenSwaps = swapData.length;
        // Swap unwrapped token(s) into `zapData.outputToken`.
        for (uint256 i; i < numTokenSwaps; ) {
            // Execute swap(s) into `zapData.outputToken`.
            SwapperLib._swapUnsafe(centralRegistry, swapData[i++]);
        }

        outAmount = CommonLib._getTokenBalance(zapData.outputToken);
        // Validate zap output is sufficient.
        if (outAmount < zapData.minimumOut) {
            revert ComplexZapper__SlippageError();
        }

        // Transfer output tokens to `recipient`.
        _transferToRecipient(zapData.outputToken, recipient, outAmount);
    }

    /// @notice Withdraws a Curvance BPT position, and zaps it into
    ///         desired token (zapData.outputToken).
    /// @param balancerVault The Balancer vault address.
    /// @param balancerPoolId The BPT pool ID.
    /// @param singleAssetWithdraw Whether BPT should be unwrapped to a single
    ///                            token or not.
    ///                            false = all tokens.
    ///                            true = single token.
    /// @param singleAssetIndex Used if `singleAssetWithdraw` = true,
    ///                         indicates the coin index inside the Balancer
    ///                         BPT to withdraw as.
    /// @param zapData Zap instruction data to execute the Zap.
    /// @param tokens The underlying token addresses of the BPT.
    /// @param swapData Array of swap instruction data to execute the Zap.
    /// @param recipient Address that should receive Zapped withdrawal.
    /// @return outAmount The output amount received from Zapping.
    function _exitBalancer(
        address balancerVault,
        bytes32 balancerPoolId,
        bool singleAssetWithdraw,
        uint256 singleAssetIndex,
        ZapperData calldata zapData,
        address[] calldata tokens,
        SwapperLib.Swap[] calldata swapData,
        address recipient
    ) internal returns (uint256 outAmount) {
        // Exit BPT position.
        BalancerLib.exitBalancer(
            balancerVault,
            balancerPoolId,
            zapData.inputToken,
            tokens,
            zapData.inputAmount,
            singleAssetWithdraw,
            singleAssetIndex
        );

        uint256 numTokenSwaps = swapData.length;
        // Swap unwrapped token(s) into `zapData.outputToken`.
        for (uint256 i; i < numTokenSwaps; ) {
            // Execute swap(s) into `zapData.outputToken`.
            SwapperLib._swapUnsafe(centralRegistry, swapData[i++]);
        }

        outAmount = CommonLib._getTokenBalance(zapData.outputToken);
        // Validate zap output is sufficient.
        if (outAmount < zapData.minimumOut) {
            revert ComplexZapper__SlippageError();
        }

        // Transfer output tokens to `recipient`.
        _transferToRecipient(zapData.outputToken, recipient, outAmount);
    }

    /// @notice Withdraws a Curvance Velodrome sAMM/vAMM position, and zaps it
    ///         into desired token (zapData.outputToken).
    /// @param router The Velodrome router address.
    /// @param zapData Zap instruction data to execute the Zap.
    /// @param swapData Array of swap instruction data to execute the Zap.
    /// @param recipient Address that should receive Zapped withdrawal.
    /// @return outAmount The output amount received from Zapping.
    function _exitVelodrome(
        address router,
        ZapperData calldata zapData,
        SwapperLib.Swap[] calldata swapData,
        address recipient
    ) internal returns (uint256 outAmount) {
        // Exit Velodrome sAMM/vAMM position.
        VelodromeLib.exitVelodrome(
            router,
            zapData.inputToken,
            zapData.inputAmount
        );

        uint256 numTokenSwaps = swapData.length;
        // Swap unwrapped tokens into `zapData.outputToken`.
        for (uint256 i; i < numTokenSwaps; ) {
            // Execute swap(s) into `zapData.outputToken`.
            SwapperLib._swapUnsafe(centralRegistry, swapData[i++]);
        }

        outAmount = CommonLib._getTokenBalance(zapData.outputToken);
        // Validate zap output is sufficient.
        if (outAmount < zapData.minimumOut) {
            revert ComplexZapper__SlippageError();
        }

        // Transfer output tokens to `recipient`.
        _transferToRecipient(zapData.outputToken, recipient, outAmount);
    }

    /// @notice Withdraws a Curvance Pendle market position, and zaps it
    ///         into desired token (zapData.outputToken).
    /// @param router The Pendle router address.
    /// @param isPt Whether lp token is PT or not.
    /// @param token The underlying token address of the SY.
    /// @param zapData Zap instruction data to execute the Zap.
    /// @param swapData Array of swap instruction data to execute the Zap.
    /// @param recipient Address that should receive Zapped withdrawal.
    /// @return outAmount The output amount received from Zapping.
    function _exitPendle(
        address router,
        bool isPt,
        address token,
        PendleLib.PendleData calldata data,
        ZapperData calldata zapData,
        SwapperLib.Swap[] calldata swapData,
        address recipient
    ) internal returns (uint256 outAmount) {
        // Exit Pendle market position.
        PendleLib.exitPendle(
            router,
            isPt,
            token,
            data,
            zapData.inputToken,
            zapData.inputAmount,
            0
        );

        uint256 numTokenSwaps = swapData.length;
        // Swap unwrapped tokens into `zapData.outputToken`.
        for (uint256 i; i < numTokenSwaps; ) {
            // Execute swap(s) into `zapData.outputToken`.
            SwapperLib._swapUnsafe(centralRegistry, swapData[i++]);
        }

        outAmount = CommonLib._getTokenBalance(zapData.outputToken);
        // Validate zap output is sufficient.
        if (outAmount < zapData.minimumOut) {
            revert ComplexZapper__SlippageError();
        }

        // Transfer output tokens to `recipient`.
        _transferToRecipient(zapData.outputToken, recipient, outAmount);
    }

    /// @notice Swap `inputToken` into desired pToken underlying tokens.
    /// @param inputToken The input token address.
    /// @param inputAmount The amount of `inputToken` to swap for underlying
    ///                    tokens.
    /// @param swapData Array of swap instruction data
    /// @param depositAsWrappedNative Used when `inputToken` is chain gas token,
    ///                           indicates depositing gas token into wrapper
    ///                           contract.
    function _swapForUnderlyings(
        address inputToken,
        uint256 inputAmount,
        SwapperLib.Swap[] memory swapData,
        bool depositAsWrappedNative
    ) internal {
        _prepareSwap(inputToken, inputAmount, depositAsWrappedNative);

        uint256 numTokenSwaps = swapData.length;
        // Swap `inputToken` into desired pToken underlying tokens.
        for (uint256 i; i < numTokenSwaps; ) {
            if (
                CommonLib._isNative(swapData[i].inputToken) &&
                depositAsWrappedNative
            ) {
                // Switch inputToken to wrapped native token address.
                swapData[i].inputToken = address(wrappedNative);
            }

            // Execute swap into underlying(s).
            SwapperLib._swapUnsafe(centralRegistry, swapData[i++]);
        }
    }
}
