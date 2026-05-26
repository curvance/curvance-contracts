// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IOracleManager} from "contracts/interfaces/IOracleManager.sol";

contract RiskReader {
    /// TYPES ///
    struct OraclePriceStatus {
        address asset;
        bool inUSD;
        bool getLower;
        uint256 price;
        uint256 errorCode;
        uint256 flags;
    }

    /// CONSTANTS ///

    uint256 public constant FLAG_CALL_FAILED = 1 << 0;
    uint256 public constant FLAG_ZERO_PRICE = 1 << 1;

    /// EXTERNAL FUNCTIONS ///

    /// @notice Returns batched OracleManager price status for `assets`.
    /// @dev This uses the same oracle route the protocol uses instead of
    ///      reading underlying feeds directly. A non-zero price indicates the
    ///      OracleManager route returned a usable price; zero or failed calls
    ///      should be treated as stale/unavailable by analytics.
    /// @param oracleManager The Curvance OracleManager to read prices from.
    /// @param assets Assets or cTokens to price.
    /// @param inUSD Whether prices should be denominated in USD.
    /// @param getLower Whether OracleManager should return the lower price
    ///                 when multiple adaptors are configured.
    /// @return statuses Per-asset OracleManager price status.
    function getOraclePriceStatuses(address oracleManager, address[] calldata assets, bool inUSD, bool getLower)
        external
        view
        returns (OraclePriceStatus[] memory statuses)
    {
        uint256 numAssets = assets.length;
        statuses = new OraclePriceStatus[](numAssets);

        IOracleManager manager = IOracleManager(oracleManager);

        for (uint256 i; i < numAssets; ++i) {
            statuses[i].asset = assets[i];
            statuses[i].inUSD = inUSD;
            statuses[i].getLower = getLower;

            try manager.getPrice(assets[i], inUSD, getLower) returns (uint256 price, uint256 errorCode) {
                statuses[i].price = price;
                statuses[i].errorCode = errorCode;

                if (price == 0) {
                    statuses[i].flags |= FLAG_ZERO_PRICE;
                }
            } catch {
                statuses[i].flags |= FLAG_CALL_FAILED | FLAG_ZERO_PRICE;
            }
        }
    }
}
