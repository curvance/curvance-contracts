// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

interface IPendleMarket {
    function increaseObservationsCardinalityNext(
        uint16 cardinalityNext
    ) external;
}
