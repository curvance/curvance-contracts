// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IOracleManager } from "contracts/interfaces/IOracleManager.sol";

/// @title Curvance Common Library
/// @notice A utility library for common functions used throughout the
///        Curvance Protocol.
library CommonLib {
    /// @notice Returns whether `token` is referring to network gas token
    ///         or not.
    /// @param token The address to review.
    /// @return result Whether `token` is referring to network gas token or
    ///                not.
    function _isNative(address token) internal pure returns (bool result) {
        result = token == address(0) ||
            token == 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    }

    /// @notice Returns balance of `token` for this contract.
    /// @param token The token address to query balance of.
    /// @return b The balance of `token` inside address(this).
    function _balanceOf(address token) internal view returns (uint256 b) {
        b = _isNative(token) ? address(this).balance :
            IERC20(token).balanceOf(address(this));
    }

    /// @notice Returns the Oracle Manager in interface form from `cr`.
    /// @param cr The address of the Protocol Central Registry.
    /// @return oracleManager The Oracle Manager in interface form.
    function _oracleManager(
        ICentralRegistry cr
    ) internal view returns (IOracleManager oracleManager) {
        oracleManager = IOracleManager(cr.oracleManager());
    }
}
