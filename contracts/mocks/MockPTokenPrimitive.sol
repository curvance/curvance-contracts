// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { PTokenPrimitive, IERC20 } from "contracts/market/token/PTokenPrimitive.sol";

contract MockPTokenPrimitive is PTokenPrimitive {
    constructor(
        ICentralRegistry centralRegistry_,
        address asset_,
        address lendtroller_
    ) PTokenPrimitive(centralRegistry_, IERC20(asset_), lendtroller_) {}
}
