// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

interface ICve {
    function totalSupply() external view returns (uint256);

    function maxSupply() external view returns (uint256);

    function operator() external view returns (address);

    function vlcveProxy() external view returns (address);

    function updateOperator() external;

    function mint(address _to, uint256 _amount) external;
}
