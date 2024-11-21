// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

interface IBlastCentralRegistry is ICentralRegistry {
    function nativeYieldManager() external view returns (address);
}
