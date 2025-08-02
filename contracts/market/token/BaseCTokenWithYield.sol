// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BaseCToken, FixedPointMathLib, WAD, IERC20, ICentralRegistry } from "contracts/market/token/BaseCToken.sol";

abstract contract BaseCTokenWithYield is BaseCToken {
    /// CONSTANTS ///

    /// @notice The maximum length of time between vesting periods.
    uint256 internal constant _MAXIMUM_VESTING_PERIOD = 3 days;

    /// STORAGE ///

    /// @notice The period of time harvested rewards are vested over,
    ///         in seconds.
    uint256 public vestingPeriod;

    /// @dev Internal packed vesting data:
    ///      StrategyCToken Bits Layout:
    ///      - [0..127]   `vestingRate`.
    ///      - [128..191] `vestingPeriodEnd`.
    ///      - [192..255] `lastVestingClaim`.
    ///
    ///      BorrowableCToken Bits Layout:
    ///      - [0..95]   `vestingRate`.
    ///      - [96..135] `vestingPeriodEnd`.
    ///      - [136..175] `lastVestingClaim`.
    ///      - [176..255] `marketDebtIndex`.
    uint256 internal _vestingData;

    /// ERRORS ///

    error BaseCTokenWithYield__InvalidVestingPeriod();

    /// CONSTRUCTOR ///

    /// @param centralRegistry_ The address of the Protocol Central Registry.
    /// @param asset_ The address of the underlying asset for this cToken.
    /// @param marketManager_ The address of the MarketManager which manages
    ///                       liquidity positions between linked cTokens
    ///                       inside a joint market.
    /// @param vestingPeriod_ The length of time a vesting period will last,
    ///                       in seconds.
    constructor(
        ICentralRegistry centralRegistry_,
        IERC20 asset_,
        address marketManager_,
        uint256 vestingPeriod_
    ) BaseCToken(centralRegistry_, asset_, marketManager_) {
        _checkVestingPeriod(vestingPeriod_);

        vestingPeriod = vestingPeriod_;
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Validates whether `newPeriod` is a valid value for
    ///         `vestingPeriod`.
    function _checkVestingPeriod(uint256 newPeriod) internal pure {
         if (newPeriod > _MAXIMUM_VESTING_PERIOD && newPeriod != 0) {
            revert BaseCTokenWithYield__InvalidVestingPeriod();
        }
    }

    /// @notice Returns the total amount of the underlying asset in the vault,
    ///         including pending rewards that are vested.
    /// @return r The total number of underlying assets.
    function _getTotalAssets() internal view override returns (uint256 r) {
        r = _totalAssets + _getPendingYield();
    }

    /// @notice Calculates pending yield that have been vested.
    /// @dev If there are no pending yield or the vesting period has ended,
    ///      it returns 0.
    /// @return The calculated pending yield.
    function _getPendingYield() internal view virtual returns (uint256);

    /// @notice Returns whether the current vesting period has ended,
    ///         based on the last vest timestamp.
    function _checkVestingFinished(uint256) internal pure virtual returns (bool) {}
}
