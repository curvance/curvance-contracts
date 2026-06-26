// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { VaultAggregator } from "contracts/oracles/adaptors/wrappedAggregators/VaultAggregator.sol";

import { IEarnAUSD } from "contracts/interfaces/external/agora/IEarnAUSD.sol";

contract EarnAUSDAggregator is VaultAggregator {
    /// CONSTRUCTOR ///

    constructor(
        address earnAUSD,
        address AUSD,
        address AUSDAggregator,
        string memory id
    ) VaultAggregator(earnAUSD, AUSD, AUSDAggregator, id) {}

    /// INTERNAL FUNCTIONS ///

    /// @notice Returns the current exchange rate between the wrapped asset
    ///         and the underlying aggregator, in `WAD`.
    /// @return result The current exchange rate between the wrapped asset
    ///                and the underlying aggregator, in `WAD`.
    function _getExchangeRate() internal view override returns (
        uint256 result
    ) {
        if (!_isAssetConfigValid()) return 0;

        // Earn AUSD contract returns naturally in `_vaultDecimalPrecision`
        // format, so no adjustment needed.
        result = IEarnAUSD(vault).getSharePrice();
    }
}
