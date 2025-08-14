// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @dev Scalar for math. `WAD` * `WAD` * `WAD` / `BPS`.
///      1e18 * 1e18 * 1e18 / 1e4
uint256 constant WAD_CUBED_BPS_OFFSET = 1e50;

/// @dev Scalar for math. `WAD` * `WAD`.
uint256 constant WAD_SQUARED = 1e36;

/// @dev Scalar for math. Increased precision when WAD is insufficient
///      but WAD_SQUARED runs the risk of overflow.
uint256 constant RAY = 1e27;

/// @dev Scalar for math. `WAD` * `BPS`.
uint256 constant WAD_BPS = 1e22;

/// @dev Scalar for math. Base precision matching ether.
uint256 constant WAD = 1e18;

/// @dev Scalar for math. `BPS` * `BPS`.
uint256 constant BPS_SQUARED = 1e8;

/// @dev Scalar for math. Represents basis points typically used in TradFi.
uint256 constant BPS = 1e4;

/// @dev Return value indicating no price returned at all.
uint256 constant BAD_SOURCE = 2;

/// @dev Return value indicating price divergence or a missing price feed.
uint256 constant CAUTION = 1;

/// @dev Return value indicating no price error.
uint256 constant NO_ERROR = 0;

/// @dev Extra time added to top end Oracle feed heartbeat incase of
///      transaction congestion delaying an update.
uint256 constant HEARTBEAT_GRACE_PERIOD = 60;

/// @dev Unix time has 31,536,000 seconds per year.
///      All my homies hate leap seconds and leap years.
uint256 constant SECONDS_PER_YEAR = 31_536_000;
