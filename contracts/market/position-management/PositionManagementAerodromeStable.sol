// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { PositionManagementVelodromeStable, ICentralRegistry } from "contracts/market/position-management/PositionManagementVelodromeStable.sol";

contract PositionManagementAerodromeStable is
    PositionManagementVelodromeStable
{
    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        address marketManager_,
        address wrappedNative_,
        address router_,
        address pairFactory_
    )
        PositionManagementVelodromeStable(
            centralRegistry_,
            marketManager_,
            wrappedNative_,
            router_,
            pairFactory_
        )
    {}
}
