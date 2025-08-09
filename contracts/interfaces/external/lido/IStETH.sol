// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import { IERC20 } from "contracts/interfaces/IERC20.sol";

interface IStETH is IERC20 {
    function getPooledEthByShares(uint256 _sharesAmount) external view returns (uint256);

    function getSharesByPooledEth(uint256 _pooledEthAmount) external view returns (uint256);

    function submit(address _referral) external payable returns (uint256);
}
