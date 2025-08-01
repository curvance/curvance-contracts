// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { VelodromeZapper } from "contracts/plugins/market/VelodromeZapper.sol";
import { BaseZapper } from "contracts/plugins/BaseZapper.sol";
import { BaseSwapChecker } from "./BaseSwapChecker.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";

contract VelodromeZapperCalldataChecker is BaseSwapChecker {
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

        if (funcSigHash == VelodromeZapper.enterVelodrome.selector) {
            (
                address cToken,
                VelodromeZapper.ZapAction memory desc,
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
                        VelodromeZapper.ZapAction,
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
                VelodromeZapper.ZapAction memory desc,
                ,
                address _recipient
            ) = abi.decode(
                    _getFuncParams(swapAction.call),
                    (
                        address,
                        VelodromeZapper.ZapAction,
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
                BaseZapper.RedeemAction memory redeemAction,
                ,
                VelodromeZapper.ZapAction memory desc,
                ,
                address _recipient
            ) = abi.decode(
                    _getFuncParams(swapAction.call),
                    (
                        BaseZapper.RedeemAction,
                        address,
                        VelodromeZapper.ZapAction,
                        SwapperLib.Swap[],
                        address
                    )
                );
            recipient = _recipient;
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
