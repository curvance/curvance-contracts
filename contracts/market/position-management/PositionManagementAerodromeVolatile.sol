// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { PositionManagementVelodromeVolatile, ICentralRegistry, IVeloRouter } from "contracts/market/position-management/VelodromeVolatilePositionManagement.sol";

contract PositionManagementAerodromeVolatile is PositionManagementVelodromeVolatile {

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        address marketManager_,
        address pool_,
        IVeloRouter router_
    ) PositionManagementVelodromeVolatile(centralRegistry_, marketManager_, pool_, router_) {}

}