// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { PendleLib } from "contracts/libraries/PendleLib.sol";
import { ComplexZapper } from "contracts/plugins/market/ComplexZapper.sol";
import { ZapperBase } from "contracts/plugins/ZapperBase.sol";
import { BaseSwapChecker, SwapperLib } from "./BaseSwapChecker.sol";

contract ComplexZapperBetaCalldataChecker is BaseSwapChecker {
    /// CONSTRUCTOR ///

    constructor(address _target) BaseSwapChecker(_target) {}

    /// EXTERNAL FUNCTIONS ///

    /// @notice Inspects calldata for compliance with other swap instruction
    ///         parameters.
    /// @dev Used on Zap/swap to inspect and validate calldata safety.
    /// @param swapData Zap/swap instruction data including both direct
    ///                 parameters and decodeable calldata.
    /// @param expectedRecipient User who will receive results of Zap/swap.
    function checkCalldata(
        SwapperLib.Swap memory swapData,
        address expectedRecipient
    ) external view override {
        if (swapData.target != target) {
            revert CalldataChecker__TargetError();
        }

        bytes4 funcSigHash = _getFuncSigHash(swapData.call);
        address recipient;
        address inputToken;
        uint256 inputAmount;
        address outputToken;

        if (funcSigHash == ComplexZapper.enterVelodrome.selector) {
            (
                address pToken,
                ComplexZapper.ZapperData memory desc,
                ,
                ,
                ,
                ,
                address _recipient
            ) = abi.decode(
                    _getFuncParams(swapData.call),
                    (
                        address,
                        ComplexZapper.ZapperData,
                        SwapperLib.Swap[],
                        address,
                        address,
                        bool,
                        address
                    )
                );
            recipient = _recipient;
            inputToken = desc.inputToken;
            inputAmount = desc.inputAmount;
            outputToken = pToken == address(0) ? desc.outputToken : pToken;
        } else if (funcSigHash == ComplexZapper.exitVelodrome.selector) {
            (
                ,
                ComplexZapper.ZapperData memory desc,
                ,
                address _recipient
            ) = abi.decode(
                    _getFuncParams(swapData.call),
                    (
                        address,
                        ComplexZapper.ZapperData,
                        SwapperLib.Swap[],
                        address
                    )
                );
            recipient = _recipient;
            inputToken = desc.inputToken;
            inputAmount = desc.inputAmount;
            outputToken = desc.outputToken;
        } else if (
            funcSigHash == ComplexZapper.redeemAndExitVelodrome.selector
        ) {
            (
                ZapperBase.RedemptionData memory redemptionData,
                ,
                ComplexZapper.ZapperData memory desc,
                ,
                address _recipient
            ) = abi.decode(
                    _getFuncParams(swapData.call),
                    (
                        ZapperBase.RedemptionData,
                        address,
                        ComplexZapper.ZapperData,
                        SwapperLib.Swap[],
                        address
                    )
                );
            recipient = _recipient;
            inputToken = redemptionData.mToken;
            inputAmount = desc.inputAmount;
            outputToken = desc.outputToken;
        } else if (funcSigHash == ComplexZapper.enterPendle.selector) {
            (
                address pToken,
                ComplexZapper.ZapperData memory desc,
                ,
                ,
                ,
                ,
                ,
                address _recipient
            ) = abi.decode(
                    _getFuncParams(swapData.call),
                    (
                        address,
                        ComplexZapper.ZapperData,
                        SwapperLib.Swap[],
                        address,
                        bool,
                        PendleLib.PendleData,
                        bool,
                        address
                    )
                );
            recipient = _recipient;
            inputToken = desc.inputToken;
            inputAmount = desc.inputAmount;
            outputToken = pToken == address(0) ? desc.outputToken : pToken;
        } else if (funcSigHash == ComplexZapper.exitPendle.selector) {
            (
                ,
                ,
                ,
                ,
                ComplexZapper.ZapperData memory desc,
                ,
                address _recipient
            ) = abi.decode(
                    _getFuncParams(swapData.call),
                    (
                        address,
                        bool,
                        address,
                        PendleLib.PendleData,
                        ComplexZapper.ZapperData,
                        SwapperLib.Swap[],
                        address
                    )
                );
            recipient = _recipient;
            inputToken = desc.inputToken;
            inputAmount = desc.inputAmount;
            outputToken = desc.outputToken;
        } else if (funcSigHash == ComplexZapper.redeemAndExitPendle.selector) {
            (
                ZapperBase.RedemptionData memory redemptionData,
                ,
                ,
                ,
                ,
                ComplexZapper.ZapperData memory desc,
                ,
                address _recipient
            ) = abi.decode(
                    _getFuncParams(swapData.call),
                    (
                        ZapperBase.RedemptionData,
                        address,
                        bool,
                        address,
                        PendleLib.PendleData,
                        ComplexZapper.ZapperData,
                        SwapperLib.Swap[],
                        address
                    )
                );
            recipient = _recipient;
            inputToken = redemptionData.mToken;
            inputAmount = desc.inputAmount;
            outputToken = desc.outputToken;
        } else {
            revert CalldataChecker__InvalidFuncSig();
        }

        if (recipient != expectedRecipient) {
            revert CalldataChecker__RecipientError();
        }

        if (inputToken != swapData.inputToken) {
            revert CalldataChecker__InputTokenError();
        }

        if (inputAmount != swapData.inputAmount) {
            revert CalldataChecker__InputAmountError();
        }

        if (outputToken != swapData.outputToken) {
            revert CalldataChecker__OutputTokenError();
        }
    }
}
