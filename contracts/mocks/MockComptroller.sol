pragma solidity ^0.8.4;
// SPDX-License-Identifier: GPL-3.0-or-later

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./MCErc20.sol";

// mock CVE for testing
contract MockComptroller {
    MCErc20[] public markets;

    constructor(MCErc20[] memory _markets) {
        markets = _markets;
    }

    function getAllMarkets() external view returns (MCErc20[] memory) {
        return markets;
    }
}
