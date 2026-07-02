// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { DeployScript } from "../../utils/DeployScript.sol";
import { OracleDeploymentPreflight } from "../../utils/OracleDeploymentPreflight.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";

contract DeployChainlinkAdaptor is DeployScript {
    function run(address registry, address oracleManager) external recordEvents {
        OracleDeploymentPreflight.requireOracleManagerRegistry(oracleManager, registry);
        ChainlinkAdaptor adaptor = new ChainlinkAdaptor(ICentralRegistry(registry));
        OracleManager(oracleManager).addApprovedAdaptor(address(adaptor));
        emit ContractDeployed(address(adaptor), "oracleMigration.adaptors.ChainlinkAdaptor");
    }
}
