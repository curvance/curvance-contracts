// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { VelodromeStablePToken, ICentralRegistry, IERC20, IVeloGauge, IVeloPairFactory, IVeloRouter } from "contracts/market/token/VelodromeStablePToken.sol";

contract AerodromeStablePToken is VelodromeStablePToken {
    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        IERC20 asset_,
        address marketManager_,
        IVeloGauge gauge,
        IVeloPairFactory pairFactory,
        IVeloRouter router
    )
        VelodromeStablePToken(
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
