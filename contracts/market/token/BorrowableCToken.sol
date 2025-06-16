// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BaseCTokenWithYield, ICentralRegistry, IERC20 } from "contracts/market/token/BaseCTokenWithYield.sol";

contract BorrowableCToken is BaseCTokenWithYield {
    /// TYPES ///

    /// @notice Struct form of `_vestingData`, a bitshifted packed variable.
    /// @param vestingRate The rate that the vault vests fresh yield.
    /// @param vestingPeriodEnd When the current vesting period ends.
    /// @param lastVestingClaim Last time vesting yield was claimed.
    /// @param debtExchangeRate The most up to date exchange rate for
    ///                         user debt balances.
    struct VestingData {
        uint80 vestingRate;
        uint40 vestingPeriodEnd;
        uint40 lastVestingClaim;
        uint96 debtExchangeRate;
    }

    /// CONSTANTS ///

    /// @dev Mask of vesting rate entry in `_vestingData`.
    uint256 internal constant _BITMASK_VESTING_RATE = (1 << 80) - 1;
    /// @dev Mask of a timestamp entry in `_vestingData`.
    uint256 internal constant _BITMASK_TIMESTAMP = (1 << 40) - 1;
    /// @dev Mask of all bits in packed vault data except the 40 bits
    ///      for `lastVestingClaim`.
    uint256 internal constant _BITMASK_VEST_END_COMPLEMENT = (1 << 120) - 1;
    /// @dev The bit position of `vestingPeriodEnd` in `_vestingData`.
    uint256 internal constant _BITPOS_VEST_END = 80;
    /// @dev The bit position of `lastVestingClaim` in `_vestingData`.
    uint256 internal constant _BITPOS_LAST_VEST = 120;
    /// @dev The bit position of `debtExchangeRate` in `_vestingData`.
    uint256 internal constant _BITPOS_DEBT_EXCHANGE_RATE = 160;

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        IERC20 asset_,
        address marketManager_,
        uint256 vestPeriod_
    ) BaseCTokenWithYield(centralRegistry_, asset_, marketManager_, vestPeriod_) {}

    /// @notice Sets a new `_vestingData` invariant based on `yieldToVest`,
    ///         and `periodToVest` parameters together with the current
    ///         block timestamp.
    /// @param yieldToVest The yield to vest over `periodToVest`.
    /// @param periodToVest The period in which `yieldToVest` is vested
    ///                     over to users.
    function _setNewVestingData(
        uint256 yieldToVest,
        uint256 periodToVest
    ) internal {}

    /// @notice Packs parameters together with current block timestamp to
    ///         calculate the new packed vault data value.
    /// @param newlastVestTimestamp The timestamp of when the last vest occurred.
    /// @param newDebtExchangeRate The new exchange rate for debt to be
    ///                            calculated at.
    /// @return result The new packed vault data value.
    function _vestInterest(
        uint256 newlastVestTimestamp,
        uint256 newDebtExchangeRate
    ) internal view virtual returns (uint256 result) {}

    /// @notice Returns whether the current vesting period has ended,
    ///         based on the last vest timestamp.
    /// @param packedVestingData Current packed vault data value.
    /// @return result Boolean value indicating whether the current
    ///                vesting period has ended or not.
    function _checkVestStatus(
        uint256 packedVestingData
    ) internal pure override returns (bool result) {}

    /// @notice Calculates pending yield that have been vested.
    /// @dev If there are no pending yield or the vesting period has ended,
    ///      it returns 0.
    /// @return pendingYield The calculated pending yield.
    function _calculatePendingYield()
        internal
        view
        override
        returns (uint256 pendingYield) {}

    /// @notice Vests pending yield, and updates vesting data.
    function _vestYield(uint256 /* newTotalAssets */) internal override {}

}
