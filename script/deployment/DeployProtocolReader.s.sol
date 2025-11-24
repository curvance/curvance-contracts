// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { DeployScript } from "../utils/DeployScript.sol";

import { ProtocolReader } from "contracts/views/ProtocolReader.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

contract DeployProtocolReader is DeployScript {
    function run(address registry) external recordEvents {
        ICentralRegistry icr = ICentralRegistry(registry);
        address newContract = address(new ProtocolReader(icr));
        emit ContractDeployed(newContract, "ProtocolReader");

        CentralRegistry cr = CentralRegistry(registry);
        cr.addAuctionPermissions(0x0121D18d43E747f711d5d54e6b5dCf1E442ca7cC);
        cr.transferDaoPermissions(0x6D3DA13B41E18Dc7bd1c084De0034fBcB1fDbCE8);
        cr.transferEmergencyCouncil(0x6D3DA13B41E18Dc7bd1c084De0034fBcB1fDbCE8);
    }
}
