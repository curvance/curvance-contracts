// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { SimplePToken, IERC20 } from "contracts/market/token/SimplePToken.sol";

contract MockSimplePToken is SimplePToken {
    constructor(
        ICentralRegistry centralRegistry_,
        address asset_,
        address lendtroller_
    ) SimplePToken(centralRegistry_, IERC20(asset_), lendtroller_) {}
}
