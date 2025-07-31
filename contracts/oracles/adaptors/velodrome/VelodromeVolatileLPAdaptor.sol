// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BaseVolatileLPAdaptor } from "contracts/oracles/adaptors/stableswapBase/BaseVolatileLPAdaptor.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IVeloPool } from "contracts/interfaces/external/velodrome/IVeloPool.sol";
import { PricingResult } from "contracts/interfaces/IOracleAdaptor.sol";

contract VelodromeVolatileLPAdaptor is BaseVolatileLPAdaptor {
    /// EVENTS ///

    event VelodromeVolatileLPAssetAdded(
        address asset,
        AssetConfig assetConfig,
        bool isUpdate
    );
    event VelodromeVolatileLPAssetRemoved(address asset);

    /// ERRORS ///

    error VelodromeVolatileLPAdaptor__AssetIsNotSupported();
    error VelodromeVolatileLPAdaptor__AssetIsAlreadyAdded();
    error VelodromeVolatileLPAdaptor__AssetIsNotVolatileLP();

    /// CONSTRUCTOR ///

    /// @param centralRegistry_ The address of central registry.
    constructor(
        ICentralRegistry centralRegistry_,
        uint256 MAXIMUM_INCREASE_PER_YEAR,
        uint256 MINIMUM_INCREASE_PER_YEAR,
        uint256 MAXIMUM_TIMESTAMP_BUFFER,
        uint256 MINIMUM_TIMESTAMP_BUFFER
    ) BaseVolatileLPAdaptor(
        centralRegistry_,
        MAXIMUM_INCREASE_PER_YEAR,
        MINIMUM_INCREASE_PER_YEAR,
        MAXIMUM_TIMESTAMP_BUFFER,
        MINIMUM_TIMESTAMP_BUFFER
    ) {}

    /// EXTERNAL FUNCTIONS ///

    /// @notice Adds pricing support for `asset`, a new Velodrome Volatile LP.
    /// @dev Should be called before `OracleManager:addAssetPriceFeed`
    ///      is called.
    /// @param asset The address of the lp token to add pricing support for.
    function addAsset(address asset) external override {
        _checkElevatedPermissions();

        if (IVeloPool(asset).stable()) {
            revert VelodromeVolatileLPAdaptor__AssetIsNotVolatileLP();
        }

        // Check whether this is new or updated support for `asset`.
        bool isUpdate;
        if (isSupportedAsset[asset]) {
            isUpdate = true;
        }

        AssetConfig memory config = _addAsset(asset);
        emit VelodromeVolatileLPAssetAdded(asset, config, isUpdate);
    }

    /// @notice Returns the adaptor's type.
    /// @dev Used by frontends to determine how to properly interact
    ///      with a supported asset.
    /// @return The adaptor's type.
    function adaptorType() external pure override returns (uint256) {
        return 9;
    }

    /// PUBLIC FUNCTIONS ///

    /// @notice Removes a supported asset from the adaptor.
    /// @dev Calls back into Oracle Manager to notify it of its removal.
    ///      Requires that `asset` is currently supported.
    /// @param asset The address of the supported asset to remove from
    ///              the adaptor.
    function removeAsset(address asset) external virtual override {
        _checkElevatedPermissions();

        _removeAsset(asset);
        emit VelodromeVolatileLPAssetRemoved(asset);
    }

    /// INTERNAL FUNCTIONS TO OVERRIDE ///

    /// @notice Retrieves the price of a given asset in `inUSD` price form.
    /// @param asset The address of the asset for which the price is needed.
    /// @param inUSD Whether `asset` should be priced in USD or native tokens.
    /// @return result Return data for a priced asset containing:
    ///                price The price of the asset.
    ///                inUSD Boolean indicating whether `price` is denominated
    ///                      in USD (true) or native token (false).
    ///                hadError Boolean indicating whether the asset was priced
    ///                         without running into any issues or not.
    function _getPrice(
        address asset,
        bool inUSD
    ) internal virtual view override returns (PricingResult memory result) {}
}
