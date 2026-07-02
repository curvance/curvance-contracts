// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {Script} from "forge-std/Script.sol";

import {
    IChainlinkStyleAdaptor
} from "contracts/interfaces/IChainlinkStyleAdaptor.sol";
import {ICToken} from "contracts/interfaces/ICToken.sol";
import {ILendingOptimizer} from "contracts/interfaces/ILendingOptimizer.sol";
import {IMarketManager} from "contracts/interfaces/IMarketManager.sol";
import {IOracleAdaptor} from "contracts/interfaces/IOracleAdaptor.sol";
import {IOracleManager} from "contracts/interfaces/IOracleManager.sol";
import {
    VaultAggregator
} from "contracts/oracles/adaptors/wrappedAggregators/VaultAggregator.sol";

contract VerifyOptimizerShareLaunch is Script {
    error VerifyOptimizerShareLaunch__InvalidConfig();

    struct Config {
        address optimizer;
        address shareCToken;
        address marketManager;
        address oracleManager;
        address oracleAdaptor;
        address vaultAggregator;
        address expectedUnderlying;
        uint256 expectedCollateralCap;
        uint8 expectedFeedDecimals;
        uint24 expectedHeartbeat;
        uint40 expectedGuardTimestampStart;
        uint40 expectedGuardIps;
        uint88 expectedGuardBasePrice;
        uint88 expectedGuardMinPrice;
    }

    function run() external view {
        Config memory config;
        config.optimizer = vm.envAddress("OPTIMIZER_ADDRESS");
        config.shareCToken = vm.envAddress("OPTIMIZER_SHARE_CTOKEN");
        config.marketManager = vm.envAddress("OPTIMIZER_MARKET_MANAGER");
        config.oracleManager = vm.envAddress("OPTIMIZER_ORACLE_MANAGER");
        config.oracleAdaptor = vm.envAddress("OPTIMIZER_ORACLE_ADAPTOR");
        config.vaultAggregator = vm.envAddress("OPTIMIZER_VAULT_AGGREGATOR");
        config.expectedUnderlying = vm.envAddress("OPTIMIZER_UNDERLYING");
        config.expectedCollateralCap =
            vm.envUint("OPTIMIZER_SHARE_COLLATERAL_CAP");
        config.expectedFeedDecimals = _envUint8("OPTIMIZER_FEED_DECIMALS");
        config.expectedHeartbeat = _envUint24("OPTIMIZER_FEED_HEARTBEAT");
        config.expectedGuardTimestampStart =
            _envUint40("OPTIMIZER_GUARD_TIMESTAMP_START");
        config.expectedGuardIps = _envUint40("OPTIMIZER_GUARD_IPS");
        config.expectedGuardBasePrice =
            _envUint88("OPTIMIZER_GUARD_BASE_PRICE");
        config.expectedGuardMinPrice = _envUint88("OPTIMIZER_GUARD_MIN_PRICE");

        _verify(config);
    }

    function verify(Config calldata config) external view {
        _verify(config);
    }

    function _verify(Config memory config) internal view {
        _requireContract(config.optimizer);
        _requireContract(config.shareCToken);
        _requireContract(config.marketManager);
        _requireContract(config.oracleManager);
        _requireContract(config.oracleAdaptor);
        _requireContract(config.vaultAggregator);
        _requireContract(config.expectedUnderlying);

        if (
            ILendingOptimizer(config.optimizer).asset()
                != config.expectedUnderlying
        ) {
            revert VerifyOptimizerShareLaunch__InvalidConfig();
        }

        if (
            ILendingOptimizer(config.optimizer).centralRegistry()
                    .oracleManager() != config.oracleManager
        ) {
            revert VerifyOptimizerShareLaunch__InvalidConfig();
        }

        if (ICToken(config.shareCToken).asset() != config.optimizer) {
            revert VerifyOptimizerShareLaunch__InvalidConfig();
        }

        if (
            address(ICToken(config.shareCToken).marketManager())
                != config.marketManager
        ) {
            revert VerifyOptimizerShareLaunch__InvalidConfig();
        }

        if (!IMarketManager(config.marketManager).isListed(config.shareCToken))
        {
            revert VerifyOptimizerShareLaunch__InvalidConfig();
        }

        if (
            IMarketManager(config.marketManager).debtCaps(config.shareCToken)
                != 0
        ) {
            revert VerifyOptimizerShareLaunch__InvalidConfig();
        }

        if (
            IMarketManager(config.marketManager)
                    .collateralCaps(config.shareCToken)
                != config.expectedCollateralCap
        ) {
            revert VerifyOptimizerShareLaunch__InvalidConfig();
        }

        if (
            IOracleManager(config.oracleManager).cTokens(config.shareCToken)
                != config.optimizer
        ) {
            revert VerifyOptimizerShareLaunch__InvalidConfig();
        }

        (
            bool isConfigured,
            address configuredAggregator,
            uint8 configuredDecimals,
            uint24 configuredHeartbeat
        ) = IChainlinkStyleAdaptor(config.oracleAdaptor)
            .assetConfig(config.optimizer, true);

        if (
            !isConfigured || configuredAggregator != config.vaultAggregator
                || configuredDecimals != config.expectedFeedDecimals
                || configuredHeartbeat != config.expectedHeartbeat
        ) {
            revert VerifyOptimizerShareLaunch__InvalidConfig();
        }

        if (
            VaultAggregator(config.vaultAggregator).vault() != config.optimizer
        ) {
            revert VerifyOptimizerShareLaunch__InvalidConfig();
        }

        if (
            VaultAggregator(config.vaultAggregator).asset()
                != config.expectedUnderlying
        ) {
            revert VerifyOptimizerShareLaunch__InvalidConfig();
        }

        IOracleAdaptor.PriceGuard memory guard = IOracleAdaptor(
                config.oracleAdaptor
            ).getPriceGuard(config.optimizer, true);

        if (
            guard.timestampStart != config.expectedGuardTimestampStart
                || guard.ips != config.expectedGuardIps
                || guard.basePrice != config.expectedGuardBasePrice
                || guard.minPrice != config.expectedGuardMinPrice
        ) {
            revert VerifyOptimizerShareLaunch__InvalidConfig();
        }
    }

    function _requireContract(address target) internal view {
        if (target == address(0) || target.code.length == 0) {
            revert VerifyOptimizerShareLaunch__InvalidConfig();
        }
    }

    function _envUint8(string memory key) internal view returns (uint8) {
        uint256 value = vm.envUint(key);
        if (value > type(uint8).max) {
            revert VerifyOptimizerShareLaunch__InvalidConfig();
        }

        // Bound check above guarantees this cast cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint8(value);
    }

    function _envUint24(string memory key) internal view returns (uint24) {
        uint256 value = vm.envUint(key);
        if (value > type(uint24).max) {
            revert VerifyOptimizerShareLaunch__InvalidConfig();
        }

        // Bound check above guarantees this cast cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint24(value);
    }

    function _envUint40(string memory key) internal view returns (uint40) {
        uint256 value = vm.envUint(key);
        if (value > type(uint40).max) {
            revert VerifyOptimizerShareLaunch__InvalidConfig();
        }

        // Bound check above guarantees this cast cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint40(value);
    }

    function _envUint88(string memory key) internal view returns (uint88) {
        uint256 value = vm.envUint(key);
        if (value > type(uint88).max) {
            revert VerifyOptimizerShareLaunch__InvalidConfig();
        }

        // Bound check above guarantees this cast cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint88(value);
    }
}
