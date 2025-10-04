// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { BaseWrappedAggregator, WAD } from "contracts/oracles/adaptors/wrappedAggregators/BaseWrappedAggregator.sol";

import { ICToken } from "contracts/interfaces/ICToken.sol";

contract VaultAggregator is BaseWrappedAggregator {
    /// CONSTANTS ///

    /// @notice The address of the vault token.
    address public immutable vault;
    /// @notice The address of the underlying asset token.
    address public immutable asset;

    /// @notice The expanded decimal precision (10 ** decimals) for
    ///         `vault` asset.
    uint256 internal immutable _vaultDecimalPrecision;
    /// @notice The expanded decimal precision (10 ** decimals) for
    ///         `asset` asset, in int256 form.
    int256 internal immutable _assetDecimalPrecision;
    /// @notice The address of the underlying asset aggregator.
    address internal immutable _assetAggregator;

    /// CONSTRUCTOR ///
    
    constructor(address _vault, address _asset, address _aggregator) {
        _checkAssetConfig(_vault, _asset);

        vault = _vault;
        asset = _asset;

        _vaultDecimalPrecision = 10 ** ICToken(_vault).decimals();
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

    /// @notice Returns the current exchange rate between `vault` and the
    ///         and the underlying `asset`, in `_vaultDecimalPrecision`.
    /// @return result The current exchange rate between `vault` and the
    ///                underlying `asset`, in `_vaultDecimalPrecision`.
    function _getExchangeRate() internal view virtual returns (
        uint256 result
    ) {
        // Return exchange rate in `_vaultDecimalPrecision` format directly.
        // We can use ICToken since its an erc4626 vault itself.
        result = ICToken(vault).convertToAssets(_vaultDecimalPrecision);
    }

    /// @notice Validates whether `_vault`'s asset() is `_asset`.
    function _checkAssetConfig(
        address _vault,
        address _asset
    ) internal view virtual {
        if (ICToken(_vault).asset() != _asset) {
            revert BaseWrappedAggregator__InvalidConfig();
        }
    }
}
