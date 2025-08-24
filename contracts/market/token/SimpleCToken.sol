// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { BaseCToken, ICentralRegistry, IERC20 } from "contracts/market/token/BaseCToken.sol";

/// @dev `Asset()` Positions must have all assets ready for withdraw,
///      IE assets can NOT be locked.
///      This way assets can be easily liquidated when loans default.
/// @dev Built to support assets that do not generate rewards in external,
///      claimable tokens. Meaning SimpleCToken is built for assets such as:
///      WETH, LSTs, Principal Tokens, Stablecoins, Yield-bearing stablecoins,
///      etc.
contract SimpleCToken is BaseCToken {
    /// CONSTRUCTOR ///

    /// @param cr The address of the Protocol Central Registry.
    /// @param asset_ The address of the underlying asset for this cToken.
    /// @param mm The address of the MarketManager which manages liquidity
    ///           positions between linked cTokens inside a joint market.
    constructor(
        ICentralRegistry cr,
        IERC20 asset_,
        address mm
    ) BaseCToken(cr, asset_, mm) {}
}
