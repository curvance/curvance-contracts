// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";

import { DeployCalldataChecker } from "script/deployment/DeployCalldataChecker.s.sol";
import { DeployBase } from "script/deployment/DeployBase.s.sol";
import { DeploymentLogger } from "script/utils/DeploymentLogger.sol";
import { KyberSwapChecker } from "contracts/calldata-checker/swap-checker/KyberSwapChecker.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { PendleZapperMinimalCalldataChecker } from "contracts/calldata-checker/swap-checker/PendleZapperMinimalCalldataChecker.sol";
import { PendleZapperMinimal } from "contracts/plugins/market/PendleZapperMinimal.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

contract DeployCalldataCheckerMiniRegistry {
    address public constant daoAddress = address(0xDA0);

    mapping(address => address) public externalCalldataChecker;

    event CalldataCheckerSet(string checkerType, address target, address checker);

    function hasDaoPermissions(address addressToCheck) external pure returns (bool) {
        return addressToCheck == daoAddress;
    }

    function setExternalCalldataChecker(address target, address checker) external {
        externalCalldataChecker[target] = checker;
        emit CalldataCheckerSet("External", target, checker);
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0x01ffc9a7 ||
            interfaceId == type(ICentralRegistry).interfaceId;
    }
}

contract DeployCalldataCheckerHarness is DeployCalldataChecker {
    modifier recordEvents() override {
        _;
    }
}

contract DeployCalldataCheckerRecordedHarness is DeployCalldataChecker {
    string internal _testDirectory;
    string internal _testFile;

    constructor(
        string memory testDirectory,
        string memory testFile
    ) {
        _testDirectory = testDirectory;
        _testFile = testFile;
    }

    function _deploymentFilePath() internal view override returns (string memory) {
        return _testFile;
    }

    function _deploymentDirectoryPath() internal view override returns (string memory) {
        return _testDirectory;
    }
}

contract DeployBaseForCalldataCheckerHarness is DeployBase {
    function deployZappersForTest(
        ICentralRegistry icr,
        address wrappedNative
    ) external {
        _deployZappers(icr, wrappedNative);
    }
}

contract DeployCalldataCheckerRevertingPendleTarget {
    function ptOnly() external pure returns (bool) {
        revert("ptOnly failed");
    }
}

contract DeployCalldataCheckerRevertingRegistryPendleTarget {
    function ptOnly() external pure returns (bool) {
        return true;
    }

    function centralRegistry() external pure returns (ICentralRegistry) {
        revert("centralRegistry failed");
    }
}

contract TestDeployCalldataChecker is Test {
    event ContractDeployed(address contractAddress, string contractName);

    address internal constant KYBER_ROUTER =
        0x6131B5fae19EA4f9D964eAc0408E4408b66337b5;
    address internal constant KYBER_EXECUTOR =
        0x63242A4Ea82847b20E506b63B0e2e2eFF0CC6cB0;
    address internal constant PLANNED_KYBER_EXECUTOR =
        0x4a16958D2041044C67c8F33017a75693Cc58F7CC;
    address internal constant CURRENT_API_KYBER_EXECUTOR =
        0x8F10B468b06c6FD214B65F87778827F7D113f996;
    address internal constant PENDLE_ROUTER =
        0x888888888889758F76e7103c6CbF23ABbF58F946;

    function test_deployCalldataChecker_registersKyberChecker() public {
        vm.chainId(143);

        DeployCalldataCheckerHarness deployCalldataChecker =
            new DeployCalldataCheckerHarness();
        DeployCalldataCheckerMiniRegistry registry =
            new DeployCalldataCheckerMiniRegistry();

        vm.recordLogs();
        deployCalldataChecker.run(
            address(registry),
            DeployCalldataChecker.AvailableCheckers({
                router: KYBER_ROUTER,
                pendleZapperMinimal: address(0),
                pendleRouter: address(0)
            })
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        KyberSwapChecker checker = KyberSwapChecker(
            registry.externalCalldataChecker(KYBER_ROUTER)
        );

        assertGt(address(checker).code.length, 0);
        assertEq(checker.target(), KYBER_ROUTER);
        assertTrue(checker.isApprovedExecutor(KYBER_EXECUTOR), "legacy executor");
        assertTrue(checker.isApprovedExecutor(PLANNED_KYBER_EXECUTOR), "planned executor");
        assertTrue(
            checker.isApprovedExecutor(CURRENT_API_KYBER_EXECUTOR),
            "current API executor"
        );
        assertEq(
            _countContractDeployedLogs(
                logs,
                address(checker),
                "calldataCheckers.kyberSwapChecker"
            ),
            1,
            "expected one Kyber checker deployment event"
        );
    }

    function test_deployCalldataChecker_revertsUnexpectedKyberRouter() public {
        vm.chainId(143);

        DeployCalldataCheckerHarness deployCalldataChecker =
            new DeployCalldataCheckerHarness();
        DeployCalldataCheckerMiniRegistry registry =
            new DeployCalldataCheckerMiniRegistry();

        vm.expectRevert(
            DeployCalldataChecker.DeployCalldataChecker__InvalidKyberRouter.selector
        );
        deployCalldataChecker.run(
            address(registry),
            DeployCalldataChecker.AvailableCheckers({
                router: makeAddr("wrongRouter"),
                pendleZapperMinimal: address(0),
                pendleRouter: address(0)
            })
        );
    }

    function test_deployCalldataChecker_registersPendleMinimalChecker() public {
        DeployCalldataCheckerHarness deployCalldataChecker =
            new DeployCalldataCheckerHarness();
        DeployCalldataCheckerMiniRegistry registry =
            new DeployCalldataCheckerMiniRegistry();

        address pendleZapperMinimal = address(new PendleZapperMinimal(
            ICentralRegistry(address(registry)),
            makeAddr("wrappedNative"),
            true
        ));
        vm.recordLogs();
        deployCalldataChecker.run(
            address(registry),
            DeployCalldataChecker.AvailableCheckers({
                router: address(0),
                pendleZapperMinimal: pendleZapperMinimal,
                pendleRouter: PENDLE_ROUTER
            })
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        PendleZapperMinimalCalldataChecker checker =
            PendleZapperMinimalCalldataChecker(
                registry.externalCalldataChecker(pendleZapperMinimal)
            );

        assertGt(address(checker).code.length, 0);
        assertEq(checker.target(), pendleZapperMinimal);
        assertEq(checker.pendleRouter(), PENDLE_ROUTER);
        assertEq(
            _countContractDeployedLogs(
                logs,
                address(checker),
                "calldataCheckers.pendleZapperMinimalChecker"
            ),
            1,
            "expected one Pendle checker deployment event"
        );
    }

    function test_deployCalldataChecker_registersCheckersOnProductionRegistry()
        public
    {
        vm.chainId(143);

        DeployCalldataCheckerHarness deployCalldataChecker =
            new DeployCalldataCheckerHarness();
        CentralRegistry registry = new CentralRegistry(
            address(this),
            address(deployCalldataChecker),
            1_779_686_867,
            address(0),
            makeAddr("feeToken")
        );

        address pendleZapperMinimal = address(new PendleZapperMinimal(
            ICentralRegistry(address(registry)),
            makeAddr("wrappedNative"),
            true
        ));

        deployCalldataChecker.run(
            address(registry),
            DeployCalldataChecker.AvailableCheckers({
                router: KYBER_ROUTER,
                pendleZapperMinimal: pendleZapperMinimal,
                pendleRouter: PENDLE_ROUTER
            })
        );

        KyberSwapChecker kyberChecker = KyberSwapChecker(
            registry.externalCalldataChecker(KYBER_ROUTER)
        );
        PendleZapperMinimalCalldataChecker pendleChecker =
            PendleZapperMinimalCalldataChecker(
                registry.externalCalldataChecker(pendleZapperMinimal)
            );

        assertGt(address(kyberChecker).code.length, 0);
        assertEq(kyberChecker.target(), KYBER_ROUTER);
        assertTrue(kyberChecker.isApprovedExecutor(CURRENT_API_KYBER_EXECUTOR));

        assertGt(address(pendleChecker).code.length, 0);
        assertEq(pendleChecker.target(), pendleZapperMinimal);
        assertEq(pendleChecker.pendleRouter(), PENDLE_ROUTER);
    }

    function test_deployCalldataChecker_recordEventsWritesDeploymentFile()
        public
    {
        vm.chainId(143);

        (string memory directory, string memory file) =
            _deploymentOutput("deploy-calldata-checker");
        DeployCalldataCheckerRecordedHarness deployCalldataChecker =
            new DeployCalldataCheckerRecordedHarness(directory, file);
        DeployCalldataCheckerMiniRegistry registry =
            new DeployCalldataCheckerMiniRegistry();

        address pendleZapperMinimal = address(new PendleZapperMinimal(
            ICentralRegistry(address(registry)),
            makeAddr("wrappedNative"),
            true
        ));

        deployCalldataChecker.run(
            address(registry),
            DeployCalldataChecker.AvailableCheckers({
                router: KYBER_ROUTER,
                pendleZapperMinimal: pendleZapperMinimal,
                pendleRouter: PENDLE_ROUTER
            })
        );

        string memory saved = vm.readFile(file);
        assertEq(
            _countOccurrences(saved, vm.toString(ContractDeployed.selector)),
            2,
            "expected both checker deployments to be recorded"
        );
        assertGt(
            _countOccurrences(saved, _hexPayload("calldataCheckers.kyberSwapChecker")),
            0,
            "expected Kyber checker label in recorded deployment data"
        );
        assertGt(
            _countOccurrences(saved, _hexPayload("calldataCheckers.pendleZapperMinimalChecker")),
            0,
            "expected Pendle checker label in recorded deployment data"
        );
        vm.parseJson(saved);

        _cleanup(directory, file);
    }

    function test_deployCalldataChecker_recordEventsRejectsInvalidDeploymentFile()
        public
    {
        vm.chainId(143);

        (string memory directory, string memory file) =
            _deploymentOutput("deploy-calldata-checker-invalid");
        vm.createDir(directory, true);
        vm.writeFile(file, "{}");

        DeployCalldataCheckerRecordedHarness deployCalldataChecker =
            new DeployCalldataCheckerRecordedHarness(directory, file);
        DeployCalldataCheckerMiniRegistry registry =
            new DeployCalldataCheckerMiniRegistry();

        vm.expectRevert(DeploymentLogger.DeploymentLogger__InvalidDeploymentFile.selector);
        deployCalldataChecker.run(
            address(registry),
            DeployCalldataChecker.AvailableCheckers({
                router: KYBER_ROUTER,
                pendleZapperMinimal: address(0),
                pendleRouter: address(0)
            })
        );

        _cleanup(directory, file);
    }

    function test_deployCalldataChecker_revertsUnexpectedPendleRouter() public {
        DeployCalldataCheckerHarness deployCalldataChecker =
            new DeployCalldataCheckerHarness();
        DeployCalldataCheckerMiniRegistry registry =
            new DeployCalldataCheckerMiniRegistry();

        address pendleZapperMinimal = address(new PendleZapperMinimal(
            ICentralRegistry(address(registry)),
            makeAddr("wrappedNative"),
            true
        ));

        vm.expectRevert(
            DeployCalldataChecker.DeployCalldataChecker__InvalidPendleRouter.selector
        );
        deployCalldataChecker.run(
            address(registry),
            DeployCalldataChecker.AvailableCheckers({
                router: address(0),
                pendleZapperMinimal: pendleZapperMinimal,
                pendleRouter: makeAddr("pendleRouter")
            })
        );
    }

    function test_deployCalldataChecker_revertsPendleMinimalWithWrongRegistry() public {
        DeployCalldataCheckerHarness deployCalldataChecker =
            new DeployCalldataCheckerHarness();
        DeployCalldataCheckerMiniRegistry registry =
            new DeployCalldataCheckerMiniRegistry();
        DeployCalldataCheckerMiniRegistry wrongRegistry =
            new DeployCalldataCheckerMiniRegistry();

        address pendleZapperMinimal = address(new PendleZapperMinimal(
            ICentralRegistry(address(wrongRegistry)),
            makeAddr("wrappedNative"),
            true
        ));

        vm.expectRevert(
            DeployCalldataChecker
                .DeployCalldataChecker__InvalidPendleZapperMinimal
                .selector
        );
        deployCalldataChecker.run(
            address(registry),
            DeployCalldataChecker.AvailableCheckers({
                router: address(0),
                pendleZapperMinimal: pendleZapperMinimal,
                pendleRouter: PENDLE_ROUTER
            })
        );
    }

    function test_deployCalldataChecker_revertsPendleMinimalWhenRegistryCallReverts()
        public
    {
        DeployCalldataCheckerHarness deployCalldataChecker =
            new DeployCalldataCheckerHarness();
        DeployCalldataCheckerMiniRegistry registry =
            new DeployCalldataCheckerMiniRegistry();
        DeployCalldataCheckerRevertingRegistryPendleTarget pendleZapperMinimal =
            new DeployCalldataCheckerRevertingRegistryPendleTarget();

        vm.expectRevert(
            DeployCalldataChecker
                .DeployCalldataChecker__InvalidPendleZapperMinimal
                .selector
        );
        deployCalldataChecker.run(
            address(registry),
            DeployCalldataChecker.AvailableCheckers({
                router: address(0),
                pendleZapperMinimal: address(pendleZapperMinimal),
                pendleRouter: PENDLE_ROUTER
            })
        );
    }

    function test_deployCalldataChecker_registersDeployBasePendleMinimalTarget()
        public
    {
        DeployBaseForCalldataCheckerHarness deployBase =
            new DeployBaseForCalldataCheckerHarness();
        DeployCalldataCheckerHarness deployCalldataChecker =
            new DeployCalldataCheckerHarness();
        DeployCalldataCheckerMiniRegistry registry =
            new DeployCalldataCheckerMiniRegistry();

        address wrappedNative = makeAddr("wrappedNative");

        vm.recordLogs();
        deployBase.deployZappersForTest(
            ICentralRegistry(address(registry)),
            wrappedNative
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        address pendleZapperMinimal;
        uint256 pendleZapperMinimalCount;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].topics.length != 1 ||
                logs[i].topics[0] != ContractDeployed.selector
            ) {
                continue;
            }

            (address deployed, string memory label) = abi.decode(
                logs[i].data,
                (address, string)
            );

            if (
                keccak256(bytes(label)) ==
                keccak256(bytes("zappers.pendleZapperMinimal"))
            ) {
                pendleZapperMinimal = deployed;
                ++pendleZapperMinimalCount;
            }
        }

        assertEq(pendleZapperMinimalCount, 1, "expected one minimal zapper");
        assertTrue(
            PendleZapperMinimal(payable(pendleZapperMinimal)).ptOnly(),
            "DeployBase minimal zapper must be PT-only"
        );

        deployCalldataChecker.run(
            address(registry),
            DeployCalldataChecker.AvailableCheckers({
                router: address(0),
                pendleZapperMinimal: pendleZapperMinimal,
                pendleRouter: PENDLE_ROUTER
            })
        );

        PendleZapperMinimalCalldataChecker checker =
            PendleZapperMinimalCalldataChecker(
                registry.externalCalldataChecker(pendleZapperMinimal)
            );

        assertGt(address(checker).code.length, 0);
        assertEq(checker.target(), pendleZapperMinimal);
        assertEq(checker.pendleRouter(), PENDLE_ROUTER);
        assertEq(
            registry.externalCalldataChecker(pendleZapperMinimal),
            address(checker)
        );
    }

    function test_deployCalldataChecker_revertsPendleMinimalWhenTargetIsNotPtOnly() public {
        DeployCalldataCheckerHarness deployCalldataChecker =
            new DeployCalldataCheckerHarness();
        DeployCalldataCheckerMiniRegistry registry =
            new DeployCalldataCheckerMiniRegistry();

        address pendleZapper = address(new PendleZapperMinimal(
            ICentralRegistry(address(registry)),
            makeAddr("wrappedNative"),
            false
        ));

        vm.expectRevert(
            DeployCalldataChecker.DeployCalldataChecker__InvalidPendleZapperMinimal.selector
        );
        deployCalldataChecker.run(
            address(registry),
            DeployCalldataChecker.AvailableCheckers({
                router: address(0),
                pendleZapperMinimal: pendleZapper,
                pendleRouter: makeAddr("pendleRouter")
            })
        );
    }

    function test_deployCalldataChecker_revertsPendleMinimalWhenPtOnlyCallReverts()
        public
    {
        DeployCalldataCheckerHarness deployCalldataChecker =
            new DeployCalldataCheckerHarness();
        DeployCalldataCheckerMiniRegistry registry =
            new DeployCalldataCheckerMiniRegistry();
        DeployCalldataCheckerRevertingPendleTarget pendleZapperMinimal =
            new DeployCalldataCheckerRevertingPendleTarget();

        vm.expectRevert(
            DeployCalldataChecker
                .DeployCalldataChecker__InvalidPendleZapperMinimal
                .selector
        );
        deployCalldataChecker.run(
            address(registry),
            DeployCalldataChecker.AvailableCheckers({
                router: address(0),
                pendleZapperMinimal: address(pendleZapperMinimal),
                pendleRouter: PENDLE_ROUTER
            })
        );
    }

    function _countContractDeployedLogs(
        Vm.Log[] memory logs,
        address deployed,
        string memory label
    ) internal pure returns (uint256 count) {
        bytes32 labelHash = keccak256(bytes(label));
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].topics.length != 1 ||
                logs[i].topics[0] != ContractDeployed.selector
            ) {
                continue;
            }

            (address logDeployed, string memory logLabel) = abi.decode(
                logs[i].data,
                (address, string)
            );

            if (
                logDeployed == deployed &&
                keccak256(bytes(logLabel)) == labelHash
            ) {
                ++count;
            }
        }
    }

    function _deploymentOutput(
        string memory suffix
    ) internal returns (
        string memory directory,
        string memory file
    ) {
        directory = string.concat(vm.projectRoot(), "/tmp/", suffix);
        file = string.concat(directory, "/deployment.json");
        if (vm.exists(file)) {
            vm.removeFile(file);
        }
        if (vm.exists(directory)) {
            vm.removeDir(directory, true);
        }
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

    function _hexPayload(
        string memory value
    ) internal pure returns (string memory) {
        bytes memory data = bytes(value);
        bytes memory alphabet = "0123456789abcdef";
        bytes memory encoded = new bytes(data.length * 2);

        for (uint256 i; i < data.length; ++i) {
            encoded[i * 2] = alphabet[uint8(data[i]) >> 4];
            encoded[i * 2 + 1] = alphabet[uint8(data[i]) & 0x0f];
        }

        return string(encoded);
    }
}
