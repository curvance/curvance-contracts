// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IVault {
    function deposit(
        uint256 assets,
        address receiver
    ) external returns (uint256 shares);

    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) external returns (uint256 assets);

    function previewDeposit(
        uint256 assets,
        address receiver
    ) external returns (uint256 shares);

    function previewRedeem(
        uint256 shares,
        address receiver
    ) external returns (uint256 assets);
}
