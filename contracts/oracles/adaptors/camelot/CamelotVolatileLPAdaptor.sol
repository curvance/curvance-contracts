// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

// import { BaseVolatileLPAdaptor } from "contracts/oracles/adaptors/stableswapBase/BaseVolatileLPAdaptor.sol";

// import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
// import { ICamelotPair } from "contracts/interfaces/external/camelot/ICamelotPair.sol";

// contract CamelotVolatileLPAdaptor is BaseVolatileLPAdaptor {
//     /// CONSTRUCTOR ///

//     constructor(
//         ICentralRegistry centralRegistry_
//     ) BaseVolatileLPAdaptor(centralRegistry_) {}

//     /// EXTERNAL FUNCTIONS ///

//     /// @notice Adds pricing support for `asset`, a new Camelot Volatile LP.
//     /// @dev Should be called before `OracleManager:addAssetPriceFeed`
//     ///      is called.
//     /// @param asset The address of the lp token to add pricing support for.
//     function addAsset(address asset) external override {
//         _checkElevatedPermissions();

//         if (ICamelotPair(asset).stableSwap()) {
//             revert BaseVolatileLPAdaptor__InvalidAssetType();
//         }

//         // Check whether this is new or updated support for `asset`.
//         bool isUpdate;
//         if (isSupportedAsset[asset]) {
//             isUpdate = true;
//         }

//         AssetConfig memory data = _addAsset(asset);
//         emit AssetAdded(asset, data, isUpdate);
//     }

//     /// @notice Removes a supported asset from the adaptor.
//     /// @dev Calls back into Oracle Manager to notify it of its removal.
//     ///      Requires that `asset` is currently supported.
//     /// @param asset The address of the supported asset to remove from
//     ///              the adaptor.
//     function removeAsset(address asset) external virtual override {
//         _checkElevatedPermissions();

//         _removeAsset(asset);
//         emit CamelotVolatileLPAssetRemoved(asset);
//     }

//     /// @notice Returns the adaptor's type.
//     /// @dev Used by frontends to determine how to properly interact
//     ///      with a supported asset.
//     function adaptorType() external pure override returns (uint256) {
//         return 15;
//     }
// }
