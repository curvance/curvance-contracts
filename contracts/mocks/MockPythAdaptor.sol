// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { PythAdaptor } from "contracts/oracles/adaptors/pyth/PythAdaptor.sol";

contract MockPythAdaptor is PythAdaptor {
    constructor(
        ICentralRegistry centralRegistry_,
        address universalBalance_,
        address pyth_,
        address weth_
    ) PythAdaptor(centralRegistry_, universalBalance_, pyth_, weth_) {}
}
