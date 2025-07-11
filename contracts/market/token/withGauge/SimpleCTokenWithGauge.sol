// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BaseCTokenWithGauge } from "contracts/market/token/withGauge/BaseCTokenWithGauge.sol";

import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

/// @dev Built to support assets that do not generate rewards in external,
///      claimable tokens. Meaning SimpleCTokenWithGauge is built for assets
///      such as:
///      WETH, LSTs, Principal Tokens, Stablecoins, Yield-bearing stablecoins,
///      etc.
///
///      All token deposits are recorded in the protocol "Gauge Manager"
///      facilitating the distribution of native tokens both liquid and
///      locked to users based on their contributions to the protocol over
///      time.
contract SimpleCTokenWithGauge is BaseCTokenWithGauge {
    /// CONSTRUCTOR ///

    /// @param centralRegistry_ The address of the Protocol Central Registry.
    /// @param asset_ The address of the underlying asset for this cToken.
    /// @param marketManager_ The address of the MarketManager which manages
    ///                       liquidity positions between linked cTokens
    ///                       inside a joint market.
    constructor(
        ICentralRegistry centralRegistry_,
        IERC20 asset_,
        address marketManager_
    ) BaseCTokenWithGauge(centralRegistry_, asset_, marketManager_) {}
}
