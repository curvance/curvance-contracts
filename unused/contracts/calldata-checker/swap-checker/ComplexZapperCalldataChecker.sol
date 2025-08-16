// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

import { PendleLib } from "contracts/libraries/PendleLib.sol";
import { ComplexZapper } from "contracts/plugins/market/ComplexZapper.sol";
import { BaseZapper } from "contracts/plugins/BaseZapper.sol";
import { BaseSwapChecker, SwapperLib } from "./BaseSwapChecker.sol";

contract ComplexZapperCalldataChecker is BaseSwapChecker {
    /// CONSTRUCTOR ///

    constructor(address _target) BaseSwapChecker(_target) {}

    /// EXTERNAL FUNCTIONS ///

    /// @notice Inspects calldata for compliance with other swap instruction
    ///         parameters.
    /// @dev Used on Zap/swap to inspect and validate calldata safety.
    /// @param swapAction Zap/swap instruction data including both direct
    ///                 parameters and decodeable calldata.
    /// @param expectedRecipient User who will receive results of Zap/swap.
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
        if (funcSigHash == ComplexZapper.enterCurve.selector) {
            (
                address pToken,
                ComplexZapper.ZapAction memory desc,
                ,
                ,
                ,
                ,
                ,
                address _recipient
            ) = abi.decode(
                    _getFuncParams(swapAction.call),
                    (
                        address,
                        ComplexZapper.ZapAction,
                        SwapperLib.Swap[],
                        address,
                        address[],
                        uint256,
                        bool,
                        address
                    )
                );
            recipient = _recipient;
            inputToken = desc.inputToken;
            inputAmount = desc.inputAmount;
            outputToken = pToken == address(0) ? desc.outputToken : pToken;
        } else if (funcSigHash == ComplexZapper.exitCurve.selector) {
            (
                ,
                ComplexZapper.ZapAction memory desc,
                ,
                ,
                ,
                ,
                address _recipient
            ) = abi.decode(
                    _getFuncParams(swapAction.call),
                    (
                        address,
                        ComplexZapper.ZapAction,
                        address[],
                        uint256,
                        uint256,
                        SwapperLib.Swap[],
                        address
                    )
                );
            recipient = _recipient;
            inputToken = desc.inputToken;
            inputAmount = desc.inputAmount;
            outputToken = desc.outputToken;
        } else if (funcSigHash == ComplexZapper.redeemAndExitCurve.selector) {
            (
                BaseZapper.RedeemAction memory redeemAction,
                ,
                ComplexZapper.ZapAction memory desc,
                ,
                ,
                ,
                ,
                address _recipient
            ) = abi.decode(
                    _getFuncParams(swapAction.call),
                    (
                        BaseZapper.RedeemAction,
                        address,
                        ComplexZapper.ZapAction,
                        address[],
                        uint256,
                        uint256,
                        SwapperLib.Swap[],
                        address
                    )
                );
            recipient = _recipient;
            inputToken = redeemAction.mToken;
            inputAmount = desc.inputAmount;
            outputToken = desc.outputToken;
        } else if (funcSigHash == ComplexZapper.enterBalancer.selector) {
            (
                address pToken,
                ,
                ComplexZapper.ZapAction memory desc,
                ,
                ,
                ,
                address _recipient
            ) = abi.decode(
                    _getFuncParams(swapAction.call),
                    (
                        address,
                        ComplexZapper.BalancerData,
                        ComplexZapper.ZapAction,
                        SwapperLib.Swap[],
                        uint256,
                        bool,
                        address
                    )
                );
            recipient = _recipient;
            inputToken = desc.inputToken;
            inputAmount = desc.inputAmount;
            outputToken = pToken == address(0) ? desc.outputToken : pToken;
        } else if (funcSigHash == ComplexZapper.exitBalancer.selector) {
            (
                ,
                ComplexZapper.ZapAction memory desc,
                ,
                ,
                ,
                address _recipient
            ) = abi.decode(
                    _getFuncParams(swapAction.call),
                    (
                        ComplexZapper.BalancerData,
                        ComplexZapper.ZapAction,
                        bool,
                        uint256,
                        SwapperLib.Swap[],
                        address
                    )
                );
            recipient = _recipient;
            inputToken = desc.inputToken;
            inputAmount = desc.inputAmount;
            outputToken = desc.outputToken;
        } else if (
            funcSigHash == ComplexZapper.redeemAndExitBalancer.selector
        ) {
            (
                BaseZapper.RedeemAction memory redeemAction,
                ,
                ComplexZapper.ZapAction memory desc,
                ,
                ,
                ,
                address _recipient
            ) = abi.decode(
                    _getFuncParams(swapAction.call),
                    (
                        BaseZapper.RedeemAction,
                        ComplexZapper.BalancerData,
                        ComplexZapper.ZapAction,
                        bool,
                        uint256,
                        SwapperLib.Swap[],
                        address
                    )
                );
            recipient = _recipient;
            inputToken = redeemAction.mToken;
            inputAmount = desc.inputAmount;
            outputToken = desc.outputToken;
        } else if (funcSigHash == ComplexZapper.enterVelodrome.selector) {
            (
                address pToken,
                ComplexZapper.ZapAction memory desc,
                ,
                ,
                ,
                ,
                ,
                address _recipient
            ) = abi.decode(
                    _getFuncParams(swapAction.call),
                    (
                        address,
                        ComplexZapper.ZapAction,
                        SwapperLib.Swap[],
                        address,
                        address,
                        uint256,
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
                ComplexZapper.ZapAction memory desc,
                ,
                address _recipient
            ) = abi.decode(
                    _getFuncParams(swapAction.call),
                    (
                        address,
                        ComplexZapper.ZapAction,
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
                BaseZapper.RedeemAction memory redeemAction,
                ,
                ComplexZapper.ZapAction memory desc,
                ,
                address _recipient
            ) = abi.decode(
                    _getFuncParams(swapAction.call),
                    (
                        BaseZapper.RedeemAction,
                        address,
                        ComplexZapper.ZapAction,
                        SwapperLib.Swap[],
                        address
                    )
                );
            recipient = _recipient;
            inputToken = redeemAction.mToken;
            inputAmount = desc.inputAmount;
            outputToken = desc.outputToken;
        } else if (funcSigHash == ComplexZapper.enterPendle.selector) {
            (
                address pToken,
                ComplexZapper.ZapAction memory desc,
                ,
                ,
                ,
                ,
                ,
                ,
                address _recipient
            ) = abi.decode(
                    _getFuncParams(swapAction.call),
                    (
                        address,
                        ComplexZapper.ZapAction,
                        SwapperLib.Swap[],
                        address,
                        bool,
                        PendleLib.PendleAction,
                        uint256,
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
                ComplexZapper.ZapAction memory desc,
                ,
                address _recipient
            ) = abi.decode(
                    _getFuncParams(swapAction.call),
                    (
                        address,
                        bool,
                        address,
                        PendleLib.PendleAction,
                        ComplexZapper.ZapAction,
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
                BaseZapper.RedeemAction memory redeemAction,
                ,
                ,
                ,
                ,
                ComplexZapper.ZapAction memory desc,
                ,
                address _recipient
            ) = abi.decode(
                    _getFuncParams(swapAction.call),
                    (
                        BaseZapper.RedeemAction,
                        address,
                        bool,
                        address,
                        PendleLib.PendleAction,
                        ComplexZapper.ZapAction,
                        SwapperLib.Swap[],
                        address
                    )
                );
            recipient = _recipient;
            inputToken = redeemAction.mToken;
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
