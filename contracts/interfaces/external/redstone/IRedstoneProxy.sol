// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

interface IRedstoneProxy {

    function updateDataFeedsValues(bytes calldata updateData) external;

    function updateDataFeedsValuesPartial(bytes calldata updateData) external;
}