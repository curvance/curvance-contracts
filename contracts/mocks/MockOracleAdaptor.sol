// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { BaseOracleAdaptor } from "contracts/oracles/adaptors/BaseOracleAdaptor.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IOracleManager } from "contracts/interfaces/IOracleManager.sol";
import { PricingResult } from "contracts/interfaces/IOracleAdaptor.sol";

contract MockOracleAdaptor is BaseOracleAdaptor {
    struct MockPrice {
        uint240 usdPrice;
        uint240 nativePrice;
    }

    /// @notice Hard coded price that will always be returned.
    mapping(address => MockPrice) public definedPrices;
    mapping(address => bool) public hasSetPrice;

    constructor(
        ICentralRegistry centralRegistry_
    ) BaseOracleAdaptor(centralRegistry_) {}

    function getPrice(
        address asset,
        bool inUSD,
        bool
    ) external view override returns (PricingResult memory) {
        if (!hasSetPrice[asset]) {
            revert("Price not set by MockOracle");
        }

        if (inUSD) {
            return PricingResult(definedPrices[asset].usdPrice, false, true);
        }

        return PricingResult(definedPrices[asset].nativePrice, false, false);
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

    function removeAsset(address asset) external override {
        _checkElevatedPermissions();

        if (!isSupportedAsset[asset]) {
            revert("Asset not supported");
        }

        delete isSupportedAsset[asset];
        delete definedPrices[asset];
        delete hasSetPrice[asset];

        IOracleManager(centralRegistry.oracleManager()).notifyFeedRemoval(
            asset
        );
    }
}
