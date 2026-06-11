// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";

import { DeployBase } from "script/deployment/DeployBase.s.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { OptimizerZapper } from "contracts/plugins/market/OptimizerZapper.sol";
import { PendleZapperMinimal } from "contracts/plugins/market/PendleZapperMinimal.sol";

contract DeployBaseMiniRegistry {
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0x01ffc9a7 ||
            interfaceId == type(ICentralRegistry).interfaceId;
    }
}

contract DeployBaseHarness is DeployBase {
    function deployZappersForTest(
        ICentralRegistry icr,
        address wrappedNative
    ) external {
        _deployZappers(icr, wrappedNative);
    }
}

contract TestDeployBaseZappers is Test {
    event ContractDeployed(address contractAddress, string contractName);

    function test_deployZappers_emitsLaunchZapperDeployments() public {
        DeployBaseHarness deployBase = new DeployBaseHarness();
        DeployBaseMiniRegistry registry = new DeployBaseMiniRegistry();
        address wrappedNative = makeAddr("wrappedNative");

        vm.recordLogs();
        deployBase.deployZappersForTest(
            ICentralRegistry(address(registry)),
            wrappedNative
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 nativeVaultZapperCount;
        uint256 vaultZapperCount;
        uint256 simpleZapperCount;
        uint256 optimizerZapperCount;
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
                keccak256(bytes("zappers.nativeVaultZapper"))
            ) {
                assertNotEq(deployed, address(0));
                assertGt(deployed.code.length, 0);
                ++nativeVaultZapperCount;
            }

            if (
                keccak256(bytes(label)) ==
                keccak256(bytes("zappers.vaultZapper"))
            ) {
                assertNotEq(deployed, address(0));
                assertGt(deployed.code.length, 0);
                ++vaultZapperCount;
            }

            if (
                keccak256(bytes(label)) ==
                keccak256(bytes("zappers.simpleZapper"))
            ) {
                assertNotEq(deployed, address(0));
                assertGt(deployed.code.length, 0);
                ++simpleZapperCount;
            }

            if (
                keccak256(bytes(label)) ==
                keccak256(bytes("zappers.optimizerZapper"))
            ) {
                assertNotEq(deployed, address(0));
                assertGt(deployed.code.length, 0);
                assertEq(
                    address(OptimizerZapper(deployed).centralRegistry()),
                    address(registry)
                );
                assertEq(OptimizerZapper(deployed).wrappedNative(), wrappedNative);
                ++optimizerZapperCount;
            }

            if (
                keccak256(bytes(label)) ==
                keccak256(bytes("zappers.pendleZapperMinimal"))
            ) {
                assertNotEq(deployed, address(0));
                assertGt(deployed.code.length, 0);
                assertEq(
                    address(PendleZapperMinimal(payable(deployed)).centralRegistry()),
                    address(registry)
                );
                assertEq(
                    PendleZapperMinimal(payable(deployed)).wrappedNative(),
                    wrappedNative
                );
                assertTrue(
                    PendleZapperMinimal(payable(deployed)).ptOnly(),
                    "minimal Pendle zapper should deploy PT-only"
                );
                ++pendleZapperMinimalCount;
            }
        }

        assertEq(nativeVaultZapperCount, 1, "native vault zapper label count");
        assertEq(vaultZapperCount, 1, "vault zapper label count");
        assertEq(simpleZapperCount, 1, "simple zapper label count");
        assertEq(optimizerZapperCount, 1, "optimizer zapper label count");
        assertEq(
            pendleZapperMinimalCount,
            1,
            "PT-only PendleZapperMinimal label count"
        );
    }
}
