// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { SafeTransferLib } from "contracts/libraries/ERC4626.sol";
import { OracleRouter } from "contracts/oracles/OracleRouter.sol";
import { PythAdaptor } from "contracts/oracles/adaptors/pyth/PythAdaptor.sol";
import { BaseRedstoneCoreAdaptor } from "contracts/oracles/adaptors/redstone/BaseRedstoneCoreAdaptor.sol";

/// @title Curvance Multicall Plugin
abstract contract Multicall {
    /// TYPES ///
    struct MulticallData {
        address target;
        bool isPriceUpdate;
        bytes data;
    }

    /// ERRORS ///

    error Multicall__InvalidTarget();
    error Multicall__InvalidCallData();

    /// EXTERNAL FUNCTIONS ///

    /// @notice Executes multiple calls in a single transaction.
    ///         This can be used to update oracle prices before
    ///         a liquidity dependent action.
    function multicall(
        MulticallData[] memory calls
    ) external returns (bytes[] memory results) {
        ICentralRegistry centralRegistry = _getCentralRegistry();
        OracleRouter oracleRouter = OracleRouter(
            centralRegistry.oracleRouter()
        );

        results = new bytes[](calls.length);
        for (uint256 i; i < calls.length; ++i) {
            if (calls[i].isPriceUpdate) {
                if (!oracleRouter.isApprovedAdaptor(calls[i].target)) {
                    revert Multicall__InvalidTarget();
                }

                bytes4 functionSig = getFuncSigHash(calls[i].data);
                if (
                    functionSig == BaseRedstoneCoreAdaptor.writePrice.selector
                ) {
                    results[i] = Address.functionCall(
                        calls[i].target,
                        calls[i].data
                    );
                } else if (
                    functionSig ==
                    PythAdaptor.updateFeedsFromUniversalBalance.selector
                ) {
                    results[i] = Address.functionCall(
                        calls[i].target,
                        calls[i].data
                    );
                } else {
                    revert Multicall__InvalidCallData();
                }
            } else {
                if (address(this) != calls[i].target) {
                    revert Multicall__InvalidTarget();
                }

                results[i] = Address.functionDelegateCall(
                    address(this),
                    calls[i].data
                );
            }
        }
    }

    /// INTERNAL FUNCTIONS ///

    /// @dev Queries the function signature of `_data`, this is used
    ///      to check against an expected selector.
    /// @param _data The bytes array to pull a function signature from.
    function getFuncSigHash(
        bytes memory _data
    ) internal pure returns (bytes4 sig) {
        assembly {
            sig := mload(add(_data, add(32, 0)))
        }
    }

    /// @dev Returns the central registry interface,
    ///      overridden in child contract.
    function _getCentralRegistry()
        internal
        view
        virtual
        returns (ICentralRegistry)
    {}
}
