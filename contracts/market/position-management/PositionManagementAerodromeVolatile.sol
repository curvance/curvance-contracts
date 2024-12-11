// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { PositionManagementVelodromeVolatile, ICentralRegistry } from "contracts/market/position-management/PositionManagementVelodromeVolatile.sol";

contract PositionManagementAerodromeVolatile is PositionManagementVelodromeVolatile {

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        address marketManager_,
        address wrappedNative_,
        address router_,
        address pairFactory_
    ) PositionManagementVelodromeVolatile(
        centralRegistry_,
        marketManager_,
        address wrappedNative_,
        router_,
        pairFactory_
    ) {}

}