// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

/// @title LendingOptimizerHarness
/// @notice Exposes internal functions and state for testing exchangeRateUpdated() coverage.
contract LendingOptimizerHarness is LendingOptimizer {

    constructor(
        IERC20 asset_,
        ICentralRegistry _centralRegistry,
        address[] memory _approvedCTokens,
        uint256[] memory _allocationCapsBps,
        uint256 _feeBps,
        uint256 _vestingPeriod
    ) LendingOptimizer(
        asset_,
        _centralRegistry,
        _approvedCTokens,
        _allocationCapsBps,
        _feeBps,
        _vestingPeriod
    ) {}

    /// @notice Exposes _assetsToVest() for direct testing.
    function exposed_assetsToVest() external view returns (uint256) {
        return _assetsToVest();
    }

    /// @notice Computes vesting with specific params for testing.
    function exposed_assetsToVest(
        uint256 vestingRate,
        uint256 vestingEnd,
        uint256 lastVestingClaim
    ) external view returns (uint256) {
        if (vestingRate > 0 && lastVestingClaim < vestingEnd) {
            return (
                block.timestamp < vestingEnd
                    ? vestingRate * (block.timestamp - lastVestingClaim)
                    : vestingRate * (vestingEnd - lastVestingClaim)
            ) / 1e18;
        }
        return 0;
    }

    /// @notice Returns the indexed total assets (without pending vest).
    function exposed_totalAssetsIndexed() external view returns (uint256) {
        return _totalAssets;
    }

    /// @notice Returns unpacked vesting data.
    /// @return vestingRate The rate of asset vesting per second (in WAD).
    /// @return vestingEnd Timestamp when vesting ends.
    /// @return lastVestingClaim Timestamp of last vesting claim.
    function exposed_getVestingData() external view returns (
        uint256 vestingRate,
        uint256 vestingEnd,
        uint256 lastVestingClaim
    ) {
        uint256 data = _vestingData;
        vestingRate = uint176(data);
        vestingEnd = uint40(data >> 176);
        lastVestingClaim = uint40(data >> 216);
    }

    /// @notice Returns just the vesting rate.
    function exposed_getVestingRate() external view returns (uint256) {
        return uint176(_vestingData);
    }

    /// @notice Returns just the vesting end timestamp.
    function exposed_getVestingEnd() external view returns (uint256) {
        return uint40(_vestingData >> 176);
    }

    /// @notice Returns just the last vesting claim timestamp.
    function exposed_getLastVestingClaim() external view returns (uint256) {
        return uint40(_vestingData >> 216);
    }

    /// @notice Exposes _accrueIfNeeded() for direct testing.
    function exposed_accrueIfNeeded() external {
        _accrueIfNeeded();
    }

    /// @notice Exposes _accrueMarkets() for direct testing.
    function exposed_accrueMarkets() external returns (uint256) {
        return _accrueMarkets();
    }

    /// @notice Checks if currently in active vesting period.
    function exposed_isVestingActive() external view returns (bool) {
        uint256 data = _vestingData;
        uint256 rate = uint176(data);
        uint256 vestingEnd = uint40(data >> 176);
        return rate > 0 && block.timestamp < vestingEnd;
    }

    /// @notice Returns raw _vestingData for inspection.
    function exposed_rawVestingData() external view returns (uint256) {
        return _vestingData;
    }
}
