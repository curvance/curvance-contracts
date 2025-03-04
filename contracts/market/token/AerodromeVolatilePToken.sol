// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { VelodromeVolatilePToken } from "contracts/market/token/VelodromeVolatilePToken.sol";

import { IVeloGauge } from "contracts/interfaces/external/velodrome/IVeloGauge.sol";
import { IVeloPairFactory } from "contracts/interfaces/external/velodrome/IVeloPairFactory.sol";
import { IVeloRouter } from "contracts/interfaces/external/velodrome/IVeloRouter.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

contract AerodromeVolatilePToken is VelodromeVolatilePToken {
    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        IERC20 asset_,
        address marketManager_,
        IVeloGauge gauge,
        IVeloPairFactory pairFactory,
        IVeloRouter router
    )
        VelodromeVolatilePToken(
            centralRegistry_,
            asset_,
            marketManager_,
            gauge,
            pairFactory,
            router
        )
    {}

    /// @notice Validates whether a contract can be deployed based on
    ///         the current chainid.
    /// @dev This check is so incompatible deployments never occur, such as
    ///      assuming the wrong token address on a deployment.
    function _validateChainDeployment() internal view override {
        if (block.chainid != 8453) {
            revert BasePToken__UnsupportedChain();
        }
    }
}
