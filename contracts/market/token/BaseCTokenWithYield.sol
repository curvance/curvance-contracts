// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

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
    ///      - [0..127]   `VESTING_RATE`.
    ///      - [128..191] `VEST_END`.
    ///      - [192..255] `LAST_VEST`.
    ///
    ///      BorrowableCToken Bits Layout:
    ///      - [0..95]   `VESTING_RATE`.
    ///      - [96..135] `VEST_END`.
    ///      - [136..175] `LAST_VEST`.
    ///      - [176..255] Market `DEBT_INDEX`.
    uint256 internal _vestingData;

    /// ERRORS ///

    error BaseCTokenWithYield__InvalidVestingPeriod();

    /// CONSTRUCTOR ///

    /// @param cr The address of the Protocol Central Registry.
    /// @param asset_ The address of the underlying asset for this cToken.
    /// @param mm The address of the MarketManager which manages liquidity
    ///           positions between linked cTokens inside a joint market.
    /// @param vestingPeriod_ The length of time a vesting period will last,
    ///                       in seconds.
    constructor(
        ICentralRegistry cr,
        IERC20 asset_,
        address mm,
        uint256 vestingPeriod_
    ) BaseCToken(cr, asset_, mm) {
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
        r = _totalAssets + _assetsToVest();
    }

    /// @notice Calculates pending assets that have been vested.
    /// @dev If there are no pending assets or the vesting period has ended,
    ///      it returns 0.
    /// @return The calculated pending assets to vest.
    function _assetsToVest() internal view virtual returns (uint256);

    /// @notice Returns whether the current vesting period has ended,
    ///         based on the last vest timestamp.
    function _checkVestingFinished(uint256) internal pure virtual returns (bool) {}
}