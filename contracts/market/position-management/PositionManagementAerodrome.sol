// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { PositionManagementVelodrome } from "contracts/market/position-management/PositionManagementVelodrome.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract PositionManagementAerodrome is PositionManagementVelodrome {
    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        address marketManager_,
        address wrappedNative_,
        address router_,
        address pairFactory_
    )
        PositionManagementVelodrome(
            centralRegistry_,
            marketManager_,
            wrappedNative_,
            router_,
            pairFactory_
        )
    {}
}
