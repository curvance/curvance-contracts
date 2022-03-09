pragma solidity ^0.8.4;
// SPDX-License-Identifier: GPL-3.0-or-later

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// mock CVE for testing
contract MCErc20 {
    address public underlying;

    constructor(address _underlying) {
        underlying = _underlying;
    }

    function totalAdminFees() external view returns (uint256) {
        return IERC20(underlying).balanceOf(address(this));
    }

    function _withdrawAdminFees(uint256 _amount) external returns (uint256) {
        {
            _amount;
        }
        // side effects
        underlying = underlying;
        IERC20(underlying).transfer(msg.sender, IERC20(underlying).balanceOf(address(this)));

        return 0;
    }
}
