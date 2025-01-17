// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";

import { MarketManager } from "contracts/market/MarketManager.sol";

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

        MarketManager(marketManager).updatePositionToken(
            pToken,
            _readConfigUint256(string.concat(pathName, ".collRatio")),
            _readConfigUint256(string.concat(pathName, ".collReqA")),
            _readConfigUint256(string.concat(pathName, ".collReqB")),
            _readConfigUint256(string.concat(pathName, ".liqIncA")),
            _readConfigUint256(string.concat(pathName, ".liqIncB")),
            _readConfigUint256(string.concat(pathName, ".liqFee")),
            _readConfigUint256(string.concat(pathName, ".baseCFactor"))
        );
        console.log("updatePositionToken");

        address[] memory mTokens = new address[](1);
        mTokens[0] = pToken;
        uint256[] memory newCollateralCaps = new uint256[](1);
        newCollateralCaps[0] = _readConfigUint256(
            string.concat(pathName, ".collateralCaps")
        );
        MarketManager(marketManager).setPTokenCollateralCaps(
            mTokens,
            newCollateralCaps
        );
        console.log("setPTokenCollateralCaps");
    }
}
