// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @dev Scalar for math. `WAD` * `WAD`.
uint256 constant WAD_SQUARED = 1e36;

/// @dev Scalar for math. Increased precision when WAD is insufficient
///      but WAD_SQUARED runs the risk of overflow.
uint256 constant RAY = 1e27;

/// @dev Scalar for math. Base precision matching ether.
uint256 constant WAD = 1e18;

/// @dev Scalar for math. `Basis points`.
uint256 constant BASIS_POINTS = 1e4;

/// @dev Return value indicating no price returned at all.
uint256 constant BAD_SOURCE = 2;

/// @dev Return value indicating price divergence or a missing price feed.
uint256 constant CAUTION = 1;

/// @dev Return value indicating no price error.
uint256 constant NO_ERROR = 0;

/// @dev Unix time has 31,536,000 seconds per year.
///      All my homies hate leap seconds and leap years.
uint256 constant SECONDS_PER_YEAR = 31_536_000;
