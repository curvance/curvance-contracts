// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { BaseWrappedAggregator } from "contracts/oracles/adaptors/wrappedAggregators/BaseWrappedAggregator.sol";

import { WAD, SECONDS_PER_YEAR } from "contracts/libraries/ConstantsLib.sol";

import { ICToken } from "contracts/interfaces/ICToken.sol";

import { IPPrincipalToken } from "contracts/interfaces/external/pendle/IPPrincipalToken.sol";
import { IStandardizedYield } from "contracts/interfaces/external/pendle/IStandardizedYield.sol";

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
    /// @notice The expanded decimal precision (10 ** decimals) for
    ///         `PT` asset.
    uint256 internal immutable _PTDecimalPrecision;
    /// @notice The expanded decimal precision (10 ** decimals) for
    ///         `asset` asset, in int256 form.
    int256 internal immutable _assetDecimalPrecision;
    /// @notice The address of the underlying asset aggregator.
    address internal immutable _assetAggregator;

    /// CONSTRUCTOR ///
    
    constructor(
        address _PT,
        address _asset,
        address _aggregator,
        uint256 _discountOneYearBPS
    ) {
        // Adjust input from `BPS` to `WAD` since we set protocol values in
        // BPS for consistency.
        _discountOneYearBPS = _discountOneYearBPS * 1e14;

        if (_discountOneYear > WAD) {
            revert BaseWrappedAggregator__InvalidConfig();
        }

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

        _PTDecimalPrecision = 10 ** ICToken(_PT).decimals();
        _assetDecimalPrecision = _toInt256(10 ** ICToken(_asset).decimals());
        _assetAggregator = _aggregator;
    }

    /// PUBLIC FUNCTIONS ///

    /// @notice Returns the underlying aggregator address.
    /// @return r The underlying aggregator address.
    function underlyingAggregator() public view override returns (address r) {
        r = _assetAggregator;
    }

    /// @notice Returns the adjusted `answer` based on the current exchange
    ///         rate between the wrapped asset and the underlying aggregator.
    /// @dev Overridden in implemented wrapped oracle aggregators.
    /// @param answer The answer to adjust based on current exchange rate value.
    /// @return result The adjusted oracle `answer`.
    function getAdjustedAnswer(
        int256 answer
    ) public view virtual override returns (int256 result) {
        // Adjust `answer` by current exchange rate and any difference in decimals.
        result = (answer * _toInt256(_getExchangeRate())) / _assetDecimalPrecision;
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Returns the current exchange rate between `PT` and the
    ///         and the underlying `asset`, in `_PTDecimalPrecision`.
    /// @return result The current exchange rate between `PT` and the
    ///                underlying `asset`, in `_PTDecimalPrecision`.
    function _getExchangeRate() internal view returns (
        uint256 result
    ) {
        uint256 timeToExpiry = _expiry >  block.timestamp ?
            _expiry - block.timestamp : 0;
        // We know this wont overflow since even 1 year _expiry, 100% discount,
        // 40 decimals is only 3.15e65, well below 1.15792e77 limit.
        result = (timeToExpiry * _discountOneYear * _PTDecimalPrecision) /
            SECONDS_PER_YEAR;
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
