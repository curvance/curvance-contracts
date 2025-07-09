// // SPDX-License-Identifier: UNLICENSED
// pragma solidity ^0.8.19;

// import { IHevm } from "./helpers/Hevm.sol";
// import { PropertiesAsserts } from "tests/fuzzing/helpers/PropertiesHelper.sol";
// import { ErrorConstants } from "tests/fuzzing/helpers/ErrorConstants.sol";
// import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";

// import { MockToken } from "contracts/mocks/MockToken.sol";
// import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
// import { MockSimpleCToken } from "contracts/mocks/MockSimpleCToken.sol";
// import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";

// import { CVE } from "contracts/token/CVE.sol";
// import { VeCVE } from "contracts/token/VeCVE.sol";
// import { RewardManager } from "contracts/architecture/RewardManager.sol";
// import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";
// import { FeeManager } from "contracts/architecture/FeeManager.sol";
// import { MessagingHub } from "contracts/architecture/MessagingHub.sol";
// import { GaugeManager } from "contracts/architecture/GaugeManager.sol";
// import { EToken } from "contracts/market/token/EToken.sol";
// import { AuraCToken } from "contracts/market/token/AuraCToken.sol";
// import { DynamicInterestRateModel } from "contracts/market/DynamicInterestRateModel.sol";
// 
// import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
// import { IVault } from "contracts/oracles/adaptors/balancer/BalancerBaseAdaptor.sol";
// import { BalancerStablePoolAdaptor } from "contracts/oracles/adaptors/balancer/BalancerStablePoolAdaptor.sol";
// import { OracleManager } from "contracts/oracles/OracleManager.sol";
// import { ERC20 } from "contracts/libraries/external/ERC20.sol";

// import { IERC20 } from "contracts/interfaces/IERC20.sol";
// import { ICToken } from "contracts/interfaces/ICToken.sol";
// import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
// import { ERC165Checker } from "contracts/libraries/external/ERC165Checker.sol";

// // import { AuxiliaryDataDeployer } from "./deployers/AuxiliaryDataDeployer.s.sol";

// contract StatefulBaseMarket is PropertiesAsserts, ErrorConstants {
//     IHevm constant hevm = IHevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
//     address internal _WETH_ADDRESS;
//     address internal _USDC_ADDRESS;
//     address internal _RETH_ADDRESS;
//     address internal _BAL_WETH_RETH_ADDRESS;
//     address internal _DAI_ADDRESS;

//     CVE public cve;
//     VeCVE public veCVE;
//     RewardManager public rewardManager;
//     CentralRegistry public centralRegistry;
//     FeeManager public feeManager;
//     MessagingHub public messagingHub;
//     ChainlinkAdaptor public chainlinkAdaptor;
//     ChainlinkAdaptor public dualChainlinkAdaptor;
//     DynamicInterestRateModel public interestRateModel;
//     MarketManager public marketManager;
//     OracleManager public oracleManager;

//     AuraCToken public pBALRETH;

//     EToken public eUSDC;
//     EToken public eDAI;

//     MockSimpleCToken public pDAI;
//     MockSimpleCToken public pUSDC;
//     MockToken public usdc;
//     MockToken public dai;
//     MockToken public WETH;
//     MockToken public balRETH;

//     MockV3Aggregator public chainlinkUsdcUsd;
//     MockV3Aggregator public chainlinkUsdcEth;
//     MockV3Aggregator public chainlinkRethEth;
//     MockV3Aggregator public chainlinkEthUsd;
//     MockV3Aggregator public chainlinkDaiUsd;
//     MockV3Aggregator public chainlinkDaiEth;

//     MockToken public rewardToken;
//     GaugeManager public gaugeManager;

//     address public harvester;
//     uint256 public voteBoostMultiplier = 10001; // 110%
//     uint256 public lockBoostMultiplier = 10001; // 110%
//     uint256 public marketInterestFactor = 1; // 10%

//     mapping(address => uint256) public postedCollateralAt;

//     // the maximum collateral cap for a specific cToken
//     mapping(address => uint256) public maxCollateralCap;

//     constructor() {
//         // _fork(18031848);
//         WETH = new MockToken("WETH", "WETH", 18);
//         _WETH_ADDRESS = address(WETH);
//         usdc = new MockToken("USDC", "USDC", 6);
//         _USDC_ADDRESS = address(usdc);
//         dai = new MockToken("DAI", "DAI", 18);
//         _DAI_ADDRESS = address(dai);
//         balRETH = new MockToken("balWethReth", "balWethReth", 18);
//         _BAL_WETH_RETH_ADDRESS = address(balRETH);

//         emit LogString("DEPLOYED: centralRegistry");
//         _deployCentralRegistry();
//         emit LogString("DEPLOYED: CVE");
//         _deployCVE();
//         emit LogString("DEPLOYED: Reward Manager");
//         _deployRewardManager();
//         emit LogString("DEPLOYED: MessagingHub");
//         _deployMessagingHub();
//         emit LogString("DEPLOYED: FeeManager");
//         _deployFeeManager();

//         emit LogString("DEPLOYED: VECVE");
//         _deployVeCVE();
//         emit LogString("DEPLOYED: Mock Chainlink V3 Aggregator");
//         chainlinkEthUsd = new MockV3Aggregator(8, 1500e8, 1e50, 1e6);
//         emit LogString("DEPLOYED: OracleManager");
//         _deployOracleManager();
//         _deployChainlinkAdaptors();
//         emit LogString("DEPLOYED: GaugePool");
//         _deployGaugeManager();
//         emit LogString("DEPLOYED: MarketManager");
//         _deployMarketManager();
//         emit LogString("DEPLOYED: DynamicInterestRateModel");
//         _deployDynamicInterestRateModel();
//         emit LogString("DEPLOYED: EUSDC");
//         _deployBorrowableCUSDC();
//         emit LogString("DEPLOYED: EDAI");
//         _deployBorrowableCDAI();
//         emit LogString("DEPLOYED: PUSDC");
//         _deployPUSDC();
//         emit LogString("DEPLOYED: DAI");
//         _deployPDAI();
//         // emit LogString("DEPLOYED: ZAPPER");
//     }

//     function _deployCentralRegistry() internal {
//         centralRegistry = new CentralRegistry(
//             address(0x0000000000000000000000000000000000020000),
//             address(this),
//             address(this),
//             0,
//             address(0),
//             address(usdc)
//         );
//         centralRegistry.transferEmergencyCouncil(address(this));
//         centralRegistry.setLockBoostMultiplier(lockBoostMultiplier);
//     }

//     function _deployCVE() internal {
//         cve = new CVE(
//             ICentralRegistry(address(centralRegistry)),
//             address(this)
//         );
//         centralRegistry.setCVE(address(cve));
//     }

//     function _deployRewardManager() internal {
//         rewardManager = new RewardManager(
//             ICentralRegistry(address(centralRegistry))
//         );
//         centralRegistry.setRewardManager(address(rewardManager));
//     }

//     function _deployVeCVE() internal {
//         veCVE = new VeCVE(ICentralRegistry(address(centralRegistry)));
//         centralRegistry.setVeCVE(address(veCVE));
//         centralRegistry.setVoteBoostMultiplier(voteBoostMultiplier);
//         rewardManager.startRewardManager();
//     }

//     function _deployOracleManager() internal {
//         oracleManager = new OracleManager(
//             ICentralRegistry(address(centralRegistry))
//         );

//         centralRegistry.setOracleManager(address(oracleManager));
//     }

//     function _deployMessagingHub() internal {
//         messagingHub = new MessagingHub(
//             ICentralRegistry(address(centralRegistry))
//         );
//         centralRegistry.setMessagingHub(address(messagingHub));
//     }

//     function _deployFeeManager() internal {
//         // harvester = makeAddr("harvester");
//         harvester = address(this);
//         centralRegistry.addHarvestPermissions(harvester);

//         emit LogUint256("woowowo", 0);
//         feeManager = new FeeManager(
//             ICentralRegistry(address(centralRegistry))
//         );
//         centralRegistry.setFeeManager(address(feeManager));
//     }

//     int192 public constant MIN_ORACLE_ANSWER = 1e6;
//     int192 public constant MAX_USDC_ANSWER = 1e11;
//     int192 public constant MAX_DAI_ANSWER = 1e50;

//     function _deployChainlinkAdaptors() internal {
//         // TODO: These numbers should be pulled into const variables
//         // setup chainlink usdcUdc with 8 deciamsl, starting price = 1e8, maxAnswer = 1e11, minAnswer = 1e6
//         chainlinkUsdcUsd = new MockV3Aggregator(
//             8,
//             1e8,
//             MAX_USDC_ANSWER,
//             MIN_ORACLE_ANSWER
//         );
//         // setup chainlink daiUSD with 8 decimals, starting price = 1e8, maxAnswer = 1e50, minAnswer = 1e6
//         chainlinkDaiUsd = new MockV3Aggregator(
//             8,
//             1e8,
//             MAX_DAI_ANSWER,
//             MIN_ORACLE_ANSWER
//         );
//         chainlinkUsdcEth = new MockV3Aggregator(18, 1e18, 1e24, 1e13);
//         chainlinkRethEth = new MockV3Aggregator(18, 1e18, 1e24, 1e13);
//         chainlinkDaiEth = new MockV3Aggregator(18, 1e18, 1e24, 1e13);

//         chainlinkAdaptor = new ChainlinkAdaptor(
//             ICentralRegistry(address(centralRegistry))
//         );
//         chainlinkAdaptor.addAsset(
//             _WETH_ADDRESS,
//             address(chainlinkEthUsd),
//             0,
//             true
//         );
//         chainlinkAdaptor.addAsset(
//             _USDC_ADDRESS,
//             address(chainlinkUsdcUsd),
//             0,
//             true
//         );
//         chainlinkAdaptor.addAsset(
//             _USDC_ADDRESS,
//             address(chainlinkUsdcEth),
//             0,
//             false
//         );
//         chainlinkAdaptor.addAsset(
//             _DAI_ADDRESS,
//             address(chainlinkDaiUsd),
//             0,
//             true
//         );
//         chainlinkAdaptor.addAsset(
//             _DAI_ADDRESS,
//             address(chainlinkDaiEth),
//             0,
//             false
//         );
//         chainlinkAdaptor.addAsset(
//             _RETH_ADDRESS,
//             address(chainlinkRethEth),
//             0,
//             false
//         );

//         oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));
//         oracleManager.addAssetPriceFeed(
//             _WETH_ADDRESS,
//             address(chainlinkAdaptor)
//         );
//         oracleManager.addAssetPriceFeed(
//             _USDC_ADDRESS,
//             address(chainlinkAdaptor)
//         );
//         oracleManager.addAssetPriceFeed(
//             _DAI_ADDRESS,
//             address(chainlinkAdaptor)
//         );
//         oracleManager.addAssetPriceFeed(
//             _RETH_ADDRESS,
//             address(chainlinkAdaptor)
//         );

//         dualChainlinkAdaptor = new ChainlinkAdaptor(
//             ICentralRegistry(address(centralRegistry))
//         );

//         dualChainlinkAdaptor.addAsset(
//             _WETH_ADDRESS,
//             address(chainlinkEthUsd),
//             0,
//             true
//         );

//         dualChainlinkAdaptor.addAsset(
//             _USDC_ADDRESS,
//             address(chainlinkUsdcUsd),
//             0,
//             true
//         );

//         dualChainlinkAdaptor.addAsset(
//             _USDC_ADDRESS,
//             address(chainlinkUsdcEth),
//             0,
//             false
//         );
//         dualChainlinkAdaptor.addAsset(
//             _DAI_ADDRESS,
//             address(chainlinkDaiUsd),
//             0,
//             true
//         );
//         dualChainlinkAdaptor.addAsset(
//             _DAI_ADDRESS,
//             address(chainlinkDaiEth),
//             0,
//             false
//         );
//         dualChainlinkAdaptor.addAsset(
//             _RETH_ADDRESS,
//             address(chainlinkRethEth),
//             0,
//             false
//         );
//         oracleManager.addApprovedAdaptor(address(dualChainlinkAdaptor));
//         oracleManager.addAssetPriceFeed(
//             _WETH_ADDRESS,
//             address(dualChainlinkAdaptor)
//         );
//         oracleManager.addAssetPriceFeed(
//             _USDC_ADDRESS,
//             address(dualChainlinkAdaptor)
//         );
//         oracleManager.addAssetPriceFeed(
//             _DAI_ADDRESS,
//             address(dualChainlinkAdaptor)
//         );
//         oracleManager.addAssetPriceFeed(
//             _RETH_ADDRESS,
//             address(dualChainlinkAdaptor)
//         );
//     }

//     function _deployGaugeManager() internal {
//         gaugeManager = new GaugeManager(
//             ICentralRegistry(address(centralRegistry))
//         );
//         centralRegistry.addLockingPermissions(address(gaugeManager));

//         // Additional logic for partner gauge pool fuzzing logic
//         // partnerGaugePool = new PartnerGaugePool(
//         //     address(gaugeManager),
//         //     address(usdc),
//         //     ICentralRegistry(address(centralRegistry))
//         // );
//         // gaugeManager.addPartnerGauge(address(partnerGaugePool));
//     }

//     function _deployMarketManager() internal {
//         marketManager = new MarketManager(
//             ICentralRegistry(address(centralRegistry))
//         );
//         centralRegistry.addMarketManager(
//             address(marketManager),
//             marketInterestFactor
//         );
//     }

//     function _deployDynamicInterestRateModel() internal {
//         interestRateModel = new DynamicInterestRateModel(
//             ICentralRegistry(address(centralRegistry)),
//             1000, // baseRatePerYear
//             1000, // vertexRatePerYear
//             5000, // vertexUtilizationStart
//             12 hours, // adjustmentRate
//             5000, // adjustmentVelocity
//             100000000, // 1000x maximum vertex multiplier
//             100 // decayRate
//         );
//     }

//     function _deployBorrowableCUSDC() internal returns (EToken) {
//         eUSDC = _deployBorrowableCToken(_USDC_ADDRESS);
//         return eUSDC;
//     }

//     function _deployBorrowableCDAI() internal returns (EToken) {
//         eDAI = _deployBorrowableCToken(_DAI_ADDRESS);
//         return eDAI;
//     }

//     function _deployPUSDC() internal returns (MockSimpleCToken) {
//         pUSDC = new MockSimpleCToken(
//             ICentralRegistry(address(centralRegistry)),
//             address(usdc),
//             address(marketManager)
//         );
//         return pUSDC;
//     }

//     function _deployPDAI() internal returns (MockSimpleCToken) {
//         pDAI = new MockSimpleCToken(
//             ICentralRegistry(address(centralRegistry)),
//             address(dai),
//             address(marketManager)
//         );
//         return pDAI;
//     }

//     function _deployBorrowableCToken(address token) internal returns (EToken) {
//         return
//             new EToken(
//                 ICentralRegistry(address(centralRegistry)),
//                 token,
//                 address(marketManager),
//                 address(interestRateModel)
//             );
//     }

//     function _addSinglePriceFeed() internal {
//         oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));
//         oracleManager.addAssetPriceFeed(
//             _USDC_ADDRESS,
//             address(chainlinkAdaptor)
//         );
//     }

//     function _addDualPriceFeed() internal {
//         _addSinglePriceFeed();

//         oracleManager.addApprovedAdaptor(address(dualChainlinkAdaptor));
//         oracleManager.addAssetPriceFeed(
//             _USDC_ADDRESS,
//             address(dualChainlinkAdaptor)
//         );
//     }

//     function _mintAndApprove(
//         address underlyingAddress,
//         address cToken,
//         uint256 amount
//     ) internal returns (bool) {
//         // mint ME enough tokens to cover deposit
//         try MockToken(underlyingAddress).mint(amount) {} catch (
//             bytes memory revertData
//         ) {
//             uint256 underlyingSupply = MockToken(underlyingAddress)
//                 .totalSupply();
//             uint256 cTokenSupply = MockToken(underlyingAddress).totalSupply();
//             uint256 errorSelector = extractErrorSelector(revertData);

//             unchecked {
//                 if (
//                     doesOverflow(
//                         underlyingSupply + amount,
//                         underlyingSupply
//                     ) || doesOverflow(cTokenSupply + amount, cTokenSupply)
//                 ) {
//                     assertWithMsg(
//                         errorSelector == token_total_supply_overflow,
//                         "CToken underlying - mint underlying amount should succeed"
//                     );
//                     return false;
//                 } else {
//                     assertWithMsg(
//                         false,
//                         "CToken underlying - mint underlying amount should succeed"
//                     );
//                 }
//             }
//         }
//         // approve sufficient underlying tokens prior to calling deposit
//         try MockToken(underlyingAddress).approve(cToken, amount) {} catch (
//             bytes memory revertData
//         ) {
//             uint256 currentAllowance = MockToken(underlyingAddress).allowance(
//                 msg.sender,
//                 cToken
//             );

//             uint256 errorSelector = extractErrorSelector(revertData);
//             unchecked {
//                 if (
//                     doesOverflow(currentAllowance + amount, currentAllowance)
//                 ) {
//                     assertEq(
//                         errorSelector,
//                         token_allowance_overflow,
//                         "MTOKEN underlying - revert expected when underflow"
//                     );
//                     return false;
//                 } else {
//                     assertWithMsg(
//                         false,
//                         "MTOKEN underlying - approve underlying amount should succeed"
//                     );
//                 }
//             }
//         }
//         return true;
//     }

//     MockDataFeed public mockUsdcFeed;
//     MockDataFeed public mockDaiFeed;
//     bool public feedsSetup;
//     uint256 public lastRoundUpdate;

//     function setUpFeeds() public {
//         require(centralRegistry.hasElevatedPermissions(address(this)));
//         require(gaugeManager.gaugeStartTime() < block.timestamp);
//         // use mock pricing for testing
//         // StatefulBaseMarket - chainlinkAdaptor - usdc, dai
//         mockUsdcFeed = new MockDataFeed(address(chainlinkUsdcUsd));
//         chainlinkAdaptor.addAsset(
//             address(pUSDC),
//             address(mockUsdcFeed),
//             0,
//             true
//         );
//         chainlinkAdaptor.addAsset(
//             address(borrowableCUSDC),
//             address(mockUsdcFeed),
//             0,
//             true
//         );

//         // dualChainlinkAdaptor.addAsset(
//         //     address(pUSDC),
//         //     address(mockUsdcFeed),
//         //     0,
//         //     true
//         // );
//         mockDaiFeed = new MockDataFeed(address(chainlinkDaiUsd));
//         chainlinkAdaptor.addAsset(
//             address(pDAI),
//             address(mockDaiFeed),
//             0,
//             true
//         );
//         chainlinkAdaptor.addAsset(
//             address(borrowableCDAI),
//             address(mockDaiFeed),
//             0,
//             true
//         );
//         // dualChainlinkAdaptor.addAsset(
//         //     address(pDAI),
//         //     address(mockDaiFeed),
//         //     0,
//         //     true
//         // );
//         _setPriceToDefault();
//         emit LogUint256("set price to default", 1e8);
//         chainlinkUsdcUsd.updateRoundData(
//             0,
//             1e8,
//             block.timestamp,
//             block.timestamp
//         );
//         chainlinkDaiUsd.updateRoundData(
//             0,
//             1e8,
//             block.timestamp,
//             block.timestamp
//         );
//         emit LogString("DEPLOYED: Adding pDAI to router");
//         oracleManager.addCTokenSupport(address(pDAI));
//         emit LogString("DEPLOYED: Adding pUSDC to router");
//         oracleManager.addCTokenSupport(address(pUSDC));
//         oracleManager.addCTokenSupport(address(borrowableCDAI));
//         oracleManager.addCTokenSupport(address(borrowableCUSDC));
//         feedsSetup = true;
//         lastRoundUpdate = block.timestamp;
//     }

//     // If the price is stale, update the round data and update lastRoundUpdate
//     function _check_price_feed() internal {
//         // if lastRoundUpdate timestamp is stale
//         if (lastRoundUpdate > block.timestamp) {
//             lastRoundUpdate = block.timestamp;
//         }
//         if (
//             block.timestamp - chainlinkUsdcUsd.latestTimestamp() > 24 hours ||
//             block.timestamp - chainlinkDaiUsd.latestTimestamp() > 24 hours
//         ) {
//             // TODO: Change this to a loop to loop over marketManager.assetsOf()
//             // Save a mapping of assets -> chainlink oracle
//             // call updateRoundData on each oracle
//             chainlinkUsdcUsd.updateRoundData(
//                 0,
//                 1e8,
//                 block.timestamp,
//                 block.timestamp
//             );
//             chainlinkDaiUsd.updateRoundData(
//                 0,
//                 1e8,
//                 block.timestamp,
//                 block.timestamp
//             );
//         }
//         _setPriceToDefault();
//         lastRoundUpdate = block.timestamp;
//     }

//     function _setPriceToDefault() private {
//         mockUsdcFeed.setMockUpdatedAt(block.timestamp);
//         mockDaiFeed.setMockUpdatedAt(block.timestamp);
//         mockUsdcFeed.setMockAnswer(1e8);
//         mockDaiFeed.setMockAnswer(1e8);
//     }

//     function _isSupportedEToken(address eToken) internal view {
//         require(eToken == address(borrowableCUSDC) || eToken == address(borrowableCDAI));
//         require(marketManager.isListed(eToken));
//     }

//     function _isSupportedPToken(address cToken) internal view {
//         require(cToken == address(pUSDC) || cToken == address(pDAI));
//         require(marketManager.isListed(cToken));
//     }

//     function _getLiquidityDeficit(
//         address account,
//         address cToken,
//         uint256 redeecTokens,
//         uint256 amount
//     ) internal view returns (uint256) {
//         (, uint256 liquidityDeficit, ) = _getHypotheticalLiquidityOf(
//             account,
//             cToken,
//             redeecTokens,
//             amount
//         );
//         return liquidityDeficit;
//     }

//     function _getHypotheticalLiquidityOf(
//         address account,
//         address cToken,
//         uint256 redeecTokens,
//         uint256 amount
//     ) internal view returns (uint256, uint256, bool[] memory) {
//         (
//             uint256 accountLiquidity,
//             uint256 liquidityDeficit,
//             bool[] memory closePositions
//         ) = marketManager.hypotheticalLiquidityOf(
//                 account,
//                 cToken,
//                 redeecTokens,
//                 amount
//             );
//         return (accountLiquidity, liquidityDeficit, closePositions);
//     }

//     function _hasPosition(address cToken) internal view returns (bool) {
//         (bool hasPosition, , ) = marketManager.tokenDataOf(
//             address(this),
//             cToken
//         );
//         return hasPosition;
//     }

//     function _collateralPostedFor(
//         address cToken
//     ) internal view returns (uint256) {
//         (, , uint256 collateralPosted) = marketManager.tokenDataOf(
//             address(this),
//             cToken
//         );
//         return collateralPosted;
//     }

//     function _getCooldownTimestampFor() internal view returns (uint256) {
//         uint256 downtime = marketManager.accountAssets(address(this));
//         return downtime;
//     }
// }
