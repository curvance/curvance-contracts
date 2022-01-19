// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

interface ICve {
    function maxSupply() external view returns (uint256);

    function mint(address _to, uint256 _amount) external;

    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}
