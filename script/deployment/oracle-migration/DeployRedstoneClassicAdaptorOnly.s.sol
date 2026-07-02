// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { DeployScript } from "../../utils/DeployScript.sol";
import { OracleDeploymentPreflight } from "../../utils/OracleDeploymentPreflight.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { RedstoneClassicAdaptor } from "contracts/oracles/adaptors/redstone/RedstoneClassicAdaptor.sol";

contract DeployRedstoneClassicAdaptorOnly is DeployScript {
    function run(address registry) external recordEvents {
        OracleDeploymentPreflight.requireContract(registry);
        RedstoneClassicAdaptor adaptor = new RedstoneClassicAdaptor(ICentralRegistry(registry));
        emit ContractDeployed(address(adaptor), "oracleMigration.adaptors.RedstoneClassicAdaptor");
    }
}
