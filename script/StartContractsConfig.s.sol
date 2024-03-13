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
        address guagePool = _getDeployedContract("gaugePool");
        address oracleRouter = _getDeployedContract("oracleRouter");
        address chainlinkAdaptor = _getDeployedContract("chainlinkAdaptor");
        uint256 marketInterestFactor = 1000; // 10%

        MarketManager firstMarket = new MarketManager(cr, guagePool);
        console.log("firstMarket =", address(firstMarket));
        _saveDeployedContracts("firstTestMarket", address(firstMarket));
        CentralRegistry(address(cr)).addMarketManager(
            address(firstMarket),
            marketInterestFactor
        );

        MarketManager secondMarket = new MarketManager(cr, guagePool);
        console.log("secondMarket =", address(secondMarket));
        _saveDeployedContracts("secondTestMarket", address(secondMarket));
        CentralRegistry(address(cr)).addMarketManager(
            address(secondMarket),
            marketInterestFactor
        );

        address usdc = _readConfigAddress(".markets.dTokens.USDC.asset");
        address dai = _readConfigAddress(".markets.dTokens.DAI.asset");
        address wbtc = _readConfigAddress(".markets.cTokens.WBTC.asset");

        MockToken(usdc).mint(52e25);
        MockToken(dai).mint(52e25);
        MockToken(wbtc).mint(52e25);

        address dusdc = _deployDToken(
            "Div-D-USDC",
            ".markets.dTokens.USDC",
            cr,
            firstMarket
        );
        MockToken(usdc).approve(dusdc, 52e25);
        address ddai = _deployDToken(
            "Div-D-DAI",
            ".markets.dTokens.DAI",
            cr,
            firstMarket
        );
        MockToken(dai).approve(ddai, 52e25);
        address cwbtc = _deployCToken(
            "Div-C-WBTC",
            ".markets.cTokens.WBTC",
            cr,
            secondMarket
        );
        MockToken(wbtc).approve(cwbtc, 52e25);

        firstMarket.listToken(dusdc);
        firstMarket.listToken(ddai);
        secondMarket.listToken(cwbtc);

        secondMarket.updateCollateralToken(
            IMToken(cwbtc),
            7000,
            4000,
            3000,
            200,
            400,
            0,
            1000
        );
        address[] memory mTokens = new address[](1);
        mTokens[0] = cwbtc;
        uint256[] memory newCollateralCaps = new uint256[](1);
        newCollateralCaps[0] = _readConfigUint256(
            ".markets.cTokens.WBTC.collateralConfig.collateralCaps"
        );
        secondMarket.setCTokenCollateralCaps(mTokens, newCollateralCaps);
    }

    function _deployCToken(
        string memory name,
        string memory param_path,
        ICentralRegistry cr,
        MarketManager market
    ) internal returns (address) {
        address oracleRouter = _getDeployedContract("oracleRouter");
        address chainlinkAdaptor = _getDeployedContract("chainlinkAdaptor");

        CTokenParam memory param = CTokenParam({
            asset: _readConfigAddress(string.concat(param_path, ".asset")),
            chainlinkEth: _readConfigAddress(
                string.concat(param_path, ".chainlinkEth")
            ),
            chainlinkUsd: _readConfigAddress(
                string.concat(param_path, ".chainlinkUsd")
            )
        });

        // Setup underlying chainlink adapters.
        if (
            !ChainlinkAdaptor(chainlinkAdaptor).isSupportedAsset(param.asset)
        ) {
            // TO-DO: Have a lookup table here for param assets for whether
            // there are special heartbeats smaller than 24 hours.
            if (param.chainlinkEth != address(0)) {
                ChainlinkAdaptor(chainlinkAdaptor).addAsset(
                    param.asset,
                    param.chainlinkEth,
                    0,
                    false
                );
            }
            // TO-DO: Have a lookup table here for param assets for whether
            // there are special heartbeats smaller than 24 hours.
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

        return cToken;
    }

    function _deployDToken(
        string memory name,
        string memory param_path,
        ICentralRegistry cr,
        MarketManager market
    ) internal returns (address) {
        address oracleRouter = _getDeployedContract("oracleRouter");
        address chainlinkAdaptor = _getDeployedContract("chainlinkAdaptor");

        DTokenParam memory param = DTokenParam({
            asset: _readConfigAddress(string.concat(param_path, ".asset")),
            chainlinkEth: _readConfigAddress(
                string.concat(param_path, ".chainlinkEth")
            ),
            chainlinkUsd: _readConfigAddress(
                string.concat(param_path, ".chainlinkUsd")
            ),
            interestRateParam: DTokenInterestRateParam({
                adjustmentRate: _readConfigUint256(
                    string.concat(
                        param_path,
                        ".interestRateParam.adjustmentRate"
                    )
                ),
                adjustmentVelocity: _readConfigUint256(
                    string.concat(
                        param_path,
                        ".interestRateParam.adjustmentVelocity"
                    )
                ),
                baseRatePerYear: _readConfigUint256(
                    string.concat(
                        param_path,
                        ".interestRateParam.baseRatePerYear"
                    )
                ),
                decayRate: _readConfigUint256(
                    string.concat(param_path, ".interestRateParam.decayRate")
                ),
                vertexMultiplierMax: _readConfigUint256(
                    string.concat(
                        param_path,
                        ".interestRateParam.vertexMultiplierMax"
                    )
                ),
                vertexRatePerYear: _readConfigUint256(
                    string.concat(
                        param_path,
                        ".interestRateParam.vertexRatePerYear"
                    )
                ),
                vertexUtilizationStart: _readConfigUint256(
                    string.concat(
                        param_path,
                        ".interestRateParam.vertexUtilizationStart"
                    )
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
