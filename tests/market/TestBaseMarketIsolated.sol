// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";
import { TestBase } from "tests/utils/TestBase.sol";

import { CVE } from "contracts/token/CVE.sol";
import { VeCVE } from "contracts/token/VeCVE.sol";
import { RewardManager } from "contracts/architecture/RewardManager.sol";
import { SimpleRewardZapper } from "contracts/plugins/rewards/SimpleRewardZapper.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";
import { FeeManager } from "contracts/architecture/FeeManager.sol";
import { MessagingHub } from "contracts/architecture/MessagingHub.sol";
import { VotingHub } from "contracts/architecture/VotingHub.sol";
import { GaugeManager } from "contracts/architecture/GaugeManager.sol";
import { EToken } from "contracts/market/token/EToken.sol";
import { SimpleCToken } from "contracts/market/token/SimpleCToken.sol";
import { AuraCToken } from "contracts/market/token/AuraCToken.sol";
import { DynamicInterestRateModel } from "contracts/market/DynamicInterestRateModel.sol";
import { PendleZapper } from "contracts/plugins/market/PendleZapper.sol";
import { PendleZapperCalldataChecker } from "contracts/calldata-checker/swap-checker/PendleZapperCalldataChecker.sol";
import { VelodromeZapper } from "contracts/plugins/market/VelodromeZapper.sol";
import { VelodromeZapperCalldataChecker } from "contracts/calldata-checker/swap-checker/VelodromeZapperCalldataChecker.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { IVault } from "contracts/oracles/adaptors/balancer/BalancerBaseAdaptor.sol";
import { BalancerStablePoolAdaptor } from "contracts/oracles/adaptors/balancer/BalancerStablePoolAdaptor.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { MockMessageTransmitter } from "contracts/mocks/MockMessageTransmitter.sol";
import { MockTokenBridgeRelayer } from "contracts/mocks/MockTokenBridgeRelayer.sol";
import { MockAuraCTokenWithExitFee } from "contracts/mocks/MockAuraCTokenWithExitFee.sol";
import { QueryTest } from "tests/utils/QueryTest.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IWormhole } from "contracts/interfaces/external/wormhole/IWormhole.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { AuxiliaryData } from "contracts/indexing/AuxiliaryData.sol";
import { DAOTimelock } from "contracts/architecture/DAOTimelock.sol";

contract TestBaseMarketIsolated is TestBase {
    struct PerChainData {
        uint256 chainId;
        uint256 blockNumber;
        uint64 timestamp;
        address to;
        bytes result;
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

        _deployEUSDC();
        _deployEDAI();

        _deployPUSDC();
        _deployPBALRETH();
        _deployPBALRETHWithExitFee();


        _deployPendleZapper();
        _deployVelodromeZapper();

        _setRedstoneSigners();

        oracleManagers[chainId].addMTokenSupport(address(eUSDC));
        oracleManagers[chainId].addMTokenSupport(address(pBALRETH));
        oracleManagers[chainId].addMTokenSupport(address(pBALRETHWithExitFee));
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
        _deployAuxiliaryData();


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
        // If TokenBridgeRelayer doesn't exist on the address,
        // deploy mock TokenBridgeRelayer on the address.
        // if (_TOKEN_BRIDGE.code.length == 0) {
        //    vm.etch(_TOKEN_BRIDGE, address(new MockTokenBridgeRelayer()).code);
        // }

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
        harvester = makeAddr("harvester");
        centralRegistry.addHarvestPermissions(harvester);

        feeManager = feeManagers[block.chainid] = new FeeManager(
            ICentralRegistry(address(centralRegistry))
        );
        centralRegistry.setFeeManager(address(feeManager));
    }

    function _deployAuxiliaryData() internal initMainVariables {
        auxiliaryData = auxiliaryDatas[block.chainid] = new AuxiliaryData(
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
            marketInterestFactor
        );
    }

    function _deployDynamicInterestRateModel(
        address underlyingToken
    ) internal returns (address) {
        interestRateModels[block.chainid][
            underlyingToken
        ] = new DynamicInterestRateModel(
            ICentralRegistry(address(centralRegistry)),
            1000, // baseRatePerYear
            1000, // vertexRatePerYear
            5000, // vertexUtilizationStart
            4 hours, // adjustmentRate
            5000, // adjustmentVelocity
            100000000, // 1000x maximum vertex multiplier
            100 // decayRate
        );

        return address(interestRateModels[block.chainid][underlyingToken]);
    }

    function _deployEUSDC() internal initMainVariables returns (EToken) {
        eUSDC = eUSDCs[block.chainid] = _deployEToken(_USDC_ADDRESS);
        return eUSDC;
    }

    function _deployEDAI() internal initMainVariables returns (EToken) {
        eDAI = eDAIs[block.chainid] = _deployEToken(_DAI_ADDRESS);
        return eDAI;
    }

    function _deployEToken(
        address token
    ) internal virtual initMainVariables returns (EToken) {
        EToken eToken = new EToken(
            ICentralRegistry(address(centralRegistry)),
            token,
            address(marketManagerIsolated),
            _deployDynamicInterestRateModel(token)
        );

        interestRateModels[block.chainid][token].setLinkedToken(
            address(eToken)
        );

        return eToken;
    }

    function _deployPUSDC()
        internal
        initMainVariables
        returns (SimpleCToken) {
        pUSDC = new SimpleCToken(
            ICentralRegistry(address(centralRegistry)),
            usdc,
            address(marketManagerIsolated)
        );
        return pUSDC;
    }

    function _deployPBALRETH()
        internal
        initMainVariables
        returns (AuraCToken)
    {
        pBALRETH = pBALRETHs[block.chainid] = new AuraCToken(
            ICentralRegistry(address(centralRegistry)),
            balRETH,
            address(marketManagerIsolated),
            109,
            _REWARDER,
            _AURA_BOOSTER,
            1 days
        );
        return pBALRETH;
    }

    function _deployPBALRETHWithExitFee()
        internal
        initMainVariables
        returns (MockAuraCTokenWithExitFee)
    {
        pBALRETHWithExitFee = pBALRETHWithExitFees[
            block.chainid
        ] = new MockAuraCTokenWithExitFee(
            ICentralRegistry(address(centralRegistry)),
            balRETH,
            address(marketManagerIsolated),
            109,
            _REWARDER,
            _AURA_BOOSTER,
            200,
            1 days
        );
        return pBALRETHWithExitFee;
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

    function _setPBALRETHCollateralCaps(
        uint256 cap
    ) internal initMainVariables {
        marketManagerIsolated.updatePositionToken(
            7000,    // collRatio 70%
            4000,    // collReqSoft 40%
            3000,    // collReqHard 25%
            1000,    // liqIncBase 10%
            1500,    // liqIncHard 15%
            500,     // liqIncMin 5%
            2000,    // liqIncMax 20%
            2000,    // minEffectiveCFactor 20%
            5000,    // maxEffectiveCFactor 50%
            2000     // baseCFactor 20%
        );
        address[] memory tokens = new address[](1);
        tokens[0] = address(pBALRETH);
        uint256[] memory caps = new uint256[](1);
        caps[0] = cap;
        marketManagerIsolated.setCollateralCaps(tokens, caps);
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
}
