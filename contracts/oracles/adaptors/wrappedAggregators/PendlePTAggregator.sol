// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { BaseWrappedAggregator } from "contracts/oracles/adaptors/wrappedAggregators/BaseWrappedAggregator.sol";

import { BPS, WAD, SECONDS_PER_YEAR } from "contracts/libraries/ConstantsLib.sol";

import { IPPrincipalToken } from "contracts/interfaces/external/pendle/IPPrincipalToken.sol";
import { IStandardizedYield } from "contracts/interfaces/external/pendle/IStandardizedYield.sol";

/// @title Curvance Pendle Principal Token Aggregator.
/// @notice Modifies an oracle aggregator to return the price for a related
///         Pendle principal token, based on the exchange rate between them.
/// @dev Curvance Pendle PT aggregators are intended to hook up to any
///      onchain push based oracle that supports rounds of data with the
///      "latestRoundData" function interface (see "IChainlink"). An exchange
///      rate between the oracle aggregator's asset and the principal token
///      is calculated and applied to the underlying aggregator's answer.
///
///      This aggregator is intended for PTs whose SY does not have a material
///      principal-loss path. Use `PendlePTLossAwareAggregator` when SY/NAV
///      losses should reduce PT pricing.
///
///      Validation is done on contract deployment to ensure that the linked
///      contracts have the expected asset addresses supported and that any
///      difference in decimals between the assets MUST be adjusted so that
///      the new answer's decimals batches the underlying aggregator's
///      decimals.
///
///      These aggregators should then be listed in the corresponding adaptor
///      (e.g. "ChainlinkAdaptor", "RedstoneClassicAdaptor") to price assets
///      inside Curvance Markets.
///
contract PendlePTAggregator is BaseWrappedAggregator {
    /// CONSTANTS ///

    /// @notice The address of the principal token.
    address public immutable PT;
    /// @notice The address of the underlying asset token.
    address public immutable asset;

    /// @notice The unix timestamp when `PT` expires allowing redemption
    ///         into `asset`.
    uint256 internal immutable _expiry;
    /// @notice The discount `PT` is valued at versus `asset` annualized,
    ///         in `WAD`.
    uint256 internal immutable _discountOneYear;

    /// CONSTRUCTOR ///

    constructor(
        address _PT,
        address _asset,
        address _aggregator,
        uint256 _discountOneYearBPS,
        string memory id
    ) BaseWrappedAggregator(_aggregator, id) {
        if (_discountOneYearBPS >= BPS || _discountOneYearBPS == 0) {
            revert BaseWrappedAggregator__InvalidConfig();
        }

        // Adjust input from `BPS` to `WAD` since we set protocol values in
        // BPS for consistency.
        _discountOneYearBPS = _discountOneYearBPS * 1e14;

        _checkAssetConfig(_PT, _asset);

        _expiry = IPPrincipalToken(_PT).expiry();
        uint256 timeToExpiry = _expiry >  block.timestamp ?
            _expiry - block.timestamp : 0;

        // If somehow the pendle PT does not expire within a year this wrapped
        // aggregator would break, so revert.
        if (timeToExpiry > SECONDS_PER_YEAR) {
            revert BaseWrappedAggregator__InvalidConfig();
        }

        PT = _PT;
        asset = _asset;

        _discountOneYear = _discountOneYearBPS;
    }

    /// PUBLIC FUNCTIONS ///

    /// @notice Returns the adjusted `answer` based on the current exchange
    ///         rate between the wrapped asset and the underlying aggregator.
    /// @dev Overridden in implemented wrapped oracle aggregators.
    /// @param answer The answer to adjust based on current exchange rate value.
    /// @return result The adjusted oracle `answer`.
    function getAdjustedAnswer(
        int256 answer
    ) public view virtual override returns (int256 result) {
        // Adjust `answer` by current exchange rate normalized in `WAD`.
        result = (answer * _toInt256(_getExchangeRate())) / _toInt256(WAD);
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Returns the current exchange rate between `PT` and the
    ///         underlying `asset`, normalized in `WAD`.
    /// @return The current exchange rate between `PT` and the underlying
    ///         `asset`, in `WAD`.
    function _getExchangeRate() internal view virtual returns (uint256) {
        // If the PT has expired directly return `WAD`
        // to price it 1:1 with underlying asset.
        if (block.timestamp >= _expiry) {
            return WAD;
        }

        uint256 timeToExpiry = _expiry - block.timestamp;
        return WAD -
            ((timeToExpiry * _discountOneYear * WAD) /
                (SECONDS_PER_YEAR * WAD));
    }

    /// @notice Validates whether `_PT`'s asset is `_asset`.
    function _checkAssetConfig(
        address _PT,
        address _asset
    ) internal view {
        address SY = IPPrincipalToken(_PT).SY();
        // Pull PT asset configuration from `SY` to compare with `_asset`.
        (, address assetAddress, ) = IStandardizedYield(SY).assetInfo();

        if (_asset != assetAddress) {
            revert BaseWrappedAggregator__InvalidConfig();
        }
    }
}
