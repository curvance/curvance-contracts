// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import { CVE } from "contracts/token/CVE.sol";
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
import { CTokenPrimitive } from "contracts/market/collateral/CTokenPrimitive.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

import { DeployConfiguration } from "./utils/DeployConfiguration.sol";

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

    function _is_testnet(string memory network) internal pure returns (bool) {
        return
            keccak256(abi.encodePacked(network)) ==
            keccak256(abi.encodePacked("sepolia"));
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

        centralRegistry.setEarlyUnlockPenaltyMultiplier(8000);
        _createTestMarkets();
        _loadFaucet();
    }

    function _createTestMarkets() internal {
        // Load dependencies
        ICentralRegistry cr = ICentralRegistry(
            _getDeployedContract("centralRegistry")
        );
        address gaugePool = _getDeployedContract("gaugePool");
        address oracleRouter = _getDeployedContract("oracleRouter");
        address chainlinkAdaptor = _getDeployedContract("chainlinkAdaptor");
        uint256 marketInterestFactor = 1000; // 10%

        MarketManager firstMarket = new MarketManager(cr, gaugePool);
        console.log("firstMarket =", address(firstMarket));
        _saveDeployedContracts("firstTestMarket", address(firstMarket));
        CentralRegistry(address(cr)).addMarketManager(
            address(firstMarket),
            marketInterestFactor
        );

        MarketManager secondMarket = new MarketManager(cr, gaugePool);
        console.log("secondMarket =", address(secondMarket));
        _saveDeployedContracts("secondTestMarket", address(secondMarket));
        CentralRegistry(address(cr)).addMarketManager(
            address(secondMarket),
            marketInterestFactor
        );

        address usdc = _readConfigAddress(".markets.dTokens.USDC.asset");
        address wbtc = _readConfigAddress(".markets.cTokens.WBTC.asset");

        MockToken(usdc).mint(52e25);
        MockToken(wbtc).mint(52e25);

        address dusdc = _deployDTokenAndList(
            "Div-D-USDC",
            address(usdc),
            cr,
            firstMarket
        );
        address cwbtc = _deployCTokenAndList(
            "Div-C-WBTC",
            address(wbtc),
            cr,
            firstMarket
        );
        address dwbtc = _deployDTokenAndList(
            "Div-D-WBTC",
            address(wbtc),
            cr,
            secondMarket
        );
        address cusdc = _deployCTokenAndList(
            "Div-C-USDC",
            address(usdc),
            cr,
            secondMarket
        );
    }

    function _deployCTokenAndList(
        string memory name,
        address asset,
        ICentralRegistry cr,
        MarketManager market
    ) internal returns (address) {
        address oracleRouter = _getDeployedContract("oracleRouter");
        address chainlinkAdaptor = _getDeployedContract("chainlinkAdaptor");

        CTokenParam memory param = CTokenParam({
            asset: asset,
            chainlinkEth: _readConfigAddress(
                ".markets.cTokens.WBTC.chainlinkEth"
            ),
            chainlinkUsd: _readConfigAddress(
                ".markets.cTokens.WBTC.chainlinkUsd"
            )
        });

        // Setup underlying chainlink adapters.
        if (
            !ChainlinkAdaptor(chainlinkAdaptor).isSupportedAsset(param.asset)
        ) {
            if (param.chainlinkEth != address(0)) {
                ChainlinkAdaptor(chainlinkAdaptor).addAsset(
                    param.asset,
                    param.chainlinkEth,
                    0,
                    false
                );
            }
            if (param.chainlinkUsd != address(0)) {
                ChainlinkAdaptor(chainlinkAdaptor).addAsset(
                    param.asset,
                    param.chainlinkUsd,
                    0,
                    true
                );
            }
        }

        if (!OracleRouter(oracleRouter).isApprovedAdaptor(chainlinkAdaptor)) {
            OracleRouter(oracleRouter).addApprovedAdaptor(chainlinkAdaptor);
        }

        try
            OracleRouter(oracleRouter).assetPriceFeeds(param.asset, 0)
        returns (address feed) {} catch {
            OracleRouter(oracleRouter).addAssetPriceFeed(
                param.asset,
                chainlinkAdaptor
            );
        }

        // Deploy CToken
        address cToken = address(
            new CTokenPrimitive(cr, IERC20(param.asset), address(market))
        );

        _saveDeployedContracts(name, cToken);

        if (!OracleRouter(oracleRouter).isSupportedAsset(cToken)) {
            OracleRouter(oracleRouter).addMTokenSupport(cToken);
        }

        MockToken(asset).approve(cToken, 52e25);
        market.listToken(cToken);
        market.updateCollateralToken(
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
        newCollateralCaps[0] = 1e25;
        market.setCTokenCollateralCaps(mTokens, newCollateralCaps);

        return cToken;
    }

    function _deployDTokenAndList(
        string memory name,
        address asset,
        ICentralRegistry cr,
        MarketManager market
    ) internal returns (address) {
        address oracleRouter = _getDeployedContract("oracleRouter");
        address chainlinkAdaptor = _getDeployedContract("chainlinkAdaptor");

        DTokenParam memory param = DTokenParam({
            asset: asset,
            chainlinkEth: _readConfigAddress(
                ".markets.dTokens.USDC.chainlinkEth"
            ),
            chainlinkUsd: _readConfigAddress(
                ".markets.dTokens.USDC.chainlinkUsd"
            ),
            interestRateParam: DTokenInterestRateParam({
                adjustmentRate: _readConfigUint256(
                    ".markets.dTokens.USDC.interestRateParam.adjustmentRate"
                ),
                adjustmentVelocity: _readConfigUint256(
                    ".markets.dTokens.USDC.interestRateParam.adjustmentVelocity"
                ),
                baseRatePerYear: _readConfigUint256(
                    ".markets.dTokens.USDC.interestRateParam.baseRatePerYear"
                ),
                decayRate: _readConfigUint256(
                    ".markets.dTokens.USDC.interestRateParam.decayRate"
                ),
                vertexMultiplierMax: _readConfigUint256(
                    ".markets.dTokens.USDC.interestRateParam.vertexMultiplierMax"
                ),
                vertexRatePerYear: _readConfigUint256(
                    ".markets.dTokens.USDC.interestRateParam.vertexRatePerYear"
                ),
                vertexUtilizationStart: _readConfigUint256(
                    ".markets.dTokens.USDC.interestRateParam.vertexUtilizationStart"
                )
            })
        });
        address asset = param.asset;

        // Setup chainlink adapters
        if (!ChainlinkAdaptor(chainlinkAdaptor).isSupportedAsset(asset)) {
            ChainlinkAdaptor(chainlinkAdaptor).addAsset(
                asset,
                address(0),
                0,
                false
            );
        }

        if (!OracleRouter(oracleRouter).isApprovedAdaptor(chainlinkAdaptor)) {
            OracleRouter(oracleRouter).addApprovedAdaptor(chainlinkAdaptor);
            console.log("oracleRouter.addApprovedAdaptor: ", chainlinkAdaptor);
        }

        try OracleRouter(oracleRouter).assetPriceFeeds(asset, 0) returns (
            address feed
        ) {} catch {
            OracleRouter(oracleRouter).addAssetPriceFeed(
                asset,
                chainlinkAdaptor
            );
            console.log("oracleRouter.addAssetPriceFeed: ", asset);
        }

        // Create DToken
        address interestRateModel = address(
            new DynamicInterestRateModel(
                cr,
                param.interestRateParam.baseRatePerYear,
                param.interestRateParam.vertexRatePerYear,
                param.interestRateParam.vertexUtilizationStart,
                param.interestRateParam.adjustmentRate,
                param.interestRateParam.adjustmentVelocity,
                param.interestRateParam.vertexMultiplierMax,
                param.interestRateParam.decayRate
            )
        );
        address dToken = address(
            new DToken(cr, param.asset, address(market), interestRateModel)
        );
        _saveDeployedContracts(name, dToken);

        if (!OracleRouter(oracleRouter).isSupportedAsset(dToken)) {
            OracleRouter(oracleRouter).addMTokenSupport(dToken);
        }

        MockToken(asset).approve(dToken, 52e25);
        market.listToken(dToken);

        return dToken;
    }

    function _loadFaucet() internal {
        address faucet_addr = _getDeployedContract("faucet");
        address cve_addr = _getDeployedContract("cve");

        require(faucet_addr != address(0), "Faucet is not deployed!");
        require(cve_addr != address(0), "CVE is not deployed!");

        // Load with 10M CVE
        CVE cve = CVE(cve_addr);
        address deployer = vm.addr(vm.envUint("PRIVATE_KEY"));
        console.log("Balance", cve.balanceOf(deployer));
        cve.transfer(faucet_addr, 1e25);
    }
}
