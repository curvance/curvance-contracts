// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { DeployScript } from "../../utils/DeployScript.sol";
import { OracleDeploymentPreflight } from "../../utils/OracleDeploymentPreflight.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";

contract DeployOracleManager is DeployScript {
    function run(address registry) external recordEvents {
        OracleDeploymentPreflight.requireContract(registry);
        OracleManager manager = new OracleManager(ICentralRegistry(registry));
        emit ContractDeployed(address(manager), "oracleMigration.OracleManager");
    }
}
