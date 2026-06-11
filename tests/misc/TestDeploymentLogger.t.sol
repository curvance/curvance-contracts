// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";

import { DeploymentLogger } from "script/utils/DeploymentLogger.sol";

contract DeploymentLoggerHarness is DeploymentLogger {
    error DeploymentLoggerHarness__BodyReached();

    string internal _testDirectory;
    string internal _testFile;

    constructor(
        string memory testDirectory,
        string memory testFile
    ) {
        _testDirectory = testDirectory;
        _testFile = testFile;
    }

    function saveLogs(
        Vm.Log[] memory logs
    ) external {
        _saveLogsToDeployment(logs);
    }

    function emitRecordedDeployment(
        address deployed,
        string calldata name
    ) external recordEvents {
        emit ContractDeployed(deployed, name);
    }

    function revertIfBodyRuns() external recordEvents {
        revert DeploymentLoggerHarness__BodyReached();
    }

    function _deploymentFilePath() internal view override returns (string memory) {
        return _testFile;
    }

    function _deploymentDirectoryPath() internal view override returns (string memory) {
        return _testDirectory;
    }
}

contract TestDeploymentLogger is Test {
    event ContractDeployed(address contractAddress, string contractName);

    function test_saveLogsToDeployment_appendsExistingDeploymentFile() public {
        (DeploymentLoggerHarness logger, string memory directory, string memory file) = _logger("append");

        logger.saveLogs(_singleLog(address(0x1111), "First"));
        string memory first = vm.readFile(file);
        assertEq(_countOccurrences(first, '"emitter"'), 1, "first run should write one log");

        logger.saveLogs(_singleLog(address(0x2222), "Second"));
        string memory second = vm.readFile(file);
        assertEq(_countOccurrences(second, '"emitter"'), 2, "second run should append one log");
        vm.parseJson(second);

        bytes memory secondBytes = bytes(second);
        assertEq(uint8(secondBytes[0]), uint8(0x5b), "deployment file should remain a JSON array");
        assertEq(uint8(secondBytes[secondBytes.length - 1]), uint8(0x5d), "deployment file should remain a JSON array");

        _cleanup(directory, file);
    }

    function test_recordEvents_writesDeploymentLog() public {
        (DeploymentLoggerHarness logger, string memory directory, string memory file) = _logger("record-events");

        logger.emitRecordedDeployment(address(0x3333), "Recorded");

        string memory saved = vm.readFile(file);
        assertEq(_countOccurrences(saved, '"emitter"'), 1, "recordEvents should write one log");
        assertGt(
            _countOccurrences(saved, vm.toString(ContractDeployed.selector)),
            0,
            "recordEvents should persist the emitted deployment event"
        );
        vm.parseJson(saved);

        _cleanup(directory, file);
    }

    function test_recordEvents_revertsOnInvalidDeploymentFileBeforeBody() public {
        (DeploymentLoggerHarness logger, string memory directory, string memory file) = _logger("preflight-invalid");
        vm.createDir(directory, true);
        vm.writeFile(file, "{}");

        vm.expectRevert(DeploymentLogger.DeploymentLogger__InvalidDeploymentFile.selector);
        logger.revertIfBodyRuns();

        _cleanup(directory, file);
    }

    function test_saveLogsToDeployment_treatsWhitespaceOnlyArrayAsEmpty() public {
        (DeploymentLoggerHarness logger, string memory directory, string memory file) = _logger("empty-array");
        vm.createDir(directory, true);
        vm.writeFile(file, "[ \n\t]");

        logger.saveLogs(_singleLog(address(0x1111), "First"));
        string memory saved = vm.readFile(file);
        assertEq(_countOccurrences(saved, '"emitter"'), 1, "empty array should be replaced");
        vm.parseJson(saved);

        _cleanup(directory, file);
    }

    function test_saveLogsToDeployment_treatsWhitespaceOnlyFileAsEmpty() public {
        (DeploymentLoggerHarness logger, string memory directory, string memory file) = _logger("empty-file");
        vm.createDir(directory, true);
        vm.writeFile(file, " \n\t");

        logger.saveLogs(_singleLog(address(0x1111), "First"));
        string memory saved = vm.readFile(file);
        assertEq(_countOccurrences(saved, '"emitter"'), 1, "blank file should be replaced");
        vm.parseJson(saved);

        _cleanup(directory, file);
    }

    function test_saveLogsToDeployment_revertsOnInvalidExistingDeploymentFile() public {
        (DeploymentLoggerHarness logger, string memory directory, string memory file) = _logger("invalid");
        vm.createDir(directory, true);
        vm.writeFile(file, "{}");

        vm.expectRevert(DeploymentLogger.DeploymentLogger__InvalidDeploymentFile.selector);
        logger.saveLogs(_singleLog(address(0x1111), "First"));

        _cleanup(directory, file);
    }

    function test_saveLogsToDeployment_revertsOnMalformedExistingDeploymentFile() public {
        (DeploymentLoggerHarness logger, string memory directory, string memory file) = _logger("malformed");
        vm.createDir(directory, true);
        vm.writeFile(file, "[not-json]");

        vm.expectRevert();
        logger.saveLogs(_singleLog(address(0x1111), "First"));

        _cleanup(directory, file);
    }

    function _logger(
        string memory suffix
    ) internal returns (
        DeploymentLoggerHarness logger,
        string memory directory,
        string memory file
    ) {
        directory = string.concat(vm.projectRoot(), "/tmp/deployment-logger-test-", suffix);
        file = string.concat(directory, "/deployment.json");
        if (vm.exists(file)) {
            vm.removeFile(file);
        }
        if (vm.exists(directory)) {
            vm.removeDir(directory, true);
        }

        logger = new DeploymentLoggerHarness(directory, file);
    }

    function _singleLog(
        address deployed,
        string memory name
    ) internal returns (Vm.Log[] memory logs) {
        vm.recordLogs();
        emit ContractDeployed(deployed, name);
        logs = vm.getRecordedLogs();
    }

    function _cleanup(
        string memory directory,
        string memory file
    ) internal {
        if (vm.exists(file)) {
            vm.removeFile(file);
        }
        if (vm.exists(directory)) {
            vm.removeDir(directory, true);
        }
    }

    function _countOccurrences(
        string memory haystack,
        string memory needle
    ) internal pure returns (uint256 count) {
        bytes memory haystackBytes = bytes(haystack);
        bytes memory needleBytes = bytes(needle);
        if (needleBytes.length == 0 || haystackBytes.length < needleBytes.length) return 0;

        for (uint256 i; i <= haystackBytes.length - needleBytes.length; ++i) {
            bool matches = true;
            for (uint256 j; j < needleBytes.length; ++j) {
                if (haystackBytes[i + j] != needleBytes[j]) {
                    matches = false;
                    break;
                }
            }
            if (matches) ++count;
        }
    }
}
