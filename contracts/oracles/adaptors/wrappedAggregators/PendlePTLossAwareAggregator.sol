// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { PendlePTAggregator } from "contracts/oracles/adaptors/wrappedAggregators/PendlePTAggregator.sol";

import { IPPrincipalToken } from "contracts/interfaces/external/pendle/IPPrincipalToken.sol";
import { IStandardizedYield } from "contracts/interfaces/external/pendle/IStandardizedYield.sol";
import { IPYieldToken } from "contracts/interfaces/external/pendle/IPYieldToken.sol";

/// @title Curvance Pendle Principal Token Loss-Aware Aggregator.
/// @notice Pendle PT wrapper that applies Pendle's SY-loss adjustment when
///         SY value falls below the PY index.
contract PendlePTLossAwareAggregator is PendlePTAggregator {
    /// @notice The standardized yield token paired with `PT` at deployment.
    address internal immutable _SY;
    /// @notice The yield token paired with `PT` at deployment.
    address internal immutable _YT;

    /// CONSTRUCTOR ///

    constructor(
        address _PT,
        address _asset,
        address _aggregator,
        uint256 _discountOneYearBPS,
        string memory id
    )
        PendlePTAggregator(
            _PT,
            _asset,
            _aggregator,
            _discountOneYearBPS,
            id
        )
    {
        _SY = IPPrincipalToken(_PT).SY();
        _YT = IPPrincipalToken(_PT).YT();
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Returns the current exchange rate between `PT` and the
    ///         underlying `asset`, normalized in `WAD`.
    function _getExchangeRate()
        internal
        view
        override
        returns (uint256 exchangeRate)
    {
        exchangeRate = _adjustForSYLoss(super._getExchangeRate());
    }

    /// @notice Applies Pendle's SY-loss adjustment when SY value has fallen
    ///         below the PY index.
    function _adjustForSYLoss(
        uint256 exchangeRate
    ) internal view returns (uint256) {
        uint256 syIndex = IStandardizedYield(_SY).exchangeRate();
        uint256 pyIndexStored = IPYieldToken(_YT).pyIndexStored();
        uint256 pyIndex = pyIndexStored;

        if (IPYieldToken(_YT).doCacheIndexSameBlock()) {
            if (
                IPYieldToken(_YT).pyIndexLastUpdatedBlock() != block.number &&
                syIndex > pyIndexStored
            ) {
                pyIndex = syIndex;
            }
        } else if (syIndex > pyIndexStored) {
            pyIndex = syIndex;
        }

        if (pyIndex == 0) return 0;

        if (syIndex >= pyIndex) return exchangeRate;

        return (exchangeRate * syIndex) / pyIndex;
    }
}
