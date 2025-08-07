// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { CVE } from "contracts/token/CVE.sol";
import { VeCVE } from "contracts/token/VeCVE.sol";
import { RewardManager } from "contracts/architecture/RewardManager.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";
import { FeeManager } from "contracts/architecture/FeeManager.sol";
import { MessagingHub } from "contracts/architecture/MessagingHub.sol";
import { VotingHub } from "contracts/architecture/VotingHub.sol";
import { GaugeManager } from "contracts/architecture/GaugeManager.sol";
import { DAOTimelock } from "contracts/architecture/DAOTimelock.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { SimpleCToken } from "contracts/market/token/SimpleCToken.sol";
import { AuraCToken } from "contracts/market/token/AuraCToken.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { DynamicIRM } from "contracts/market/DynamicIRM.sol";
import { SimpleRewardZapper } from "contracts/plugins/rewards/SimpleRewardZapper.sol";
import { PendleZapper } from "contracts/plugins/market/PendleZapper.sol";
import { VelodromeZapper } from "contracts/plugins/market/VelodromeZapper.sol";
import { PendleZapperCalldataChecker } from "contracts/calldata-checker/swap-checker/PendleZapperCalldataChecker.sol";
import { VelodromeZapperCalldataChecker } from "contracts/calldata-checker/swap-checker/VelodromeZapperCalldataChecker.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { IVault } from "contracts/oracles/adaptors/balancer/BalancerBaseAdaptor.sol";
import { BalancerStablePoolAdaptor } from "contracts/oracles/adaptors/balancer/BalancerStablePoolAdaptor.sol";
import { ProtocolReader } from "contracts/views/ProtocolReader.sol";

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { WAD, WAD_SQUARED } from "contracts/libraries/ConstantsLib.sol";

import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { ICToken } from "contracts/interfaces/ICToken.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

import { IWormhole } from "contracts/interfaces/external/wormhole/IWormhole.sol";
import { IBooster } from "contracts/interfaces/external/convex/IBooster.sol";
import { IBaseRewardPool } from "contracts/interfaces/external/convex/IBaseRewardPool.sol";

import { TestBase } from "tests/utils/TestBase.sol";
import { QueryTest } from "tests/utils/QueryTest.sol";

import { console2 } from "forge-std/console2.sol";

import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";
import { MockMessageTransmitter } from "contracts/mocks/MockMessageTransmitter.sol";
import { MockTokenBridgeRelayer } from "contracts/mocks/MockTokenBridgeRelayer.sol";
import { MockAuraCTokenWithExitFee } from "contracts/mocks/MockAuraCTokenWithExitFee.sol";
import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";


contract TestBaseMarketIsolated is TestBase {
    // Chain Data
    struct PerChainData {
        uint256 chainId;
        uint256 blockNumber;
        uint64 timestamp;
        address to;
        bytes result;
    }

    // Liquidation helpers

    struct LiquidationParams {
        address borrower;
        address collateralToken;
        address borrowedToken;
        bool isLiquidateExact;
        uint256 liquidateExactAmount;
        bool isAuction;
        bool isMultiMarketTest;
        uint256 marketManagerId;
    }

    struct ExpectedLiquidationValues {
        uint256 debtRepaid;
        uint256 collateralLiquidated;
        uint256 badDebt;
        uint256 collateralRequired;
        uint256 maxAmountRepaid;
    }

    struct LiquidationCalcData {
        uint256 collateralTokenPrice;
        uint256 collateralTokenDecimals;
        uint256 debtTokenPrice;
        uint256 debtTokenDecimals;
        uint256 liqIncBase;
        uint256 liqIncCurve;
        uint256 closeFactorBase;
        uint256 closeFactorCurve;
        uint256 liqInc;
        uint256 lFactor;
    }

    function setUp() public virtual {
        _fork(18031848);

        _init();
    }

    function _init() internal {
        uint256 chainId = block.chainid;

        _deployBaseContracts();

        _deployOracleManager();
        _deployChainlinkAdaptors();

        _deployMarketManager();

        _deployBorrowableCUSDC();
        _deployBorrowableCDAI();
        _deploySimpleCUSDC();
        _deployStrategyCBALRETH();
        _deployStrategyCBALRETHWithExitFee();

        _deployPendleZapper();
        _deployVelodromeZapper();

        _setRedstoneSigners();

        _deployUniswapV2CalldataChecker();

        _setMockFeedsInitial();

        // Create a dapp control user.
        vm.startPrank(centralRegistry.daoAddress());
        centralRegistry.addAuctionPermissions(dappControlUser);
        vm.stopPrank();

        oracleManagers[chainId].addCTokenSupport(address(borrowableCUSDC));
        oracleManagers[chainId].addCTokenSupport(address(borrowableCDAI));
        oracleManagers[chainId].addCTokenSupport(address(strategyCBALRETH));
        oracleManagers[chainId].addCTokenSupport(address(strategyCBALRETHWithExitFee));
    }

    function _deployBaseContracts() internal {
        _deployCentralRegistry();
        _deployDAOTimelock();
        _deployCVE();
        _deployRewardManager();
        _deployVeCVE();
        _deployGaugeManager();
        _deployMessagingHub();
        _deployVotingHub();
        _deployFeeManager();
        _deployProtocolReader();

        vm.warp(centralRegistry.genesisEpoch());
        rewardManager.startRewardManager();
    }

    function _deployCentralRegistry() internal virtual initMainVariables {
        centralRegistry = centralRegistries[
            block.chainid
        ] = new CentralRegistry(
            _ZERO_ADDRESS,
            _ZERO_ADDRESS,
            block.timestamp + 1,
            address(0),
            _USDC_ADDRESS
        );
        centralRegistry.transferEmergencyCouncil(address(this));
        centralRegistry.setLockBoostMultiplier(lockBoostMultiplier);
        centralRegistry.setTokenMessager(_CIRCLE_TOKEN_MESSENGER);
        centralRegistry.setCrosschainRelayer(_CROSSCHAIN_RELAYER);
        centralRegistry.setCrosschainCore(_CROSSCHAIN_CORE);
        centralRegistry.setMessageTransmitter(
            address(new MockMessageTransmitter())
        );
        centralRegistry.setSlippageLimit(6000);

        _prepareUSDC(
            address(centralRegistry.messageTransmitter()),
            1_000_000e6
        );
    }

    function _deployDAOTimelock() internal initMainVariables {
        daoTimelock = daoTimelocks[block.chainid] = new DAOTimelock(
            ICentralRegistry(address(centralRegistry))
        );

        centralRegistry.transferTimelockPermissions(address(daoTimelock));
    }

    function _deployCVE() internal virtual initMainVariables {
        cve = cves[block.chainid] = new CVE(
            ICentralRegistry(address(centralRegistry)),
            address(0)
        );
        centralRegistry.setCVE(address(cve));
    }

    function _deployRewardManager() internal initMainVariables {
        rewardManager = rewardManagers[block.chainid] = new RewardManager(
            ICentralRegistry(address(centralRegistry))
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
    }

    function _deployOracleManager() internal initMainVariables {
        oracleManager = oracleManagers[block.chainid] = new OracleManager(
            ICentralRegistry(address(centralRegistry))
        );

        centralRegistry.setOracleManager(address(oracleManager));
    }

    function _deployMessagingHub() internal initMainVariables {
        messagingHub = messagingHubs[block.chainid] = new MessagingHub(
            ICentralRegistry(address(centralRegistry))
        );
        centralRegistry.setMessagingHub(address(messagingHub));
    }

    function _deployVotingHub() internal initMainVariables {
        votingHub = votingHubs[block.chainid] = new VotingHub(
            ICentralRegistry(address(centralRegistry))
        );
        centralRegistry.setVotingHub(address(votingHub));
        centralRegistry.setEraTargetEmissions(_ONE);
    }

    function _deployFeeManager() internal initMainVariables {
        centralRegistry.addHarvestPermissions(harvester);

        feeManager = feeManagers[block.chainid] = new FeeManager(
            ICentralRegistry(address(centralRegistry))
        );
        centralRegistry.setFeeManager(address(feeManager));
    }

    function _deployProtocolReader() internal initMainVariables {
        protocolReader = protocolReaders[block.chainid] = new ProtocolReader(
            ICentralRegistry(address(centralRegistry))
        );
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

        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));
        oracleManager.addAssetPriceFeed(
            _ETH_ADDRESS,
            address(chainlinkAdaptor)
        );
        oracleManager.addAssetPriceFeed(
            _WETH_ADDRESS,
            address(chainlinkAdaptor)
        );
        oracleManager.addAssetPriceFeed(
            _USDC_ADDRESS,
            address(chainlinkAdaptor)
        );
        oracleManager.addAssetPriceFeed(
            _DAI_ADDRESS,
            address(chainlinkAdaptor)
        );
        oracleManager.addAssetPriceFeed(
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
        oracleManager.addApprovedAdaptor(address(dualChainlinkAdaptor));
        oracleManager.addAssetPriceFeed(
            _WETH_ADDRESS,
            address(dualChainlinkAdaptor)
        );
        oracleManager.addAssetPriceFeed(
            _USDC_ADDRESS,
            address(dualChainlinkAdaptor)
        );
        oracleManager.addAssetPriceFeed(
            _DAI_ADDRESS,
            address(dualChainlinkAdaptor)
        );
        oracleManager.addAssetPriceFeed(
            _RETH_ADDRESS,
            address(dualChainlinkAdaptor)
        );

        balRETHAdapter = balRETHAdapters[
            chainId
        ] = new BalancerStablePoolAdaptor(
            ICentralRegistry(address(centralRegistry)),
            IVault(_BAL_VAULT_ADDRESS)
        );
        BalancerStablePoolAdaptor.AssetConfig memory assetConfig;
        assetConfig.poolId = _BAL_WETH_RETH_POOLID;
        assetConfig.poolDecimals = 18;
        assetConfig.rateProviderDecimals[0] = 18;
        assetConfig.rateProviders[
            0
        ] = 0x1a8F81c256aee9C640e14bB0453ce247ea0DFE6F;
        assetConfig.underlyingOrConstituent[0] = _RETH_ADDRESS;
        assetConfig.underlyingOrConstituent[1] = _WETH_ADDRESS;
        balRETHAdapter.addAsset(_BAL_WETH_RETH_ADDRESS, assetConfig);
        oracleManager.addApprovedAdaptor(address(balRETHAdapter));
        oracleManager.addAssetPriceFeed(
            _BAL_WETH_RETH_ADDRESS,
            address(balRETHAdapter)
        );
    }

    function _deployGaugeManager() internal initMainVariables {
        gaugeManager = gaugeManagers[block.chainid] = new GaugeManager(
            ICentralRegistry(address(centralRegistry))
        );
        centralRegistry.setGaugeManager(address(gaugeManager));
        centralRegistry.addLockingPermissions(address(gaugeManager));
    }

    function _deployMarketManager() internal initMainVariables {
        marketManagerIsolated = marketManagersIsolated[block.chainid] = new MarketManagerIsolated(
            ICentralRegistry(address(centralRegistry))
        );
        centralRegistry.addMarketManager(
            address(marketManagerIsolated),
            marketInterestFee
        );
    }

    function _deployDynamicIRM(
        address underlyingToken
    ) internal returns (address) {
        IRMs[block.chainid][
            underlyingToken
        ] = new DynamicIRM(
            ICentralRegistry(address(centralRegistry)),
            1000, // baseRatePerYear
            1000, // vertexRatePerYear
            5000, // vertexUtilizationStart
            1000, // adjustmentVelocity
            100000000, // 1000x maximum vertex multiplier
            100 // decayRate
        );

        return address(IRMs[block.chainid][underlyingToken]);
    }

    function _deployBorrowableCUSDC() internal initMainVariables returns (BorrowableCToken) {
        borrowableCUSDC = borrowableCUSDCs[block.chainid] = _deployBorrowableCToken(_USDC_ADDRESS);
        return borrowableCUSDC;
    }

    function _deployBorrowableCDAI() internal initMainVariables returns (BorrowableCToken) {
        borrowableCDAI = borrowableCDAIs[block.chainid] = _deployBorrowableCToken(_DAI_ADDRESS);
        return borrowableCDAI;
    }

    function _deployBorrowableCToken(
        address underlyingAsset
    ) internal virtual initMainVariables returns (BorrowableCToken) {
        BorrowableCToken borrowableCToken = new BorrowableCToken(
            ICentralRegistry(address(centralRegistry)),
            IERC20(underlyingAsset),
            address(marketManagerIsolated),
            _deployDynamicIRM(underlyingAsset)
        );

        IRMs[block.chainid][underlyingAsset].setLinkedToken(
            address(borrowableCToken)
        );

        return borrowableCToken;
    }

    function _deploySimpleCUSDC()
        internal
        initMainVariables
        returns (SimpleCToken) {
        simpleCUSDC = new SimpleCToken(
            ICentralRegistry(address(centralRegistry)),
            usdc,
            address(marketManagerIsolated)
        );
        return simpleCUSDC;
    }

    function _deployStrategyCBALRETH()
        internal
        initMainVariables
        returns (AuraCToken)
    {
        strategyCBALRETH = strategyCBALRETHs[block.chainid] = new AuraCToken(
            ICentralRegistry(address(centralRegistry)),
            balRETH,
            address(marketManagerIsolated),
            109,
            _REWARDER,
            _AURA_BOOSTER,
            1 days
        );
        return strategyCBALRETH;
    }

    function _deployStrategyCBALRETHWithExitFee()
        internal
        initMainVariables
        returns (MockAuraCTokenWithExitFee)
    {
        strategyCBALRETHWithExitFee = strategyCBALRETHWithExitFees[
            block.chainid
        ] = new MockAuraCTokenWithExitFee(
            ICentralRegistry(address(centralRegistry)),
            balRETH,
            address(marketManagerIsolated),
            109,
            _REWARDER,
            _AURA_BOOSTER,
            1 days,
            200
        );
        return strategyCBALRETHWithExitFee;
    }

    function _deployPendleZapper()
        internal
        initMainVariables
        returns (PendleZapper)
    {
        pendleZapper = pendleZappers[block.chainid] = new PendleZapper(
            ICentralRegistry(address(centralRegistry)),
            _WETH_ADDRESS
        );
        centralRegistry.setExternalCalldataChecker(
            address(pendleZapper),
            address(new PendleZapperCalldataChecker(address(pendleZapper)))
        );
        return pendleZapper;
    }

    function _deployVelodromeZapper()
        internal
        initMainVariables
        returns (VelodromeZapper)
    {
        velodromeZapper = velodromeZappers[
            block.chainid
        ] = new VelodromeZapper(
            ICentralRegistry(address(centralRegistry)),
            _WETH_ADDRESS
        );
        centralRegistry.setExternalCalldataChecker(
            address(velodromeZapper),
            address(
                new VelodromeZapperCalldataChecker(address(velodromeZapper))
            )
        );
        return velodromeZapper;
    }

    function _addSinglePriceFeed() internal initMainVariables {
        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));
        oracleManager.addAssetPriceFeed(
            _USDC_ADDRESS,
            address(chainlinkAdaptor)
        );
    }

    function _addDualPriceFeed() internal initMainVariables {
        _addSinglePriceFeed();

        oracleManager.addApprovedAdaptor(address(dualChainlinkAdaptor));
        oracleManager.addAssetPriceFeed(
            _USDC_ADDRESS,
            address(dualChainlinkAdaptor)
        );
    }

    function _setRedstoneSigners() internal initMainVariables {
        redstoneSigners.push(0x96729dF85d393546e41CD5F860d10Ea8Bd107a28);
        redstoneSigners.push(0x47fCB422783DC56BC61FaeFC48DC2287F6Bce8A5);
        redstoneSigners.push(0x53C875cB2f8Bfab574FD91047B5893F5ACcC9381);
        redstoneSigners.push(0xfb5009a8573762f98E9E99304195197a6f188de1);

        redstoneSignerKeys.push(
            0x56938289786ae24fdb687a2a740e755d6ed7e72a1f82f8f9c3ed6eac5b38ba23
        );
        redstoneSignerKeys.push(
            0x4022f8e215d01e76d90987d7f56a09513fe76f97add10db250215bdbfab3e9c1
        );
        redstoneSignerKeys.push(
            0x00b2ff109fc6421974dff44f7e2f95a0ebbba51acb43b6975b77615c6cba12b2
        );
        redstoneSignerKeys.push(
            0x7058697b9c2cd9dc583f9c44577ba4867e4b0c3fa5924a34db983c7b031266b4
        );
    }

    function _prepareWETH(
        address user,
        uint256 amount
    ) internal initMainVariables {
        deal(_WETH_ADDRESS, user, amount);
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

    function _prepareWBTC(
        address user,
        uint256 amount
    ) internal initMainVariables {
        deal(_WBTC_ADDRESS, user, amount);
    }

    function _prepareBALRETH(
        address user,
        uint256 amount
    ) internal initMainVariables {
        deal(_BAL_WETH_RETH_ADDRESS, user, amount);
    }

    function _prepareCVE(
        address user,
        uint256 amount
    ) internal initMainVariables {
        deal(address(cve), user, amount);
    }

    function _setCTokenConfigBasic(
        address cToken,
        uint256 collateralCap,
        uint256 debtCap
    ) internal initMainVariables {
        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = cToken;
        tokenConfig.collRatio = 7000;
        tokenConfig.collReqSoft = 4000;
        tokenConfig.collReqHard = 3000;
        tokenConfig.liqIncBase = 1000;
        tokenConfig.liqIncHard = 1500;
        tokenConfig.liqIncMin = 10;
        tokenConfig.liqIncMax = 2000;
        tokenConfig.closeFactorBase = 2000;
        tokenConfig.closeFactorMin = 2000;
        tokenConfig.closeFactorMax = 5000;
        tokenConfig.collateralCap = collateralCap;
        tokenConfig.debtCap = debtCap;

        marketManagerIsolated.updateTokenConfig(tokenConfig);
    }

    function _setCTokenConfigLowValues(
        address cToken,
        uint256 collateralCap,
        uint256 debtCap
    ) internal initMainVariables {
        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = cToken;
        tokenConfig.collRatio = 5000;
        tokenConfig.collReqSoft = 3000;
        tokenConfig.collReqHard = 2000;
        tokenConfig.liqIncBase = 500;
        tokenConfig.liqIncHard = 800;
        tokenConfig.liqIncMin = 300;
        tokenConfig.liqIncMax = 1000;
        tokenConfig.closeFactorBase = 2000;
        tokenConfig.closeFactorMin = 2000;
        tokenConfig.closeFactorMax = 5000;
        tokenConfig.collateralCap = collateralCap;
        tokenConfig.debtCap = debtCap;

        marketManagerIsolated.updateTokenConfig(tokenConfig);
    }

    function _setCTokenConfigHighValues(
        address cToken,
        uint256 collateralCap,
        uint256 debtCap
    ) internal initMainVariables {
        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = cToken;
        tokenConfig.collRatio = 9500;
        tokenConfig.collReqSoft = 250;
        tokenConfig.collReqHard = 200;
        tokenConfig.liqIncBase = 60;
        tokenConfig.liqIncHard = 90;
        tokenConfig.liqIncMin = 30;
        tokenConfig.liqIncMax = 90;
        tokenConfig.closeFactorBase = 2000;
        tokenConfig.closeFactorMin = 2000;
        tokenConfig.closeFactorMax = 5000;
        tokenConfig.collateralCap = collateralCap;
        tokenConfig.debtCap = debtCap;

        marketManagerIsolated.updateTokenConfig(tokenConfig);
    }

    function _setCTokenConfigCollateralOff(
        address cToken,
        uint256 debtCap
    ) internal initMainVariables {
        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = cToken;
        tokenConfig.collRatio = 0;
        tokenConfig.collReqSoft = 4000;
        tokenConfig.collReqHard = 3000;
        tokenConfig.liqIncBase = 1000;
        tokenConfig.liqIncHard = 1500;
        tokenConfig.liqIncMin = 10;
        tokenConfig.liqIncMax = 2000;
        tokenConfig.closeFactorBase = 2000;
        tokenConfig.closeFactorMin = 2000;
        tokenConfig.closeFactorMax = 5000;
        tokenConfig.collateralCap = 0;
        tokenConfig.debtCap = debtCap;

        marketManagerIsolated.updateTokenConfig(tokenConfig);
    }

    function _setAuctionConfigs(
        address token,
        uint256 liquidationPenalty,
        uint256 liquidationCloseFactor
    ) internal {
        vm.startPrank(dappControlUser);
        centralRegistry.unlockAuctionForMarket(address(marketManagerIsolated));
        marketManagerIsolated.unlockAuctionCollateral(token);
        marketManagerIsolated.setLiquidationConfig(token, liquidationPenalty, liquidationCloseFactor);
        vm.stopPrank();
    }

    function _skipRestrictionDuration() internal {
        skip(veCVE.RESTRICTION_DURATION() + 1);
    }

    function _skipEpochDuration(uint256 numEpochs) internal {
        skip(rewardManager.epochDuration() * numEpochs);
    }

    function _recordEpochRewards(
        uint256 numEpochs,
        uint256 epochRewards
    ) internal {
        for (uint256 i = 0; i < numEpochs; i++) {
            vm.prank(address(messagingHub));
            rewardManager.recordEpochRewards(epochRewards);
        }

        _skipEpochDuration(numEpochs);
    }

    function _deployUniswapV2CalldataChecker() internal initMainVariables {
        centralRegistry.setExternalCalldataChecker(
            _UNISWAP_V2_ROUTER,
            address(new MockCalldataChecker(_UNISWAP_V2_ROUTER))
        );
    }

    function _prepareResponseAndSignatures(
        PerChainData[] memory perChainData,
        bytes memory callData
    ) internal {
        delete signatures;

        bytes[] memory perChainQueries = new bytes[](perChainData.length);
        bytes[] memory perChainResponses = new bytes[](perChainData.length);

        for (uint256 i = 0; i < perChainData.length; i++) {
            bytes memory resultsBytes = QueryTest.buildEthCallResultBytes(
                perChainData[i].result
            );
            bytes memory reponseBytes = QueryTest.buildEthCallResponseBytes(
                uint64(perChainData[i].blockNumber),
                bytes32(blockhash(perChainData[i].blockNumber)),
                perChainData[i].timestamp,
                1,
                resultsBytes
            );
            perChainResponses[i] = QueryTest.buildPerChainResponseBytes(
                uint16(perChainData[i].chainId),
                1,
                reponseBytes
            );

            bytes memory dataBytes = QueryTest.buildEthCallDataBytes(
                perChainData[i].to,
                callData
            );
            bytes memory requestBytes = QueryTest.buildEthCallRequestBytes(
                abi.encode(perChainData[i].blockNumber),
                1,
                dataBytes
            );
            perChainQueries[i] = QueryTest.buildPerChainRequestBytes(
                uint16(perChainData[i].chainId),
                1,
                requestBytes
            );
        }

        response = _concatenateQueryResponseBytesOffChain(
            0x01,
            0x0000,
            hex"ff0c222dc9e3655ec38e212e9792bf1860356d1277462b6bf747db865caca6fc08e6317b64ee3245264e371146b1d315d38c867fe1f69614368dc4430bb560f200",
            0x01,
            0xdd9914c6,
            perChainQueries,
            perChainResponses
        );

        bytes32 responseDigest = votingHub.getResponseDigest(response);
        (uint8 sigV, bytes32 sigR, bytes32 sigS) = vm.sign(
            0xcfb12303a19cde580bb4dd771639b0d26bc68353645571a8cff516ab2ee113a0,
            responseDigest
        );

        signatures.push(
            IWormhole.Signature({
                r: sigR,
                s: sigS,
                v: sigV,
                guardianIndex: 0
            })
        );
    }

    function _concatenateQueryResponseBytesOffChain(
        uint8 version,
        uint16 senderChainId,
        bytes memory _signature,
        uint8 queryRequestVersion,
        uint32 queryRequestNonce,
        bytes[] memory perChainQueries,
        bytes[] memory perChainResponses
    ) internal pure returns (bytes memory) {
        bytes memory concatenatedPerChainQueries = _concatenateBytesArrays(
            perChainQueries
        );
        bytes memory concatenatedPerChainResponses = _concatenateBytesArrays(
            perChainResponses
        );

        bytes memory queryRequest = QueryTest.buildOffChainQueryRequestBytes(
            queryRequestVersion,
            queryRequestNonce,
            uint8(perChainQueries.length),
            concatenatedPerChainQueries
        );
        return
            QueryTest.buildQueryResponseBytes(
                version,
                senderChainId,
                _signature,
                queryRequest,
                uint8(perChainResponses.length),
                concatenatedPerChainResponses
            );
    }

    function _concatenateBytesArrays(
        bytes[] memory arrays
    ) internal pure returns (bytes memory concatenated) {
        uint256 totalLength = 0;
        for (uint256 i = 0; i < arrays.length; i++) {
            totalLength += arrays[i].length;
        }

        concatenated = new bytes(totalLength);
        uint256 offset = 0;
        for (uint256 i = 0; i < arrays.length; i++) {
            bytes memory array = arrays[i];
            for (uint256 j = 0; j < array.length; j++) {
                concatenated[offset + j] = array[j];
            }
            offset += array.length;
        }
    }

    function _addressToBytes32(address addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(addr)));
    }

    function _makeTokenArray(
        address token
    ) internal pure returns (address[] memory result) {
        result = new address[](1);
        result[0] = token;
    }

    function _calculateExpectedLiquidationValues(
        LiquidationParams memory params
    ) internal view returns (
       ExpectedLiquidationValues memory expectedLiquidationValues
    ) {

        uint256 lFactor;
        MarketManagerIsolated marketManager_;

        if(params.isMultiMarketTest) {
            marketManager_ = marketManagersIsolated[params.marketManagerId];
            (lFactor,,) = 
                marketManagersIsolated[params.marketManagerId].liquidationStatusOf(params.borrower, params.collateralToken, params.borrowedToken);

        } else {
            marketManager_ = marketManagerIsolated;
            (lFactor,,) = 
                marketManagerIsolated.liquidationStatusOf(params.borrower, params.collateralToken, params.borrowedToken);
        }

        // Handle auction scenarios where lFactor=0 but auction buffer makes it liquidatable
        if(lFactor == 0 && params.isAuction) {

            lFactor = _calculateAuctionLFactor(params, marketManager_);

            if(lFactor == 0) {
                console2.log("lFactor is 0 even with auction buffer");
                return ExpectedLiquidationValues({
                    debtRepaid: 0,
                    collateralLiquidated: 0,
                    badDebt: 0,
                    collateralRequired: 0,
                    maxAmountRepaid: 0
                });
            }
        } else if(lFactor == 0) {
            console2.log("lFactor is 0");
            return ExpectedLiquidationValues({
                debtRepaid: 0,
                collateralLiquidated: 0,
                badDebt: 0,
                collateralRequired: 0,
                maxAmountRepaid: 0
            });
        }

        // calculate auctionCFactor & debtToCollateralMultiplier
        (uint256 debtToCollateral, uint256 cFactor) = 
            _calculateAuctionCFactorAndDebtToCollateral(
                params.borrower,
                params.collateralToken,
                params.borrowedToken,
                params.isAuction,
                marketManager_
            );

        uint256 debtBalance = IBorrowableCToken(params.borrowedToken).debtBalance(params.borrower);
        uint256 maxAmount = (cFactor * debtBalance) / WAD;
        
        expectedLiquidationValues.maxAmountRepaid = maxAmount;

        uint256 collateralAvailable = ICToken(params.collateralToken).collateralPosted(params.borrower);

        if(params.isLiquidateExact) {
            expectedLiquidationValues.debtRepaid = params.liquidateExactAmount;
        } else {
            expectedLiquidationValues.debtRepaid = maxAmount;
        }

        console2.log("debtRepaid after if(params.isLiquidateExact) ", expectedLiquidationValues.debtRepaid);

        expectedLiquidationValues.collateralLiquidated = (expectedLiquidationValues.debtRepaid * debtToCollateral) / WAD_SQUARED;

        console2.log("collateralLiquidated", expectedLiquidationValues.collateralLiquidated);
        console2.log("collateralAvailable", collateralAvailable);

        if (expectedLiquidationValues.collateralLiquidated > collateralAvailable) {
            expectedLiquidationValues.debtRepaid = FixedPointMathLib.mulDivUp(
                expectedLiquidationValues.debtRepaid,
                collateralAvailable,
                expectedLiquidationValues.collateralLiquidated
            );
            expectedLiquidationValues.collateralLiquidated = collateralAvailable;
        }

        console2.log("debtRepaid after collateralLiquidated > collateralAvailable ", expectedLiquidationValues.debtRepaid);

        expectedLiquidationValues.collateralRequired = (debtBalance * debtToCollateral) / WAD_SQUARED;

        expectedLiquidationValues.badDebt = _calculateExpectedBadDebt(
            params.borrower,
            expectedLiquidationValues.debtRepaid,
            expectedLiquidationValues.collateralRequired,
            expectedLiquidationValues.collateralLiquidated,
            params.collateralToken,
            params.borrowedToken
        );

    }
    
    function _calculateAuctionCFactorAndDebtToCollateral(
        address _borrower,
        address _collateralToken,
        address _debtToken,
        bool _isAuction,
        MarketManagerIsolated _marketManager
    ) internal view 
    returns (uint256 debtToCollateral, uint256 cFactor) {

        LiquidationCalcData memory data;

        (data.liqIncBase, data.liqIncCurve,,, data.closeFactorBase, data.closeFactorCurve,,)
            = _marketManager.liquidationConfig(address(_collateralToken));

        (data.lFactor, data.collateralTokenPrice, data.debtTokenPrice) = 
            _marketManager.liquidationStatusOf(_borrower, _collateralToken, _debtToken);

        if (_isAuction) {
            (data.liqInc, cFactor) = _marketManager.getLiquidationConfig();
        } else {
            cFactor = data.closeFactorBase + ((data.closeFactorCurve * data.lFactor) / WAD);
            data.liqInc = data.liqIncBase + ((data.liqIncCurve * data.lFactor) / WAD);
        }

        console2.log("data.liqInc from auction", data.liqInc);
        console2.log("cFactor from auction", cFactor);

        data.collateralTokenDecimals = 10 ** ICToken(_collateralToken).decimals();
        data.debtTokenDecimals = 10 ** ICToken(_debtToken).decimals();

        uint256 collateralExchangeRate = ICToken(_collateralToken).exchangeRate();

        debtToCollateral = (((data.liqInc *
            data.debtTokenPrice * WAD_SQUARED) /
            (data.collateralTokenPrice * collateralExchangeRate)) * 
            data.collateralTokenDecimals) / data.debtTokenDecimals;
            
    }

    function _calculateExpectedBadDebt(
        address _borrower,
        uint256 _debtAmount,
        uint256 _collateralRequired,
        uint256 _collateralLiquidated,
        address _collateralToken,
        address _debtToken
    ) internal view returns (uint256 badDebt) {

        uint256 debtTokenDecimals = 10 ** ICToken(_debtToken).decimals();
        uint256 collateralTokenExchangeRate = ICToken(_collateralToken).exchangeRate();

        uint256 collateralAvailable = ICToken(_collateralToken).collateralPosted(_borrower);
        (uint256 collateralTokenUnderlyingPrice, uint256 debtTokenUnderlyingPrice) = oracleManager.getPriceIsolatedPair(
            _collateralToken,
            _debtToken,
            2
        );

        uint256 debtBalance = IBorrowableCToken(_debtToken).debtBalance(_borrower);

        console2.log("debtBalance", debtBalance);
        console2.log("debtTokenUnderlyingPrice", debtTokenUnderlyingPrice);
        console2.log("collateralTokenExchangeRate", collateralTokenExchangeRate);
        console2.log("collateralTokenUnderlyingPrice", collateralTokenUnderlyingPrice);
        console2.log("collateralAvailable", collateralAvailable);
        console2.log("collateralRequired", _collateralRequired);
        console2.log("collateralLiquidated", _collateralLiquidated);
        console2.log("remaining debt", debtBalance - _debtAmount);
        console2.log("remaining collateral shares", collateralAvailable - _collateralLiquidated);
        
        if (_collateralRequired > collateralAvailable) {
            // of debt should be recognized as bad debt.
            badDebt = FixedPointMathLib.fullMulDiv(
                FixedPointMathLib.mulDiv(
                    _debtAmount,
                    _collateralRequired,
                    collateralAvailable
                ),
                WAD_SQUARED - FixedPointMathLib.mulDiv(
                    WAD_SQUARED,
                    collateralAvailable,
                    _collateralRequired
                ),
                WAD_SQUARED
            );

            console2.log("badDebt", badDebt);

            if (badDebt + _debtAmount > debtBalance) {
                badDebt = debtBalance - _debtAmount;
            }
        }    
    }

    function _calculateAuctionLFactor(
        LiquidationParams memory params,
        MarketManagerIsolated marketManager_
    ) internal view returns (uint256) {
        // Get collateral and debt values
        (uint256 collateralSoft,, uint256 debt) =
            marketManager_.liquidationValuesOf(params.borrower);

        // Apply auction buffer
        uint256 AUCTION_BUFFER = marketManager_.AUCTION_BUFFER();
        uint256 adjustedCollateralSoft = (collateralSoft * AUCTION_BUFFER) / WAD;

        // Recalculate lFactor with buffered collateral
        if (adjustedCollateralSoft == 0) {
            return 0;
        }

        // Get collateral requirement
        (, uint256 collReqSoft, ) = marketManager_.collConfig(params.collateralToken);

        // Calculate lFactor: (debt * collReqSoft) / adjustedCollateralSoft
        return (debt * collReqSoft) / adjustedCollateralSoft;
    }

    function _harvestAuraStrategyRewards(uint256 time) internal {

        uint256 exchangeRateBefore = strategyCBALRETH.exchangeRate();

        IBooster(_AURA_BOOSTER).earmarkRewards(109);

        skip(time);

        mockUsdcFeed.setMockUpdatedAt(block.timestamp);
        mockWethFeed.setMockUpdatedAt(block.timestamp);
        mockRethFeed.setMockUpdatedAt(block.timestamp);
        mockBALFeed.setMockUpdatedAt(block.timestamp);
        mockAURAFeed.setMockUpdatedAt(block.timestamp);

        IBaseRewardPool rewarder = IBaseRewardPool(_REWARDERS[1]);
        uint256 earnedBAL = rewarder.earned(address(strategyCBALRETH));
        console2.log("Earned BAL:", earnedBAL);

        uint256 protocolFee = centralRegistry.protocolHarvestFee();
        uint256 netHarvestAmount = (earnedBAL * (WAD - protocolFee)) / WAD;
        console2.log("Protocol fee:", protocolFee);
        console2.log("Net harvest amount:", netHarvestAmount);

        if (netHarvestAmount > 0) {
            console2.log("Proceeding with harvest, netHarvestAmount > 0");

            SwapperLib.Swap[] memory swaps = new SwapperLib.Swap[](1);
            swaps[0].slippage = 0.3e18;
            swaps[0].inputToken = _BAL_ADDRESS;
            swaps[0].inputAmount = netHarvestAmount;
            swaps[0].outputToken = _WETH_ADDRESS;
            swaps[0].target = _UNISWAP_V2_ROUTER;

            address[] memory path = new address[](2);
            path[0] = _BAL_ADDRESS;
            path[1] = _WETH_ADDRESS;

            swaps[0].call = abi.encodeWithSignature(
                "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
                netHarvestAmount,
                0,
                path,
                address(strategyCBALRETH),
                block.timestamp
            );

            console2.log("About to call harvest()");

            vm.startPrank(harvester);
            strategyCBALRETH.harvest(abi.encode(swaps, 1e8));
            vm.stopPrank();
            
            // Wait for vesting period
            uint256 vestingPeriod = 1 days;
            skip(vestingPeriod);
            
            // Update mock feeds
            mockUsdcFeed.setMockUpdatedAt(block.timestamp);
            mockWethFeed.setMockUpdatedAt(block.timestamp);
            mockRethFeed.setMockUpdatedAt(block.timestamp);
            mockBALFeed.setMockUpdatedAt(block.timestamp);
            mockAURAFeed.setMockUpdatedAt(block.timestamp);
            
            // Accrue the vested yield
            strategyCBALRETH.accrueIfNeeded();

            console2.log("Harvest() call completed");
        } else {
            console2.log("Skipping harvest - netHarvestAmount is 0");
        }

        uint256 exchangeRateAfter = strategyCBALRETH.exchangeRate();
    }

    function _setMockFeedsInitial() internal {

        /// STABLECOINS
        mockUsdcFeed = new MockDataFeed(_CHAINLINK_USDC_USD);
        chainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            address(mockUsdcFeed),
            0,
            true
        );
        dualChainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            address(mockUsdcFeed),
            0,
            true
        );

        mockDaiFeed = new MockDataFeed(_CHAINLINK_DAI_USD);
        chainlinkAdaptor.addAsset(_DAI_ADDRESS, address(mockDaiFeed), 0, true);
        dualChainlinkAdaptor.addAsset(
            _DAI_ADDRESS,
            address(mockDaiFeed),
            0,
            true
        );

        /// ETH

        mockWethFeed = new MockDataFeed(_CHAINLINK_ETH_USD);
        chainlinkAdaptor.addAsset(
            _WETH_ADDRESS,
            address(mockWethFeed),
            0,
            true
        );
        dualChainlinkAdaptor.addAsset(
            _WETH_ADDRESS,
            address(mockWethFeed),
            0,
            true
        );

        mockRethFeed = new MockDataFeed(_CHAINLINK_ETH_USD);
        chainlinkAdaptor.addAsset(
            _RETH_ADDRESS,
            address(mockRethFeed),
            0,
            true
        );
        dualChainlinkAdaptor.addAsset(
            _RETH_ADDRESS,
            address(mockRethFeed),
            0,
            true
        );

        /// STETH

        mockStethFeed = new MockDataFeed(_CHAINLINK_ETH_USD);
        chainlinkAdaptor.addAsset(_STETH, address(mockStethFeed), 0, true);
        dualChainlinkAdaptor.addAsset(_STETH, address(mockStethFeed), 0, true);

        oracleManager.addAssetPriceFeed(_STETH, address(chainlinkAdaptor));
        oracleManager.addAssetPriceFeed(_STETH, address(dualChainlinkAdaptor));

        /// BAL
        mockBALFeed = new MockDataFeed(
            0xdF2917806E30300537aEB49A7663062F4d1F2b5F
        );
        mockBALFeed.setMockUpdatedAt(block.timestamp);
        chainlinkAdaptor.addAsset(_BAL_ADDRESS, address(mockBALFeed), 0, true);
        oracleManager.addAssetPriceFeed(
            _BAL_ADDRESS,
            address(chainlinkAdaptor)
        );

        /// AURA
        mockAURAFeed = new MockDataFeed(
            0xdF2917806E30300537aEB49A7663062F4d1F2b5F
        );
        mockAURAFeed.setMockUpdatedAt(block.timestamp);
        chainlinkAdaptor.addAsset(
            _AURA_ADDRESS,
            address(mockAURAFeed),
            0,
            true
        );
        oracleManager.addAssetPriceFeed(
            _AURA_ADDRESS,
            address(chainlinkAdaptor)
        );

        // WBTC

        mockWbtcFeed = new MockV3Aggregator(8, 60000e8, 1e50, 1e6);
        chainlinkAdaptor.addAsset(
            _WBTC_ADDRESS,
            address(mockWbtcFeed),
            0,
            true
        );
        dualChainlinkAdaptor.addAsset(
            _WBTC_ADDRESS,
            address(mockWbtcFeed),
            0,
            true
        );
        oracleManager.addAssetPriceFeed(
            _WBTC_ADDRESS,
            address(chainlinkAdaptor)
        );
        oracleManager.addAssetPriceFeed(
            _WBTC_ADDRESS,
            address(dualChainlinkAdaptor)
        );
    }

    function _refreshMockFeeds() internal {
        mockUsdcFeed.setMockUpdatedAt(block.timestamp);
        mockWethFeed.setMockUpdatedAt(block.timestamp);
        mockRethFeed.setMockUpdatedAt(block.timestamp);
        mockStethFeed.setMockUpdatedAt(block.timestamp);
        mockBALFeed.setMockUpdatedAt(block.timestamp);
        mockAURAFeed.setMockUpdatedAt(block.timestamp);
        mockDaiFeed.setMockUpdatedAt(block.timestamp);
    }
}
