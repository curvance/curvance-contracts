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

    function listTokens(bytes calldata data) external override {
        _checkElevatedPermissions();

        address mToken = abi.decode(data, (address));

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

    function updatePositionToken(bytes calldata data) external override {
        _checkElevatedPermissions();

        (address pToken, 
        uint256 collRatio, 
        uint256 collReqSoft, 
        uint256 collReqHard, 
        uint256 liqIncSoft, 
        uint256 liqIncHard, 
        uint256 baseCFactor) = 
        abi.decode(data, (address, uint256, uint256, uint256, uint256, uint256, uint256));

        _checkIsListedToken(pToken);
        _checkIsPToken(pToken);

        // Convert the parameters from basis points to `WAD` format.
        // While inefficient, we want to minimize potential human error
        // as much as possible, even if it costs a bit extra gas on config.
        collRatio = _bpToWad(collRatio);
        collReqSoft = _bpToWad(collReqSoft);
        collReqHard = _bpToWad(collReqHard);
        liqIncSoft = _bpToWad(liqIncSoft);
        liqIncHard = _bpToWad(liqIncHard);
        baseCFactor = _bpToWad(baseCFactor);

        // Validate collateralization ratio is not above the maximum allowed.
        if (collRatio > MAX_COLLATERALIZATION_RATIO) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Validate soft liquidation collateral requirement is
        // not above the maximum allowed.
        if (collReqSoft > MAX_COLLATERAL_REQUIREMENT) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Validate hard liquidation incentive is
        // not above the maximum allowed.
        if (liqIncHard > MAX_LIQUIDATION_INCENTIVE) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Validate hard liquidation collateral requirement is not above
        // the soft liquidation requirement. Liquidations occur when
        // collateral dries up so hard liquidation should be less collateral
        // than soft liquidation.
        if (collReqHard >= collReqSoft) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Validate hard liquidation incentive is
        // higher than the soft liquidation incentive. Give heavier incentives
        // when collateral is running out to reduce delta exposure.
        if (liqIncSoft >= liqIncHard) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Validate hard liquidation collateral requirement is larger
        // than the hard liquidation incentive. We cannot give more incentives
        // than are available. We do not need to check soft liquidation as the
        // restrictions are thinner than this case.
        if (liqIncHard + MIN_EXCESS_COLLATERAL_REQUIREMENT > collReqHard) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Validate that soft liquidation is within acceptable bounds.
        if (baseCFactor > MAX_BASE_CFACTOR || baseCFactor < MIN_BASE_CFACTOR) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Validate the soft liquidation collateral premium
        // is not more strict than the asset's CR.
        if (collRatio > (WAD_SQUARED / (WAD + collReqSoft))) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        MarketToken storage marketToken = tokenData[pToken];

        // If this token already has collateralization enabled,
        // we cannot turn collateralization off completely as this
        // would cause downstream effects to the DLE.
        if (marketToken.collRatio != 0 && collRatio == 0) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        (, uint256 errorCode) = IOracleManager(centralRegistry.oracleManager())
            .getPrice(pToken, true, true);

        // Validate that we get a usable price.
        if (errorCode == 2) {
            revert MarketManager__PriceError();
        }

        // Assign new collateralization ratio.
        // Note that a collateralization ratio of 0 corresponds to
        // no collateralization of the pToken.
        marketToken.collRatio = collRatio;

        // Store the collateral requirement as a premium above `WAD`,
        // that way we can calculate solvency via division
        // efficiently in _liquidationStatusOf.
        marketToken.collReqSoft = collReqSoft + WAD;
        marketToken.collReqHard = collReqHard + WAD;

        // Store the distance between liquidation incentive A & B,
        // so we can quickly scale between [base, 100%] based on lFactor.
        marketToken.liqCurve = liqIncHard - liqIncSoft;
        // We use the liquidation incentive values as a premium in
        // `calculateLiquidatedTokens`, so it needs to be 1 + incentive.
        marketToken.liqBaseIncentive = WAD + liqIncSoft;

        // Assign the base cFactor
        marketToken.baseCFactor = baseCFactor;
        // Store the distance between base cFactor and 100%,
        // that way we can quickly scale between [base, 100%] based on lFactor.
        marketToken.cFactorCurve = WAD - baseCFactor;

        emit PositionTokenUpdated(
            pToken,
            collRatio,
            collReqSoft,
            collReqHard,
            liqIncSoft,
            liqIncHard,
            baseCFactor
        );
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
    ) override external {
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