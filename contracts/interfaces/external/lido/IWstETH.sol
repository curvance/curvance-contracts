// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import { IStETH } from "contracts/interfaces/external/lido/IStETH.sol";

interface IWstETH {
    function getStETHByWstETH(
        uint256 _wstETHAmount
    ) external view returns (uint256);

    function stETH() external view returns (IStETH);
}
