// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface IVeloPairFactory {
    function allPoolsLength() external view returns (uint);

    function isPair(address pair) external view returns (bool);

    function getPair(
        address tokenA,
        address tokenB,
        bool stable
    ) external view returns (address);

    function createPair(
        address tokenA,
        address tokenB,
        bool stable
    ) external returns (address pair);

    function getFee(address pool, bool _stable) external view returns (uint);
}
