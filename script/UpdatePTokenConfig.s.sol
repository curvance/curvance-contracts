// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { DeployConfiguration } from "./utils/DeployConfiguration.sol";

contract UpdatePTokenConfig is Script, DeployConfiguration {
    using stdJson for string;

    function run(string memory name) external {
        _update("ethereum", name);
    }

    function run(string memory network, string memory name) external {
        _update(network, name);
    }

    function _update(string memory network, string memory name) internal {
        _setConfigurationPath(network);
        _setDeploymentPath(network);

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deployer: ", deployer);

        vm.startBroadcast(deployerPrivateKey);

        _updateConfig(
            string.concat("P-", name),
            string.concat(".markets.pTokens.", name)
        );

        vm.stopBroadcast();
    }

    function _updateConfig(
        string memory deploymentName,
        string memory pathName
    ) internal {
        address marketManager = _getDeployedContract("marketManager");
        console.log("marketManager =", marketManager);
        require(marketManager != address(0), "Set the marketManager!");

        address pToken = _getDeployedContract(deploymentName);
        console.log("pToken =", pToken);
        require(pToken != address(0), "Set the pToken!");

        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = pToken;
        tokenConfig.collRatio = _readConfigUint256(string.concat(pathName, ".collRatio"));
        tokenConfig.collReqSoft = _readConfigUint256(string.concat(pathName, ".collReqSoft"));
        tokenConfig.collReqHard = _readConfigUint256(string.concat(pathName, ".collReqHard"));
        tokenConfig.liqIncBase = _readConfigUint256(string.concat(pathName, ".liqIncBase"));
        tokenConfig.liqIncHard = _readConfigUint256(string.concat(pathName, ".liqIncHard"));
        tokenConfig.liqIncMin = _readConfigUint256(string.concat(pathName, ".liqIncMin"));
        tokenConfig.liqIncMax = _readConfigUint256(string.concat(pathName, ".liqIncMax"));
        tokenConfig.minEffectiveCloseFactor = _readConfigUint256(string.concat(pathName, ".minEffectiveCloseFactor"));
        tokenConfig.maxEffectiveCloseFactor = _readConfigUint256(string.concat(pathName, ".maxEffectiveCloseFactor"));
        tokenConfig.baseCFactor = _readConfigUint256(string.concat(pathName, ".baseCFactor"));
        tokenConfig.collateralCap = _readConfigUint256(string.concat(pathName, ".collateralCap"));
        tokenConfig.debtCap = _readConfigUint256(string.concat(pathName, ".debtCap"));

        MarketManagerIsolated(marketManager).updateTokenConfig(tokenConfig);
        console.log("updateTokenConfig");

    }
}
