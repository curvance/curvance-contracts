// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { IVault } from "contracts/interfaces/IVault.sol";

interface IEarnAUSDVault is IVault {
    /// @notice The address of the LP token.
    function lpTokenAddress() external returns (address);
}
