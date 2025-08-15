// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

interface IBooster {
    function isShutdown() external view returns (bool);

    function deposit(uint256 _poolId, uint256 _amount, bool _stake) external;

    function withdraw(uint256 _poolId, uint256 _amount) external;

    function poolInfo(
        uint256 pid
    )
        external
        view
        returns (address, address, address, address, address, bool);

    function earmarkRewards(uint256 _pid) external returns (bool);
}
