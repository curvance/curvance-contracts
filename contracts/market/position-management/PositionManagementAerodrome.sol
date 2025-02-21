// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { PositionManagementVelodrome, ICentralRegistry } from "contracts/market/position-management/PositionManagementVelodrome.sol";

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
