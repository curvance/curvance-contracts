// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { BaseSwapChecker } from "contracts/calldata-checker/swap-checker/BaseSwapChecker.sol";
import { VelodromeZapper } from "contracts/plugins/market/VelodromeZapper.sol";
import { BaseZapper } from "contracts/plugins/BaseZapper.sol";

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";

/// @notice Inspects the calldata for a VelodromeZapper zap action.
contract VelodromeZapperCalldataChecker is BaseSwapChecker {
    /// STORAGE ///
    /// @notice The only Velodrome Router this checker permits the zapper to call.
    address public immutable velodromeRouter;
    /// @notice The only Velodrome Factory this checker permits the zapper to use.
    address public immutable velodromeFactory;

    /// CONSTRUCTOR ///
    /// @param _target The address of the Velodrome Zapper contract.
    /// @param _velodromeRouter The Velodrome Router address allowed by this checker.
    /// @param _velodromeFactory The Velodrome Factory address allowed by this checker.
    constructor(
        address _target,
        address _velodromeRouter,
        address _velodromeFactory
    ) BaseSwapChecker(_target) {
        if (
            _velodromeRouter == address(0) ||
            _velodromeFactory == address(0)
        ) {
            revert CalldataChecker__TargetError();
        }

        velodromeRouter = _velodromeRouter;
        velodromeFactory = _velodromeFactory;
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
    ) external view override returns (uint256 minOutAmount) {
        if (swapAction.target != target) {
            revert CalldataChecker__TargetError();
        }

        bytes4 funcSigHash = _getFuncSigHash(swapAction.call);
        address recipient;
        address inputToken;
        uint256 inputAmount;
        address outputToken;
        address router;

        if (funcSigHash == VelodromeZapper.enterVelodrome.selector) {
            {
                address cToken;
                VelodromeZapper.ZapAction memory desc;
                address factory;
                uint256 expectedShares;

                (
                    cToken,
                    desc,
                    ,
                    router,
                    factory,
                    expectedShares,
                    ,
                    recipient
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

                if (cToken == address(0)) {
                    revert CalldataChecker__OutputTokenError();
                }

                if (desc.minimumOut == 0) {
                    revert CalldataChecker__InvalidMinOut();
                }

                if (factory != velodromeFactory) {
                    revert CalldataChecker__TargetError();
                }

                inputToken = desc.inputToken;
                inputAmount = desc.inputAmount;
                outputToken = cToken;
                minOutAmount = expectedShares;
            }
        } else if (funcSigHash == VelodromeZapper.exitVelodrome.selector) {
            {
                VelodromeZapper.ZapAction memory desc;

                (router, desc, , recipient) = abi.decode(
                    _getFuncParams(swapAction.call),
                    (
                        address,
                        VelodromeZapper.ZapAction,
                        SwapperLib.Swap[],
                        address
                    )
                );

                inputToken = desc.inputToken;
                inputAmount = desc.inputAmount;
                outputToken = desc.outputToken;
                minOutAmount = desc.minimumOut;
            }
        } else if (
            funcSigHash == VelodromeZapper.redeemAndExitVelodrome.selector
        ) {
            {
                BaseZapper.RedeemAction memory redeemAction;
                VelodromeZapper.ZapAction memory desc;

                (redeemAction, router, desc, , recipient) = abi.decode(
                    _getFuncParams(swapAction.call),
                    (
                        BaseZapper.RedeemAction,
                        address,
                        VelodromeZapper.ZapAction,
                        SwapperLib.Swap[],
                        address
                    )
                );

                inputToken = redeemAction.cToken;
                inputAmount = redeemAction.shares;
                outputToken = desc.outputToken;
                minOutAmount = desc.minimumOut;
            }
        } else {
            revert CalldataChecker__InvalidFuncSig();
        }

        if (router != velodromeRouter) {
            revert CalldataChecker__TargetError();
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

        if (minOutAmount == 0) {
            revert CalldataChecker__InvalidMinOut();
        }
    }
}
