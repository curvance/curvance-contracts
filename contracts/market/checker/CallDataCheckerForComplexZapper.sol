// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { ComplexZapper } from "contracts/market/utils/ComplexZapper.sol";
import { UniswapV3Pool } from "contracts/interfaces/external/uniswap/UniswapV3Pool.sol";
import { CallDataCheckerBase, SwapperLib } from "./CallDataCheckerBase.sol";

contract CallDataCheckerForComplexZapper is CallDataCheckerBase {
    /// CONSTRUCTOR ///

    constructor(address _target) CallDataCheckerBase(_target) {}

    /// EXTERNAL FUNCTIONS ///

    /// @notice Inspects calldata for compliance with other swap instruction
    ///         parameters.
    /// @dev Used on Zap/swap to inspect and validate calldata safety.
    /// @param swapData Zap/swap instruction data including both direct
    ///                 parameters and decodeable calldata.
    /// @param expectedRecipient User who will receive results of Zap/swap.
    function checkCallData(
        SwapperLib.Swap memory swapData,
        address expectedRecipient
    ) external view override {
        if (swapData.target != target) {
            revert CallDataChecker__TargetError();
        }

        bytes4 funcSigHash = getFuncSigHash(swapData.call);
        address recipient;
        address inputToken;
        uint256 inputAmount;
        address outputToken;
        if (funcSigHash == ComplexZapper.enterCurve.selector) {
            (
                address cToken,
                ComplexZapper.ZapperData memory desc,
                ,
                ,
                ,
                address _recipient
            ) = abi.decode(
                    getFuncParams(swapData.call),
                    (
                        address,
                        ComplexZapper.ZapperData,
                        SwapperLib.Swap[],
                        address,
                        address[],
                        address
                    )
                );
            recipient = _recipient;
            inputToken = desc.inputToken;
            inputAmount = desc.inputAmount;
            outputToken = cToken == address(0) ? desc.outputToken : cToken;
        } else if (funcSigHash == ComplexZapper.exitCurve.selector) {
            (
                ,
                ComplexZapper.ZapperData memory desc,
                ,
                ,
                ,
                ,
                address _recipient
            ) = abi.decode(
                    getFuncParams(swapData.call),
                    (
                        address,
                        ComplexZapper.ZapperData,
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
                ComplexZapper.RedemptionData memory redemptionData,
                ,
                ComplexZapper.ZapperData memory desc,
                ,
                ,
                ,
                ,
                address _recipient
            ) = abi.decode(
                    getFuncParams(swapData.call),
                    (
                        ComplexZapper.RedemptionData,
                        address,
                        ComplexZapper.ZapperData,
                        address[],
                        uint256,
                        uint256,
                        SwapperLib.Swap[],
                        address
                    )
                );
            recipient = _recipient;
            inputToken = redemptionData.cToken;
            inputAmount = desc.inputAmount;
            outputToken = desc.outputToken;
        } else if (funcSigHash == ComplexZapper.enterBalancer.selector) {
            (
                address cToken,
                ComplexZapper.ZapperData memory desc,
                ,
                ,
                ,
                ,
                address _recipient
            ) = abi.decode(
                    getFuncParams(swapData.call),
                    (
                        address,
                        ComplexZapper.ZapperData,
                        SwapperLib.Swap[],
                        address,
                        bytes32,
                        address[],
                        address
                    )
                );
            recipient = _recipient;
            inputToken = desc.inputToken;
            inputAmount = desc.inputAmount;
            outputToken = cToken == address(0) ? desc.outputToken : cToken;
        } else if (funcSigHash == ComplexZapper.exitBalancer.selector) {
            (
                ,
                ComplexZapper.ZapperData memory desc,
                ,
                ,
                address _recipient
            ) = abi.decode(
                    getFuncParams(swapData.call),
                    (
                        ComplexZapper.BPTRedemption,
                        ComplexZapper.ZapperData,
                        address[],
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
                ComplexZapper.RedemptionData memory redemptionData,
                ,
                ComplexZapper.ZapperData memory desc,
                ,
                ,
                address _recipient
            ) = abi.decode(
                    getFuncParams(swapData.call),
                    (
                        ComplexZapper.RedemptionData,
                        ComplexZapper.BPTRedemption,
                        ComplexZapper.ZapperData,
                        address[],
                        SwapperLib.Swap[],
                        address
                    )
                );
            recipient = _recipient;
            inputToken = redemptionData.cToken;
            inputAmount = desc.inputAmount;
            outputToken = desc.outputToken;
        } else if (funcSigHash == ComplexZapper.enterVelodrome.selector) {
            (
                address cToken,
                ComplexZapper.ZapperData memory desc,
                ,
                ,
                ,
                address _recipient
            ) = abi.decode(
                    getFuncParams(swapData.call),
                    (
                        address,
                        ComplexZapper.ZapperData,
                        SwapperLib.Swap[],
                        address,
                        address,
                        address
                    )
                );
            recipient = _recipient;
            inputToken = desc.inputToken;
            inputAmount = desc.inputAmount;
            outputToken = cToken == address(0) ? desc.outputToken : cToken;
        } else if (funcSigHash == ComplexZapper.exitVelodrome.selector) {
            (
                ,
                ComplexZapper.ZapperData memory desc,
                ,
                address _recipient
            ) = abi.decode(
                    getFuncParams(swapData.call),
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
                ComplexZapper.RedemptionData memory redemptionData,
                ,
                ComplexZapper.ZapperData memory desc,
                ,
                address _recipient
            ) = abi.decode(
                    getFuncParams(swapData.call),
                    (
                        ComplexZapper.RedemptionData,
                        address,
                        ComplexZapper.ZapperData,
                        SwapperLib.Swap[],
                        address
                    )
                );
            recipient = _recipient;
            inputToken = redemptionData.cToken;
            inputAmount = desc.inputAmount;
            outputToken = desc.outputToken;
        } else {
            revert CallDataChecker__InvalidFuncSig();
        }

        if (recipient != expectedRecipient) {
            revert CallDataChecker__RecipientError();
        }

        if (inputToken != swapData.inputToken) {
            revert CallDataChecker__InputTokenError();
        }

        if (inputAmount != swapData.inputAmount) {
            revert CallDataChecker__InputAmountError();
        }

        if (outputToken != swapData.outputToken) {
            revert CallDataChecker__OutputTokenError();
        }
    }
}
