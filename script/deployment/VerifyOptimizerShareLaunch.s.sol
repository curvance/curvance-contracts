// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {Script} from "forge-std/Script.sol";

import {
    IChainlinkStyleAdaptor
} from "contracts/interfaces/IChainlinkStyleAdaptor.sol";
import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";
import {ICToken} from "contracts/interfaces/ICToken.sol";
import {ILendingOptimizer} from "contracts/interfaces/ILendingOptimizer.sol";
import {IMarketManager} from "contracts/interfaces/IMarketManager.sol";
import {IOracleAdaptor} from "contracts/interfaces/IOracleAdaptor.sol";
import {IOracleManager} from "contracts/interfaces/IOracleManager.sol";
import {IPositionManager} from "contracts/interfaces/IPositionManager.sol";
import {
    LendingOptimizerShareCToken
} from "contracts/market/token/LendingOptimizerShareCToken.sol";
import {
    VaultAggregator
} from "contracts/oracles/adaptors/wrappedAggregators/VaultAggregator.sol";

interface ICentralRegistryBound {
    function centralRegistry() external view returns (ICentralRegistry);
}

contract VerifyOptimizerShareLaunch is Script {
    error VerifyOptimizerShareLaunch__InvalidConfig();

    uint256 internal constant _DEBT_SURFACE_PROBE_ASSETS = 1;

    struct Config {
        address optimizer;
        address shareCToken;
        address marketManager;
        address oracleManager;
        address oracleAdaptor;
        address vaultAggregator;
        address expectedUnderlyingAggregator;
        address expectedUnderlying;
        bytes32 expectedDataFeedId;
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
        config.expectedUnderlyingAggregator =
            vm.envAddress("OPTIMIZER_UNDERLYING_AGGREGATOR");
        config.expectedUnderlying = vm.envAddress("OPTIMIZER_UNDERLYING");
        config.expectedDataFeedId = vm.envBytes32("OPTIMIZER_DATA_FEED_ID");
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

        _requireBoundRegistries(config);

        if (ICToken(config.shareCToken).asset() != config.optimizer) {
            revert VerifyOptimizerShareLaunch__InvalidConfig();
        }

        _requireShareDebtSurfacesDisabled(config.shareCToken);

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

        IOracleManager oracleManager = IOracleManager(config.oracleManager);
        if (!oracleManager.isSupportedAsset(config.optimizer)) {
            revert VerifyOptimizerShareLaunch__InvalidConfig();
        }

        address[] memory pricingAdaptors =
            oracleManager.getPricingAdaptors(config.optimizer);
        bool routeFound;
        uint256 numAdaptors = pricingAdaptors.length;
        for (uint256 i; i < numAdaptors; ++i) {
            if (pricingAdaptors[i] == config.oracleAdaptor) {
                routeFound = true;
                break;
            }
        }

        if (!routeFound) {
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

        if (
            address(
                        VaultAggregator(config.vaultAggregator)
                            .underlyingAggregator()
                    ) != config.expectedUnderlyingAggregator
                || VaultAggregator(config.vaultAggregator).getDataFeedId()
                    != config.expectedDataFeedId
                || VaultAggregator(config.vaultAggregator).decimals()
                    != config.expectedFeedDecimals
        ) {
            revert VerifyOptimizerShareLaunch__InvalidConfig();
        }

        (uint80 roundId, int256 answer,, uint256 updatedAt,) =
            VaultAggregator(config.vaultAggregator).latestRoundData();
        if (roundId == 0 || answer <= 0 || updatedAt == 0) {
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

        _requireAdaptorPricePath(config.oracleAdaptor, config.optimizer);
    }

    function _requireBoundRegistries(Config memory config) internal view {
        ICentralRegistry optimizerRegistry =
            ILendingOptimizer(config.optimizer).centralRegistry();
        if (optimizerRegistry.oracleManager() != config.oracleManager) {
            revert VerifyOptimizerShareLaunch__InvalidConfig();
        }

        if (
            ICentralRegistryBound(config.shareCToken).centralRegistry()
                != optimizerRegistry
        ) {
            revert VerifyOptimizerShareLaunch__InvalidConfig();
        }

        if (
            ICentralRegistryBound(config.marketManager).centralRegistry()
                != optimizerRegistry
        ) {
            revert VerifyOptimizerShareLaunch__InvalidConfig();
        }
    }

    function _requireShareDebtSurfacesDisabled(address shareCToken)
        internal
        view
    {
        _requireShareDebtSurfaceDisabled(
            shareCToken,
            abi.encodeWithSignature(
                "borrow(uint256,address)",
                _DEBT_SURFACE_PROBE_ASSETS,
                address(this)
            )
        );
        _requireShareDebtSurfaceDisabled(
            shareCToken,
            abi.encodeWithSignature(
                "borrowFor(uint256,address,address)",
                _DEBT_SURFACE_PROBE_ASSETS,
                address(this),
                address(this)
            )
        );
        IPositionManager.LeverageAction memory emptyAction;
        _requireShareDebtSurfaceDisabled(
            shareCToken,
            abi.encodeWithSelector(
                LendingOptimizerShareCToken.borrowForPositionManager.selector,
                _DEBT_SURFACE_PROBE_ASSETS,
                address(this),
                emptyAction
            )
        );
        _requireShareDebtSurfaceDisabled(
            shareCToken,
            abi.encodeWithSignature(
                "flashLoan(uint256,bytes)", _DEBT_SURFACE_PROBE_ASSETS, ""
            )
        );
    }

    function _requireShareDebtSurfaceDisabled(
        address shareCToken,
        bytes memory callData
    ) internal view {
        (bool success, bytes memory returnData) =
            shareCToken.staticcall(callData);
        if (success || returnData.length < 4) {
            revert VerifyOptimizerShareLaunch__InvalidConfig();
        }

        bytes4 selector;
        /// @solidity memory-safe-assembly
        assembly {
            selector := mload(add(returnData, 32))
        }

        if (
            selector
                != LendingOptimizerShareCToken.LendingOptimizerShareCToken__BorrowDisabled
                    .selector
        ) {
            revert VerifyOptimizerShareLaunch__InvalidConfig();
        }
    }

    function _requireAdaptorPricePath(address adaptor, address asset)
        internal
        view
    {
        (bool success, bytes memory returnData) = adaptor.staticcall(
            abi.encodeCall(IOracleAdaptor.isSupportedAsset, (asset))
        );
        if (
            !success || returnData.length < 32
                || !abi.decode(returnData, (bool))
        ) {
            revert VerifyOptimizerShareLaunch__InvalidConfig();
        }

        _requireAdaptorPrice(adaptor, asset, true);
        _requireAdaptorPrice(adaptor, asset, false);
    }

    function _requireAdaptorPrice(
        address adaptor,
        address asset,
        bool getLower
    ) internal view {
        (bool success, bytes memory returnData) = adaptor.staticcall(
            abi.encodeCall(IOracleAdaptor.getPrice, (asset, true, getLower))
        );
        if (!success || returnData.length < 96) {
            revert VerifyOptimizerShareLaunch__InvalidConfig();
        }

        IOracleAdaptor.PricingResult memory result =
            abi.decode(returnData, (IOracleAdaptor.PricingResult));
        if (result.price == 0 || result.hadError || !result.inUSD) {
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
