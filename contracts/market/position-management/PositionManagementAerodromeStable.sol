// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { PositionManagementVelodromeStable, ICentralRegistry, IVeloRouter } from "contracts/market/position-management/PositionManagementVelodromeStable.sol";

contract PositionManagementAerodromeStable is PositionManagementVelodromeStable {

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        address marketManager_,
        address pool_,
        IVeloRouter router_
    ) PositionManagementVelodromeStable(centralRegistry_, marketManager_, pool_, router_) {}

}