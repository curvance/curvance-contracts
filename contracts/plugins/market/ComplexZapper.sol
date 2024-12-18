// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { CommonLib } from "contracts/libraries/CommonLib.sol";
import { CurveLib } from "contracts/libraries/CurveLib.sol";
import { BalancerLib } from "contracts/libraries/BalancerLib.sol";
import { VelodromeLib } from "contracts/libraries/VelodromeLib.sol";
import { PendleLib } from "contracts/libraries/PendleLib.sol";
import { ReentrancyGuard } from "contracts/libraries/external/ReentrancyGuard.sol";
import { ERC165Checker } from "contracts/libraries/external/ERC165Checker.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";

import { IWETH } from "contracts/interfaces/IWETH.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IPluginDelegable } from "contracts/interfaces/IPluginDelegable.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IVeloPair } from "contracts/interfaces/external/velodrome/IVeloPair.sol";
import { IPToken } from "contracts/interfaces/IPToken.sol";

contract ComplexZapper is ReentrancyGuard {
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

    /// @param pToken The address of the pToken corresponding to Curve lp
    ///               token to be exited.
    /// @param shares The amount of shares to redeemed.
    /// @param forceRedeemCollateral Whether the collateral should be always
    ///                              reduced from callers collateralPosted.
    struct RedemptionData {
        address pToken;
        uint256 shares;
        bool forceRedeemCollateral;
    }

    /// @param balancerVault The Balancer vault address.
    /// @param balancerPoolId The BPT pool ID.
    /// @param underlyingTokens The underlying token addresses of the BPT.
    struct BalancerData {
        address balancerVault;
        bytes32 balancerPoolId;
        address[] underlyingTokens;
    }

    /// CONSTANTS ///

    /// @notice Curvance DAO hub.
    ICentralRegistry public immutable centralRegistry;
    /// @notice Address of the Market Manager linked to this contract.
    IMarketManager public immutable marketManager;
    /// @notice The address of wrapped native token on this chain.
    address public immutable wrappedNative;

    /// ERRORS ///

    error ComplexZapper__ExecutionError();
    error ComplexZapper__InvalidCentralRegistry();
    error ComplexZapper__InvalidMarketManager();
    error ComplexZapper__PTokenUnderlyingIsNotInputToken();
    error ComplexZapper__Unauthorized();
    error ComplexZapper__SlippageError();

    /// CONSTRUCTOR ///

    receive() external payable {}

    constructor(
        ICentralRegistry centralRegistry_,
        address marketManager_,
        address wrappedNative_
    ) {
        if (
            !ERC165Checker.supportsInterface(
                address(centralRegistry_),
                type(ICentralRegistry).interfaceId
            )
        ) {
            revert ComplexZapper__InvalidCentralRegistry();
        }

        centralRegistry = centralRegistry_;

        // Validate that `marketManager_` is configured as a market manager
        // inside the Central Registry.
        if (!centralRegistry.isMarketManager(marketManager_)) {
            revert ComplexZapper__InvalidMarketManager();
        }

        marketManager = IMarketManager(marketManager_);
        wrappedNative = wrappedNative_;
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Swaps then deposits `zapData.inputToken` into Curve lp token,
    ///         and enters into Curvance position.
    /// @dev Requires plugin approval for collateralization.
    /// @param pToken The Curvance pToken address.
    /// @param zapData Zap instruction data to execute the Zap.
    /// @param swapData Array of swap instruction data to execute the Zap.
    /// @param lpMinter The minter address of the Curve lp token.
    /// @param tokens The underlying coins of the Curve lp token.
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
        uint256 lpOutAmount = CurveLib.enterCurve(
            lpMinter,
            zapData.outputToken,
            tokens,
            zapData.minimumOut
        );

        // Enter Curvance pToken position.
        outAmount = _enterCurvance(
            pToken,
            zapData.outputToken,
            lpOutAmount,
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
            IPToken(redemptionData.pToken),
            redemptionData.shares,
            redemptionData.forceRedeemCollateral,
            zapData.inputToken,
            zapData.inputAmount,
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
    /// @param collateralize Whether the zapped deposit should be
    ///                      collateralized afterwards.
    /// @param recipient Address that should receive Zapped deposit.
    /// @return outAmount The output amount received from Zapping.
    function enterBalancer(
        address pToken,
        BalancerData calldata balancerData,
        ZapperData calldata zapData,
        SwapperLib.Swap[] calldata swapData,
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
        uint256 lpOutAmount = BalancerLib.enterBalancer(
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
            lpOutAmount,
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
            IPToken(redemptionData.pToken),
            redemptionData.shares,
            redemptionData.forceRedeemCollateral,
            zapData.inputToken,
            zapData.inputAmount,
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
            CommonLib.getTokenBalance(IVeloPair(zapData.outputToken).token0()),
            CommonLib.getTokenBalance(IVeloPair(zapData.outputToken).token1()),
            zapData.minimumOut
        );

        // Enter Curvance pToken position.
        outAmount = _enterCurvance(
            pToken,
            zapData.outputToken,
            outAmount,
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
            IPToken(redemptionData.pToken),
            redemptionData.shares,
            redemptionData.forceRedeemCollateral,
            zapData.inputToken,
            zapData.inputAmount,
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
        outAmount = PendleLib.enterPendle(
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
            outAmount,
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
            IPToken(redemptionData.pToken),
            redemptionData.shares,
            redemptionData.forceRedeemCollateral,
            zapData.inputToken,
            zapData.inputAmount,
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

    /// @notice Routes lp/BPT into Curvance pToken contract.
    /// @param pToken The Curvance pToken address.
    /// @param inputToken The input token address, should match
    ///                   pToken.underlying().
    /// @param amount The amount of `inputToken` to deposit into pToken
    ///               position.
    /// @param collateralize Whether the zapped deposit should be
    ///                      collateralized afterwards.
    /// @param recipient Address that should receive Curvance pTokens.
    /// @return The output amount of pTokens received.
    function _enterCurvance(
        address pToken,
        address inputToken,
        uint256 amount,
        bool collateralize,
        address recipient
    ) internal returns (uint256) {
        // pToken not configured so transfer their token back and return.
        if (pToken == address(0)) {
            SafeTransferLib.safeTransfer(inputToken, recipient, amount);
            return amount;
        }

        // Validate that `pToken` is listed inside the associated
        // Market Manager.
        if (!marketManager.isListed(pToken)) {
            revert ComplexZapper__Unauthorized();
        }

        // Validate inputToken matches underlying token of pToken contract.
        if (IPToken(pToken).underlying() != inputToken) {
            revert ComplexZapper__PTokenUnderlyingIsNotInputToken();
        }

        // Approve pToken to take `inputToken`.
        SwapperLib._approveTokenIfNeeded(inputToken, pToken, amount);

        uint256 priorBalance = IERC20(pToken).balanceOf(recipient);

        uint256 shares;
        // The user is trusting this plugin to not use their delegation
        // approval for nefarious reasons such as keeping them stuck in
        // positions, so lets validate that the recipient is a delegate
        // as well.
        // Enter Curvance pToken position and collateralize
        if (collateralize && msg.sender == recipient) {
            shares = IPToken(pToken).depositAsCollateral(amount, msg.sender);
        } else if (
            collateralize &&
            msg.sender != recipient &&
            IPluginDelegable(pToken).isDelegate(recipient, msg.sender)
        ) {
            shares = IPToken(pToken).depositAsCollateralFor(amount, recipient);
        }
        // Enter Curvance pToken position,
        else {
            shares = IPToken(pToken).deposit(amount, recipient);
        }

        // Make sure `recipient` got pTokens.
        if (shares == 0) {
            revert ComplexZapper__ExecutionError();
        }

        // Remove any leftover approval.
        SwapperLib._removeApprovalIfNeeded(inputToken, pToken);

        // Bubble up how many pTokens `recipient` received.
        return IERC20(pToken).balanceOf(recipient) - priorBalance;
    }

    /// @notice Exits a Curvance position.
    /// @param pToken The address of the pToken to be exited.
    /// @param shares The amount of shares to redeemed.
    /// @param forceRedeemCollateral Whether the collateral should be always
    ///                              reduced from callers collateralPosted.
    /// @param underlying The expected underlying token of `pToken`.
    /// @param expectedAssets The amount of assets expected to be redeemed
    ///                       on exiting Curvance position.
    function _exitCurvance(
        IPToken pToken,
        uint256 shares,
        bool forceRedeemCollateral,
        address underlying,
        uint256 expectedAssets,
        address recipient
    ) internal {
        if (pToken.underlying() != underlying) {
            revert ComplexZapper__ExecutionError();
        }

        uint256 assets;

        // Transfer underlying lp tokens to the Zapper.
        if (forceRedeemCollateral) {
            assets = pToken.redeemCollateralFor(
                shares,
                address(this),
                msg.sender
            );
        } else {
            assets = pToken.redeemFor(shares, address(this), msg.sender);
        }

        // Validate output of redemption is sufficient.
        if (assets < expectedAssets) {
            revert ComplexZapper__ExecutionError();
        }

        // Return any excess assets remaining back to the user.
        if (assets > expectedAssets) {
            _transferToRecipient(
                underlying,
                recipient,
                assets - expectedAssets
            );
        }
    }

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
            SwapperLib.swapUnsafe(centralRegistry, swapData[i++]);
        }

        outAmount = CommonLib.getTokenBalance(zapData.outputToken);
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
            SwapperLib.swapUnsafe(centralRegistry, swapData[i++]);
        }

        outAmount = CommonLib.getTokenBalance(zapData.outputToken);
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
            SwapperLib.swapUnsafe(centralRegistry, swapData[i++]);
        }

        outAmount = CommonLib.getTokenBalance(zapData.outputToken);
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
            zapData.inputAmount
        );

        uint256 numTokenSwaps = swapData.length;
        // Swap unwrapped tokens into `zapData.outputToken`.
        for (uint256 i; i < numTokenSwaps; ) {
            // Execute swap(s) into `zapData.outputToken`.
            SwapperLib.swapUnsafe(centralRegistry, swapData[i++]);
        }

        outAmount = CommonLib.getTokenBalance(zapData.outputToken);
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
        // If the input token is chain gas token, check if it should be
        // wrapped.
        if (CommonLib.isETH(inputToken)) {
            // Validate message has gas token attached.
            if (inputAmount != msg.value) {
                revert ComplexZapper__ExecutionError();
            }

            if (depositAsWrappedNative) {
                IWETH(wrappedNative).deposit{ value: inputAmount }();
            }
        } else {
            SafeTransferLib.safeTransferFrom(
                inputToken,
                msg.sender,
                address(this),
                inputAmount
            );
        }

        uint256 numTokenSwaps = swapData.length;
        // Swap `inputToken` into desired pToken underlying tokens.
        for (uint256 i; i < numTokenSwaps; ) {
            if (
                CommonLib.isETH(swapData[i].inputToken) &&
                depositAsWrappedNative
            ) {
                // Switch inputToken to wrapped native token address.
                swapData[i].inputToken = address(wrappedNative);
            }

            // Execute swap into underlying(s).
            SwapperLib.swapUnsafe(centralRegistry, swapData[i++]);
        }
    }

    /// @notice Helper function for efficiently transferring tokens
    ///         to desired user.
    /// @param token The token to transfer to `recipient`,
    ///              this can be the network gas token.
    /// @param recipient The user receiving `token`.
    /// @param amount The amount of `token` to be transferred to `recipient`.
    function _transferToRecipient(
        address token,
        address recipient,
        uint256 amount
    ) internal {
        if (CommonLib.isETH(token)) {
            return SafeTransferLib.safeTransferETH(recipient, amount);
        }

        SafeTransferLib.safeTransfer(token, recipient, amount);
    }
}
