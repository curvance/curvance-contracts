// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { MarketManagerBase } from "contracts/market/base-implementation/MarketManagerBase.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { LiquidityManagerBase } from "contracts/market/base-implementation/LiquidityManagerBase.sol";
import { LiquidationManagerBase } from "contracts/market/base-implementation/LiquidationManagerBase.sol";
import { IMToken } from "contracts/interfaces/IMToken.sol";
import { IOracleManager } from "contracts/interfaces/IOracleManager.sol";
import { WAD, WAD_SQUARED } from "contracts/libraries/Constants.sol";

contract CrossMarketManager is MarketManagerBase {

    /// CONSTANTS ///

    /// @notice Maximum number of listed assets allowed inside a market.
    /// @dev This restriction is to minimize the outside chance that a market
    ///      manager has so many assets that a full account liquidation
    ///      becomes too expensive to support.
    uint256 public constant MAX_LISTED_ASSETS = 25;

    /// EVENTS ///
    event PositionTokenUpdated(
        address mToken,
        uint256 collRatio,
        uint256 collReqSoft,
        uint256 collReqHard,
        uint256 liqIncSoft,
        uint256 liqIncHard,
        uint256 baseCFactor
    );

    constructor(
        ICentralRegistry centralRegistry_
    ) MarketManagerBase(centralRegistry_) {}

    /// PERMISSIONED EXTERNAL FUNCTIONS ///

    /// @notice Add the market token to the market and set it as listed.
    /// @dev Admin function to set isListed and add support for the market.
    ///      Emits a {TokenListed} event.
    /// @param mToken The address of the market token to list.
    function listToken(address mToken) external {
        _checkElevatedPermissions();

        if (tokenData[mToken].isListed) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Sanity check to make sure its really a mToken.
        IMToken(mToken).isPToken();

        uint256 numTokens = tokensListed.length;
        if (numTokens == MAX_LISTED_ASSETS) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // List the token and set collateralization to 0%.
        MarketToken storage token = tokenData[mToken];
        token.collRatio = 0;
        token.isListed = true;

        // Immediately deposit into the market to prevent any rounding
        // exploits.
        if (!IMToken(mToken).startMarket(msg.sender)) {
            _revert(_INVARIANT_ERROR_SELECTOR);
        }

        for (uint256 i; i < numTokens; ) {
            unchecked {
                if (tokensListed[i++] == mToken) {
                    _revert(_INVALID_PARAMETER_SELECTOR);
                }
            }
        }

        tokensListed.push(mToken);
        emit TokenListed(mToken);
    }

    /// @notice Set `newCollateralizationCaps` for the given `pTokens`.
    /// @dev Can emit {NewCollateralCap} events.
    /// @param pTokens The addresses of the markets (tokens) to
    ///                change the borrow caps for.
    /// @param newCollateralCaps The new collateral cap values in underlying
    ///                          to be set, in  shares.
    function setPTokenCollateralCaps(
        address[] calldata pTokens,
        uint256[] calldata newCollateralCaps
    ) external {
        _checkDaoPermissions();

        uint256 numTokens = pTokens.length;

        assembly {
            if iszero(numTokens) {
                // store the error selector to location 0x0.
                mstore(0x0, _INVALID_PARAMETER_SELECTOR)
                // return bytes 29-32 for the selector.
                revert(0x1c, 0x04)
            }
        }

        if (numTokens != newCollateralCaps.length) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        for (uint256 i; i < numTokens; ++i) {
            // Make sure the pToken is a pToken.
            _checkIsPToken(pTokens[i]);

            // Do not let people collateralize assets
            // with collateralization ratio of 0.
            if (tokenData[pTokens[i]].collRatio == 0) {
                _revert(_INVALID_PARAMETER_SELECTOR);
            }

            collateralCaps[pTokens[i]] = newCollateralCaps[i];
            emit NewCollateralCap(pTokens[i], newCollateralCaps[i]);
        }
    }
}