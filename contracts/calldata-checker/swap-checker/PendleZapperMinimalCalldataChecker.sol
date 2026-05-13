// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { BaseSwapChecker } from "contracts/calldata-checker/swap-checker/BaseSwapChecker.sol";
import { PendleZapperMinimal } from "contracts/plugins/market/PendleZapperMinimal.sol";

import { PendleLib } from "contracts/libraries/PendleLib.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";

/// @notice Inspects calldata for the minimal PendleZapper enter flow.
contract PendleZapperMinimalCalldataChecker is BaseSwapChecker {
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
    ) external view virtual override returns (uint256 minOutAmount) {
        if (swapAction.target != target) {
            revert CalldataChecker__TargetError();
        }

        bytes4 funcSigHash = _getFuncSigHash(swapAction.call);
        if (funcSigHash != PendleZapperMinimal.enterPendle.selector) {
            revert CalldataChecker__InvalidFuncSig();
        }

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

        if (routerParam != pendleRouter) {
            revert CalldataChecker__TargetError();
        }

        if (receiver != expectedRecipient) {
            revert CalldataChecker__RecipientError();
        }

        if (desc.inputToken != swapAction.inputToken) {
            revert CalldataChecker__InputTokenError();
        }

        if (desc.inputAmount != swapAction.inputAmount) {
            revert CalldataChecker__InputAmountError();
        }

        if (cToken == address(0) || cToken != swapAction.outputToken) {
            revert CalldataChecker__OutputTokenError();
        }

        if (desc.minimumOut == 0) {
            revert CalldataChecker__InvalidMinOut();
        }

        if (expectedShares == 0) {
            revert CalldataChecker__InvalidMinOut();
        }

        minOutAmount = expectedShares;
    }
}
