// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

interface IVeloPool {
    function token0() external view returns (address);

    function token1() external view returns (address);

    function totalSupply() external view returns (uint256);

    function factory() external view returns (address);

    function stable() external view returns (bool);

    function getK() external view returns (uint256);

    function getReserves()
        external
        view
        returns (
            uint112 reserve0,
            uint112 reserve1,
            uint32 blockTimestampLast
        );
}
