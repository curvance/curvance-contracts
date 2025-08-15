// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { VelodromeVolatileCToken, ICentralRegistry, IERC20 } from "contracts/market/token/VelodromeVolatileCToken.sol";

import { IVeloGauge } from "contracts/interfaces/external/velodrome/IVeloGauge.sol";
import { IVeloPairFactory } from "contracts/interfaces/external/velodrome/IVeloPairFactory.sol";
import { IVeloRouter } from "contracts/interfaces/external/velodrome/IVeloRouter.sol";

contract AerodromeVolatileCToken is VelodromeVolatileCToken {
    /// CONSTRUCTOR ///

    /// @param cr The address of the Protocol Central Registry.
    /// @param asset_ The address of the underlying asset for this cToken.
    /// @param mm The address of the MarketManager which manages liquidity
    ///           positions between linked cTokens inside a joint market.
    /// @param vestingPeriod_ The length of time a vesting period will last,
    ///                       in seconds.
    constructor(
        ICentralRegistry cr,
        IERC20 asset_,
        address mm,
        IVeloGauge gauge,
        IVeloPairFactory pairFactory,
        IVeloRouter router,
        uint256 vestingPeriod_
    )
        VelodromeVolatileCToken(
            cr,
            asset_,
            mm,
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
