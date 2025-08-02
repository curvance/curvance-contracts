// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { VelodromePositionManager, ICentralRegistry } from "contracts/market/position-management/VelodromePositionManager.sol";

contract AerodromePositionManager is VelodromePositionManager {
    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry cr,
        address mm,
        address wrappedNative_,
        address router_,
        address pairFactory_
    )
        VelodromePositionManager(
            cr,
            mm,
            wrappedNative_,
            router_,
            pairFactory_
        )
    {}
}
