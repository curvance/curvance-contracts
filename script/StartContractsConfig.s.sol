// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import { CVE } from "contracts/token/CVE.sol";
import { VeCVE } from "contracts/token/VeCVE.sol";
import { RewardManager } from "contracts/architecture/RewardManager.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IMToken } from "contracts/interfaces/IMToken.sol";

import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { DynamicInterestRateModel } from "contracts/market/DynamicInterestRateModel.sol";
import { EToken } from "contracts/market/token/EToken.sol";
import { MockToken } from "contracts/mocks/MockToken.sol";
import { TestnetToken } from "contracts/mocks/TestnetToken.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { SimplePToken } from "contracts/market/token/SimplePToken.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { DeployConfiguration } from "./utils/DeployConfiguration.sol";
import { RewardsData } from "contracts/interfaces/IRewardManager.sol";
import { Faucet } from "contracts/testnet/Faucet.sol";
import { RedstoneCoreAdaptor } from "contracts/oracles/adaptors/redstone/RedstoneCoreAdaptor.sol";
import { SimpleZapperDeployer } from "./deployers/SimpleZapperDeployer.s.sol";
import { OogaBoogaDeployer } from "./deployers/OogaBoogaDeployer.s.sol";
import { SimplePositionManagerDeployer } from "./deployers/SimplePositionManagerDeployer.s.sol";

contract StartContractsConfig is
    Script,
    DeployConfiguration,
    SimpleZapperDeployer,
    OogaBoogaDeployer,
    SimplePositionManagerDeployer
{
    struct ETokenInterestRateParam {
        uint256 adjustmentRate;
        uint256 adjustmentVelocity;
        uint256 baseRatePerYear;
        uint256 decayRate;
        uint256 vertexMultiplierMax;
        uint256 vertexRatePerYear;
        uint256 vertexUtilizationStart;
    }

    struct ETokenParam {
        address asset;
        address chainlinkEth;
        address chainlinkUsd;
        ETokenInterestRateParam interestRateParam;
    }

    struct PTokenParam {
        address asset;
        address chainlinkEth;
        address chainlinkUsd;
    }

    struct MarketTokenDeploy {
        string name;
        address token;
        address chainlinkEthAggregator;
        address chainlinkUsdAggregator;
    }

    bool public is_movement = false;
    bool public is_berachain = false;

    function _is_testnet(string memory network) internal pure returns (bool) {
        bytes32 network_hash = keccak256(abi.encodePacked(network));

        return
            network_hash == keccak256(abi.encodePacked("sepolia")) ||
            network_hash == keccak256(abi.encodePacked("arb_sepolia")) ||
            network_hash == keccak256(abi.encodePacked("bartio")) ||
            network_hash == keccak256(abi.encodePacked("localhost")) ||
            network_hash == keccak256(abi.encodePacked("movement"));
    }

    function _after_deploy_config(string memory network) internal {
        bytes32 network_hash = keccak256(abi.encodePacked(network));
        if (network_hash == keccak256(abi.encodePacked("bartio"))) {
            is_berachain = true;
            _deployOogaBoogaCallDataChecker();
        }

        if (network_hash == keccak256(abi.encodePacked("movement"))) {
            is_movement = true;
        }

        _startRewardManager();

        if (_is_testnet(network)) {
            _configTestnet();
        }
    }

    function getRedstoneApiPayload(
        // Comma separated list of token symbols (e.g. "ETH,USDC") -- Or a single token symbol: "ETH"
        string memory tokenSymbols
    ) public returns (bytes memory) {
        string[] memory args = new string[](3);
        args[0] = "node";
        args[1] = "getRedstonePayloadFromAPI.js";
        args[2] = tokenSymbols;

        return vm.ffi(args);
    }

    function _startRewardManager() internal {
        address centralRegistry = _getDeployedContract("centralRegistry");
        console.log("centralRegistry =", centralRegistry);
        address payable rewardManager = payable(
            _getDeployedContract("rewardManager")
        );
        console.log("rewardManager =", rewardManager);

        require(centralRegistry != address(0), "Set the centralRegistry!");
        require(
            RewardManager(rewardManager).rewardManagerStarted() != 2,
            "Reward Manager already started!"
        );
        require(
            CentralRegistry(centralRegistry).veCVE() != address(0),
            "Set veCVE!"
        );
        require(
            RewardManager(rewardManager).rewardManagerStarted() != 2,
            "Reward Manager already started!"
        );
        require(
            CentralRegistry(centralRegistry).veCVE() != address(0),
            "Set veCVE!"
        );

        RewardManager(rewardManager).startRewardManager();
        console.log("startRewardManager");
    }

    function _configTestnet() internal {
        CentralRegistry centralRegistry = CentralRegistry(
            _getDeployedContract("centralRegistry")
        );
        ICentralRegistry icr = ICentralRegistry(address(centralRegistry));

        // Create chainlink adaptor
        ChainlinkAdaptor chainlinkAdaptor = new ChainlinkAdaptor(icr);
        _saveDeployedContracts("chainlinkAdaptor", address(chainlinkAdaptor));

        centralRegistry.setEarlyUnlockPenaltyMultiplier(8000);
        _createTestMarkets();
        _createRealTestMarkets();
        _loadFaucet();

        // Lock 25%
        // address deployer = vm.addr(vm.envUint("PRIVATE_KEY"));
        // CVE cve = CVE(_getDeployedContract("cve"));
        // VeCVE veCVE = VeCVE(centralRegistry.veCVE());
        // uint256 lockAmount = cve.balanceOf(deployer) / 4;
        // cve.approve(address(veCVE), lockAmount);
        // RewardsData memory rewardsData;
        // veCVE.createLock(lockAmount, true, rewardsData, "", 0);
    }

    function _deployMockTokens() internal {
        if (!is_berachain && !is_movement) {
            address m_eth = address(new TestnetToken("mETH", "mETH", 18));
            address m_usd = address(new TestnetToken("mUSD", "mUSD", 18));
            address mk_usd = address(
                new TestnetToken("Prisma mkUSD", "mkUSD", 18)
            );

            _saveDeployedContracts("mETH", m_eth);
            _saveDeployedContracts("mUSD", m_usd);
            _saveDeployedContracts("mkUSD", mk_usd);
        }

        address l_usd = address(
            new TestnetToken("LUSD Stablecoin", "LUSD", 18)
        );
        address dai = address(new TestnetToken("Dai Stablecoin", "DAI", 18));
        address sweth = address(
            new TestnetToken("Swell Ethereum", "SWETH", 18)
        );
        address usdc = address(new TestnetToken("USD Coin", "USDC", 6));
        address wbtc = address(new TestnetToken("Wrapped Bitcoin", "WBTC", 8));

        _saveDeployedContracts("LUSD", l_usd);
        _saveDeployedContracts("SWETH", sweth);
        _saveDeployedContracts("WBTC", wbtc);
        _saveDeployedContracts("USDC", usdc);
        _saveDeployedContracts("DAI", dai);

        // Create faucet for tokens
        address faucet = address(new Faucet());
        _saveDeployedContracts("faucet", faucet);
    }

    function _createRealTestMarkets() internal {
        ICentralRegistry cr = ICentralRegistry(
            _getDeployedContract("centralRegistry")
        );

        address l_usd = _getDeployedContract("LUSD");
        address sweth = _getDeployedContract("SWETH");

        address chainlinkUsdcFeedInUsd = _readConfigAddress(
            ".oracleManager.chainlinkUsd"
        );
        address chainlinkEthFeedInUsd = _readConfigAddress(
            ".oracleManager.chainlinkEthUsd"
        );

        if (!is_berachain && !is_movement) {
            address m_eth = _getDeployedContract("mETH");
            address m_usd = _getDeployedContract("mUSD");

            MarketManagerIsolated thirdMarket = _createMarket("thirdTestMarket", cr);
            _configureMarket(
                thirdMarket,
                cr,
                MarketTokenDeploy(
                    "PToken-mETH",
                    m_eth,
                    address(0),
                    chainlinkEthFeedInUsd
                ),
                MarketTokenDeploy(
                    "EToken-mUSD",
                    m_usd,
                    address(0),
                    chainlinkUsdcFeedInUsd
                ),
            1000000,
            700000
            );
        }

        MarketManagerIsolated fourthMarket = _createMarket("fourthTestMarket", cr);
        _configureMarket(
            fourthMarket,
            cr,
            MarketTokenDeploy(
                "PToken-LUSD",
                l_usd,
                address(0),
                chainlinkUsdcFeedInUsd
            ),
            MarketTokenDeploy(
                "EToken-SWETH",
                sweth,
                address(0),
                chainlinkUsdcFeedInUsd
            ),
            1000000,
            700000
        );
    }

    function _createTestMarkets() internal {
        ICentralRegistry cr = ICentralRegistry(
            _getDeployedContract("centralRegistry")
        );

        address usdc = _getDeployedContract("USDC");
        address wbtc = _getDeployedContract("WBTC");

        MarketManagerIsolated firstMarket = _createMarket("firstTestMarket", cr);
        _configureMarket(
            firstMarket,
            cr,
            MarketTokenDeploy(
                "PToken-WBTC",
                wbtc,
                _readConfigAddress(".markets.pTokens.WBTC.chainlinkEth"),
                _readConfigAddress(".markets.pTokens.WBTC.chainlinkUsd")
            ),
            MarketTokenDeploy(
                "EToken-USDC",
                usdc,
                _readConfigAddress(".markets.eTokens.USDC.chainlinkEth"),
                _readConfigAddress(".markets.eTokens.USDC.chainlinkUsd")
            ),
            1000000,
            700000
        );

        MarketManagerIsolated secondMarket = _createMarket("secondTestMarket", cr);
        _configureMarket(
            secondMarket,
            cr,
            MarketTokenDeploy(
                "PToken-USDC",
                usdc,
                _readConfigAddress(".markets.eTokens.USDC.chainlinkEth"),
                _readConfigAddress(".markets.eTokens.USDC.chainlinkUsd")
            ),
            MarketTokenDeploy(
                "EToken-WBTC",
                wbtc,
                _readConfigAddress(".markets.pTokens.WBTC.chainlinkEth"),
                _readConfigAddress(".markets.pTokens.WBTC.chainlinkUsd")
            ),
            1000000,
            700000
        );
    }

    function _createMarket(
        string memory marketName,
        ICentralRegistry cr
    ) internal returns (MarketManagerIsolated market) {
        uint256 marketInterestFactor = 1000; // 10%
        market = new MarketManagerIsolated(cr);
        _saveDeployedContracts(marketName, address(market));
        CentralRegistry(address(cr)).addMarketManager(
            address(market),
            marketInterestFactor
        );

        // Deploy Addons
        _deploySimplePositionManager(
            address(market),
            marketName,
            _readConfigAddress(".zapper.weth")
        );
        _deploySimpleZapper(
            address(cr),
            _readConfigAddress(".zapper.weth"),
            marketName
        );
    }

    function _configureMarket(
        MarketManagerIsolated market,
        ICentralRegistry cr,
        MarketTokenDeploy memory PositionToken,
        MarketTokenDeploy memory earnToken,
        uint256 collateralCap,
        uint256 debtCap
    ) internal {
        address pTokenToList =_deployPToken(
                PositionToken.name,
                PositionToken.token,
                PositionToken.chainlinkEthAggregator,
                PositionToken.chainlinkUsdAggregator,
                cr,
                market
        );
        address eTokenToList = _deployEToken(
            earnToken.name,
            earnToken.token,
            earnToken.chainlinkEthAggregator,
            earnToken.chainlinkUsdAggregator,
            cr,
            market
        );
        market.listTokens(pTokenToList, eTokenToList);
        market.updatePositionToken(
            9200, // collRatio 92%
            830,  // collReqSoft 8.3%
            650,  // collReqHard 6.5%
            500,  // liqIncBase 5%
            550,  // liqIncHard 5.5%
            300,  // liqIncMin 3%
            550,  // liqIncMax 5.5% 
            2000, // minEffectiveCFactor 20%
            5000, // maxEffectiveCFactor 50%
            2000  // baseCFactor 20%
        );

        address[] memory mTokens = new address[](1);
        uint256[] memory newCollateralCaps = new uint256[](1);
        uint256[] memory newDebtCaps = new uint256[](1);

        // Set Collateral Caps
        mTokens[0] = pTokenToList;
        // mTokens have same decimals as underlying token.
        newCollateralCaps[0]
            = collateralCap * 10 ** IERC20(mTokens[0]).decimals(); //1m tokens
        market.setCollateralCaps(mTokens, newCollateralCaps);
        
        // Set Debt Caps
        mTokens[0] = eTokenToList;
        // mTokens have same decimals as underlying token.
        newDebtCaps[0]
            = debtCap * 10 ** IERC20(mTokens[0]).decimals(); //700k tokens
        market.setDebtCaps(mTokens, newDebtCaps);
    }

    function _deployEToken(
        string memory name,
        address tokenAddress,
        address chainlinkEthAggregator,
        address chainlinkUsdAggregator,
        ICentralRegistry cr,
        MarketManagerIsolated market
    ) internal returns (address) {
        DynamicInterestRateModel interestRateModel = new DynamicInterestRateModel(
                cr,
                1000,
                1000,
                5000,
                43200,
                5000,
                100000000,
                100
            );

        address eToken = address(
            new EToken(
                cr,
                tokenAddress,
                address(market),
                address(interestRateModel)
            )
        );
        _saveDeployedContracts(name, eToken);
        interestRateModel.setLinkedEToken(eToken);

        if (tokenAddress != _getDeployedContract("SWETH")) {
            _addChainlinkOracleSupport(
                chainlinkEthAggregator,
                chainlinkUsdAggregator,
                eToken
            );
        }

        if (
            tokenAddress != _getDeployedContract("mETH") &&
            tokenAddress != _getDeployedContract("mUSD") &&
            tokenAddress != _getDeployedContract("mkUSD")
        ) {
            console.log("[REDSTONE] - Adding", name);
            _addRedstoneOracleSupport(eToken);
        } else {
            console.log("Avoiding Redstone Oracle for testnet token: ", name);
        }

        MockToken(tokenAddress).approve(eToken, 1e25);
        return eToken;
    }

    function _deployPToken(
        string memory name,
        address tokenAddress,
        address chainlinkEthAggregator,
        address chainlinkUsdAggregator,
        ICentralRegistry cr,
        MarketManagerIsolated market
    ) internal returns (address) {
        IERC20 underlying = IERC20(tokenAddress);
        address pToken = address(
            new SimplePToken(cr, underlying, address(market))
        );
        _saveDeployedContracts(name, pToken);

        _addChainlinkOracleSupport(
            chainlinkEthAggregator,
            chainlinkUsdAggregator,
            pToken
        );

        if (
            tokenAddress != _getDeployedContract("mETH") &&
            tokenAddress != _getDeployedContract("mUSD") &&
            tokenAddress != _getDeployedContract("mkUSD")
        ) {
            console.log("[REDSTONE] - Adding", name);
            _addRedstoneOracleSupport(pToken);
        } else {
            console.log("Avoiding Redstone Oracle for testnet token: ", name);
        }

        MockToken(tokenAddress).approve(pToken, 1e25);
        return pToken;
    }

    function _addRedstoneOracleSupport(address mToken) internal {
        address oracleManager = _getDeployedContract("oracleManager");
        // address redstoneAdaptor = _getDeployedContract("redstoneAdaptor");
        // address underlying = IMToken(mToken).underlying();

        // IERC20 underlyingToken = IERC20(underlying);
        // RedstoneCoreAdaptor adaptor = RedstoneCoreAdaptor(redstoneAdaptor);
        OracleManager router = OracleManager(oracleManager);

        if (!router.isSupportedAsset(mToken)) {
            router.addMTokenSupport(mToken);
        }
    }

    function _addChainlinkOracleSupport(
        address chainlinkEth,
        address chainlinkUsd,
        address mToken
    ) internal {
        address oracleManager = _getDeployedContract("oracleManager");
        address chainlinkAdaptor = _getDeployedContract("chainlinkAdaptor");
        address underlying = IMToken(mToken).underlying();

        if (chainlinkEth == address(0) && chainlinkUsd == address(0)) {
            return;
        }

        if (!ChainlinkAdaptor(chainlinkAdaptor).isSupportedAsset(underlying)) {
            if (chainlinkEth != address(0)) {
                ChainlinkAdaptor(chainlinkAdaptor).addAsset(
                    underlying,
                    chainlinkEth,
                    0,
                    false
                );
            }

            if (chainlinkUsd != address(0)) {
                ChainlinkAdaptor(chainlinkAdaptor).addAsset(
                    underlying,
                    chainlinkUsd,
                    0,
                    true
                );
            }
        }

        if (
            !OracleManager(oracleManager).isApprovedAdaptor(chainlinkAdaptor)
        ) {
            OracleManager(oracleManager).addApprovedAdaptor(chainlinkAdaptor);
        }

        try
            OracleManager(oracleManager).assetPriceFeeds(underlying, 0)
        returns (address /* feed */) {} catch {
            OracleManager(oracleManager).addAssetPriceFeed(
                underlying,
                chainlinkAdaptor
            );
        }

        // Link mToken
        if (!OracleManager(oracleManager).isSupportedAsset(mToken)) {
            OracleManager(oracleManager).addMTokenSupport(mToken);
        }
    }

    function _deploy_redstone_price_feeds(
        bool setup,
        bool executeFeeds
    ) internal {
        // CentralRegistry centralRegistry = CentralRegistry(
        //     _getDeployedContract("centralRegistry")
        // );
        // ICentralRegistry icr = ICentralRegistry(address(centralRegistry));

        address[] memory mockTokens = new address[](4);
        mockTokens[0] = _getDeployedContract("LUSD");
        mockTokens[1] = _getDeployedContract("USDC");
        mockTokens[2] = _getDeployedContract("WBTC");
        mockTokens[3] = _getDeployedContract("SWETH");

        address oracleManager = _getDeployedContract("oracleManager");
        address redstoneAdaptor = _getDeployedContract("redstoneAdaptor");
        RedstoneCoreAdaptor adaptor = RedstoneCoreAdaptor(redstoneAdaptor);
        OracleManager router = OracleManager(oracleManager);

        address[] memory priceFeedAdds = new address[](mockTokens.length);
        for (uint256 i = 0; i < mockTokens.length; i++) {
            address underlying = mockTokens[i];
            IERC20 underlyingToken = IERC20(underlying);

            if (setup) {
                if (!adaptor.isSupportedAsset(underlying)) {
                    adaptor.addAsset(underlying, true, 8, 12 hours);
                }

                if (!router.isApprovedAdaptor(redstoneAdaptor)) {
                    router.addApprovedAdaptor(redstoneAdaptor);
                }
            }

            if (executeFeeds && !router.isSupportedAsset(underlying)) {
                _addRedstonePriceFeed(underlyingToken, adaptor, router);
                priceFeedAdds[i] = address(underlying);
            }
        }

        for (uint256 i = 0; i < priceFeedAdds.length; i++) {
            if (priceFeedAdds[i] == address(0)) {
                continue;
            }

            router.addAssetPriceFeed(priceFeedAdds[i], address(adaptor));
        }
    }

    function _addRedstonePriceFeed(
        IERC20 underlyingToken,
        RedstoneCoreAdaptor adaptor,
        OracleManager /* router */
    ) internal {
        console.log(
            "[REDSTONE] - Fetching & applying price for ",
            underlyingToken.symbol()
        );
        bytes memory redstonePayload = getRedstoneApiPayload(
            underlyingToken.symbol()
        );
        adaptor.adaptorData(address(underlyingToken), true);
        bytes memory encodedFunction = abi.encodeWithSignature(
            "writePrice(address,bool)",
            address(underlyingToken),
            true
        );
        bytes memory encodedFunctionWithRedstonePayload = abi.encodePacked(
            encodedFunction,
            redstonePayload
        );
        (bool success, ) = address(adaptor).call(
            encodedFunctionWithRedstonePayload
        );

        require(success, "Failed to get price from Redstone API");

        // TODO: This could be extracted out to speed up the redstone price execution
        // router.addAssetPriceFeed(address(underlyingToken), address(adaptor));
    }

    function _loadFaucet() internal {
        address faucet_addr = _getDeployedContract("faucet");
        address cve_addr = _getDeployedContract("cve");

        require(faucet_addr != address(0), "Faucet is not deployed!");
        require(cve_addr != address(0), "CVE is not deployed!");

        // Load with 10M CVE
        CVE cve = CVE(cve_addr);
        cve.transfer(faucet_addr, 1e25);

        // Load with 5M tokens from testnet tokens
        address[] memory mockTokens = new address[](4);
        if (!is_berachain && !is_movement) {
            mockTokens = new address[](7);
        }

        mockTokens[0] = _getDeployedContract("LUSD");
        mockTokens[1] = _getDeployedContract("USDC");
        mockTokens[2] = _getDeployedContract("WBTC");
        mockTokens[3] = _getDeployedContract("SWETH");

        if (!is_berachain && !is_movement) {
            mockTokens[4] = _getDeployedContract("mETH");
            mockTokens[5] = _getDeployedContract("mUSD");
            mockTokens[6] = _getDeployedContract("mkUSD");
        }

        for (uint256 i = 0; i < mockTokens.length; i++) {
            TestnetToken t = TestnetToken(mockTokens[i]);
            uint256 decimals = t.decimals();
            t.transfer(faucet_addr, 5_000_000 * (10 ** decimals));
        }

        Faucet(faucet_addr).setMaxClaimAmounts(mockTokens[1], 10_000e6);
    }
}
