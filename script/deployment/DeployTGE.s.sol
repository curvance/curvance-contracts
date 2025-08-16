// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Script } from "forge-std/Script.sol";
import { Vm } from "forge-std/Vm.sol";
import { DeploymentLogger } from "../utils/DeploymentLogger.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { CVE } from "contracts/token/CVE.sol";
import { RewardManager } from "contracts/architecture/RewardManager.sol";
import { VeCVE } from "contracts/token/VeCVE.sol";
import { GaugeManager } from "contracts/architecture/GaugeManager.sol";
import { VotingHub } from "contracts/architecture/VotingHub.sol";

contract DeployTGE is Script {
    event ContractDeployed(address contractAddress, string contractName);

    DeploymentLogger logger;

    function run(
        address centralRegistry,
        uint256 lockBoostMultiplier,
        address teamAddress,
        uint256 baseEmissionsPerEpoch
    ) external {
        logger = new DeploymentLogger();
        vm.recordLogs();
        vm.startBroadcast();

        CentralRegistry registry = CentralRegistry(centralRegistry);
        ICentralRegistry icr = ICentralRegistry(centralRegistry);
        registry.setLockBoostMultiplier(lockBoostMultiplier);

        CVE cve = new CVE(icr, teamAddress);
        registry.setCVE(address(cve));
        emit ContractDeployed(address(cve), "CVE");

        RewardManager rewardManager = new RewardManager(icr);
        registry.setRewardManager(address(rewardManager));
        emit ContractDeployed(address(rewardManager), "RewardManager");

        VeCVE veCve = new VeCVE(icr);
        registry.setVeCVE(address(veCve));
        rewardManager.startRewardManager();
        emit ContractDeployed(address(veCve), "VeCVE");

        GaugeManager gaugeManager = new GaugeManager(icr);
        registry.setGaugeManager(address(gaugeManager));
        registry.addLockingPermissions(address(gaugeManager));
        emit ContractDeployed(address(gaugeManager), "GaugeManager");

        VotingHub votingHub = new VotingHub(icr);
        registry.setVotingHub(address(votingHub));
        registry.setEraTargetEmissions(baseEmissionsPerEpoch);
        emit ContractDeployed(address(votingHub), "VotingHub");

        vm.stopBroadcast();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        logger.saveLogsToDeployment(logs);
    }
}
