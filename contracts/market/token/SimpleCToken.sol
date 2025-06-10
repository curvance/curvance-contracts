// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BaseCToken, ICentralRegistry, IERC20 } from "contracts/market/token/BaseCToken.sol";

/// @notice Asset positions must always be ready for withdraw,
///         IE assets can NOT be locked.
///         This way assets can be easily liquidated when loans default.
/// @dev Built to support assets that do not generate rewards in external,
///      claimable tokens. Meaning SimpleCToken is built for assets such as:
///      WETH, LSTs, Principal Tokens, Stablecoins, Yield-bearing stablecoins,
///      etc.
contract SimpleCToken is BaseCToken {
    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        IERC20 asset_,
        address marketManager_
    ) BaseCToken(centralRegistry_, asset_, marketManager_) {}
}
