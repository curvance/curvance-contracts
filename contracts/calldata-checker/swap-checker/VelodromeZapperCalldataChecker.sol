// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { VelodromeZapper } from "contracts/plugins/market/VelodromeZapper.sol";
import { ZapperBase } from "contracts/plugins/ZapperBase.sol";
import { BaseSwapChecker } from "./BaseSwapChecker.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";

contract VelodromeZapperCalldataChecker is BaseSwapChecker {
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

        if (funcSigHash == VelodromeZapper.enterVelodrome.selector) {
            (
                address cToken,
                VelodromeZapper.ZapperData memory desc,
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
                        VelodromeZapper.ZapperData,
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
            outputToken = cToken == address(0) ? desc.outputToken : cToken;
        } else if (funcSigHash == VelodromeZapper.exitVelodrome.selector) {
            (
                ,
                VelodromeZapper.ZapperData memory desc,
                ,
                address _recipient
            ) = abi.decode(
                    _getFuncParams(swapData.call),
                    (
                        address,
                        VelodromeZapper.ZapperData,
                        SwapperLib.Swap[],
                        address
                    )
                );
            recipient = _recipient;
            inputToken = desc.inputToken;
            inputAmount = desc.inputAmount;
            outputToken = desc.outputToken;
        } else if (
            funcSigHash == VelodromeZapper.redeemAndExitVelodrome.selector
        ) {
            (
                ZapperBase.RedemptionData memory redemptionData,
                ,
                VelodromeZapper.ZapperData memory desc,
                ,
                address _recipient
            ) = abi.decode(
                    _getFuncParams(swapData.call),
                    (
                        ZapperBase.RedemptionData,
                        address,
                        VelodromeZapper.ZapperData,
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
