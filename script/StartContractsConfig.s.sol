// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import { CVE } from "contracts/token/CVE.sol";
import { VeCVE } from "contracts/token/VeCVE.sol";
import { RewardManager } from "contracts/architecture/RewardManager.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IMToken } from "contracts/interfaces/market/IMToken.sol";
import { MarketManager } from "contracts/market/MarketManager.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { OracleRouter } from "contracts/oracles/OracleRouter.sol";
import { DynamicInterestRateModel } from "contracts/market/DynamicInterestRateModel.sol";
import { DToken } from "contracts/market/collateral/DToken.sol";
import { MockToken } from "contracts/mocks/MockToken.sol";
import { TestnetToken } from "contracts/mocks/TestnetToken.sol";
import { CTokenPrimitive } from "contracts/market/collateral/CTokenPrimitive.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { DeployConfiguration } from "./utils/DeployConfiguration.sol";
import { RewardsData } from "contracts/interfaces/IRewardManager.sol";
import { Faucet } from "contracts/testnet/Faucet.sol";
import { RedstoneCoreAdaptor } from "contracts/oracles/adaptors/redstone/RedstoneCoreAdaptor.sol";
import { PriceReturnData } from "contracts/interfaces/IOracleAdaptor.sol";
import { MulticallDataCheckerForRedstoneAdaptor } from "contracts/market/multicall-checker/MulticallDataCheckerForRedstoneAdaptor.sol";
import { SimpleZapperDeployer } from "./deployers/SimpleZapperDeployer.s.sol";
import { ComplexZapperDeployer } from "./deployers/ComplexZapperDeployer.s.sol";

contract StartContractsConfig is
    Script,
    DeployConfiguration,
    SimpleZapperDeployer,
    ComplexZapperDeployer
{
    struct DTokenInterestRateParam {
        uint256 adjustmentRate;
        uint256 adjustmentVelocity;
        uint256 baseRatePerYear;
        uint256 decayRate;
        uint256 vertexMultiplierMax;
        uint256 vertexRatePerYear;
        uint256 vertexUtilizationStart;
    }

    struct DTokenParam {
        address asset;
        address chainlinkEth;
        address chainlinkUsd;
        DTokenInterestRateParam interestRateParam;
    }

    struct CTokenParam {
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
            ".oracleRouter.chainlinkUsd"
        );
        address chainlinkEthFeedInUsd = _readConfigAddress(
            ".oracleRouter.chainlinkEthUsd"
        );

        if (!is_berachain && !is_movement) {
            address m_eth = _getDeployedContract("mETH");
            address m_usd = _getDeployedContract("mUSD");

            MarketManager thirdMarket = _createMarket("thirdTestMarket", cr);
            MarketTokenDeploy[]
                memory thirdCollateralTokens = new MarketTokenDeploy[](1);
            MarketTokenDeploy[]
                memory thirdDebtTokens = new MarketTokenDeploy[](1);
            thirdCollateralTokens[0] = MarketTokenDeploy(
                "CToken-mETH",
                m_eth,
                address(0),
                chainlinkEthFeedInUsd
            );
            thirdDebtTokens[0] = MarketTokenDeploy(
                "DToken-mUSD",
                m_usd,
                address(0),
                chainlinkUsdcFeedInUsd
            );
            _deployMarketTokens(
                thirdMarket,
                cr,
                thirdCollateralTokens,
                thirdDebtTokens
            );
        }

        MarketManager fourthMarket = _createMarket("fourthTestMarket", cr);
        MarketTokenDeploy[]
            memory fourthCollateralTokens = new MarketTokenDeploy[](1);
        MarketTokenDeploy[] memory fourthDebtTokens = new MarketTokenDeploy[](
            1
        );
        if (!is_berachain && !is_movement) {
            fourthDebtTokens = new MarketTokenDeploy[](2);
        }
        fourthCollateralTokens[0] = MarketTokenDeploy(
            "CToken-LUSD",
            l_usd,
            address(0),
            chainlinkUsdcFeedInUsd
        );

        fourthDebtTokens[0] = MarketTokenDeploy(
            "DToken-SWETH",
            sweth,
            address(0),
            chainlinkUsdcFeedInUsd
        );

        if (!is_berachain && !is_movement) {
            address mk_usd = _getDeployedContract("mkUSD");

            fourthDebtTokens[1] = MarketTokenDeploy(
                "DToken-mkUSD",
                mk_usd,
                address(0),
                chainlinkUsdcFeedInUsd
            );
        }

        _deployMarketTokens(
            fourthMarket,
            cr,
            fourthCollateralTokens,
            fourthDebtTokens
        );
    }

    function _createTestMarkets() internal {
        ICentralRegistry cr = ICentralRegistry(
            _getDeployedContract("centralRegistry")
        );

        address usdc = _getDeployedContract("USDC");
        address wbtc = _getDeployedContract("WBTC");

        MarketManager firstMarket = _createMarket("firstTestMarket", cr);
        MarketTokenDeploy[]
            memory firstCollateralTokens = new MarketTokenDeploy[](1);
        MarketTokenDeploy[] memory firstDebtTokens = new MarketTokenDeploy[](
            1
        );
        firstCollateralTokens[0] = MarketTokenDeploy(
            "CToken-WBTC",
            wbtc,
            _readConfigAddress(".markets.cTokens.WBTC.chainlinkEth"),
            _readConfigAddress(".markets.cTokens.WBTC.chainlinkUsd")
        );
        firstDebtTokens[0] = MarketTokenDeploy(
            "DToken-USDC",
            usdc,
            _readConfigAddress(".markets.dTokens.USDC.chainlinkEth"),
            _readConfigAddress(".markets.dTokens.USDC.chainlinkUsd")
        );
        _deployMarketTokens(
            firstMarket,
            cr,
            firstCollateralTokens,
            firstDebtTokens
        );

        MarketManager secondMarket = _createMarket("secondTestMarket", cr);
        MarketTokenDeploy[]
            memory secondCollateralTokens = new MarketTokenDeploy[](1);
        MarketTokenDeploy[] memory secondDebtTokens = new MarketTokenDeploy[](
            1
        );
        secondCollateralTokens[0] = MarketTokenDeploy(
            "CToken-USDC",
            usdc,
            _readConfigAddress(".markets.dTokens.USDC.chainlinkEth"),
            _readConfigAddress(".markets.dTokens.USDC.chainlinkUsd")
        );
        secondDebtTokens[0] = MarketTokenDeploy(
            "DToken-WBTC",
            wbtc,
            _readConfigAddress(".markets.cTokens.WBTC.chainlinkEth"),
            _readConfigAddress(".markets.cTokens.WBTC.chainlinkUsd")
        );
        _deployMarketTokens(
            secondMarket,
            cr,
            secondCollateralTokens,
            secondDebtTokens
        );
    }

    function _createMarket(
        string memory marketName,
        ICentralRegistry cr
    ) internal returns (MarketManager market) {
        uint256 marketInterestFactor = 1000; // 10%
        market = new MarketManager(cr);
        _saveDeployedContracts(marketName, address(market));
        CentralRegistry(address(cr)).addMarketManager(
            address(market),
            marketInterestFactor
        );

        // Deploy ComplexZapper
        address complexZapper = _deployComplexZapper(
            address(cr),
            address(market),
            _readConfigAddress(".zapper.weth")
        );

        address simpleZapper = _deploySimpleZapper(
            address(cr),
            address(market),
            _readConfigAddress(".zapper.weth")
        );

        _saveDeployedContracts(
            string.concat(marketName, "-complexZapper"),
            complexZapper
        );
        _saveDeployedContracts(
            string.concat(marketName, "-simpleZapper"),
            simpleZapper
        );
    }

    function _deployMarketTokens(
        MarketManager market,
        ICentralRegistry cr,
        MarketTokenDeploy[] memory collateralTokens,
        MarketTokenDeploy[] memory debtTokens
    ) internal {
        for (uint256 i = 0; i < collateralTokens.length; i++) {
            _deployCToken(
                collateralTokens[i].name,
                collateralTokens[i].token,
                collateralTokens[i].chainlinkEthAggregator,
                collateralTokens[i].chainlinkUsdAggregator,
                cr,
                market
            );
        }

        for (uint256 i = 0; i < debtTokens.length; i++) {
            _deployDToken(
                debtTokens[i].name,
                debtTokens[i].token,
                debtTokens[i].chainlinkEthAggregator,
                debtTokens[i].chainlinkUsdAggregator,
                cr,
                market
            );
        }
    }

    function _deployDToken(
        string memory name,
        address tokenAddress,
        address chainlinkEthAggregator,
        address chainlinkUsdAggregator,
        ICentralRegistry cr,
        MarketManager market
    ) internal returns (address) {
        address interestRateModel = address(
            // .markets.dTokens.USDC.interestRateParam
            new DynamicInterestRateModel(
                cr,
                1000,
                1000,
                5000,
                43200,
                5000,
                100000000,
                100
            )
        );

        address dToken = address(
            new DToken(cr, tokenAddress, address(market), interestRateModel)
        );
        _saveDeployedContracts(name, dToken);

        if (tokenAddress != _getDeployedContract("SWETH")) {
            _addChainlinkOracleSupport(
                chainlinkEthAggregator,
                chainlinkUsdAggregator,
                dToken
            );
        }

        if (
            tokenAddress != _getDeployedContract("mETH") &&
            tokenAddress != _getDeployedContract("mUSD") &&
            tokenAddress != _getDeployedContract("mkUSD")
        ) {
            console.log("[REDSTONE] - Adding", name);
            _addRedstoneOracleSupport(dToken);
        } else {
            console.log("Avoiding Redstone Oracle for testnet token: ", name);
        }

        MockToken(tokenAddress).approve(dToken, 1e25);
        market.listToken(dToken);

        return dToken;
    }

    function _deployCToken(
        string memory name,
        address tokenAddress,
        address chainlinkEthAggregator,
        address chainlinkUsdAggregator,
        ICentralRegistry cr,
        MarketManager market
    ) internal returns (address) {
        IERC20 underlying = IERC20(tokenAddress);
        address cToken = address(
            new CTokenPrimitive(cr, underlying, address(market))
        );
        _saveDeployedContracts(name, cToken);

        _addChainlinkOracleSupport(
            chainlinkEthAggregator,
            chainlinkUsdAggregator,
            cToken
        );

        if (
            tokenAddress != _getDeployedContract("mETH") &&
            tokenAddress != _getDeployedContract("mUSD") &&
            tokenAddress != _getDeployedContract("mkUSD")
        ) {
            console.log("[REDSTONE] - Adding", name);
            _addRedstoneOracleSupport(cToken);
        } else {
            console.log("Avoiding Redstone Oracle for testnet token: ", name);
        }

        MockToken(tokenAddress).approve(cToken, 1e25);
        market.listToken(cToken);
        market.updateCollateralToken(
            // From FuzzMarketManager -> setup()
            IMToken(cToken),
            7000,
            4000,
            3000,
            200,
            400,
            0,
            1000
        );
        address[] memory mTokens = new address[](1);
        mTokens[0] = cToken;
        uint256[] memory newCollateralCaps = new uint256[](1);
        newCollateralCaps[0] = 1000000 * 10 ** underlying.decimals(); //1m tokens
        market.setCTokenCollateralCaps(mTokens, newCollateralCaps);

        return cToken;
    }

    function _addRedstoneOracleSupport(address mToken) internal {
        address oracleRouter = _getDeployedContract("oracleRouter");
        address redstoneAdaptor = _getDeployedContract("redstoneAdaptor");
        address underlying = IMToken(mToken).underlying();

        IERC20 underlyingToken = IERC20(underlying);
        RedstoneCoreAdaptor adaptor = RedstoneCoreAdaptor(redstoneAdaptor);
        OracleRouter router = OracleRouter(oracleRouter);

        if (!router.isSupportedAsset(mToken)) {
            router.addMTokenSupport(mToken);
        }
    }

    function _addChainlinkOracleSupport(
        address chainlinkEth,
        address chainlinkUsd,
        address mToken
    ) internal {
        address oracleRouter = _getDeployedContract("oracleRouter");
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

        if (!OracleRouter(oracleRouter).isApprovedAdaptor(chainlinkAdaptor)) {
            OracleRouter(oracleRouter).addApprovedAdaptor(chainlinkAdaptor);
        }

        try OracleRouter(oracleRouter).assetPriceFeeds(underlying, 0) returns (
            address feed
        ) {} catch {
            OracleRouter(oracleRouter).addAssetPriceFeed(
                underlying,
                chainlinkAdaptor
            );
        }

        // Link mToken
        if (!OracleRouter(oracleRouter).isSupportedAsset(mToken)) {
            OracleRouter(oracleRouter).addMTokenSupport(mToken);
        }
    }

    function _deploy_redstone_price_feeds(
        bool setup,
        bool executeFeeds
    ) internal {
        CentralRegistry centralRegistry = CentralRegistry(
            _getDeployedContract("centralRegistry")
        );
        ICentralRegistry icr = ICentralRegistry(address(centralRegistry));

        address[] memory mockTokens = new address[](4);
        mockTokens[0] = _getDeployedContract("LUSD");
        mockTokens[1] = _getDeployedContract("USDC");
        mockTokens[2] = _getDeployedContract("WBTC");
        mockTokens[3] = _getDeployedContract("SWETH");

        address oracleRouter = _getDeployedContract("oracleRouter");
        address redstoneAdaptor = _getDeployedContract("redstoneAdaptor");
        RedstoneCoreAdaptor adaptor = RedstoneCoreAdaptor(redstoneAdaptor);
        OracleRouter router = OracleRouter(oracleRouter);

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
        OracleRouter router
    ) internal {
        console.log(
            "[REDSTONE] - Fetching & applying price for ",
            underlyingToken.symbol()
        );
        bytes memory redstonePayload = getRedstoneApiPayload(
            underlyingToken.symbol()
        );
        adaptor.adaptorDataUSD(address(underlyingToken));
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
