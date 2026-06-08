// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { BaseSwapChecker } from "contracts/calldata-checker/swap-checker/BaseSwapChecker.sol";
import { PendleZapperMinimal } from "contracts/plugins/market/PendleZapperMinimal.sol";
import { PendleZapper } from "contracts/plugins/market/PendleZapper.sol";
import { BaseZapper } from "contracts/plugins/BaseZapper.sol";

import { PendleLib } from "contracts/libraries/PendleLib.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";

/// @notice Inspects the calldata for a PendleZapper zap action.
contract PendleZapperCalldataChecker is BaseSwapChecker {
    /// STORAGE ///
    /// @notice The only Pendle Router this checker permits the zapper to call.
    address public immutable pendleRouter;

    /// CONSTRUCTOR ///

    /// @param _target The address of the Pendle zapper contract.
    /// @param _pendleRouter The Pendle Router address allowed by this checker.
    constructor(
        address _target,
        address _pendleRouter
    ) BaseSwapChecker(_target) {
        if (_pendleRouter == address(0)) {
            revert CalldataChecker__TargetError();
        }

        pendleRouter = _pendleRouter;
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Inspects calldata for compliance with other swap instruction
    ///         parameters.
    /// @dev Used on swap to inspect and validate calldata safety.
    /// @param swapAction Swap action instructions including both direct
    ///                   parameters and decodeable calldata.
    /// @param expectedRecipient Address who will receive proceeds of
    ///                          `swapAction`.
    function checkCalldata(
        SwapperLib.Swap memory swapAction,
        address expectedRecipient
    ) external view override returns (uint256 minOutAmount) {
        if (swapAction.target != target) {
            revert CalldataChecker__TargetError();
        }

        bytes4 funcSigHash = _getFuncSigHash(swapAction.call);
        address recipient;
        address inputToken;
        uint256 inputAmount;
        address outputToken;
        address router;

        if (funcSigHash == PendleZapperMinimal.enterPendle.selector) {
            (
                address cToken,
                address routerParam,
                ,
                ,
                ,
                PendleZapperMinimal.ZapAction memory desc,
                ,
                uint256 expectedShares,
                ,
                address receiver
            ) = abi.decode(
                    _getFuncParams(swapAction.call),
                    (
                        address,
                        address,
                        address,
                        bool,
                        PendleLib.PendleAction,
                        PendleZapperMinimal.ZapAction,
                        SwapperLib.Swap[],
                        uint256,
                        bool,
                        address
                    )
                );
            recipient = receiver;
            inputToken = desc.inputToken;
            inputAmount = desc.inputAmount;
            outputToken = cToken;
            minOutAmount = expectedShares;
            router = routerParam;

            if (cToken == address(0)) {
                revert CalldataChecker__OutputTokenError();
            }

            if (desc.minimumOut == 0) {
                revert CalldataChecker__InvalidMinOut();
            }
        } else if (funcSigHash == PendleZapper.exitPendle.selector) {
            (
                ,
                address routerParam,
                ,
                ,
                ,
                PendleZapperMinimal.ZapAction memory desc,
                ,
                address receiver
            ) = abi.decode(
                    _getFuncParams(swapAction.call),
                    (
                        address,
                        address,
                        address,
                        bool,
                        PendleLib.PendleAction,
                        PendleZapperMinimal.ZapAction,
                        SwapperLib.Swap[],
                        address
                    )
                );
            recipient = receiver;
            inputToken = desc.inputToken;
            inputAmount = desc.inputAmount;
            outputToken = desc.outputToken;
            minOutAmount = desc.minimumOut;
            router = routerParam;
        } else if (funcSigHash == PendleZapper.redeemAndExitPendle.selector) {
            (
                ,
                address routerParam,
                ,
                ,
                ,
                BaseZapper.RedeemAction memory redeemAction,
                PendleZapperMinimal.ZapAction memory desc,
                ,
                address receiver
            ) = abi.decode(
                    _getFuncParams(swapAction.call),
                    (
                        address,
                        address,
                        address,
                        bool,
                        PendleLib.PendleAction,
                        BaseZapper.RedeemAction,
                        PendleZapperMinimal.ZapAction,
                        SwapperLib.Swap[],
                        address
                    )
                );
            recipient = receiver;
            inputToken = redeemAction.cToken;
            inputAmount = redeemAction.shares;
            outputToken = desc.outputToken;
            minOutAmount = desc.minimumOut;
            router = routerParam;
        } else {
            revert CalldataChecker__InvalidFuncSig();
        }

        if (router != pendleRouter) {
            revert CalldataChecker__TargetError();
        }

        if (recipient != expectedRecipient) {
            revert CalldataChecker__RecipientError();
        }

        if (inputToken != swapAction.inputToken) {
            revert CalldataChecker__InputTokenError();
        }

        if (inputAmount != swapAction.inputAmount) {
            revert CalldataChecker__InputAmountError();
        }

        if (outputToken != swapAction.outputToken) {
            revert CalldataChecker__OutputTokenError();
        }

        if (minOutAmount == 0) {
            revert CalldataChecker__InvalidMinOut();
        }
    }
}
