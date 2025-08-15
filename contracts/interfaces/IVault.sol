// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IERC20 } from "contracts/interfaces/IERC20.sol";

interface IVault {
    function deposit(
        uint256 assets,
        address receiver
    ) external payable returns (uint256 shares);

    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) external returns (uint256 assets);

    function previewDeposit(
        uint256 assets
    ) external returns (uint256 shares);

    function previewRedeem(
        uint256 shares
    ) external returns (uint256 assets);

    function asset() external view returns (IERC20);
}
