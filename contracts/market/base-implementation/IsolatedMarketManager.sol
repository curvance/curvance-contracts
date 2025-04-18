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

    // Can be flexibly called within cross and isolated implementations to preserve the function signature
    function listTokens(bytes calldata data) external override {
        _checkDaoPermissions();

        (address pToken, address eToken) = abi.decode(data, (address, address));

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

    // Can be flexibly called within cross and isolated implementations to preserve the function signature
    function updatePositionToken(bytes calldata data) external override {
        _checkElevatedPermissions();

        (uint256 collRatio, 
        uint256 collReqSoft, 
        uint256 collReqHard, 
        uint256 liqIncBase, 
        uint256 liqIncMin, 
        uint256 liqIncMax, 
        uint256 baseCFactor) = abi.decode(data, (uint256, uint256, uint256, uint256, uint256, uint256, uint256));
        
        // Convert the parameters from basis points to `WAD` format.
        // While inefficient, we want to minimize potential human error
        // as much as possible, even if it costs a bit extra gas on config.
        collRatio = _bpToWad(collRatio);
        collReqSoft = _bpToWad(collReqSoft);
        collReqHard = _bpToWad(collReqHard);
        liqIncBase = _bpToWad(liqIncBase);
        liqIncMin = _bpToWad(liqIncMin);
        liqIncMax = _bpToWad(liqIncMax);
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

        // Validate hard liquidation collateral requirement is not above
        // the soft liquidation requirement. Liquidations occur when
        // collateral dries up so hard liquidation should be less collateral
        // than soft liquidation.
        if (collReqHard >= collReqSoft) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Make sure the maximum dynamic penalty is not greater than the base
        // liquidation incentive and that the minimum dynamic penalty is not
        // less than the base liquidation incentive.
        if (liqIncBase > liqIncMax || liqIncBase < liqIncMin) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Validate hard liquidation incentive is
        // not above the maximum allowed.
        if (liqIncMax > MAX_LIQUIDATION_INCENTIVE) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Validate maximum liquidation incentive and default is
        // equal or higher than the minimum liquidation incentive.
        if (liqIncMin >= liqIncMax) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Validate hard liquidation collateral requirement is larger
        // than the hard liquidation incentive. We cannot give more incentives
        // than are available. We do not need to check soft liquidation as the
        // restrictions are thinner than this case.
        if (liqIncMax + MIN_EXCESS_COLLATERAL_REQUIREMENT > collReqHard) {
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

        // Cache positionToken storage address.
        address pToken = positionToken;
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

        // We use the liquidation incentive values as a premium in
        // `calculateLiquidatedTokens`, so it needs to be 1 + incentive.
        marketToken.liqBaseIncentive = WAD + liqIncBase;
        marketToken.liqMinIncentive = WAD + liqIncMin;
        marketToken.liqMaxIncentive = WAD + liqIncMax;

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
            liqIncBase,
            liqIncMin,
            liqIncMax,
            baseCFactor
        );
    }
    // refactored isolated version to eliminate the need for a loop
    // Uses first element of arrays, which is less expensive than decoding a bytes calldata
    function setPTokenCollateralCaps(
        address[] calldata pTokens,
        uint256[] calldata newCollateralCaps
    ) override external {
        _checkDaoPermissions();

        assembly {
            if iszero(pTokens.length) {
                // store the error selector to location 0x0.
                mstore(0x0, _INVALID_PARAMETER_SELECTOR)
                // return bytes 29-32 for the selector.
                revert(0x1c, 0x04)
            }
        }
            // Make sure the pToken is a pToken.
            _checkIsPToken(pTokens[0]);

            // Do not let people collateralize assets
            // with collateralization ratio of 0.
            if (tokenData[pTokens[0]].collRatio == 0) {
                _revert(_INVALID_PARAMETER_SELECTOR);
            }

            collateralCaps[pTokens[0]] = newCollateralCaps[0];

    }

    function _canLiquidate(
        address eToken,
        address pToken,
        address account,
        uint256 debtAmount,
        bool liquidateExact
    ) internal view override returns (uint256, uint256) {
        // TODO: implement
    }

    function _canLiquidateMany(
        address[] memory eTokens,
        address[] memory pTokens,
        address[] memory accounts,
        uint256[] memory amounts,
        bool[] memory liquidateExact
    ) internal view override returns (uint256[] memory, uint256[] memory) {
        // TODO: implement
    }

    function _processRepay(
        address[] memory eTokens,
        address[] memory pTokens,
        address[] memory accounts,
        uint256[] memory repayAmounts,
        uint256[] memory seizeAmounts,
        bool[] memory hasBadDebt
    ) internal override {
        // TODO: implement
    }

    function multiSeize(
        address[] memory eTokens,
        address[] memory pTokens,
        address[] memory accounts,
        uint256[] memory seizeAmounts
    ) override external {
        // TODO: implement
    }


    

}
