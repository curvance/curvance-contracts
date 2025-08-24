// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { DeployScript } from "../utils/DeployScript.sol";

import { ProtocolReader } from "contracts/views/ProtocolReader.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract DeployProtocolReader is DeployScript {
    function run(address registry) external recordEvents {
        ICentralRegistry icr = ICentralRegistry(registry);
        address newContract = address(new ProtocolReader(icr));
        emit ContractDeployed(newContract, "ProtocolReader");
    }
}
