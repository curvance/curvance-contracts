// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {ICToken} from "contracts/interfaces/ICToken.sol";
import {ILendingOptimizer} from "contracts/interfaces/ILendingOptimizer.sol";
import {IOracleManager} from "contracts/interfaces/IOracleManager.sol";
import {Script} from "forge-std/Script.sol";

interface IOptimizerShareDeScopeVaultAggregator {
    function vault() external view returns (address);

    function asset() external view returns (address);
}

interface IOptimizerShareDeScopeCentralRegistry {
    function feeManager() external view returns (address);

    function feeToken() external view returns (address);

    function oracleManager() external view returns (address);
}

interface IOptimizerShareDeScopeFeeManager {
    function rewardTokenInfo(address token)
        external
        view
        returns (uint256 isRewardToken, uint256 forOTC);
}

interface IOptimizerShareDeScopeLBP {
    function paymentToken() external view returns (address);
}

interface IOptimizerShareDeScopeLPAdaptor {
    function assetConfig(address asset)
        external
        view
        returns (
            address token0,
            uint8 decimals0,
            address token1,
            uint8 decimals1
        );
}

interface IOptimizerShareDeScopeUniswapAdaptor {
    function assetConfig(address asset)
        external
        view
        returns (
            address priceSource,
            uint32 secondsAgo,
            uint8 baseDecimals,
            uint8 quoteDecimals,
            address quoteToken
        );
}

interface IOptimizerShareDeScopePendleAdaptor {
    function assetConfig(address asset)
        external
        view
        returns (
            address market,
            uint32 twapDuration,
            address quoteAsset,
            uint8 quoteAssetDecimals
        );
}

contract VerifyOptimizerShareDeScope is Script {
    error VerifyOptimizerShareDeScope__InvalidConfig();

    struct Config {
        address optimizer;
        address centralRegistry;
        address oracleManager;
        uint256 expectedAllowedPricingAdaptorCount;
        address[] allowedPricingAdaptors;
        uint256 expectedMarketCTokenCount;
        address[] marketCTokens;
        uint256 expectedVaultAggregatorCount;
        address[] vaultAggregators;
        uint256 expectedLBPCount;
        address[] lbps;
        uint256 expectedLPRouteCount;
        address[] lpRouteAdaptors;
        address[] lpRouteAssets;
        uint256 expectedUniswapRouteCount;
        address[] uniswapRouteAdaptors;
        address[] uniswapRouteAssets;
        uint256 expectedPendleRouteCount;
        address[] pendleRouteAdaptors;
        address[] pendleRouteAssets;
    }

    function run() external view {
        address[] memory emptyVaultAggregators;
        address[] memory emptyLBPs;
        address[] memory emptyAllowedPricingAdaptors;
        address[] memory emptyRouteAdaptors;
        address[] memory emptyRouteAssets;
        Config memory config = Config({
            optimizer: _envAddress(
                "OPTIMIZER_DESCOPE_ADDRESS", "OPTIMIZER_ADDRESS"
            ),
            centralRegistry: _envAddressOr(
                "OPTIMIZER_DESCOPE_CENTRAL_REGISTRY",
                "OPTIMIZER_CENTRAL_REGISTRY",
                address(0)
            ),
            oracleManager: _envAddress(
                "OPTIMIZER_DESCOPE_ORACLE_MANAGER", "OPTIMIZER_ORACLE_MANAGER"
            ),
            expectedAllowedPricingAdaptorCount: _envUintOr(
                "OPTIMIZER_DESCOPE_ALLOWED_PRICING_ADAPTOR_COUNT",
                "OPTIMIZER_ALLOWED_PRICING_ADAPTOR_COUNT",
                0
            ),
            allowedPricingAdaptors: _envAddressListOr(
                "OPTIMIZER_DESCOPE_ALLOWED_PRICING_ADAPTORS",
                "OPTIMIZER_ALLOWED_PRICING_ADAPTORS",
                emptyAllowedPricingAdaptors
            ),
            expectedMarketCTokenCount: _envUint(
                "OPTIMIZER_DESCOPE_MARKET_CTOKEN_COUNT",
                "OPTIMIZER_MARKET_CTOKEN_COUNT"
            ),
            marketCTokens: _envAddressList(
                "OPTIMIZER_DESCOPE_MARKET_CTOKENS", "OPTIMIZER_MARKET_CTOKENS"
            ),
            expectedVaultAggregatorCount: _envUint(
                "OPTIMIZER_DESCOPE_VAULT_AGGREGATOR_COUNT",
                "OPTIMIZER_VAULT_AGGREGATOR_COUNT"
            ),
            vaultAggregators: _envAddressListOr(
                "OPTIMIZER_DESCOPE_VAULT_AGGREGATORS",
                "OPTIMIZER_VAULT_AGGREGATORS",
                emptyVaultAggregators
            ),
            expectedLBPCount: _envUintOr(
                "OPTIMIZER_DESCOPE_LBP_COUNT", "OPTIMIZER_LBP_COUNT", 0
            ),
            lbps: _envAddressListOr(
                "OPTIMIZER_DESCOPE_LBPS", "OPTIMIZER_LBPS", emptyLBPs
            ),
            expectedLPRouteCount: _envUintOr(
                "OPTIMIZER_DESCOPE_LP_ROUTE_COUNT",
                "OPTIMIZER_LP_ROUTE_COUNT",
                0
            ),
            lpRouteAdaptors: _envAddressListOr(
                "OPTIMIZER_DESCOPE_LP_ROUTE_ADAPTORS",
                "OPTIMIZER_LP_ROUTE_ADAPTORS",
                emptyRouteAdaptors
            ),
            lpRouteAssets: _envAddressListOr(
                "OPTIMIZER_DESCOPE_LP_ROUTE_ASSETS",
                "OPTIMIZER_LP_ROUTE_ASSETS",
                emptyRouteAssets
            ),
            expectedUniswapRouteCount: _envUintOr(
                "OPTIMIZER_DESCOPE_UNISWAP_ROUTE_COUNT",
                "OPTIMIZER_UNISWAP_ROUTE_COUNT",
                0
            ),
            uniswapRouteAdaptors: _envAddressListOr(
                "OPTIMIZER_DESCOPE_UNISWAP_ROUTE_ADAPTORS",
                "OPTIMIZER_UNISWAP_ROUTE_ADAPTORS",
                emptyRouteAdaptors
            ),
            uniswapRouteAssets: _envAddressListOr(
                "OPTIMIZER_DESCOPE_UNISWAP_ROUTE_ASSETS",
                "OPTIMIZER_UNISWAP_ROUTE_ASSETS",
                emptyRouteAssets
            ),
            expectedPendleRouteCount: _envUintOr(
                "OPTIMIZER_DESCOPE_PENDLE_ROUTE_COUNT",
                "OPTIMIZER_PENDLE_ROUTE_COUNT",
                0
            ),
            pendleRouteAdaptors: _envAddressListOr(
                "OPTIMIZER_DESCOPE_PENDLE_ROUTE_ADAPTORS",
                "OPTIMIZER_PENDLE_ROUTE_ADAPTORS",
                emptyRouteAdaptors
            ),
            pendleRouteAssets: _envAddressListOr(
                "OPTIMIZER_DESCOPE_PENDLE_ROUTE_ASSETS",
                "OPTIMIZER_PENDLE_ROUTE_ASSETS",
                emptyRouteAssets
            )
        });

        _verify(config);
    }

    function verify(Config calldata config) external view {
        _verify(config);
    }

    function _verify(Config memory config) internal view {
        _requireContract(config.optimizer);
        _requireContract(config.oracleManager);

        uint256 numCTokens = config.marketCTokens.length;
        if (numCTokens == 0 || numCTokens != config.expectedMarketCTokenCount)
        {
            revert VerifyOptimizerShareDeScope__InvalidConfig();
        }

        IOracleManager oracleManager = IOracleManager(config.oracleManager);
        _verifyAllowedPricingAdaptorList(
            config.expectedAllowedPricingAdaptorCount,
            config.allowedPricingAdaptors
        );

        for (uint256 i; i < numCTokens; ++i) {
            address cToken = config.marketCTokens[i];
            _requireContract(cToken);

            for (uint256 j; j < i; ++j) {
                if (config.marketCTokens[j] == cToken) {
                    revert VerifyOptimizerShareDeScope__InvalidConfig();
                }
            }

            address cTokenAsset = ICToken(cToken).asset();
            address oracleAsset = oracleManager.cTokens(cToken);
            if (
                cTokenAsset == address(0) || cTokenAsset == config.optimizer
                    || oracleAsset == config.optimizer
                    || oracleAsset != cTokenAsset
            ) {
                revert VerifyOptimizerShareDeScope__InvalidConfig();
            }

            _verifyAssetPricingAdaptors(
                oracleManager, cTokenAsset, config.allowedPricingAdaptors
            );
        }

        uint256 numVaultAggregators = config.vaultAggregators.length;
        if (numVaultAggregators != config.expectedVaultAggregatorCount) {
            revert VerifyOptimizerShareDeScope__InvalidConfig();
        }

        for (uint256 i; i < numVaultAggregators; ++i) {
            address vaultAggregator = config.vaultAggregators[i];
            _requireContract(vaultAggregator);

            for (uint256 j; j < i; ++j) {
                if (config.vaultAggregators[j] == vaultAggregator) {
                    revert VerifyOptimizerShareDeScope__InvalidConfig();
                }
            }

            address vault =
                IOptimizerShareDeScopeVaultAggregator(vaultAggregator).vault();
            address asset =
                IOptimizerShareDeScopeVaultAggregator(vaultAggregator).asset();
            if (
                vault == address(0) || vault == config.optimizer
                    || asset == address(0) || asset == config.optimizer
            ) {
                revert VerifyOptimizerShareDeScope__InvalidConfig();
            }
        }

        uint256 numLBPs = config.lbps.length;
        if (numLBPs != config.expectedLBPCount) {
            revert VerifyOptimizerShareDeScope__InvalidConfig();
        }

        for (uint256 i; i < numLBPs; ++i) {
            address lbp = config.lbps[i];
            _requireContract(lbp);

            for (uint256 j; j < i; ++j) {
                if (config.lbps[j] == lbp) {
                    revert VerifyOptimizerShareDeScope__InvalidConfig();
                }
            }

            if (
                IOptimizerShareDeScopeLBP(lbp).paymentToken()
                    == config.optimizer
            ) {
                revert VerifyOptimizerShareDeScope__InvalidConfig();
            }
        }

        _verifyLPRouteConfigs(
            config.optimizer,
            config.expectedLPRouteCount,
            config.lpRouteAdaptors,
            config.lpRouteAssets
        );
        _verifyUniswapRouteConfigs(
            config.optimizer,
            config.expectedUniswapRouteCount,
            config.uniswapRouteAdaptors,
            config.uniswapRouteAssets
        );
        _verifyPendleRouteConfigs(
            config.optimizer,
            config.expectedPendleRouteCount,
            config.pendleRouteAdaptors,
            config.pendleRouteAssets
        );

        if (
            oracleManager.cTokens(config.optimizer) != address(0)
                || oracleManager.isSupportedAsset(config.optimizer)
        ) {
            revert VerifyOptimizerShareDeScope__InvalidConfig();
        }

        if (config.centralRegistry != address(0)) {
            _requireContract(config.centralRegistry);

            if (
                address(ILendingOptimizer(config.optimizer).centralRegistry())
                    != config.centralRegistry
            ) {
                revert VerifyOptimizerShareDeScope__InvalidConfig();
            }

            IOptimizerShareDeScopeCentralRegistry centralRegistry =
                IOptimizerShareDeScopeCentralRegistry(config.centralRegistry);
            if (centralRegistry.oracleManager() != config.oracleManager) {
                revert VerifyOptimizerShareDeScope__InvalidConfig();
            }

            if (centralRegistry.feeToken() == config.optimizer) {
                revert VerifyOptimizerShareDeScope__InvalidConfig();
            }

            address feeManager = centralRegistry.feeManager();
            if (feeManager != address(0)) {
                _requireContract(feeManager);

                (uint256 isRewardToken, uint256 forOTC) = IOptimizerShareDeScopeFeeManager(
                        feeManager
                    ).rewardTokenInfo(config.optimizer);
                if (isRewardToken == 2 || forOTC == 2) {
                    revert VerifyOptimizerShareDeScope__InvalidConfig();
                }
            }
        }
    }

    function _verifyLPRouteConfigs(
        address optimizer,
        uint256 expectedCount,
        address[] memory adaptors,
        address[] memory assets
    ) internal view {
        uint256 numRoutes = _requireRouteArrays(
            expectedCount, adaptors, assets
        );
        for (uint256 i; i < numRoutes; ++i) {
            _requireUniqueRoute(adaptors, assets, i);

            (address token0,, address token1,) = IOptimizerShareDeScopeLPAdaptor(
                    adaptors[i]
                ).assetConfig(assets[i]);
            if (
                assets[i] == optimizer || token0 == address(0)
                    || token1 == address(0) || token0 == optimizer
                    || token1 == optimizer
            ) {
                revert VerifyOptimizerShareDeScope__InvalidConfig();
            }
        }
    }

    function _verifyAllowedPricingAdaptorList(
        uint256 expectedCount,
        address[] memory allowedAdaptors
    ) internal view {
        if (allowedAdaptors.length != expectedCount) {
            revert VerifyOptimizerShareDeScope__InvalidConfig();
        }

        for (uint256 i; i < expectedCount; ++i) {
            _requireContract(allowedAdaptors[i]);
            for (uint256 j; j < i; ++j) {
                if (allowedAdaptors[j] == allowedAdaptors[i]) {
                    revert VerifyOptimizerShareDeScope__InvalidConfig();
                }
            }
        }
    }

    function _verifyAssetPricingAdaptors(
        IOracleManager oracleManager,
        address asset,
        address[] memory allowedAdaptors
    ) internal view {
        if (allowedAdaptors.length == 0) {
            return;
        }

        address[] memory adaptors = oracleManager.getPricingAdaptors(asset);
        uint256 numAdaptors = adaptors.length;
        if (numAdaptors == 0) {
            revert VerifyOptimizerShareDeScope__InvalidConfig();
        }

        for (uint256 i; i < numAdaptors; ++i) {
            bool isAllowed;
            for (uint256 j; j < allowedAdaptors.length; ++j) {
                if (adaptors[i] == allowedAdaptors[j]) {
                    isAllowed = true;
                    break;
                }
            }

            if (!isAllowed) {
                revert VerifyOptimizerShareDeScope__InvalidConfig();
            }
        }
    }

    function _verifyUniswapRouteConfigs(
        address optimizer,
        uint256 expectedCount,
        address[] memory adaptors,
        address[] memory assets
    ) internal view {
        uint256 numRoutes = _requireRouteArrays(
            expectedCount, adaptors, assets
        );
        for (uint256 i; i < numRoutes; ++i) {
            _requireUniqueRoute(adaptors, assets, i);

            (,,,, address quoteToken) = IOptimizerShareDeScopeUniswapAdaptor(
                    adaptors[i]
                ).assetConfig(assets[i]);
            if (
                assets[i] == optimizer || quoteToken == address(0)
                    || quoteToken == optimizer
            ) {
                revert VerifyOptimizerShareDeScope__InvalidConfig();
            }
        }
    }

    function _verifyPendleRouteConfigs(
        address optimizer,
        uint256 expectedCount,
        address[] memory adaptors,
        address[] memory assets
    ) internal view {
        uint256 numRoutes = _requireRouteArrays(
            expectedCount, adaptors, assets
        );
        for (uint256 i; i < numRoutes; ++i) {
            _requireUniqueRoute(adaptors, assets, i);

            (,, address quoteAsset,) = IOptimizerShareDeScopePendleAdaptor(
                    adaptors[i]
                ).assetConfig(assets[i]);
            if (
                assets[i] == optimizer || quoteAsset == address(0)
                    || quoteAsset == optimizer
            ) {
                revert VerifyOptimizerShareDeScope__InvalidConfig();
            }
        }
    }

    function _requireRouteArrays(
        uint256 expectedCount,
        address[] memory adaptors,
        address[] memory assets
    ) internal view returns (uint256 numRoutes) {
        numRoutes = assets.length;
        if (numRoutes != expectedCount || adaptors.length != expectedCount) {
            revert VerifyOptimizerShareDeScope__InvalidConfig();
        }

        for (uint256 i; i < numRoutes; ++i) {
            _requireContract(adaptors[i]);
            _requireContract(assets[i]);
        }
    }

    function _requireUniqueRoute(
        address[] memory adaptors,
        address[] memory assets,
        uint256 index
    ) internal pure {
        for (uint256 j; j < index; ++j) {
            if (adaptors[j] == adaptors[index] && assets[j] == assets[index]) {
                revert VerifyOptimizerShareDeScope__InvalidConfig();
            }
        }
    }

    function _requireContract(address target) internal view {
        if (target == address(0) || target.code.length == 0) {
            revert VerifyOptimizerShareDeScope__InvalidConfig();
        }
    }

    function _envAddress(string memory key, string memory fallbackKey)
        internal
        view
        returns (address)
    {
        if (vm.envExists(key)) {
            return vm.envAddress(key);
        }

        return vm.envAddress(fallbackKey);
    }

    function _envAddressOr(
        string memory key,
        string memory fallbackKey,
        address defaultValue
    ) internal view returns (address) {
        if (vm.envExists(key)) {
            return vm.envAddress(key);
        }

        return vm.envOr(fallbackKey, defaultValue);
    }

    function _envAddressList(string memory key, string memory fallbackKey)
        internal
        view
        returns (address[] memory)
    {
        if (vm.envExists(key)) {
            return vm.envAddress(key, ",");
        }

        return vm.envAddress(fallbackKey, ",");
    }

    function _envAddressListOr(
        string memory key,
        string memory fallbackKey,
        address[] memory defaultValue
    ) internal view returns (address[] memory) {
        if (vm.envExists(key)) {
            return vm.envOr(key, ",", defaultValue);
        }

        return vm.envOr(fallbackKey, ",", defaultValue);
    }

    function _envUint(string memory key, string memory fallbackKey)
        internal
        view
        returns (uint256)
    {
        if (vm.envExists(key)) {
            return vm.envUint(key);
        }

        return vm.envUint(fallbackKey);
    }

    function _envUintOr(
        string memory key,
        string memory fallbackKey,
        uint256 defaultValue
    ) internal view returns (uint256) {
        if (vm.envExists(key)) {
            return vm.envUint(key);
        }

        return vm.envOr(fallbackKey, defaultValue);
    }
}
