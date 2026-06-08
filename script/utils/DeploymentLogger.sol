// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Script } from "forge-std/Script.sol";
import { Vm } from "forge-std/Vm.sol";

contract DeploymentLogger is Script {
    string constant DEPLOYMENT_FILE = "/broadcast/deployment.json";

    event ContractDeployed(address contractAddress, string contractName);
    event ContractMetadata(string jsonIndex, string key, bool value);

    error DeploymentLogger__InvalidDeploymentFile();

    /**
     * @notice Record events during deployment
     * @dev This modifier starts the broadcast and records logs for JS to pickup later.
    */
    modifier recordEvents() virtual {
        _validateDeploymentFileForAppend();
        vm.recordLogs();
        vm.startBroadcast();

        _;

        vm.stopBroadcast();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _saveLogsToDeployment(logs);
    }

    /**
     * @notice Save recorded logs to deployment.json (appends to existing)
     * @param logs Array of logs from vm.getRecordedLogs()
     */
    function _saveLogsToDeployment(Vm.Log[] memory logs) internal {
        if (logs.length == 0) return;

        string memory outputPath = _deploymentFilePath();

        // Ensure the broadcast directory exists
        string memory broadcastDir = _deploymentDirectoryPath();
        vm.createDir(broadcastDir, true);

        // Serialize and save all logs
        string memory json = _serializeLogs(logs);
        if (vm.exists(outputPath)) {
            string memory existingJson = vm.readFile(outputPath);
            _validateDeploymentFileJson(existingJson);
            json = _appendLogsJson(existingJson, json);
        }
        vm.parseJson(json);
        vm.writeFile(outputPath, json);
    }

    function _validateDeploymentFileForAppend() internal {
        string memory outputPath = _deploymentFilePath();
        if (!vm.exists(outputPath)) return;

        _validateDeploymentFileJson(vm.readFile(outputPath));
    }

    function _validateDeploymentFileJson(
        string memory deploymentJson
    ) internal {
        bytes memory existing = bytes(deploymentJson);
        (uint256 start, uint256 end) = _trimBounds(existing);
        if (start == end || _isEmptyArray(existing, start, end)) return;

        _validateLogArray(existing, start, end);
        vm.parseJson(deploymentJson);
    }

    function _deploymentFilePath() internal view virtual returns (string memory) {
        return string.concat(vm.projectRoot(), DEPLOYMENT_FILE);
    }

    function _deploymentDirectoryPath() internal view virtual returns (string memory) {
        return string.concat(vm.projectRoot(), "/broadcast");
    }

    function _appendLogsJson(
        string memory existingJson,
        string memory newJson
    ) internal pure returns (string memory) {
        bytes memory existing = bytes(existingJson);
        bytes memory fresh = bytes(newJson);
        (uint256 existingStart, uint256 existingEnd) = _trimBounds(existing);
        (uint256 freshStart, uint256 freshEnd) = _trimBounds(fresh);

        if (existingStart == existingEnd || _isEmptyArray(existing, existingStart, existingEnd)) return newJson;
        if (_isEmptyArray(fresh, freshStart, freshEnd)) return existingJson;

        _validateLogArray(existing, existingStart, existingEnd);
        _validateLogArray(fresh, freshStart, freshEnd);

        return string.concat(
            _slice(existing, existingStart, existingEnd - 1),
            ",",
            _slice(fresh, freshStart + 1, freshEnd)
        );
    }

    function _isEmptyArray(
        bytes memory data,
        uint256 start,
        uint256 end
    ) internal pure returns (bool) {
        if (!_isJsonArray(data, start, end)) return false;

        for (uint256 i = start + 1; i < end - 1; ++i) {
            if (!_isWhitespace(data[i])) return false;
        }

        return true;
    }

    function _isJsonArray(
        bytes memory data,
        uint256 start,
        uint256 end
    ) internal pure returns (bool) {
        return end > start + 1 && data[start] == 0x5b && data[end - 1] == 0x5d;
    }

    function _validateLogArray(
        bytes memory data,
        uint256 start,
        uint256 end
    ) internal pure {
        if (!_isJsonArray(data, start, end)) {
            revert DeploymentLogger__InvalidDeploymentFile();
        }

        uint256 firstValue = _firstNonWhitespace(data, start + 1, end - 1);
        uint256 lastValue = _lastNonWhitespace(data, start + 1, end - 1);
        if (firstValue == end - 1 || data[firstValue] != 0x7b || data[lastValue] != 0x7d) {
            revert DeploymentLogger__InvalidDeploymentFile();
        }
    }

    function _trimBounds(
        bytes memory data
    ) internal pure returns (uint256 start, uint256 end) {
        end = data.length;
        while (start < end && _isWhitespace(data[start])) {
            ++start;
        }

        while (end > start && _isWhitespace(data[end - 1])) {
            --end;
        }
    }

    function _firstNonWhitespace(
        bytes memory data,
        uint256 start,
        uint256 end
    ) internal pure returns (uint256 index) {
        index = end;
        for (uint256 i = start; i < end; ++i) {
            if (!_isWhitespace(data[i])) return i;
        }
    }

    function _lastNonWhitespace(
        bytes memory data,
        uint256 start,
        uint256 end
    ) internal pure returns (uint256 index) {
        index = start;
        for (uint256 i = end; i > start; --i) {
            if (!_isWhitespace(data[i - 1])) return i - 1;
        }
    }

    function _isWhitespace(
        bytes1 char
    ) internal pure returns (bool) {
        return char == 0x20 || char == 0x09 || char == 0x0a || char == 0x0d;
    }

    function _slice(
        bytes memory data,
        uint256 start,
        uint256 end
    ) internal pure returns (string memory) {
        bytes memory result = new bytes(end - start);
        for (uint256 i; i < result.length; ++i) {
            result[i] = data[start + i];
        }

        return string(result);
    }

    function _serializeLogs(
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
            json = string.concat(json, _serializeLog(logs[i], i));
        }
        json = string.concat(json, "]");
        return json;
    }

    function _serializeLog(
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
