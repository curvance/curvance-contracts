// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ITreasuryFunds {
    /**
     * @dev Withdraw an amount of a given asset to a given address
     *
     * @param _asset The ERC20 compatible asset to be used
     * @param _amount Amount to be withdrawn
     * @param _to Address to send the funds
     */
    function withdrawTo(
        IERC20 _asset,
        uint256 _amount,
        address _to
    ) external;

    /**
     * @dev Execute a low-level call to an address
     *
     * @param _to Address to execute the call
     * @param _value The amount of ethers to send
     * @param _data Call data
     */
    function execute(
        address _to,
        uint256 _value,
        bytes calldata _data
    ) external;

    /**
     * Check if interfaceId is supported by the contract
     *
     * @param _interfaceId The interfaceId to be checked
     * @return True, if the interface is supported, false otherwise
     */
    function supportsInterface(bytes4 _interfaceId) external view returns (bool);
}
