// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

interface ICve {
    /**
     * @dev Transfer contract ownership
     *
     * @param _newOwner New owner of the contract
     */
    function transferOwnership(address _newOwner) external;

    /**
     * @dev Nominate a new minter, only executable by owner
     *
     * @param _nominee New minter to be nominated
     */
    function nominateMinter(address _nominee) external;

    /**
     * @dev Remove minter from role, only executable by owner
     *
     * @param _minter Minter to be removed
     */
    function removeMinter(address _minter) external;

    /// @dev Renounce minter role, must be a minter
    function renounceMinterRole() external;

    /**
     * @dev Check if address has minter rights
     *
     * @param _addr Address to be checked for minter rights
     * @return True, if `_addr` is a minter, false otherwise
     */
    function isMinter(address _addr) external view returns (bool);

    /// @dev Get max token supply
    function maxSupply() external view returns (uint256);

    /**
     * @dev Used to mint tokens until `maxSupply` is reached, needs to be executed
     *       by addresses with the MINTER role
     * @param _to Address to send funds to
     * @param _amount Amount to send
     */
    function mint(address _to, uint256 _amount) external;

    /**
     * @dev Checks interfaces
     * @param interfaceId Interface ID to be checked for compatibility
     * @return true if `interfaceId` is compatible with contract, otherwise, false
     */
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}
