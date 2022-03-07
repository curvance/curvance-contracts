pragma solidity ^0.8.4;
// SPDX-License-Identifier: GPL-3.0-or-later

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// mock CVE for testing
contract MockVotingEscrow {
    constructor() {}

    function notifyRewardAmount(address _token, uint256 _amount) external pure returns (bool) {
        _token;
        _amount;
        return true;
    }
}
