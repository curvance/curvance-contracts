// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { DeployScript } from "../utils/DeployScript.sol";

import { ProtocolManagerDeployment } from "contracts/architecture/ProtocolManagerDeployment.sol";

/// @notice Revokes a pending one-time deployment unpause allowance.
contract RevokeProtocolManagerDeploymentUnpause is DeployScript {
    function run(
        address protocolManagerDeployment,
        address marketManager
    ) external recordEvents {
        ProtocolManagerDeployment(protocolManagerDeployment).revokeUnpause(
            marketManager
        );
    }
}
