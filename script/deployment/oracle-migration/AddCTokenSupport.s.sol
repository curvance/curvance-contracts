// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { DeployScript } from "../../utils/DeployScript.sol";
import { OracleDeploymentPreflight } from "../../utils/OracleDeploymentPreflight.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";

contract AddCTokenSupport is DeployScript {
    function run(address oracleManager, address[] calldata cTokens) external recordEvents {
        _validatePreflight(oracleManager, cTokens);

        OracleManager manager = OracleManager(oracleManager);

        for (uint256 i; i < cTokens.length; ++i) {
            manager.addCTokenSupport(cTokens[i]);
        }
    }

    function _validatePreflight(
        address oracleManager,
        address[] calldata cTokens
    ) internal view {
        OracleDeploymentPreflight.requireContract(oracleManager);
        OracleDeploymentPreflight.requireNonEmpty(cTokens.length);

        for (uint256 i; i < cTokens.length; ++i) {
            OracleDeploymentPreflight.requireContract(cTokens[i]);
        }
    }
}
