// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {DeployScript} from "../../utils/DeployScript.sol";

import {ProtocolManagerDeployment} from "contracts/architecture/ProtocolManagerDeployment.sol";

/// @notice Consumes ProtocolManagerDeployment's one-time unpause allowance for
///         a market it configured.
contract PMDUnpauseMarket is DeployScript {
    function run(address protocolManagerDeployment, address marketManager) external recordEvents {
        ProtocolManagerDeployment(protocolManagerDeployment).unpauseMarket(marketManager);
    }
}
