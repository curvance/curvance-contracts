// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { VelodromePositionManager, ICentralRegistry } from "contracts/market/position-management/VelodromePositionManager.sol";

contract AerodromePositionManager is VelodromePositionManager {
    /// CONSTRUCTOR ///

    /// @param cr The address of the Protocol Central Registry.
    /// @param mm The address of the MarketManager which manages liquidity
    ///           positions between linked cTokens inside a joint market.
    /// @param wrappedNative_ The address of wrapped native token.
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
