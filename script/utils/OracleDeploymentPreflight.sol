// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";
import {OracleManager} from "contracts/oracles/OracleManager.sol";

library OracleDeploymentPreflight {
    error OracleDeploymentPreflight__InvalidPreflight();

    uint256 internal constant MAX_INPUT_HEARTBEAT = 1 days;
    uint256 internal constant MINIMUM_TIMESTAMP_BUFFER = 7 days;
    uint256 internal constant MIN_DEVIATION_BOUND = 20;
    uint256 internal constant MAX_DEVIATION_BOUND = 350;
    uint256 internal constant MIN_CAUTION_TO_BAD_SOURCE_DELTA = 20;

    function requireNonZero(address target) internal pure {
        if (target == address(0)) {
            revert OracleDeploymentPreflight__InvalidPreflight();
        }
    }

    function requireContract(address target) internal view {
        requireNonZero(target);
        if (target.code.length == 0) {
            revert OracleDeploymentPreflight__InvalidPreflight();
        }
    }

    function requireNonEmpty(uint256 length) internal pure {
        if (length == 0) {
            revert OracleDeploymentPreflight__InvalidPreflight();
        }
    }

    function requireNonEmptyString(string memory value) internal pure {
        if (bytes(value).length == 0) {
            revert OracleDeploymentPreflight__InvalidPreflight();
        }
    }

    function requireHeartbeat(uint256 heartbeat) internal pure {
        if (heartbeat > MAX_INPUT_HEARTBEAT) {
            revert OracleDeploymentPreflight__InvalidPreflight();
        }
    }

    /// @dev PriceGuard enablement is an operator/feed policy decision. These
    ///      helpers only validate fields that a downstream guard setter will
    ///      consume; disabled guards are accepted as no-op entries.
    function validateRelativeGuardIfEnabled(
        bool enabled,
        uint256 timestampSubtract,
        uint256 ips,
        uint256 basePrice,
        uint256 minPrice
    ) internal view {
        if (!enabled) {
            return;
        }

        _requireGuardBounds(ips, basePrice, minPrice);

        if (ips == 0) {
            if (timestampSubtract != 0) {
                revert OracleDeploymentPreflight__InvalidPreflight();
            }
        } else if (
            timestampSubtract < MINIMUM_TIMESTAMP_BUFFER
                || timestampSubtract >= block.timestamp
        ) {
            revert OracleDeploymentPreflight__InvalidPreflight();
        }
    }

    function validateAbsoluteGuardIfEnabled(
        bool enabled,
        uint256 timestampStart,
        uint256 ips,
        uint256 basePrice,
        uint256 minPrice
    ) internal view {
        if (!enabled) {
            return;
        }

        _requireGuardBounds(ips, basePrice, minPrice);

        if (ips == 0) {
            if (timestampStart != 0) {
                revert OracleDeploymentPreflight__InvalidPreflight();
            }
        } else if (
            timestampStart == 0 || timestampStart > block.timestamp
                || block.timestamp - timestampStart < MINIMUM_TIMESTAMP_BUFFER
        ) {
            revert OracleDeploymentPreflight__InvalidPreflight();
        }
    }

    function validateSecondAdaptorDeviationBounds(
        bool willSetDeviationBounds,
        uint256 badSourceUSD,
        uint256 cautionUSD,
        uint256 badSourceNative,
        uint256 cautionNative
    ) internal pure {
        if (!willSetDeviationBounds) {
            return;
        }

        if (
            cautionUSD > type(uint256).max - MIN_CAUTION_TO_BAD_SOURCE_DELTA
                || cautionNative
                    > type(uint256).max - MIN_CAUTION_TO_BAD_SOURCE_DELTA
                || badSourceUSD < cautionUSD + MIN_CAUTION_TO_BAD_SOURCE_DELTA
                || badSourceNative
                    < cautionNative + MIN_CAUTION_TO_BAD_SOURCE_DELTA
                || cautionUSD < MIN_DEVIATION_BOUND
                || cautionNative < MIN_DEVIATION_BOUND
                || badSourceUSD > MAX_DEVIATION_BOUND
                || badSourceNative > MAX_DEVIATION_BOUND
        ) {
            revert OracleDeploymentPreflight__InvalidPreflight();
        }
    }

    function willSetDeviationBoundsOnAdd(OracleManager manager, address asset)
        internal
        view
        returns (bool)
    {
        try manager.getPricingAdaptors(asset) returns (
            address[] memory adaptors
        ) {
            if (adaptors.length > 1) {
                revert OracleDeploymentPreflight__InvalidPreflight();
            }

            return adaptors.length == 1;
        } catch {
            revert OracleDeploymentPreflight__InvalidPreflight();
        }
    }

    function requireOracleManagerRegistry(
        address oracleManager,
        address registry
    ) internal view {
        requireContract(oracleManager);
        requireContract(registry);

        try OracleManager(oracleManager).centralRegistry() returns (
            ICentralRegistry managerRegistry
        ) {
            if (address(managerRegistry) != registry) {
                revert OracleDeploymentPreflight__InvalidPreflight();
            }
        } catch {
            revert OracleDeploymentPreflight__InvalidPreflight();
        }
    }

    function _requireGuardBounds(
        uint256 ips,
        uint256 basePrice,
        uint256 minPrice
    ) private pure {
        if (
            basePrice == 0 || basePrice > type(uint88).max
                || minPrice > basePrice || ips > type(uint40).max
        ) {
            revert OracleDeploymentPreflight__InvalidPreflight();
        }
    }
}
