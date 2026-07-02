// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { DeployScript } from "../../utils/DeployScript.sol";
import { OracleDeploymentPreflight } from "../../utils/OracleDeploymentPreflight.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";

contract ApproveOracleAdaptor is DeployScript {
    function run(address oracleManager, address adaptor) external recordEvents {
        OracleDeploymentPreflight.requireContract(oracleManager);
        OracleDeploymentPreflight.requireContract(adaptor);
        OracleManager(oracleManager).addApprovedAdaptor(adaptor);
    }
}
