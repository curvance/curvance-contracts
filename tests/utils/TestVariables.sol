// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { MockToken } from "contracts/mocks/MockToken.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";

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
import { AuraPToken } from "contracts/market/token/AuraPToken.sol";
import { DynamicInterestRateModel } from "contracts/market/DynamicInterestRateModel.sol";
import { MarketManager } from "contracts/market/MarketManager.sol";
import { PendleZapper } from "contracts/plugins/market/PendleZapper.sol";
import { VelodromeZapper } from "contracts/plugins/market/VelodromeZapper.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { BalancerStablePoolAdaptor } from "contracts/oracles/adaptors/balancer/BalancerStablePoolAdaptor.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { MockAuraPTokenWithExitFee } from "contracts/mocks/MockAuraPTokenWithExitFee.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IWormhole } from "contracts/interfaces/external/wormhole/IWormhole.sol";

contract TestVariables {
    uint256 internal constant _ONE = 1e18;
    address internal constant _ZERO_ADDRESS = address(0);
    address internal constant _ETH_ADDRESS =
        0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address internal constant _ARB_ADDRESS =
        0x912CE59144191C1204E64559FE8253a0e49E6548;

    address internal _WETH_ADDRESS;
    address internal _USDC_ADDRESS;
    address internal _USDT_ADDRESS;
    address internal _DAI_ADDRESS;
    address internal _WBTC_ADDRESS;
    address internal _RETH_ADDRESS;
    address internal _FRAX_ADDRESS;
    address internal _BAL_WETH_RETH_ADDRESS;
    address internal _CHAINLINK_ETH_USD;
    address internal _CHAINLINK_USDC_USD;
    address internal _CHAINLINK_USDC_ETH;
    address internal _CHAINLINK_DAI_USD;
    address internal _CHAINLINK_DAI_ETH;
    address internal _CHAINLINK_RETH_ETH;
    address internal _CHAINLINK_FRAX_USD;
    address internal _UNISWAP_V2_ROUTER;
    address internal _BAL_VAULT_ADDRESS;
    bytes32 internal _BAL_WETH_RETH_POOLID;
    address internal _AURA_BOOSTER;
    address internal _REWARDER;
    address internal _WORMHOLE_CORE;
    address internal _WORMHOLE_RELAYER;
    address internal _CIRCLE_TOKEN_MESSENGER;
    address internal _CIRCLE_MESSAGE_TRANSMITTER;
    address internal _TOKEN_BRIDGE;

    // Chain ID => Data
    mapping(uint256 => address) internal _WETH_ADDRESSES;
    mapping(uint256 => address) internal _USDC_ADDRESSES;
    mapping(uint256 => address) internal _USDT_ADDRESSES;
    mapping(uint256 => address) internal _DAI_ADDRESSES;
    mapping(uint256 => address) internal _WBTC_ADDRESSES;
    mapping(uint256 => address) internal _RETH_ADDRESSES;
    mapping(uint256 => address) internal _FRAX_ADDRESSES;
    mapping(uint256 => address) internal _BAL_WETH_RETH_ADDRESSES;
    mapping(uint256 => address) internal _CHAINLINK_ETH_USD_FEEDS;
    mapping(uint256 => address) internal _CHAINLINK_USDC_USD_FEEDS;
    mapping(uint256 => address) internal _CHAINLINK_USDC_ETH_FEEDS;
    mapping(uint256 => address) internal _CHAINLINK_DAI_USD_FEEDS;
    mapping(uint256 => address) internal _CHAINLINK_DAI_ETH_FEEDS;
    mapping(uint256 => address) internal _CHAINLINK_RETH_ETH_FEEDS;
    mapping(uint256 => address) internal _CHAINLINK_FRAX_USD_FEEDS;
    mapping(uint256 => address) internal _UNISWAP_V2_ROUTERS;
    mapping(uint256 => address) internal _BAL_VAULT_ADDRESSES;
    mapping(uint256 => bytes32) internal _BAL_WETH_RETH_POOLIDS;
    mapping(uint256 => address) internal _AURA_BOOSTERS;
    mapping(uint256 => address) internal _REWARDERS;
    mapping(uint256 => address) internal _WORMHOLE_CORES;
    mapping(uint256 => address) internal _WORMHOLE_RELAYERS;
    mapping(uint256 => address) internal _CIRCLE_TOKEN_MESSENGERS;
    mapping(uint256 => address) internal _CIRCLE_MESSAGE_TRANSMITTERS;
    mapping(uint256 => address) internal _TOKEN_BRIDGES;

    CVE public cve;
    VeCVE public veCVE;
    RewardManager public rewardManager;
    SimpleRewardZapper public simpleRewardZapper;
    CentralRegistry public centralRegistry;
    FeeManager public feeManager;
    MessagingHub public messagingHub;
    VotingHub public votingHub;
    BalancerStablePoolAdaptor public balRETHAdapter;
    ChainlinkAdaptor public chainlinkAdaptor;
    ChainlinkAdaptor public dualChainlinkAdaptor;
    MarketManager public marketManager;
    OracleManager public oracleManager;
    EToken public eUSDC;
    EToken public eDAI;
    AuraPToken public pBALRETH;
    MockAuraPTokenWithExitFee public pBALRETHWithExitFee;
    IERC20 public usdc;
    IERC20 public dai;
    IERC20 public weth;
    IERC20 public wbtc;
    IERC20 public balRETH;

    MockV3Aggregator public chainlinkUsdcUsd;
    MockV3Aggregator public chainlinkUsdcEth;
    MockV3Aggregator public chainlinkRethEth;
    MockV3Aggregator public chainlinkEthUsd;
    MockV3Aggregator public chainlinkDaiUsd;
    MockV3Aggregator public chainlinkDaiEth;

    address[] public redstoneSigners;
    bytes32[] public redstoneSignerKeys;

    MockToken public rewardToken;
    GaugeManager public gaugeManager;
    PendleZapper public pendleZapper;
    VelodromeZapper public velodromeZapper;

    // Chain ID => Data
    mapping(uint256 => CVE) public cves;
    mapping(uint256 => VeCVE) public veCVEs;
    mapping(uint256 => RewardManager) public rewardManagers;
    mapping(uint256 => SimpleRewardZapper) public simpleRewardZappers;
    mapping(uint256 => CentralRegistry) public centralRegistries;
    mapping(uint256 => FeeManager) public feeManagers;
    mapping(uint256 => MessagingHub) public messagingHubs;
    mapping(uint256 => VotingHub) public votingHubs;
    mapping(uint256 => BalancerStablePoolAdaptor) public balRETHAdapters;
    mapping(uint256 => ChainlinkAdaptor) public chainlinkAdaptors;
    mapping(uint256 => ChainlinkAdaptor) public dualChainlinkAdaptors;
    mapping(uint256 => MarketManager) public marketManagers;
    mapping(uint256 => OracleManager) public oracleManagers;
    mapping(uint256 => EToken) public eUSDCs;
    mapping(uint256 => EToken) public eDAIs;
    mapping(uint256 => AuraPToken) public pBALRETHs;
    mapping(uint256 => MockAuraPTokenWithExitFee) public pBALRETHWithExitFees;

    mapping(uint256 => MockV3Aggregator) public chainlinkUsdcUsds;
    mapping(uint256 => MockV3Aggregator) public chainlinkUsdcEths;
    mapping(uint256 => MockV3Aggregator) public chainlinkRethEths;
    mapping(uint256 => MockV3Aggregator) public chainlinkEthUsds;
    mapping(uint256 => MockV3Aggregator) public chainlinkDaiUsds;
    mapping(uint256 => MockV3Aggregator) public chainlinkDaiEths;

    mapping(uint256 => mapping(address => DynamicInterestRateModel))
        public interestRateModels;

    mapping(uint256 => MockToken) public rewardTokens;
    mapping(uint256 => GaugeManager) public gaugeManagers;
    mapping(uint256 => PendleZapper) public pendleZappers;
    mapping(uint256 => VelodromeZapper) public velodromeZappers;

    address public harvester;
    address public user1 = address(1000001);
    address public user2 = address(1000002);
    address public user3 = address(1000003);
    address public user4 = address(1000004);
    address public liquidator = address(1000005);
    uint256 public voteBoostMultiplier = 12000; // 120%
    uint256 public lockBoostMultiplier = 13000; // 130%
    uint256 public marketInterestFactor = 1000; // 10%

    bytes public response;
    IWormhole.Signature[] public signatures;

    modifier initMainVariables() {
        _initMainVariables();
        _;
    }

    constructor() {
        _initMainnetVariables();
        _initArbitrumVariables();
        _initOptimismVariables();
        _initBaseVariables();
    }

    function _initMainnetVariables() internal {
        uint256 chainId = 1;

        _WETH_ADDRESSES[chainId] = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        _USDC_ADDRESSES[chainId] = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        _USDT_ADDRESSES[chainId] = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
        _DAI_ADDRESSES[chainId] = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
        _WBTC_ADDRESSES[chainId] = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
        _RETH_ADDRESSES[chainId] = 0xae78736Cd615f374D3085123A210448E74Fc6393;
        _FRAX_ADDRESSES[chainId] = 0x853d955aCEf822Db058eb8505911ED77F175b99e;
        _BAL_WETH_RETH_ADDRESSES[
            chainId
        ] = 0x1E19CF2D73a72Ef1332C882F20534B6519Be0276;
        _CHAINLINK_ETH_USD_FEEDS[
            chainId
        ] = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
        _CHAINLINK_USDC_USD_FEEDS[
            chainId
        ] = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
        _CHAINLINK_USDC_ETH_FEEDS[
            chainId
        ] = 0x986b5E1e1755e3C2440e960477f25201B0a8bbD4;
        _CHAINLINK_DAI_USD_FEEDS[
            chainId
        ] = 0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9;
        _CHAINLINK_DAI_ETH_FEEDS[
            chainId
        ] = 0x773616E4d11A78F511299002da57A0a94577F1f4;
        _CHAINLINK_RETH_ETH_FEEDS[
            chainId
        ] = 0x536218f9E9Eb48863970252233c8F271f554C2d0;
        _CHAINLINK_FRAX_USD_FEEDS[
            chainId
        ] = 0xB9E1E3A9feFf48998E45Fa90847ed4D467E8BcfD;
        _UNISWAP_V2_ROUTERS[
            chainId
        ] = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
        _BAL_VAULT_ADDRESSES[
            chainId
        ] = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
        _BAL_WETH_RETH_POOLIDS[
            chainId
        ] = 0x1e19cf2d73a72ef1332c882f20534b6519be0276000200000000000000000112;
        _AURA_BOOSTERS[chainId] = 0xA57b8d98dAE62B26Ec3bcC4a365338157060B234;
        _REWARDERS[chainId] = 0xDd1fE5AD401D4777cE89959b7fa587e569Bf125D;
        _WORMHOLE_CORES[chainId] = 0x98f3c9e6E3fAce36bAAd05FE09d375Ef1464288B;
        _WORMHOLE_RELAYERS[
            chainId
        ] = 0x27428DD2d3DD32A4D7f7C497eAaa23130d894911;
        _CIRCLE_TOKEN_MESSENGERS[
            chainId
        ] = 0xBd3fa81B58Ba92a82136038B25aDec7066af3155;
        _CIRCLE_MESSAGE_TRANSMITTERS[
            chainId
        ] = 0x0a992d191DEeC32aFe36203Ad87D7d289a738F81;
        _TOKEN_BRIDGES[chainId] = 0x3ee18B2214AFF97000D974cf647E7C347E8fa585;
    }

    function _initArbitrumVariables() internal {
        uint256 chainId = 42161;

        _WETH_ADDRESSES[chainId] = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
        _USDC_ADDRESSES[chainId] = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
        _DAI_ADDRESSES[chainId] = 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1;
        _WBTC_ADDRESSES[chainId] = 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f;
        _CHAINLINK_USDC_USD_FEEDS[
            chainId
        ] = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;
        _CHAINLINK_DAI_USD_FEEDS[
            chainId
        ] = 0xc5C8E77B397E531B8EC06BFb0048328B30E9eCfB;
        _CHAINLINK_ETH_USD_FEEDS[
            chainId
        ] = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
        _UNISWAP_V2_ROUTERS[
            chainId
        ] = 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24;
        _WORMHOLE_CORES[chainId] = 0xa5f208e072434bC67592E4C49C1B991BA79BCA46;
        _WORMHOLE_RELAYERS[
            chainId
        ] = 0x27428DD2d3DD32A4D7f7C497eAaa23130d894911;
        _CIRCLE_TOKEN_MESSENGERS[
            chainId
        ] = 0x19330d10D9Cc8751218eaf51E8885D058642E08A;
        _CIRCLE_MESSAGE_TRANSMITTERS[
            chainId
        ] = 0xC30362313FBBA5cf9163F0bb16a0e01f01A896ca;
        _TOKEN_BRIDGES[chainId] = 0x0b2402144Bb366A632D14B83F244D2e0e21bD39c;
    }

    function _initOptimismVariables() internal {
        uint256 chainId = 10;

        _WETH_ADDRESSES[chainId] = 0x4200000000000000000000000000000000000006;
        _USDC_ADDRESSES[chainId] = 0x7F5c764cBc14f9669B88837ca1490cCa17c31607;
        _DAI_ADDRESSES[chainId] = 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1;
        _CHAINLINK_USDC_USD_FEEDS[
            chainId
        ] = 0x16a9FA2FDa030272Ce99B29CF780dFA30361E0f3;
        _CHAINLINK_DAI_USD_FEEDS[
            chainId
        ] = 0x8dBa75e83DA73cc766A7e5a0ee71F656BAb470d6;
        _CHAINLINK_ETH_USD_FEEDS[
            chainId
        ] = 0xb7B9A39CC63f856b90B364911CC324dC46aC1770;
        _UNISWAP_V2_ROUTERS[
            chainId
        ] = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
        _WORMHOLE_CORES[chainId] = 0xEe91C335eab126dF5fDB3797EA9d6aD93aeC9722;
        _WORMHOLE_RELAYERS[
            chainId
        ] = 0x27428DD2d3DD32A4D7f7C497eAaa23130d894911;
        _CIRCLE_TOKEN_MESSENGERS[
            chainId
        ] = 0x2B4069517957735bE00ceE0fadAE88a26365528f;
        _CIRCLE_MESSAGE_TRANSMITTERS[
            chainId
        ] = 0x4D41f22c5a0e5c74090899E5a8Fb597a8842b3e8;
        _TOKEN_BRIDGES[chainId] = 0x1D68124e65faFC907325e3EDbF8c4d84499DAa8b;
    }

    function _initBaseVariables() internal {
        uint256 chainId = 8453;

        _WETH_ADDRESSES[chainId] = 0x4200000000000000000000000000000000000006;
        _USDC_ADDRESSES[chainId] = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
        _DAI_ADDRESSES[chainId] = 0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb;

        _UNISWAP_V2_ROUTERS[
            chainId
        ] = 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24;
    }

    function _initMainConstantVariables() internal {
        uint256 chainId = block.chainid;

        _WETH_ADDRESS = _WETH_ADDRESSES[chainId];
        _USDC_ADDRESS = _USDC_ADDRESSES[chainId];
        _USDT_ADDRESS = _USDT_ADDRESSES[chainId];
        _DAI_ADDRESS = _DAI_ADDRESSES[chainId];
        _WBTC_ADDRESS = _WBTC_ADDRESSES[chainId];
        _RETH_ADDRESS = _RETH_ADDRESSES[chainId];
        _FRAX_ADDRESS = _FRAX_ADDRESSES[chainId];
        _BAL_WETH_RETH_ADDRESS = _BAL_WETH_RETH_ADDRESSES[chainId];
        _CHAINLINK_ETH_USD = _CHAINLINK_ETH_USD_FEEDS[chainId];
        _CHAINLINK_USDC_USD = _CHAINLINK_USDC_USD_FEEDS[chainId];
        _CHAINLINK_USDC_ETH = _CHAINLINK_USDC_ETH_FEEDS[chainId];
        _CHAINLINK_DAI_USD = _CHAINLINK_DAI_USD_FEEDS[chainId];
        _CHAINLINK_DAI_ETH = _CHAINLINK_DAI_ETH_FEEDS[chainId];
        _CHAINLINK_RETH_ETH = _CHAINLINK_RETH_ETH_FEEDS[chainId];
        _CHAINLINK_FRAX_USD = _CHAINLINK_FRAX_USD_FEEDS[chainId];
        _UNISWAP_V2_ROUTER = _UNISWAP_V2_ROUTERS[chainId];
        _BAL_VAULT_ADDRESS = _BAL_VAULT_ADDRESSES[chainId];
        _BAL_WETH_RETH_POOLID = _BAL_WETH_RETH_POOLIDS[chainId];
        _AURA_BOOSTER = _AURA_BOOSTERS[chainId];
        _REWARDER = _REWARDERS[chainId];
        _WORMHOLE_CORE = _WORMHOLE_CORES[chainId];
        _WORMHOLE_RELAYER = _WORMHOLE_RELAYERS[chainId];
        _CIRCLE_TOKEN_MESSENGER = _CIRCLE_TOKEN_MESSENGERS[chainId];
        _CIRCLE_MESSAGE_TRANSMITTER = _CIRCLE_MESSAGE_TRANSMITTERS[chainId];
        _TOKEN_BRIDGE = _TOKEN_BRIDGES[chainId];

        usdc = IERC20(_USDC_ADDRESS);
        dai = IERC20(_DAI_ADDRESS);
        weth = IERC20(_WETH_ADDRESS);
        wbtc = IERC20(_WBTC_ADDRESS);
        balRETH = IERC20(_BAL_WETH_RETH_ADDRESS);
    }

    function _initMainContractVariables() internal {
        uint256 chainId = block.chainid;

        cve = cves[chainId];
        veCVE = veCVEs[chainId];
        rewardManager = rewardManagers[chainId];
        simpleRewardZapper = simpleRewardZappers[chainId];
        centralRegistry = centralRegistries[chainId];
        feeManager = feeManagers[chainId];
        messagingHub = messagingHubs[chainId];
        votingHub = votingHubs[chainId];
        balRETHAdapter = balRETHAdapters[chainId];
        chainlinkAdaptor = chainlinkAdaptors[chainId];
        dualChainlinkAdaptor = dualChainlinkAdaptors[chainId];
        marketManager = marketManagers[chainId];
        oracleManager = oracleManagers[chainId];
        eUSDC = eUSDCs[chainId];
        eDAI = eDAIs[chainId];
        pBALRETH = pBALRETHs[chainId];
        pBALRETHWithExitFee = pBALRETHWithExitFees[chainId];

        chainlinkUsdcUsd = chainlinkUsdcUsds[chainId];
        chainlinkUsdcEth = chainlinkUsdcEths[chainId];
        chainlinkRethEth = chainlinkRethEths[chainId];
        chainlinkEthUsd = chainlinkEthUsds[chainId];
        chainlinkDaiUsd = chainlinkDaiUsds[chainId];
        chainlinkDaiEth = chainlinkDaiEths[chainId];

        rewardToken = rewardTokens[chainId];
        gaugeManager = gaugeManagers[chainId];
        pendleZapper = pendleZappers[chainId];
        velodromeZapper = velodromeZappers[chainId];
    }

    function _initMainVariables() internal {
        _initMainConstantVariables();
        _initMainContractVariables();
    }
}
