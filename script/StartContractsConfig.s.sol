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

import { DeployConfiguration } from "./utils/DeployConfiguration.sol";

contract StartContractsConfig is Script, DeployConfiguration {
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
        ICentralRegistry cr = ICentralRegistry(
            _getDeployedContract("centralRegistry")
        );
        address guagePool = _getDeployedContract("gaugePool");

        MarketManager firstMarket = new MarketManager(cr, guagePool);
        console.log("firstMarket =", address(firstMarket));
        _saveDeployedContracts("firstTestMarket", address(firstMarket));

        MarketManager secondMarket = new MarketManager(cr, guagePool);
        console.log("secondMarket =", address(secondMarket));
        _saveDeployedContracts("secondTestMarket", address(secondMarket));

        address usdc = _readConfigAddress("markets.dTokens.USDC.asset");
        address dai = _readConfigAddress("markets.dTokens.DAI.asset");
        address wbtc = _readConfigAddress("markets.cTokens.WBTC.asset");

        firstMarket.listToken(usdc);
        firstMarket.listToken(dai);
        secondMarket.listToken(wbtc);

        secondMarket.updateCollateralToken(
            IMToken(wbtc),
            _readConfigUint256(
                "markets.cTokens.WBTC.collateralConfig.collRatio"
            ),
            _readConfigUint256(
                "markets.cTokens.WBTC.collateralConfig.collReqA"
            ),
            _readConfigUint256(
                "markets.cTokens.WBTC.collateralConfig.collReqB"
            ),
            _readConfigUint256(
                "markets.cTokens.WBTC.collateralConfig.liqIncA"
            ),
            _readConfigUint256(
                "markets.cTokens.WBTC.collateralConfig.liqIncB"
            ),
            _readConfigUint256("markets.cTokens.WBTC.collateralConfig.liqFee"),
            _readConfigUint256(
                "markets.cTokens.WBTC.collateralConfig.baseCFactor"
            )
        );

        address[] memory mTokens = new address[](1);
        mTokens[0] = wbtc;
        uint256[] memory newCollateralCaps = new uint256[](1);
        newCollateralCaps[0] = _readConfigUint256(
            "markets.cTokens.WBTC.collateralConfig.collateralCaps"
        );
        secondMarket.setCTokenCollateralCaps(mTokens, newCollateralCaps);
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
