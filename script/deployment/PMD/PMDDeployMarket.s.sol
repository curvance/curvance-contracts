// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {DeployScript} from "../../utils/DeployScript.sol";

import {ProtocolManagerDeployment} from "contracts/architecture/ProtocolManagerDeployment.sol";
import {MarketManagerIsolated} from "contracts/market/isolated/MarketManagerIsolated.sol";
import {ICToken} from "contracts/interfaces/ICToken.sol";
import {IERC20} from "contracts/interfaces/IERC20.sol";

/// @notice Calls an already-authorized ProtocolManagerDeployment to list,
///         pause, and configure a two-token isolated market.
/// @dev The caller must be the ProtocolManagerDeployment owner and must hold
///      77777 raw units of each underlying asset.
contract PMDDeployMarket is DeployScript {
    function run(
        address protocolManagerDeployment,
        address marketManager,
        address cToken0,
        address cToken1,
        MarketManagerIsolated.TokenConfig memory config0,
        MarketManagerIsolated.TokenConfig memory config1
    ) external recordEvents {
        ProtocolManagerDeployment pmd = ProtocolManagerDeployment(protocolManagerDeployment);
        uint256 reserve = pmd.BASE_UNDERLYING_RESERVE();

        IERC20(ICToken(cToken0).asset()).approve(protocolManagerDeployment, reserve);
        IERC20(ICToken(cToken1).asset()).approve(protocolManagerDeployment, reserve);

        pmd.deployMarket(marketManager, cToken0, cToken1, config0, config1);
    }
}
