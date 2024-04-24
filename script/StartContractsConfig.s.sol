// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import { CVE } from "contracts/token/CVE.sol";
import { VeCVE } from "contracts/token/VeCVE.sol";
import { CVELocker } from "contracts/architecture/CVELocker.sol";
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
import { GaugePool } from "contracts/gauge/GaugePool.sol";
import { DeployConfiguration } from "./utils/DeployConfiguration.sol";
import { RewardsData } from "contracts/interfaces/ICVELocker.sol";
import { Faucet } from "contracts/testnet/Faucet.sol";

contract StartContractsConfig is Script, DeployConfiguration {
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

    function _is_testnet(string memory network) internal pure returns (bool) {

        return
            keccak256(abi.encodePacked(network)) == keccak256(abi.encodePacked("sepolia"))
                ||
            keccak256(abi.encodePacked(network)) == keccak256(abi.encodePacked("localhost"));
    }

    function _after_deploy_config(string memory network) internal {
        _startLocker();

        if (_is_testnet(network)) {
            _configTestnet();
        }
    }

    function _startLocker() internal {
        address centralRegistry = _getDeployedContract("centralRegistry");
        console.log("centralRegistry =", centralRegistry);
        address payable cveLocker = payable(_getDeployedContract("cveLocker"));
        console.log("cveLocker =", cveLocker);

        require(centralRegistry != address(0), "Set the centralRegistry!");
        require(
            CVELocker(cveLocker).lockerStarted() != 2,
            "Locker already started!"
        );
        require(
            CentralRegistry(centralRegistry).veCVE() != address(0),
            "Set veCVE!"
        );

        CVELocker(cveLocker).startLocker();
        console.log("startLocker");
    }

    function _configTestnet() internal {
        CentralRegistry centralRegistry = CentralRegistry(
            _getDeployedContract("centralRegistry")
        );
        ICentralRegistry icr = ICentralRegistry(address(centralRegistry));

        // Create chainlink adaptor
        ChainlinkAdaptor chainlinkAdaptor = new ChainlinkAdaptor(icr);
        _saveDeployedContracts(
            "Div-chainlinkAdaptor",
            address(chainlinkAdaptor)
        );

        centralRegistry.setEarlyUnlockPenaltyMultiplier(8000);
        _deployMockTokens();
        _createTestMarkets();
        _createRealTestMarkets();
        _loadFaucet();

        // Lock 25%
        address deployer = vm.addr(vm.envUint("PRIVATE_KEY"));
        CVE cve = CVE(_getDeployedContract("cve"));
        VeCVE veCVE = VeCVE(centralRegistry.veCVE());
        uint256 lockAmount = cve.balanceOf(deployer) / 4;
        cve.approve(address(veCVE), lockAmount);
        RewardsData memory rewardsData;
        veCVE.createLock(lockAmount, true, rewardsData, "", 0);
    }

    function _deployMockTokens() internal {
        address l_usd = address(
            new TestnetToken("LUSD Stablecoin", "LUSD", 18)
        );
        address m_eth = address(new TestnetToken("mETH", "mETH", 18));
        address m_usd = address(new TestnetToken("mUSD", "mUSD", 18));
        address mk_usd = address(
            new TestnetToken("Prisma mkUSD", "mkUSD", 18)
        );
        address usdc = address(new TestnetToken("USD Coin", "USDC", 6));
        address wbtc = address(new TestnetToken("Wrapped Bitcoin", "WBTC", 8));

        _saveDeployedContracts("LUSD", l_usd);
        _saveDeployedContracts("mETH", m_eth);
        _saveDeployedContracts("mUSD", m_usd);
        _saveDeployedContracts("mkUSD", mk_usd);
        _saveDeployedContracts("WBTC", wbtc);
        _saveDeployedContracts("USDC", usdc);

        // Create faucet for tokens
        address faucet = address(new Faucet());
        _saveDeployedContracts("faucet", faucet);
    }

    function _createRealTestMarkets() internal {
        ICentralRegistry cr = ICentralRegistry(
            _getDeployedContract("centralRegistry")
        );

        address l_usd = _getDeployedContract("LUSD");
        address m_eth = _getDeployedContract("mETH");
        address m_usd = _getDeployedContract("mUSD");
        address mk_usd = _getDeployedContract("mkUSD");

        address chainlinkUsdcFeedInUsd = 0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E;
        address chainlinkEthFeedInUsd = 0x694AA1769357215DE4FAC081bf1f309aDC325306;

        MarketManager thirdMarket = _createMarket("thirdTestMarket", cr);
        MarketTokenDeploy[]
            memory thirdCollateralTokens = new MarketTokenDeploy[](1);
        MarketTokenDeploy[] memory thirdDebtTokens = new MarketTokenDeploy[](
            1
        );
        thirdCollateralTokens[0] = MarketTokenDeploy(
            "Div-CToken-mETH",
            m_eth,
            address(0),
            chainlinkEthFeedInUsd
        );
        thirdDebtTokens[0] = MarketTokenDeploy(
            "Div-DToken-mUSD",
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

        MarketManager fourthMarket = _createMarket("fourthTestMarket", cr);
        MarketTokenDeploy[]
            memory fourthCollateralTokens = new MarketTokenDeploy[](1);
        MarketTokenDeploy[] memory fourthDebtTokens = new MarketTokenDeploy[](
            1
        );
        fourthCollateralTokens[0] = MarketTokenDeploy(
            "Div-CToken-LUSD",
            l_usd,
            address(0),
            chainlinkUsdcFeedInUsd
        );
        fourthDebtTokens[0] = MarketTokenDeploy(
            "Div-DToken-mkUSD",
            mk_usd,
            address(0),
            chainlinkUsdcFeedInUsd
        );
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
            "Div-CToken-WBTC",
            wbtc,
            _readConfigAddress(".markets.cTokens.WBTC.chainlinkEth"),
            _readConfigAddress(".markets.cTokens.WBTC.chainlinkUsd")
        );
        firstDebtTokens[0] = MarketTokenDeploy(
            "Div-DToken-USDC",
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
            "Div-CToken-USDC",
            usdc,
            _readConfigAddress(".markets.dTokens.USDC.chainlinkEth"),
            _readConfigAddress(".markets.dTokens.USDC.chainlinkUsd")
        );
        secondDebtTokens[0] = MarketTokenDeploy(
            "Div-DToken-WBTC",
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

        GaugePool gp = new GaugePool(cr);
        market = new MarketManager(cr, address(gp));
        _saveDeployedContracts(marketName, address(market));
        CentralRegistry(address(cr)).addMarketManager(
            address(market),
            marketInterestFactor
        );
        gp.start(address(market));
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
        _addOracleSupport(
            chainlinkEthAggregator,
            chainlinkUsdAggregator,
            dToken
        );

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

        _addOracleSupport(
            chainlinkEthAggregator,
            chainlinkUsdAggregator,
            cToken
        );

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

    function _addOracleSupport(
        address chainlinkEth,
        address chainlinkUsd,
        address mToken
    ) internal {
        address oracleRouter = _getDeployedContract("oracleRouter");
        address chainlinkAdaptor = _getDeployedContract(
            "Div-chainlinkAdaptor"
        );
        address underlying = IMToken(mToken).underlying();

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

    function _loadFaucet() internal {
        address faucet_addr = _getDeployedContract("faucet");
        address cve_addr = _getDeployedContract("cve");

        require(faucet_addr != address(0), "Faucet is not deployed!");
        require(cve_addr != address(0), "CVE is not deployed!");

        // Load with 10M CVE
        CVE cve = CVE(cve_addr);
        cve.transfer(faucet_addr, 1e25);

        // Load with 5M tokens from testnet tokens
        address[] memory mockTokens = new address[](6);
        mockTokens[0] = _getDeployedContract("LUSD");
        mockTokens[1] = _getDeployedContract("mETH");
        mockTokens[2] = _getDeployedContract("mUSD");
        mockTokens[3] = _getDeployedContract("mkUSD");
        mockTokens[4] = _getDeployedContract("USDC");
        mockTokens[5] = _getDeployedContract("WBTC");
        for(uint256 i = 0; i < mockTokens.length; i++) {
            TestnetToken t = TestnetToken(mockTokens[i]);
            uint256 decimals = t.decimals();
            t.transfer(faucet_addr, 5_000_000 * (10 ** decimals));
        }
    }
}
