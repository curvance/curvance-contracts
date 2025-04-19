// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { MarketManagerBase } from "contracts/market/base-implementation/MarketManagerBase.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { LiquidityManagerBase } from "contracts/market/base-implementation/LiquidityManagerBase.sol";
import { LiquidationManagerBase } from "contracts/market/base-implementation/LiquidationManagerBase.sol";
import { IMToken } from "contracts/interfaces/IMToken.sol";
import { IOracleManager } from "contracts/interfaces/IOracleManager.sol";
import { WAD, WAD_SQUARED } from "contracts/libraries/Constants.sol";

contract IsolatedMarketManager is MarketManagerBase {

    /// STORAGE ///

    /// @notice The position token for the market.
    address public positionToken;

    /// EVENTS /// 
    event PositionTokenUpdated(
        address mToken,
        uint256 collRatio,
        uint256 collReqSoft,
        uint256 collReqHard,
        uint256 liqIncBase,
        uint256 liqIncMin,
        uint256 liqIncMax,
        uint256 baseCFactor
    );

    constructor(
        ICentralRegistry centralRegistry_
    ) MarketManagerBase(centralRegistry_) {} 

    /// PERMISSIONED EXTERNAL FUNCTIONS ///

    /// @notice Add isolated market token pair to the market and set it as
    ///         listed.
    /// @dev Admin function to set isListed for token pair and add support
    ///      for the market. Only callable once due to isolated market design.
    ///      Emits two {TokenListed} events.
    /// @param pToken The address of the market position token to list.
    /// @param eToken The address of the market earn token to list.
    function listTokens(address pToken, address eToken) external {
        _checkDaoPermissions();

        uint256 numTokens = tokensListed.length;
        if (numTokens != 0) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        if (!IMToken(pToken).isPToken() ||  IMToken(eToken).isPToken()) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // List the tokens.
        tokenData[pToken].isListed = true;
        tokenData[eToken].isListed = true;

        // Immediately deposit into the market to prevent any rounding
        // exploits.
        if (!IMToken(pToken).startMarket(msg.sender)) {
            _revert(_INVARIANT_ERROR_SELECTOR);
        }
        if (!IMToken(eToken).startMarket(msg.sender)) {
            _revert(_INVARIANT_ERROR_SELECTOR);
        }

        // Redundantly store position token address for dynamic penalty
        // checks.
        positionToken = pToken;

        // No need to check whether tokens were listed before since this
        // function can only be called once due to numTokens == 0 check.

        // Update frontend array/emit events.
        tokensListed.push(pToken);
        emit TokenListed(pToken);
        tokensListed.push(eToken);
        emit TokenListed(eToken);
    }

    /// @notice Set `newCollateralizationCaps` for the given `pTokens`.
    /// @dev Can emit {NewCollateralCap} events.
    /// @param pToken The addresses of the markets (tokens) to
    ///                change the borrow caps for.
    /// @param newCollateralCap The new collateral cap values in underlying
    ///                          to be set, in  shares.
    function setPTokenCollateralCap(
        address pToken,
        uint256 newCollateralCap
    ) external {
        _checkDaoPermissions();

        // Make sure the pToken is a pToken.
        _checkIsPToken(pToken);

        // Do not let people collateralize assets
        // with collateralization ratio of 0.
        if (tokenData[pToken].collRatio == 0) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        collateralCaps[pToken] = newCollateralCap;
        emit NewCollateralCap(pToken, newCollateralCap);
    }
    

}
