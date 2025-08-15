// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

interface IManagementOracle {
    /// @notice Reads the Management Oracle for corresponding price for `key`.
    /// @return Current price for `key` at the current timestamp.
    /// @return Timestamp that the `key`'s price price was recorded at.
    function readAsUint256WithTimestamp(
        address sender,
        bytes32 key
    ) external view returns (uint256, uint64);

    /// @notice Reads the Management Oracle for corresponding price for `key`.
    /// @return Current price for `key` at the current timestamp.
    /// @return Timestamp that the `key`'s price price was recorded at.
    function readAsInt256WithTimestamp(
        address sender,
        bytes32 key
    ) external view returns (int256, uint64);
}
