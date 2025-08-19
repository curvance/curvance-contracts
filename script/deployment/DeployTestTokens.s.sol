// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Script } from "forge-std/Script.sol";
import { Vm } from "forge-std/Vm.sol";
import { DeploymentLogger } from "../utils/DeploymentLogger.sol";
import { TestnetToken } from "contracts/mocks/TestnetToken.sol";
import { MockOracleAdaptor } from "contracts/mocks/MockOracleAdaptor.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { Faucet } from "contracts/testnet/Faucet.sol";

contract DeployTestTokens is Script, DeploymentLogger {
    function run(
        string[] memory names,
        string[] memory symbols,
        uint8[] memory decimals,
        uint256[] memory initialBalances,
        uint240[] memory prices,
        address registry
    ) external recordEvents {
        ICentralRegistry cr = ICentralRegistry(registry);
        OracleManager oracleManager = OracleManager(cr.oracleManager());

        Faucet faucet = new Faucet();
        emit ContractDeployed(address(faucet), "Faucet");

        MockOracleAdaptor adaptor = new MockOracleAdaptor(cr);
        oracleManager.addApprovedAdaptor(address(adaptor));
        emit ContractDeployed(address(adaptor), string.concat("MockOracle"));

        for (uint256 i = 0; i < names.length; i++) {
            // Create fake test token
            string memory symbol = symbols[i];
            TestnetToken token = new TestnetToken(
                names[i],
                symbol,
                decimals[i]
            );
            emit ContractDeployed(address(token), symbol);

            // Load faucet
            token.mint(initialBalances[i]);
            token.transfer(address(faucet), initialBalances[i]);

            // Setup fake oracle feed
            uint240 price = prices[i];
            if (price != 0) {
                adaptor.addAsset(address(token));
                adaptor.setPrice(address(token), price, price);
                oracleManager.addAssetPriceFeed(
                    address(token),
                    address(adaptor)
                );
            }
        }
    }
}
