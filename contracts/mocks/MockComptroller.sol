pragma solidity ^0.8.4;
// SPDX-License-Identifier: GPL-3.0-or-later

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// mock CVE for testing
contract MockComptroller {
    address[] public markets;

    constructor(address[] memory _markets) {
        markets = _markets;
    }

    function getAllMarkets() external view returns (address[] memory) {
        return markets;
    }
}
