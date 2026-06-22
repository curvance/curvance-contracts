// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {DeployScript} from "../../utils/DeployScript.sol";

import {DynamicIRM} from "contracts/market/DynamicIRM.sol";
import {
    MarketManagerIsolated
} from "contracts/market/isolated/MarketManagerIsolated.sol";
import {BorrowableCToken} from "contracts/market/token/BorrowableCToken.sol";
import {
    LendingOptimizerShareCToken
} from "contracts/market/token/LendingOptimizerShareCToken.sol";
import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";
import {IERC20} from "contracts/interfaces/IERC20.sol";
import {ILendingOptimizer} from "contracts/interfaces/ILendingOptimizer.sol";

/// @notice Deploys cTokens and IRMs for a MarketManagerIsolated that has
///         already been registered in the CentralRegistry.
/// @dev This script intentionally does not call privileged setup functions:
///      `DynamicIRM.setLinkedToken` and `OracleManager.addCTokenSupport`
///      should be queued in the Safe batch after these addresses are known.
///      `cTokenType` chooses the cToken implementation while the market token
///      config controls whether the token receives a debt cap.
contract DeployPMDMarketContracts is DeployScript {
    uint8 internal constant CTOKEN_TYPE_BORROWABLE = 0;
    uint8 internal constant CTOKEN_TYPE_LENDING_OPTIMIZER_SHARE = 1;

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
        uint8 cTokenType;
        MarketManagerIsolated.TokenConfig tokenConfig;
        DynamicInterestRateConfig interestConfig;
    }

    error DeployPMDMarketContracts__InvalidTokenLength();
    error DeployPMDMarketContracts__InvalidCTokenType();

    function run(
        address centralRegistry,
        string memory marketName,
        address marketManager,
        ListConfig[] memory tokens
    ) external recordEvents {
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

        emit ContractDeployed(
            address(irm), string.concat(outputKey, ".irms.", symbol)
        );

        address cToken;
        if (config.cTokenType == CTOKEN_TYPE_BORROWABLE) {
            cToken = address(
                new BorrowableCToken(cr, asset, marketManager, address(irm))
            );
        } else if (config.cTokenType == CTOKEN_TYPE_LENDING_OPTIMIZER_SHARE) {
            cToken = address(
                new LendingOptimizerShareCToken(
                    cr,
                    ILendingOptimizer(config.asset),
                    marketManager,
                    address(irm)
                )
            );
        } else {
            revert DeployPMDMarketContracts__InvalidCTokenType();
        }

        emit ContractDeployed(
            cToken, string.concat(outputKey, ".tokens.", symbol)
        );
    }
}
