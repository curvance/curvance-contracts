// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

interface IVestedEscrow {
    function addTokens(uint256 _amount) external returns (bool);

    function fund(address[] calldata _recipients, uint256[] calldata _amounts) external returns (bool);

    function vestedOf(address _recipient, uint256 _time) external view returns (uint256);

    function vestedOf(address _recipient) external view returns (uint256);

    function vestedSupply() external view returns (uint256);

    function lockedSupply() external view returns (uint256);

    function balanceOf(address _recipient) external view returns (uint256);

    function lockedOf(address _recipient) external view returns (uint256);

    function claim(address _recipient) external;
}
