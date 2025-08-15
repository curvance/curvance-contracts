// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { BaseSwapChecker } from "./BaseSwapChecker.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";

import { IOBRouter } from "contracts/interfaces/external/ooga/IOBRouter.sol";

/// @notice WARNING: Currently built for Router V1.
contract OogaBoogaCalldataChecker is BaseSwapChecker {
    /// CONSTANTS ///

    /// @notice The mask for the one for zero flag
    uint256 private constant _ONE_FOR_ZERO_MASK = 1 << 255;
    /// @notice The mask for the reverse flag
    uint256 private constant _REVERSE_MASK =
        0x8000000000000000000000000000000000000000000000000000000000000000;

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
        if (funcSigHash == IOBRouter.swap.selector) {
            (IOBRouter.swapTokenInfo memory tokenInfo, , , ) = abi.decode(
                _getFuncParams(swapAction.call),
                (IOBRouter.swapTokenInfo, bytes, address, uint32)
            );
            recipient = tokenInfo.outputReceiver;
            inputToken = tokenInfo.inputToken;
            inputAmount = tokenInfo.inputAmount;
            outputToken = tokenInfo.outputToken;
        } else if (funcSigHash == IOBRouter.swapERC20Permit.selector) {
            (, IOBRouter.swapTokenInfo memory tokenInfo, , , ) = abi.decode(
                _getFuncParams(swapAction.call),
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
                _getFuncParams(swapAction.call),
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
