// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { DeployScript } from "../utils/DeployScript.sol";

import { MockOracleAdaptor } from "contracts/mocks/MockOracleAdaptor.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract AddMockOracleSupport is DeployScript {
    function run(
        address registry,
        address mockOracle,
        address[] calldata assets,
        uint256[] calldata usdPrices,
        uint256[] calldata nativePrices
    ) external recordEvents {
        ICentralRegistry cr = ICentralRegistry(registry);
        OracleManager oracleManager = OracleManager(cr.oracleManager());
        MockOracleAdaptor adaptor = MockOracleAdaptor(mockOracle);

        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i];
            uint256 usdPrice = usdPrices[i];
            uint256 nativePrice = nativePrices[i];

            adaptor.addAsset(asset);
            adaptor.setPrice(asset, usdPrice, nativePrice);
            oracleManager.addAssetPricingAdaptor(asset, address(adaptor), true, 100, 50);
        }
    }
}
