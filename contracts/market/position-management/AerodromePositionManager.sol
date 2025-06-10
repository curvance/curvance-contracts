// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { VelodromePositionManager, ICentralRegistry } from "contracts/market/position-management/VelodromePositionManager.sol";

contract AerodromePositionManager is VelodromePositionManager {
    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        address marketManager_,
        address wrappedNative_,
        address router_,
        address pairFactory_
    )
        VelodromePositionManager(
            centralRegistry_,
            marketManager_,
            wrappedNative_,
            router_,
            pairFactory_
        )
    {}
}
