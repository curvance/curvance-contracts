// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { BasePTokenWithGauge, SafeTransferLib } from "contracts/market/token/withGauge/BasePTokenWithGauge.sol";

import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

/// @notice Vault Positions must have all assets ready for withdraw,
///         IE assets can NOT be locked.
///         This way assets can be easily liquidated when loans default.
/// @dev Built to support assets that do not generate rewards in external,
///      claimable tokens. Meaning SimplePToken is built for assets such as:
///      WETH, LSTs, Principal Tokens, Stablecoins, Yield-bearing stablecoins,
///      etc.
///
///      All token deposits are recorded in the protocol "Gauge Manager"
///      facilitating the distribution of native tokens both liquid and
///      locked to users based on their contributions to the protocol over
///      time.
contract SimplePToken is BasePTokenWithGauge {
    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        IERC20 asset_,
        address marketManager_
    ) BasePTokenWithGauge(centralRegistry_, asset_, marketManager_) {}
}
