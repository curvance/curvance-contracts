// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

import { BaseOracleAdaptor } from "contracts/oracles/adaptors/BaseOracleAdaptor.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IOracleManager } from "contracts/interfaces/IOracleManager.sol";

contract MockOracleAdaptor is BaseOracleAdaptor {
    struct MockPrice {
        uint240 usdPrice;
        uint240 nativePrice;
    }

    /// @notice Hard coded price that will always be returned.
    mapping(address => MockPrice) public definedPrices;
    mapping(address => bool) public hasSetPrice;

    constructor(ICentralRegistry cr) BaseOracleAdaptor(cr) {}

    function getPrice(
        address asset,
        bool inUSD,
        bool
    ) external view override returns (PricingResult memory) {
        if (!hasSetPrice[asset]) {
            revert("Price not set by MockOracle");
        }

        return PricingResult(definedPrices[asset].nativePrice, inUSD, false);
    }

    function setPrice(
        address asset,
        uint240 usdPrice,
        uint240 nativePrice
    ) external {
        _checkElevatedPermissions();
        hasSetPrice[asset] = true;
        definedPrices[asset] = MockPrice(usdPrice, nativePrice);
    }

    function addAsset(address asset) external {
        _checkElevatedPermissions();

        if (isSupportedAsset[asset]) {
            revert("Asset already supported");
        }

        isSupportedAsset[asset] = true;
    }

    function adaptorType() external view virtual override returns (uint256) {
        return 1337;
    }

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

    /// @notice Wipes supported asset pricing configs from an adaptor.
    function _wipeAssetConfigs(address asset) internal override {}
}
