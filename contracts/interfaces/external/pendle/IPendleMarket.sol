// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

interface IPendleMarket {
    function increaseObservationsCardinalityNext(
        uint16 cardinalityNext
    ) external;
}
