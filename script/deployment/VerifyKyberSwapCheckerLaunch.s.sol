// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {Script} from "forge-std/Script.sol";

import {
    KyberSwapChecker
} from "contracts/calldata-checker/swap-checker/KyberSwapChecker.sol";
import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";

contract VerifyKyberSwapCheckerLaunch is Script {
    error VerifyKyberSwapCheckerLaunch__InvalidConfig();

    struct Config {
        address registry;
        address router;
        address checker;
        bytes32 expectedCheckerCodeHash;
        uint256 expectedFeeBps;
        uint256 expectedRequiredFlags;
        address[] approvedExecutors;
        address[] unapprovedExecutors;
    }

    function run() external view {
        address[] memory empty;

        Config memory config = Config({
            registry: vm.envAddress("KYBER_CENTRAL_REGISTRY"),
            router: vm.envAddress("KYBER_ROUTER"),
            checker: vm.envAddress("KYBER_CHECKER"),
            expectedCheckerCodeHash: vm.envBytes32("KYBER_CHECKER_CODEHASH"),
            expectedFeeBps: vm.envUint("KYBER_EXPECTED_FEE_BPS"),
            expectedRequiredFlags: vm.envUint("KYBER_EXPECTED_REQUIRED_FLAGS"),
            approvedExecutors: vm.envOr(
                "KYBER_APPROVED_EXECUTORS", ",", empty
            ),
            unapprovedExecutors: vm.envOr(
                "KYBER_UNAPPROVED_EXECUTORS", ",", empty
            )
        });

        _verify(config);
    }

    function verify(Config calldata config) external view {
        _verify(config);
    }

    function _verify(Config memory config) internal view {
        _requireContract(config.registry);
        _requireContract(config.router);
        _requireContract(config.checker);

        if (
            ICentralRegistry(config.registry)
                    .externalCalldataChecker(config.router) != config.checker
        ) {
            revert VerifyKyberSwapCheckerLaunch__InvalidConfig();
        }

        KyberSwapChecker checker = KyberSwapChecker(config.checker);

        if (config.checker.codehash != config.expectedCheckerCodeHash) {
            revert VerifyKyberSwapCheckerLaunch__InvalidConfig();
        }

        if (
            checker.target() != config.router
                || address(checker.centralRegistry()) != config.registry
                || checker.FEE_BPS() != config.expectedFeeBps
                || checker.REQUIRED_FLAGS() != config.expectedRequiredFlags
        ) {
            revert VerifyKyberSwapCheckerLaunch__InvalidConfig();
        }

        uint256 numApprovedExecutors = config.approvedExecutors.length;
        for (uint256 i; i < numApprovedExecutors; ++i) {
            if (!checker.isApprovedExecutor(config.approvedExecutors[i])) {
                revert VerifyKyberSwapCheckerLaunch__InvalidConfig();
            }
        }

        uint256 numUnapprovedExecutors = config.unapprovedExecutors.length;
        for (uint256 i; i < numUnapprovedExecutors; ++i) {
            if (checker.isApprovedExecutor(config.unapprovedExecutors[i])) {
                revert VerifyKyberSwapCheckerLaunch__InvalidConfig();
            }
        }
    }

    function _requireContract(address target) internal view {
        if (target == address(0) || target.code.length == 0) {
            revert VerifyKyberSwapCheckerLaunch__InvalidConfig();
        }
    }
}
