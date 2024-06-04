// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";
import { TestBase } from "tests/utils/TestBase.sol";

import { CVE } from "contracts/token/CVE.sol";
import { VeCVE } from "contracts/token/VeCVE.sol";
import { RewardManager } from "contracts/architecture/RewardManager.sol";
import { SimpleRewardZapper } from "contracts/architecture/utils/SimpleRewardZapper.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";
import { FeeAccumulator } from "contracts/architecture/FeeAccumulator.sol";
import { ProtocolMessagingHub } from "contracts/architecture/ProtocolMessagingHub.sol";
import { DToken } from "contracts/market/collateral/DToken.sol";
import { AuraCToken } from "contracts/market/collateral/AuraCToken.sol";
import { DynamicInterestRateModel } from "contracts/market/DynamicInterestRateModel.sol";
import { MarketManager } from "contracts/market/MarketManager.sol";
import { ComplexZapper } from "contracts/market/utils/ComplexZapper.sol";
import { CallDataCheckerForComplexZapper } from "contracts/market/checker/CallDataCheckerForComplexZapper.sol";
import { PositionFolding } from "contracts/market/utils/PositionFolding.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { IVault } from "contracts/oracles/adaptors/balancer/BalancerBaseAdaptor.sol";
import { BalancerStablePoolAdaptor } from "contracts/oracles/adaptors/balancer/BalancerStablePoolAdaptor.sol";
import { OracleRouter } from "contracts/oracles/OracleRouter.sol";
import { GaugePool } from "contracts/gauge/GaugePool.sol";
import { MockMessageTransmitter } from "contracts/mocks/MockMessageTransmitter.sol";
import { MockTokenBridgeRelayer } from "contracts/mocks/MockTokenBridgeRelayer.sol";
import { MockAuraCTokenWithExitFee } from "contracts/mocks/MockAuraCTokenWithExitFee.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IMToken } from "contracts/interfaces/market/IMToken.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract TestBaseMarket is TestBase {
    function setUp() public virtual {
        _fork(18031848);

        _init();
    }

    function _init() internal {
        uint256 chainId = block.chainid;

        _deployBaseContracts();

        _deployOracleRouter();
        _deployChainlinkAdaptors();
        _deployGaugePool();

        _deployMarketManager();
        _deployDynamicInterestRateModel();
        _deployDUSDC();
        _deployDDAI();
        _deployCBALRETH();
        _deployCBALRETHWithExitFee();

        _deployComplexZapper();
        _deployPositionFolding();

        oracleRouters[chainId].addMTokenSupport(address(dUSDC));
        oracleRouters[chainId].addMTokenSupport(address(cBALRETH));
        oracleRouters[chainId].addMTokenSupport(address(cBALRETHWithExitFee));
    }

    function _deployBaseContracts() internal {
        _deployCentralRegistry();
        _deployCVE();
        _deployRewardManager();
        _deployVeCVE();
        _deployProtocolMessagingHub();
        _deployFeeAccumulator();
    }

    function _deployCentralRegistry() internal initMainVariables {
        centralRegistry = centralRegistries[
            block.chainid
        ] = new CentralRegistry(
            _ZERO_ADDRESS,
            _ZERO_ADDRESS,
            _ZERO_ADDRESS,
            block.timestamp,
            address(0),
            _USDC_ADDRESS
        );
        centralRegistry.transferEmergencyCouncil(address(this));
        centralRegistry.setLockBoostMultiplier(lockBoostMultiplier);
        centralRegistry.setCircleTokenMessenger(_CIRCLE_TOKEN_MESSENGER);
        centralRegistry.setWormholeRelayer(_WORMHOLE_RELAYER);
        centralRegistry.setWormholeCore(_WORMHOLE_CORE);
        centralRegistry.setMessageTransmitter(
            address(new MockMessageTransmitter())
        );
        centralRegistry.setTokenBridge(_TOKEN_BRIDGE);
        centralRegistry.setSlippageLimit(6000);

        deal(
            _USDC_ADDRESS,
            address(centralRegistry.circleMessageTransmitter()),
            1_000_000e6
        );
    }

    function _deployCVE() internal initMainVariables {
        // If TokenBridgeRelayer doesn't exist on the address,
        // deploy mock TokenBridgeRelayer on the address.
        if (_TOKEN_BRIDGE.code.length == 0) {
            vm.etch(_TOKEN_BRIDGE, address(new MockTokenBridgeRelayer()).code);
        }

        cve = cves[block.chainid] = new CVE(
            ICentralRegistry(address(centralRegistry)),
            address(0)
        );
        centralRegistry.setCVE(address(cve));
    }

    function _deployRewardManager() internal initMainVariables {
        rewardManager = rewardManagers[block.chainid] = new RewardManager(
            ICentralRegistry(address(centralRegistry)),
            _USDC_ADDRESS
        );
        centralRegistry.setRewardManager(address(rewardManager));

        simpleRewardZappers[block.chainid] = new SimpleRewardZapper(
            ICentralRegistry(address(centralRegistry)),
            _WETH_ADDRESS
        );
    }

    function _deployVeCVE() internal initMainVariables {
        veCVE = veCVEs[block.chainid] = new VeCVE(
            ICentralRegistry(address(centralRegistry))
        );
        centralRegistry.setVeCVE(address(veCVE));
        centralRegistry.setVoteBoostMultiplier(voteBoostMultiplier);
        rewardManager.startRewardManager();
    }

    function _deployOracleRouter() internal initMainVariables {
        oracleRouter = oracleRouters[block.chainid] = new OracleRouter(
            ICentralRegistry(address(centralRegistry))
        );

        centralRegistry.setOracleRouter(address(oracleRouter));
    }

    function _deployProtocolMessagingHub() internal initMainVariables {
        protocolMessagingHub = protocolMessagingHubs[
            block.chainid
        ] = new ProtocolMessagingHub(
            ICentralRegistry(address(centralRegistry))
        );
        centralRegistry.setProtocolMessagingHub(address(protocolMessagingHub));
    }

    function _deployFeeAccumulator() internal initMainVariables {
        harvester = makeAddr("harvester");
        centralRegistry.addHarvester(harvester);

        feeAccumulator = feeAccumulators[block.chainid] = new FeeAccumulator(
            ICentralRegistry(address(centralRegistry))
        );
        centralRegistry.setFeeAccumulator(address(feeAccumulator));
    }

    function _deployChainlinkAdaptors() internal initMainVariables {
        uint256 chainId = block.chainid;

        chainlinkEthUsd = chainlinkEthUsds[chainId] = new MockV3Aggregator(
            8,
            1500e8,
            1e50,
            1e6
        );
        chainlinkUsdcUsd = chainlinkUsdcUsds[chainId] = new MockV3Aggregator(
            8,
            1e8,
            1e11,
            1e6
        );
        chainlinkDaiUsd = chainlinkDaiUsds[chainId] = new MockV3Aggregator(
            8,
            1e8,
            1e11,
            1e6
        );
        chainlinkUsdcEth = chainlinkUsdcEths[chainId] = new MockV3Aggregator(
            18,
            1e18,
            1e24,
            1e13
        );
        chainlinkRethEth = chainlinkRethEths[chainId] = new MockV3Aggregator(
            18,
            1e18,
            1e24,
            1e13
        );
        chainlinkDaiEth = chainlinkDaiEths[chainId] = new MockV3Aggregator(
            18,
            1e18,
            1e24,
            1e13
        );

        chainlinkAdaptor = chainlinkAdaptors[chainId] = new ChainlinkAdaptor(
            ICentralRegistry(address(centralRegistry))
        );
        chainlinkAdaptor.addAsset(
            _ETH_ADDRESS,
            address(chainlinkEthUsd),
            0,
            true
        );
        chainlinkAdaptor.addAsset(
            _WETH_ADDRESS,
            address(chainlinkEthUsd),
            0,
            true
        );
        chainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            address(chainlinkUsdcUsd),
            0,
            true
        );
        chainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            address(chainlinkUsdcEth),
            0,
            false
        );
        chainlinkAdaptor.addAsset(
            _DAI_ADDRESS,
            address(chainlinkDaiUsd),
            0,
            true
        );
        chainlinkAdaptor.addAsset(
            _DAI_ADDRESS,
            address(chainlinkDaiEth),
            0,
            false
        );
        chainlinkAdaptor.addAsset(
            _RETH_ADDRESS,
            address(chainlinkRethEth),
            0,
            false
        );

        oracleRouter.addApprovedAdaptor(address(chainlinkAdaptor));
        oracleRouter.addAssetPriceFeed(
            _ETH_ADDRESS,
            address(chainlinkAdaptor)
        );
        oracleRouter.addAssetPriceFeed(
            _WETH_ADDRESS,
            address(chainlinkAdaptor)
        );
        oracleRouter.addAssetPriceFeed(
            _USDC_ADDRESS,
            address(chainlinkAdaptor)
        );
        oracleRouter.addAssetPriceFeed(
            _DAI_ADDRESS,
            address(chainlinkAdaptor)
        );
        oracleRouter.addAssetPriceFeed(
            _RETH_ADDRESS,
            address(chainlinkAdaptor)
        );

        dualChainlinkAdaptor = dualChainlinkAdaptors[
            chainId
        ] = new ChainlinkAdaptor(ICentralRegistry(address(centralRegistry)));

        dualChainlinkAdaptor.addAsset(
            _WETH_ADDRESS,
            address(chainlinkEthUsd),
            0,
            true
        );

        dualChainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            address(chainlinkUsdcUsd),
            0,
            true
        );

        dualChainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            address(chainlinkUsdcEth),
            0,
            false
        );
        dualChainlinkAdaptor.addAsset(
            _DAI_ADDRESS,
            address(chainlinkDaiUsd),
            0,
            true
        );
        dualChainlinkAdaptor.addAsset(
            _DAI_ADDRESS,
            address(chainlinkDaiEth),
            0,
            false
        );
        dualChainlinkAdaptor.addAsset(
            _RETH_ADDRESS,
            address(chainlinkRethEth),
            0,
            false
        );
        oracleRouter.addApprovedAdaptor(address(dualChainlinkAdaptor));
        oracleRouter.addAssetPriceFeed(
            _WETH_ADDRESS,
            address(dualChainlinkAdaptor)
        );
        oracleRouter.addAssetPriceFeed(
            _USDC_ADDRESS,
            address(dualChainlinkAdaptor)
        );
        oracleRouter.addAssetPriceFeed(
            _DAI_ADDRESS,
            address(dualChainlinkAdaptor)
        );
        oracleRouter.addAssetPriceFeed(
            _RETH_ADDRESS,
            address(dualChainlinkAdaptor)
        );

        balRETHAdapter = balRETHAdapters[
            chainId
        ] = new BalancerStablePoolAdaptor(
            ICentralRegistry(address(centralRegistry)),
            IVault(_BAL_VAULT_ADDRESS)
        );
        BalancerStablePoolAdaptor.AdaptorData memory adapterData;
        adapterData.poolId = _BAL_WETH_RETH_POOLID;
        adapterData.poolDecimals = 18;
        adapterData.rateProviderDecimals[0] = 18;
        adapterData.rateProviders[
            0
        ] = 0x1a8F81c256aee9C640e14bB0453ce247ea0DFE6F;
        adapterData.underlyingOrConstituent[0] = _RETH_ADDRESS;
        adapterData.underlyingOrConstituent[1] = _WETH_ADDRESS;
        balRETHAdapter.addAsset(_BAL_WETH_RETH_ADDRESS, adapterData);
        oracleRouter.addApprovedAdaptor(address(balRETHAdapter));
        oracleRouter.addAssetPriceFeed(
            _BAL_WETH_RETH_ADDRESS,
            address(balRETHAdapter)
        );
    }

    function _deployGaugePool() internal initMainVariables {
        gaugePool = gaugePools[block.chainid] = new GaugePool(
            ICentralRegistry(address(centralRegistry))
        );
        centralRegistry.addLockingPermissions(address(gaugePool));
    }

    function _deployMarketManager() internal initMainVariables {
        marketManager = marketManagers[block.chainid] = new MarketManager(
            ICentralRegistry(address(centralRegistry)),
            address(gaugePool)
        );
        centralRegistry.addMarketManager(
            address(marketManager),
            marketInterestFactor
        );
    }

    function _deployDynamicInterestRateModel() internal initMainVariables {
        interestRateModel = interestRateModels[
            block.chainid
        ] = new DynamicInterestRateModel(
            ICentralRegistry(address(centralRegistry)),
            1000, // baseRatePerYear
            1000, // vertexRatePerYear
            5000, // vertexUtilizationStart
            12 hours, // adjustmentRate
            5000, // adjustmentVelocity
            100000000, // 1000x maximum vertex multiplier
            100 // decayRate
        );
    }

    function _deployDUSDC() internal initMainVariables returns (DToken) {
        dUSDC = dUSDCs[block.chainid] = _deployDToken(_USDC_ADDRESS);
        return dUSDC;
    }

    function _deployDDAI() internal initMainVariables returns (DToken) {
        dDAI = dDAIs[block.chainid] = _deployDToken(_DAI_ADDRESS);
        return dDAI;
    }

    function _deployDToken(
        address token
    ) internal initMainVariables returns (DToken) {
        return
            new DToken(
                ICentralRegistry(address(centralRegistry)),
                token,
                address(marketManager),
                address(interestRateModel)
            );
    }

    function _deployCBALRETH()
        internal
        initMainVariables
        returns (AuraCToken)
    {
        cBALRETH = cBALRETHs[block.chainid] = new AuraCToken(
            ICentralRegistry(address(centralRegistry)),
            IERC20(_BAL_WETH_RETH_ADDRESS),
            address(marketManager),
            109,
            _REWARDER,
            _AURA_BOOSTER
        );
        return cBALRETH;
    }

    function _deployCBALRETHWithExitFee()
        internal
        initMainVariables
        returns (MockAuraCTokenWithExitFee)
    {
        cBALRETHWithExitFee = cBALRETHWithExitFees[
            block.chainid
        ] = new MockAuraCTokenWithExitFee(
            ICentralRegistry(address(centralRegistry)),
            IERC20(_BAL_WETH_RETH_ADDRESS),
            address(marketManager),
            109,
            _REWARDER,
            _AURA_BOOSTER,
            200
        );
        return cBALRETHWithExitFee;
    }

    function _deployComplexZapper()
        internal
        initMainVariables
        returns (ComplexZapper)
    {
        complexZapper = complexZappers[block.chainid] = new ComplexZapper(
            ICentralRegistry(address(centralRegistry)),
            address(marketManager),
            _WETH_ADDRESS
        );
        centralRegistry.setExternalCallDataChecker(
            address(complexZapper),
            address(
                new CallDataCheckerForComplexZapper(address(complexZapper))
            )
        );
        return complexZapper;
    }

    function _deployPositionFolding()
        internal
        initMainVariables
        returns (PositionFolding)
    {
        positionFolding = positionFoldings[
            block.chainid
        ] = new PositionFolding(
            ICentralRegistry(address(centralRegistry)),
            address(marketManager)
        );
        return positionFolding;
    }

    function _addSinglePriceFeed() internal initMainVariables {
        oracleRouter.addApprovedAdaptor(address(chainlinkAdaptor));
        oracleRouter.addAssetPriceFeed(
            _USDC_ADDRESS,
            address(chainlinkAdaptor)
        );
    }

    function _addDualPriceFeed() internal initMainVariables {
        _addSinglePriceFeed();

        oracleRouter.addApprovedAdaptor(address(dualChainlinkAdaptor));
        oracleRouter.addAssetPriceFeed(
            _USDC_ADDRESS,
            address(dualChainlinkAdaptor)
        );
    }

    function _prepareUSDC(
        address user,
        uint256 amount
    ) internal initMainVariables {
        deal(_USDC_ADDRESS, user, amount);
    }

    function _prepareDAI(
        address user,
        uint256 amount
    ) internal initMainVariables {
        deal(_DAI_ADDRESS, user, amount);
    }

    function _prepareBALRETH(
        address user,
        uint256 amount
    ) internal initMainVariables {
        deal(_BAL_WETH_RETH_ADDRESS, user, amount);
    }

    function _setCbalRETHCollateralCaps(
        uint256 cap
    ) internal initMainVariables {
        marketManager.updateCollateralToken(
            IMToken(address(cBALRETH)),
            7000,
            4000,
            3000,
            200, // 2% liq incentive
            400,
            0,
            1000
        );
        address[] memory tokens = new address[](1);
        tokens[0] = address(cBALRETH);
        uint256[] memory caps = new uint256[](1);
        caps[0] = cap;
        marketManager.setCTokenCollateralCaps(tokens, caps);
    }

    function _skipRestrictionDuration() internal {
        skip(veCVE.RESTRICTION_DURATION() + 1);
    }

    function _skipEpochDuration(uint256 numEpochs) internal {
        skip(rewardManager.EPOCH_DURATION() * numEpochs);
    }

    function _recordEpochRewards(
        uint256 numEpochs,
        uint256 epochRewards
    ) internal {
        for (uint256 i = 0; i < 2; i++) {
            vm.prank(centralRegistry.protocolMessagingHub());
            rewardManager.recordEpochRewards(epochRewards);
        }

        _skipEpochDuration(numEpochs);
    }

    function _addressToBytes32(address addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(addr)));
    }
}
