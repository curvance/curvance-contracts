// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { DeployScript } from "../../utils/DeployScript.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { RedstoneClassicAdaptor } from "contracts/oracles/adaptors/redstone/RedstoneClassicAdaptor.sol";

contract DeployRedstoneClassicAdaptor is DeployScript {
    function run(address registry, address oracleManager) external recordEvents {
        RedstoneClassicAdaptor adaptor = new RedstoneClassicAdaptor(ICentralRegistry(registry));
        OracleManager(oracleManager).addApprovedAdaptor(address(adaptor));
        emit ContractDeployed(address(adaptor), "oracleMigration.adaptors.RedstoneClassicAdaptor");
    }
}
