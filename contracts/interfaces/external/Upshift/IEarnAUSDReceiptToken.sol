// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

interface IEarnAUSDReceiptToken {
    /// @notice The addresses allowed to issue new tokens.
    function minters(
        address proposedAddress
    ) external returns (bool);

    /// @notice The addresses allowed to burn existing tokens.
    function burners(
        address proposedAddress
    ) external returns (bool);

    function asset() external view returns (IERC20);
}
