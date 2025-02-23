// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { BasePToken, IERC20, ICentralRegistry } from "contracts/market/token/BasePToken.sol";

/// @notice Vault Positions must have all assets ready for withdraw,
///         IE assets can NOT be locked.
///         This way assets can be easily liquidated when loans default.
/// @dev Built to support assets that do not generate rewards in external,
///      claimable tokens. Meaning SimplePToken is built for assets such as:
///      WETH, LSTs, Principal Tokens, Stablecoins, Yield-bearing stablecoins,
///      etc.
contract SimplePToken is BasePToken {
    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        IERC20 asset_,
        address marketManager_
    ) BasePToken(centralRegistry_, asset_, marketManager_) {}
}
