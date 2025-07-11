// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { VelodromeStableCToken, ICentralRegistry, IERC20 } from "contracts/market/token/VelodromeStableCToken.sol";

import { IVeloGauge } from "contracts/interfaces/external/velodrome/IVeloGauge.sol";
import { IVeloPairFactory } from "contracts/interfaces/external/velodrome/IVeloPairFactory.sol";
import { IVeloRouter } from "contracts/interfaces/external/velodrome/IVeloRouter.sol";

contract AerodromeStableCToken is VelodromeStableCToken {
    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        IERC20 asset_,
        address marketManager_,
        IVeloGauge gauge,
        IVeloPairFactory pairFactory,
        IVeloRouter router,
        uint256 vestingPeriod_
    )
        VelodromeStableCToken(
            centralRegistry_,
            asset_,
            marketManager_,
            gauge,
            pairFactory,
            router,
            vestingPeriod_
        )
    {}

    /// INTERNAL FUNCTIONS ///

    /// @notice Validates whether a contract can be deployed based on
    ///         the current chainid.
    /// @dev This check is so incompatible deployments never occur, such as
    ///      assuming the wrong token address on a deployment.
    function _validateChainDeployment() internal view override {
        if (block.chainid != 8453) {
            revert BaseCToken__UnsupportedChain();
        }
    }
}
