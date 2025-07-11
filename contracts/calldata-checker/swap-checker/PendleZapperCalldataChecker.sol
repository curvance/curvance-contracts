// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { PendleZapper } from "contracts/plugins/market/PendleZapper.sol";
import { ZapperBase } from "contracts/plugins/ZapperBase.sol";
import { BaseSwapChecker } from "./BaseSwapChecker.sol";
import { PendleLib } from "contracts/libraries/PendleLib.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";

contract PendleZapperCalldataChecker is BaseSwapChecker {
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

        if (funcSigHash == PendleZapper.enterPendle.selector) {
            (
                address cToken,
                PendleZapper.ZapperData memory desc,
                ,
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
                        PendleZapper.ZapperData,
                        SwapperLib.Swap[],
                        address,
                        bool,
                        PendleLib.PendleData,
                        uint256,
                        bool,
                        address
                    )
                );
            recipient = _recipient;
            inputToken = desc.inputToken;
            inputAmount = desc.inputAmount;
            outputToken = cToken == address(0) ? desc.outputToken : cToken;
        } else if (funcSigHash == PendleZapper.exitPendle.selector) {
            (
                ,
                ,
                ,
                ,
                PendleZapper.ZapperData memory desc,
                ,
                address _recipient
            ) = abi.decode(
                    _getFuncParams(swapData.call),
                    (
                        address,
                        bool,
                        address,
                        PendleLib.PendleData,
                        PendleZapper.ZapperData,
                        SwapperLib.Swap[],
                        address
                    )
                );
            recipient = _recipient;
            inputToken = desc.inputToken;
            inputAmount = desc.inputAmount;
            outputToken = desc.outputToken;
        } else if (funcSigHash == PendleZapper.redeemAndExitPendle.selector) {
            (
                ZapperBase.RedemptionData memory redemptionData,
                ,
                ,
                ,
                ,
                PendleZapper.ZapperData memory desc,
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
                        PendleZapper.ZapperData,
                        SwapperLib.Swap[],
                        address
                    )
                );
            recipient = _recipient;
            inputToken = redemptionData.cToken;
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
