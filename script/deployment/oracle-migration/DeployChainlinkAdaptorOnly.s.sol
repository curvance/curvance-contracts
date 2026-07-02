// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { DeployScript } from "../../utils/DeployScript.sol";
import { OracleDeploymentPreflight } from "../../utils/OracleDeploymentPreflight.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";

contract DeployChainlinkAdaptorOnly is DeployScript {
    function run(address registry) external recordEvents {
        OracleDeploymentPreflight.requireContract(registry);
        ChainlinkAdaptor adaptor = new ChainlinkAdaptor(ICentralRegistry(registry));
        emit ContractDeployed(address(adaptor), "oracleMigration.adaptors.ChainlinkAdaptor");
    }
}
