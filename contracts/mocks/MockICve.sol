// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "../interfaces/ICve.sol";

contract MockICve {
    function interfaceId() external pure returns (bytes4) {
        return type(ICve).interfaceId;
    }
}
