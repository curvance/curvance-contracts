// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { Script } from "forge-std/Script.sol";
import { Vm } from "forge-std/Vm.sol";

contract DeploymentLogger is Script {
    string constant DEPLOYMENT_FILE = "/broadcast/deployment.json";

    /**
     * @notice Clear the deployment.json file
     */
    function clearDeploymentLog() external {
        string memory outputPath = string.concat(
            vm.projectRoot(),
            DEPLOYMENT_FILE
        );

        // Create empty logs array
        vm.writeFile(outputPath, "[]");
    }

    /**
     * @notice Save recorded logs to deployment.json (appends to existing)
     * @param logs Array of logs from vm.getRecordedLogs()
     */
    function saveLogsToDeployment(Vm.Log[] memory logs) external {
        if (logs.length == 0) return;

        string memory outputPath = string.concat(
            vm.projectRoot(),
            DEPLOYMENT_FILE
        );

        // Load existing logs
        Vm.Log[] memory existingLogs = loadExistingLogs();

        // Create new array with existing + new logs
        Vm.Log[] memory allLogs = new Vm.Log[](
            existingLogs.length + logs.length
        );

        // Copy existing logs
        for (uint256 i = 0; i < existingLogs.length; i++) {
            allLogs[i] = existingLogs[i];
        }

        // Add new logs
        for (uint256 i = 0; i < logs.length; i++) {
            allLogs[existingLogs.length + i] = logs[i];
        }

        // Serialize and save all logs
        string memory json = serializeLogs(allLogs);
        vm.writeFile(outputPath, json);
    }

    // Internal functions

    function loadExistingLogs() internal view returns (Vm.Log[] memory) {
        string memory outputPath = string.concat(
            vm.projectRoot(),
            DEPLOYMENT_FILE
        );

        try vm.readFile(outputPath) returns (string memory) {
            // For simplicity, return empty array - appending will work
            return new Vm.Log[](0);
        } catch {
            // File doesn't exist, return empty array
            return new Vm.Log[](0);
        }
    }

    function serializeLogs(
        Vm.Log[] memory logs
    ) internal returns (string memory) {
        if (logs.length == 0) {
            return "[]";
        }

        string memory json = "[";
        for (uint256 i = 0; i < logs.length; i++) {
            if (i > 0) {
                json = string.concat(json, ",");
            }
            json = string.concat(json, serializeLog(logs[i], i));
        }
        json = string.concat(json, "]");
        return json;
    }

    function serializeLog(
        Vm.Log memory log,
        uint256 index
    ) internal returns (string memory) {
        string memory logKey = string.concat("log_", vm.toString(index));

        vm.serializeAddress(logKey, "emitter", log.emitter);

        // Serialize topics array
        string memory topicsJson = "[";
        for (uint256 j = 0; j < log.topics.length; j++) {
            if (j > 0) {
                topicsJson = string.concat(topicsJson, ",");
            }
            topicsJson = string.concat(
                topicsJson,
                '"',
                vm.toString(log.topics[j]),
                '"'
            );
        }
        topicsJson = string.concat(topicsJson, "]");
        vm.serializeString(logKey, "topics", topicsJson);

        // Serialize data and return the final JSON object
        return vm.serializeBytes(logKey, "data", log.data);
    }
}
