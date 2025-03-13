// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

/// @title Curvance Rescue Library
/// @notice A utility library for rescuing tokens sent by mistake.
library RescueLib {
    /// @notice Rescue any token sent by mistake.
    /// @dev Contracts implementing RescueLib.rescueToken should NOT support
    ///      duel-entry point tokens, otherwise pre/post protected token
    ///      balances will need to be checked in child implementations.
    /// @param token token to rescue.
    /// @param amount amount of `token` to rescue, 0 indicates to rescue all.
    function rescueToken(
        ICentralRegistry centralRegistry,
        address token,
        uint256 amount
    ) internal {
        address daoOperator = centralRegistry.daoAddress();

        if (token == address(0)) {
            if (amount == 0) {
                amount = address(this).balance;
            }

            SafeTransferLib.safeTransferETH(daoOperator, amount);
        } else {
            if (amount == 0) {
                amount = IERC20(token).balanceOf(address(this));
            }

            SafeTransferLib.safeTransfer(token, daoOperator, amount);
        }
    }
}
