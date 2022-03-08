pragma solidity ^0.8.4;
// SPDX-License-Identifier: GPL-3.0-or-later

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// mock CVE for testing
contract MockCErc20 {
    address public underlying;

    constructor(address _underlying) {
        underlying = _underlying;
    }

    function totalAdminFees() external pure returns (uint256) {
        return 1e18;
    }

    function _withdrawAdminFees() external returns (uint256) {
        // side effects
        underlying = underlying;

        return 0;
    }
}
