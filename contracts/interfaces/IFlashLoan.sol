// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface IFlashLoan {

    /// @notice The fee to be charged for a given flashloan.
    /// @param assets The amount of `asset()` lent during the flashloan.
    /// return The assets of `asset()` to be charged for the flashloan.
    function flashFee(uint256 assets) external view returns (uint256);

    /// @notice Required callback for using a flashloan on Curvance.
    /// @param assets The amount of the token loaned during the flashloan.
    /// @param assetsReturned The amount of token required to be returned
    ///                       for the flashloan.
    /// @param data Arbitrary calldata passed to flashloan callback to execute
    ///             desired action during the flashloan.
    function onFlashLoan(
        uint256 assets,
        uint256 assetsReturned,
        bytes calldata data
    ) external returns (bytes32);
}
