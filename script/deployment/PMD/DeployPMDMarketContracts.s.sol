// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {DeployScript} from "../../utils/DeployScript.sol";

import {DynamicIRM} from "contracts/market/DynamicIRM.sol";
import {MarketManagerIsolated} from "contracts/market/isolated/MarketManagerIsolated.sol";
import {BorrowableCToken} from "contracts/market/token/BorrowableCToken.sol";
import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";
import {IERC20} from "contracts/interfaces/IERC20.sol";

/// @notice Deploys cTokens and IRMs for a MarketManagerIsolated that has
///         already been registered in the CentralRegistry.
/// @dev This script intentionally does not call privileged setup functions:
///      `DynamicIRM.setLinkedToken` and `OracleManager.addCTokenSupport`
///      should be queued in the Safe batch after these addresses are known.
///      The `canBorrow` ListConfig field is retained for DeployMarkets
///      compatibility, but PMD market deployment follows the current
///      production convention of always deploying BorrowableCToken + DynamicIRM.
contract DeployPMDMarketContracts is DeployScript {
    struct DynamicInterestRateConfig {
        uint256 baseRatePerYear;
        uint256 vertexRatePerYear;
        uint256 vertexStart;
        uint256 adjustmentVelocity;
        uint256 decayPerAdjustment;
        uint256 vertexMultiplierMax;
    }

    struct ListConfig {
        address asset;
        bool canBorrow;
        MarketManagerIsolated.TokenConfig tokenConfig;
        DynamicInterestRateConfig interestConfig;
    }

    error DeployPMDMarketContracts__InvalidTokenLength();

    function run(address centralRegistry, string memory marketName, address marketManager, ListConfig[] memory tokens)
        external
        recordEvents
    {
        if (tokens.length != 2) {
            revert DeployPMDMarketContracts__InvalidTokenLength();
        }

        ICentralRegistry cr = ICentralRegistry(centralRegistry);
        string memory outputKey = string.concat("markets.", marketName);

        for (uint256 i; i < tokens.length; ++i) {
            _deployMarketToken(cr, outputKey, marketManager, tokens[i]);
        }
    }

    function _deployMarketToken(
        ICentralRegistry cr,
        string memory outputKey,
        address marketManager,
        ListConfig memory config
    ) internal {
        IERC20 asset = IERC20(config.asset);
        string memory symbol = asset.symbol();

        DynamicIRM irm = new DynamicIRM(
            cr,
            config.interestConfig.baseRatePerYear,
            config.interestConfig.vertexRatePerYear,
            config.interestConfig.vertexStart,
            config.interestConfig.adjustmentVelocity,
            config.interestConfig.decayPerAdjustment,
            config.interestConfig.vertexMultiplierMax
        );

        emit ContractDeployed(address(irm), string.concat(outputKey, ".irms.", symbol));

        BorrowableCToken cToken = new BorrowableCToken(cr, asset, marketManager, address(irm));

        emit ContractDeployed(address(cToken), string.concat(outputKey, ".tokens.", symbol));
    }
}
