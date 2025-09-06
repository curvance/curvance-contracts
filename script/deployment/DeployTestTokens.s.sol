// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { DeployScript } from "../utils/DeployScript.sol";

import { TestnetToken } from "contracts/mocks/TestnetToken.sol";
import { MockOracleAdaptor } from "contracts/mocks/MockOracleAdaptor.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { Faucet } from "contracts/testnet/Faucet.sol";

contract DeployTestTokens is DeployScript {
    function run(
        string[] memory names,
        string[] memory symbols,
        uint8[] memory decimals,
        uint256[] memory faucetInitialBalances,
        uint256[] memory faucetClaimAmounts,
        uint256[] memory prices,
        address registry,
        address mockOracle
    ) external recordEvents {
        ICentralRegistry cr = ICentralRegistry(registry);
        OracleManager oracleManager = OracleManager(cr.oracleManager());
        MockOracleAdaptor adaptor = MockOracleAdaptor(mockOracle);

        address[] memory faucetTokens = new address[](names.length);
        for (uint256 i = 0; i < names.length; i++) {
            string memory symbol = symbols[i];
            TestnetToken token = new TestnetToken(
                names[i],
                symbol,
                decimals[i]
            );
            emit ContractDeployed(address(token), symbol);
            faucetTokens[i] = address(token);

            uint256 price = prices[i];
            if (price != 0) {
                adaptor.addAsset(address(token));
                adaptor.setPrice(address(token), price, price);
                oracleManager.addAssetPriceFeed(
                    address(token),
                    address(adaptor)
                );
            }
        }
        
        address faucet = address(
            new Faucet(faucetTokens, faucetClaimAmounts)
        );
        emit ContractDeployed(faucet, "Faucet");

        for(uint256 i; i < faucetTokens.length; i++) {
            TestnetToken token = TestnetToken(faucetTokens[i]);
            token.mint(faucetInitialBalances[i]);
            token.transfer(faucet, faucetInitialBalances[i]);
        }
    }
}
