// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {DeployScript} from "../utils/DeployScript.sol";

import {VaultAggregator} from "contracts/oracles/adaptors/wrappedAggregators/VaultAggregator.sol";
import {IERC20} from "contracts/interfaces/IERC20.sol";

contract DeployVaultAggregator is DeployScript {
    function run(address vault, address asset, address aggregator, string memory assetId)
        external
        recordEvents
        returns (address vaultAggregator)
    {
        IERC20 assetToken = IERC20(asset);
        IERC20 vaultToken = IERC20(vault);

        vaultAggregator = address(new VaultAggregator(vault, asset, aggregator, assetId));

        emit ContractDeployed(
            vaultAggregator, string.concat("VaultAggregator-", assetToken.symbol(), "-", vaultToken.symbol())
        );
    }
}
