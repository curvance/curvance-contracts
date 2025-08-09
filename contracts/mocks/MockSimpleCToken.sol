// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { SimpleCToken, IERC20 } from "contracts/market/token/SimpleCToken.sol";

contract MockSimpleCToken is SimpleCToken {
    constructor(
        ICentralRegistry centralRegistry_,
        address asset_,
        address marketManager_
    ) SimpleCToken(centralRegistry_, IERC20(asset_), marketManager_) {}
}
