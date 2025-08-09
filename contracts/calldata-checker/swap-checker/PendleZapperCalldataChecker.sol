// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { PendleZapper } from "contracts/plugins/market/PendleZapper.sol";
import { BaseZapper } from "contracts/plugins/BaseZapper.sol";
import { BaseSwapChecker } from "./BaseSwapChecker.sol";
import { PendleLib } from "contracts/libraries/PendleLib.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";

contract PendleZapperCalldataChecker is BaseSwapChecker {
    /// CONSTRUCTOR ///

    constructor(address _target) BaseSwapChecker(_target) {}

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
    ) external view override {
        if (swapAction.target != target) {
            revert CalldataChecker__TargetError();
        }

        bytes4 funcSigHash = _getFuncSigHash(swapAction.call);
        address recipient;
        address inputToken;
        uint256 inputAmount;
        address outputToken;

        if (funcSigHash == PendleZapper.enterPendle.selector) {
            (
                address cToken,
                ,
                ,
                ,
                PendleZapper.ZapAction memory desc,
                ,
                ,
                ,
                address receiver
            ) = abi.decode(
                    _getFuncParams(swapAction.call),
                    (
                        address,
                        address,
                        bool,
                        PendleLib.PendleAction,
                        PendleZapper.ZapAction,
                        SwapperLib.Swap[],
                        uint256,
                        bool,
                        address
                    )
                );
            recipient = receiver;
            inputToken = desc.inputToken;
            inputAmount = desc.inputAmount;
            outputToken = cToken == address(0) ? desc.outputToken : cToken;
        } else if (funcSigHash == PendleZapper.exitPendle.selector) {
            (
                ,
                ,
                ,
                ,
                PendleZapper.ZapAction memory desc,
                ,
                address receiver
            ) = abi.decode(
                    _getFuncParams(swapAction.call),
                    (
                        address,
                        address,
                        bool,
                        PendleLib.PendleAction,
                        PendleZapper.ZapAction,
                        SwapperLib.Swap[],
                        address
                    )
                );
            recipient = receiver;
            inputToken = desc.inputToken;
            inputAmount = desc.inputAmount;
            outputToken = desc.outputToken;
        } else if (funcSigHash == PendleZapper.redeemAndExitPendle.selector) {
            (
                ,
                ,
                ,
                ,
                BaseZapper.RedeemAction memory redeemAction,
                PendleZapper.ZapAction memory desc,
                ,
                address receiver
            ) = abi.decode(
                    _getFuncParams(swapAction.call),
                    (
                        address,
                        address,
                        bool,
                        PendleLib.PendleAction,
                        BaseZapper.RedeemAction,
                        PendleZapper.ZapAction,
                        SwapperLib.Swap[],
                        address
                    )
                );
            recipient = receiver;
            inputToken = redeemAction.cToken;
            inputAmount = desc.inputAmount;
            outputToken = desc.outputToken;
        } else {
            revert CalldataChecker__InvalidFuncSig();
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
    }
}
