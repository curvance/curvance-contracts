// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

import { PTokenPrimitive } from "contracts/market/token/PTokenPrimitive.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

contract MockPToken is PTokenPrimitive {
    constructor(
        ICentralRegistry centralRegistry_,
        IERC20 underlying_,
        address lendtroller_
    ) PTokenPrimitive(centralRegistry_, underlying_, lendtroller_) {}
}
