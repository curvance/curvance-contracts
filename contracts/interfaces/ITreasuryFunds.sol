// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ITreasuryFunds {
    /**
     * @dev Transfer contract ownership
     *
     * @param _newOwner New owner of the contract
     */
    function transferOwnership(address _newOwner) external;

    /**
     * @dev Nominate a new treasurer, only executable by owner
     *
     * @param _nominee New treasurer to be nominated
     */
    function nominateTreasurer(address _nominee) external;

    /**
     * @dev Remove treasurer from role, only executable by owner
     *
     * @param _treasurer Treasurer to be removed
     */
    function removeTreasurer(address _treasurer) external;

    /// @dev Renounce minter role, must be a minter
    function renounceTreasurerRole() external;

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
