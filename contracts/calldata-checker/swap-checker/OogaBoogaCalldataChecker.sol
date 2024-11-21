// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { IOBRouter } from "contracts/interfaces/external/ooga/IOBRouter.sol";
import { BaseSwapChecker, SwapperLib } from "./BaseSwapChecker.sol";

/// @notice WARNING: Currently built for Router V1.
contract OogaBoogaCalldataChecker is BaseSwapChecker {
    /// CONSTANTS ///
    uint256 private constant _ONE_FOR_ZERO_MASK = 1 << 255;
    uint256 private constant _REVERSE_MASK =
        0x8000000000000000000000000000000000000000000000000000000000000000;

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
        if (funcSigHash == IOBRouter.swap.selector) {
            (IOBRouter.swapTokenInfo memory tokenInfo, , , ) = abi.decode(
                _getFuncParams(swapData.call),
                (IOBRouter.swapTokenInfo, bytes, address, uint32)
            );
            recipient = tokenInfo.outputReceiver;
            inputToken = tokenInfo.inputToken;
            inputAmount = tokenInfo.inputAmount;
            outputToken = tokenInfo.outputToken;
        } else if (funcSigHash == IOBRouter.swapERC20Permit.selector) {
            (, IOBRouter.swapTokenInfo memory tokenInfo, , , ) = abi.decode(
                _getFuncParams(swapData.call),
                (
                    IOBRouter.erc20PermitInfo,
                    IOBRouter.swapTokenInfo,
                    bytes,
                    address,
                    uint32
                )
            );

            recipient = tokenInfo.outputReceiver;
            inputToken = tokenInfo.inputToken;
            inputAmount = tokenInfo.inputAmount;
            outputToken = tokenInfo.outputToken;
        } else if (funcSigHash == IOBRouter.swapPermit2.selector) {
            (, IOBRouter.swapTokenInfo memory tokenInfo, , , ) = abi.decode(
                _getFuncParams(swapData.call),
                (
                    IOBRouter.permit2Info,
                    IOBRouter.swapTokenInfo,
                    bytes,
                    address,
                    uint32
                )
            );

            recipient = tokenInfo.outputReceiver;
            inputToken = tokenInfo.inputToken;
            inputAmount = tokenInfo.inputAmount;
            outputToken = tokenInfo.outputToken;
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
