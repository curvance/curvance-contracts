// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { DeployScript } from "../utils/DeployScript.sol";
import { AddPlugins } from "./AddPlugins.s.sol";

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";
import { SimpleCToken } from "contracts/market/token/SimpleCToken.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { DynamicIRM } from "contracts/market/DynamicIRM.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICToken } from "contracts/interfaces/ICToken.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";
import { BPS, WAD, SECONDS_PER_YEAR } from "contracts/libraries/ConstantsLib.sol";

contract DeployMarkets is DeployScript {
    struct DynamicInterestRateConfig {
        uint256 baseRatePerYear;
        uint256 vertexRatePerYear;
        uint256 vertexStart;
        uint256 adjustmentVelocity;
        uint256 decayPerAdjustment;
        uint256 vertexMultiplierMax;
    }

    AddPlugins internal plugin_deployer;

    constructor() {
        plugin_deployer = new AddPlugins();
    }

    struct ListConfig {
        address asset;
        bool canBorrow;
        MarketManagerIsolated.TokenConfig tokenConfig;
        DynamicInterestRateConfig interestConfig;
    }

    function run(
        address centralRegistry,
        string[] memory names,
        ListConfig[][] memory tokens,
        bool[] memory isCorrelatedMarkets,
        address wrappedNative,
        AddPlugins.AvailablePlugins[] memory plugins
    ) external recordEvents {
        CentralRegistry registry = CentralRegistry(centralRegistry);
        ICentralRegistry icr = ICentralRegistry(centralRegistry);
        OracleManager router = OracleManager(registry.oracleManager());

        for (uint256 i = 0; i < names.length; i++) {
            string memory name = string.concat("markets.", names[i]);
            ListConfig[] memory marketTokens = tokens[i];

            MarketManagerIsolated market = new MarketManagerIsolated(icr, 10e18, isCorrelatedMarkets[i]);

            // Verify MarketManager deployment state
            _verifyMarketManagerDeployment(market, icr, isCorrelatedMarkets[i]);

            registry.addMarketManager(address(market));

            // Verify market was added to registry
            require(
                registry.isMarketManager(address(market)),
                "DeployMarkets: Market not registered in CentralRegistry"
            );

            emit ContractDeployed(
                address(market),
                string.concat(name, ".address")
            );

            plugin_deployer.deployPlugins(icr, market, wrappedNative, name, plugins[i]);

            address[] memory cTokens = deployCTokens(
                marketTokens,
                router,
                name,
                market,
                icr
            );

            market.listTokens(cTokens[0], cTokens[1]);

            // Verify tokens are listed
            require(
                market.isListed(cTokens[0]),
                "DeployMarkets: cToken0 not listed"
            );
            require(
                market.isListed(cTokens[1]),
                "DeployMarkets: cToken1 not listed"
            );

            // Verify tokensListed array
            address[] memory listedTokens = market.queryTokensListed();
            require(
                listedTokens.length == 2,
                "DeployMarkets: tokensListed length mismatch"
            );
            require(
                listedTokens[0] == cTokens[0] && listedTokens[1] == cTokens[1],
                "DeployMarkets: tokensListed addresses mismatch"
            );

            market.setMintPaused(cTokens[0], true);
            market.setMintPaused(cTokens[1], true);

            // Verify minting is paused
            (bool mint0Paused,,) = market.actionsPaused(cTokens[0]);
            (bool mint1Paused,,) = market.actionsPaused(cTokens[1]);
            require(mint0Paused, "DeployMarkets: cToken0 mint not paused");
            require(mint1Paused, "DeployMarkets: cToken1 mint not paused");

            market.updateTokenConfig(marketTokens[0].tokenConfig);
            market.updateTokenConfig(marketTokens[1].tokenConfig);

            // Verify token configs
            _verifyTokenConfig(market, marketTokens[0].tokenConfig);
            _verifyTokenConfig(market, marketTokens[1].tokenConfig);
        }
    }

    /// @notice Verifies MarketManagerIsolated deployment state
    function _verifyMarketManagerDeployment(
        MarketManagerIsolated market,
        ICentralRegistry expectedRegistry,
        bool expectedCorrelated
    ) internal view {
        // Verify centralRegistry
        require(
            address(market.centralRegistry()) == address(expectedRegistry),
            "DeployMarkets: MarketManager centralRegistry mismatch"
        );

        // Verify minLoanSize (10e18)
        require(
            market.MIN_LOAN_SIZE() == 10e18,
            "DeployMarkets: MarketManager minLoanSize mismatch"
        );

        // Verify isCorrelatedMarket by checking MAX_COLL_RATIO
        // Correlated markets have MAX_COLL_RATIO of 9750, non-correlated have 9696
        uint256 expectedMaxCollRatio = expectedCorrelated ? 9750 : 9696;
        require(
            market.MAX_COLL_RATIO() == expectedMaxCollRatio,
            "DeployMarkets: MarketManager isCorrelatedMarket mismatch"
        );

        // Verify initial pause states (all should be unpaused = 1)
        require(
            market.liquidationPaused() == 1,
            "DeployMarkets: MarketManager liquidationPaused should be 1"
        );
        require(
            market.redeemPaused() == 1,
            "DeployMarkets: MarketManager redeemPaused should be 1"
        );
        require(
            market.transferPaused() == 1,
            "DeployMarkets: MarketManager transferPaused should be 1"
        );
    }

    /// @notice Verifies token configuration was applied correctly
    function _verifyTokenConfig(
        MarketManagerIsolated market,
        MarketManagerIsolated.TokenConfig memory config
    ) internal view {
        // Get collateral config
        (uint256 collRatio, uint256 collReqSoft, uint256 collReqHard) = market.collConfig(config.cToken);

        require(
            collRatio == config.collRatio,
            "DeployMarkets: collRatio mismatch"
        );
        // collReqSoft and collReqHard are stored as premium above BPS
        require(
            collReqSoft == config.collReqSoft + BPS,
            "DeployMarkets: collReqSoft mismatch"
        );
        require(
            collReqHard == config.collReqHard + BPS,
            "DeployMarkets: collReqHard mismatch"
        );

        // Get liquidation config
        (
            uint256 liqIncBase,
            uint256 liqIncCurve,
            uint256 liqIncMin,
            uint256 liqIncMax,
            uint256 closeFactorBase,
            uint256 closeFactorCurve,
            uint256 closeFactorMin,
            uint256 closeFactorMax
        ) = market.liquidationConfig(config.cToken);

        // liqInc values are stored as BPS + incentive
        require(
            liqIncBase == BPS + config.liqIncBase,
            "DeployMarkets: liqIncBase mismatch"
        );
        require(
            liqIncCurve == config.liqIncHard - config.liqIncBase,
            "DeployMarkets: liqIncCurve mismatch"
        );
        require(
            liqIncMin == BPS + config.liqIncMin,
            "DeployMarkets: liqIncMin mismatch"
        );
        require(
            liqIncMax == BPS + config.liqIncMax,
            "DeployMarkets: liqIncMax mismatch"
        );

        require(
            closeFactorBase == config.closeFactorBase,
            "DeployMarkets: closeFactorBase mismatch"
        );
        require(
            closeFactorCurve == BPS - config.closeFactorBase,
            "DeployMarkets: closeFactorCurve mismatch"
        );
        require(
            closeFactorMin == config.closeFactorMin,
            "DeployMarkets: closeFactorMin mismatch"
        );
        require(
            closeFactorMax == config.closeFactorMax,
            "DeployMarkets: closeFactorMax mismatch"
        );

        // Verify caps
        require(
            market.collateralCaps(config.cToken) == config.collateralCap,
            "DeployMarkets: collateralCap mismatch"
        );
        require(
            market.debtCaps(config.cToken) == config.debtCap,
            "DeployMarkets: debtCap mismatch"
        );
    }

    function deployCTokens(
        ListConfig[] memory tokens,
        OracleManager router,
        string memory marketName,
        MarketManagerIsolated market,
        ICentralRegistry icr
    ) public useDeployer returns (address[] memory cTokens) {
        cTokens = new address[](tokens.length);

        for (uint256 i = 0; i < tokens.length; i++) {
            ListConfig memory listConfig = tokens[i];

            if (listConfig.canBorrow) {
                cTokens[i] = deployBorrowableCToken(
                    listConfig,
                    marketName,
                    market,
                    icr
                );
            } else {
                cTokens[i] = deploySimpleCToken(
                    listConfig,
                    marketName,
                    market,
                    icr
                );
            }

            listConfig.tokenConfig.cToken = cTokens[i];
            router.addCTokenSupport(cTokens[i]);

            // Verify cToken was registered in OracleManager
            require(
                router.cTokens(cTokens[i]) == listConfig.asset,
                "DeployMarkets: cToken not registered in OracleManager"
            );
        }
    }

    function deploySimpleCToken(
        ListConfig memory config,
        string memory marketName,
        MarketManagerIsolated market,
        ICentralRegistry icr
    ) public useDeployer returns (address) {
        IERC20 asset = IERC20(config.asset);

        SimpleCToken cToken = new SimpleCToken(icr, asset, address(market));

        // Verify SimpleCToken deployment state
        _verifyBaseCTokenDeployment(cToken, icr, config.asset, address(market));

        // Verify SimpleCToken is not borrowable
        require(
            !cToken.isBorrowable(),
            "DeployMarkets: SimpleCToken should not be borrowable"
        );

        emit ContractDeployed(
            address(cToken),
            string.concat(marketName, ".tokens.", asset.symbol())
        );

        asset.approve(address(cToken), 1 * 10 ** asset.decimals());

        return address(cToken);
    }

    /// @notice Verifies base cToken deployment state (common to SimpleCToken and BorrowableCToken)
    function _verifyBaseCTokenDeployment(
        BaseCToken cToken,
        ICentralRegistry expectedRegistry,
        address expectedAsset,
        address expectedMarketManager
    ) internal view {
        // Verify centralRegistry
        require(
            address(cToken.centralRegistry()) == address(expectedRegistry),
            "DeployMarkets: cToken centralRegistry mismatch"
        );

        // Verify underlying asset
        require(
            cToken.asset() == expectedAsset,
            "DeployMarkets: cToken asset mismatch"
        );

        // Verify marketManager
        require(
            address(cToken.marketManager()) == expectedMarketManager,
            "DeployMarkets: cToken marketManager mismatch"
        );

        // Verify decimals match underlying
        require(
            cToken.decimals() == IERC20(expectedAsset).decimals(),
            "DeployMarkets: cToken decimals mismatch"
        );

        // Verify initial totalSupply is 0 (before listing)
        require(
            cToken.totalSupply() == 0,
            "DeployMarkets: cToken totalSupply should be 0 before listing"
        );
    }

    function deployBorrowableCToken(
        ListConfig memory config,
        string memory marketName,
        MarketManagerIsolated market,
        ICentralRegistry icr
    ) public useDeployer returns (address) {
        IERC20 asset = IERC20(config.asset);

        DynamicIRM IRM = new DynamicIRM(
                icr,
                config.interestConfig.baseRatePerYear,
                config.interestConfig.vertexRatePerYear,
                config.interestConfig.vertexStart,
                config.interestConfig.adjustmentVelocity,
                config.interestConfig.decayPerAdjustment,
                config.interestConfig.vertexMultiplierMax
            );

        // Verify DynamicIRM deployment state (before linking)
        _verifyDynamicIRMDeployment(IRM, icr, config.interestConfig);

        emit ContractDeployed(
            address(IRM),
            string.concat(
                marketName,
                ".",
                asset.symbol(),
                "-DynamicIRM"
            )
        );

        BorrowableCToken cToken = new BorrowableCToken(
                icr,
                asset,
                address(market),
                address(IRM)
            );

        // Verify BorrowableCToken deployment state
        _verifyBaseCTokenDeployment(cToken, icr, config.asset, address(market));
        _verifyBorrowableCTokenDeployment(cToken, IRM);

        emit ContractDeployed(
            address(cToken),
            string.concat(marketName, ".tokens.", asset.symbol())
        );

        IRM.setLinkedToken(address(cToken));

        // Verify IRM was linked correctly
        require(
            IRM.linkedToken() == address(cToken),
            "DeployMarkets: DynamicIRM linkedToken mismatch"
        );

        asset.approve(address(cToken), 1 * 10 ** asset.decimals());

        return address(cToken);
    }

    /// @notice Verifies DynamicIRM deployment state
    /// @dev This is complex because the DynamicIRM stores computed values, not input values directly
    function _verifyDynamicIRMDeployment(
        DynamicIRM IRM,
        ICentralRegistry expectedRegistry,
        DynamicInterestRateConfig memory config
    ) internal view {
        // Verify centralRegistry
        require(
            address(IRM.centralRegistry()) == address(expectedRegistry),
            "DeployMarkets: DynamicIRM centralRegistry mismatch"
        );

        // Verify adjustment rate (constant)
        require(
            IRM.ADJUSTMENT_RATE() == 10 minutes,
            "DeployMarkets: DynamicIRM ADJUSTMENT_RATE mismatch"
        );

        // Verify initial vertexMultiplier is WAD (1e18)
        require(
            IRM.vertexMultiplier() == WAD,
            "DeployMarkets: DynamicIRM initial vertexMultiplier should be WAD"
        );

        // Verify linkedToken is not set yet (address(0))
        require(
            IRM.linkedToken() == address(0),
            "DeployMarkets: DynamicIRM linkedToken should be 0 before linking"
        );

        // Get ratesConfig and verify computed values
        (
            uint64 baseRatePerSecond,
            uint64 vertexRatePerSecond,
            uint64 vertexStart,
            uint24 increaseThresholdStart,
            uint24 decreaseThresholdEnd,
            uint16 adjustmentVelocity,
            uint16 decayPerAdjustment,
            uint80 vertexMultiplierMax,
            address linkedToken
        ) = IRM.ratesConfig();

        // linkedToken should be 0 before linking
        require(
            linkedToken == address(0),
            "DeployMarkets: ratesConfig linkedToken should be 0 before linking"
        );

        // Verify adjustmentVelocity matches input
        require(
            adjustmentVelocity == config.adjustmentVelocity,
            "DeployMarkets: DynamicIRM adjustmentVelocity mismatch"
        );

        // Verify decayPerAdjustment matches input
        require(
            decayPerAdjustment == config.decayPerAdjustment,
            "DeployMarkets: DynamicIRM decayPerAdjustment mismatch"
        );

        // vertexStart is converted from BPS to WAD (input * 1e14)
        uint256 expectedVertexStartWad = config.vertexStart * 1e14;
        require(
            vertexStart == expectedVertexStartWad,
            "DeployMarkets: DynamicIRM vertexStart mismatch"
        );

        // vertexMultiplierMax is converted from BPS to WAD (input * 1e14)
        uint256 expectedVertexMultiplierMaxWad = config.vertexMultiplierMax * 1e14;
        require(
            vertexMultiplierMax == expectedVertexMultiplierMaxWad,
            "DeployMarkets: DynamicIRM vertexMultiplierMax mismatch"
        );

        // Verify computed baseRatePerSecond
        // baseRatePerSecond = (baseRatePerYear * WAD) / (SECONDS_PER_YEAR * vertexStart)
        // where baseRatePerYear is converted to WAD first (input * 1e14)
        uint256 baseRatePerYearWad = config.baseRatePerYear * 1e14;
        uint256 expectedBaseRatePerSecond = (baseRatePerYearWad * WAD) / (SECONDS_PER_YEAR * expectedVertexStartWad);
        require(
            baseRatePerSecond == expectedBaseRatePerSecond,
            "DeployMarkets: DynamicIRM baseRatePerSecond mismatch"
        );

        // Verify computed vertexRatePerSecond
        // vertexRatePerSecond = (vertexRatePerYear * WAD) / (SECONDS_PER_YEAR * (WAD - vertexStart))
        uint256 vertexRatePerYearWad = config.vertexRatePerYear * 1e14;
        uint256 expectedVertexRatePerSecond = (vertexRatePerYearWad * WAD) / (SECONDS_PER_YEAR * (WAD - expectedVertexStartWad));
        require(
            vertexRatePerSecond == expectedVertexRatePerSecond,
            "DeployMarkets: DynamicIRM vertexRatePerSecond mismatch"
        );

        // Verify computed thresholds
        // thresholdLength = (WAD - vertexStart) / 2
        // increaseThresholdStart = (vertexStart + thresholdLength) / 1e13
        // decreaseThresholdEnd = (vertexStart - thresholdLength) / 1e13
        uint256 thresholdLength = (WAD - expectedVertexStartWad) / 2;
        uint256 expectedIncreaseThresholdStart = (expectedVertexStartWad + thresholdLength) / 1e13;
        uint256 expectedDecreaseThresholdEnd = (expectedVertexStartWad - thresholdLength) / 1e13;

        require(
            increaseThresholdStart == expectedIncreaseThresholdStart,
            "DeployMarkets: DynamicIRM increaseThresholdStart mismatch"
        );
        require(
            decreaseThresholdEnd == expectedDecreaseThresholdEnd,
            "DeployMarkets: DynamicIRM decreaseThresholdEnd mismatch"
        );
    }

    /// @notice Verifies BorrowableCToken-specific deployment state
    function _verifyBorrowableCTokenDeployment(
        BorrowableCToken cToken,
        DynamicIRM expectedIRM
    ) internal view {
        // Verify it is borrowable
        require(
            cToken.isBorrowable(),
            "DeployMarkets: BorrowableCToken should be borrowable"
        );

        // Verify IRM is set correctly
        require(
            address(cToken.IRM()) == address(expectedIRM),
            "DeployMarkets: BorrowableCToken IRM mismatch"
        );

        // Verify initial marketOutstandingDebt is 0
        require(
            cToken.marketOutstandingDebt() == 0,
            "DeployMarkets: BorrowableCToken marketOutstandingDebt should be 0"
        );

        // Verify vestingPeriod matches IRM's ADJUSTMENT_RATE
        require(
            cToken.vestingPeriod() == expectedIRM.ADJUSTMENT_RATE(),
            "DeployMarkets: BorrowableCToken vestingPeriod mismatch"
        );
    }
}
