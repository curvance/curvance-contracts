// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

// Disabled legacy withGauge test base.
//
// The original version imported:
// - contracts/market/token/withGauge/BorrowableCTokenWithGauge.sol
// - contracts/market/token/withGauge/SimpleCTokenWithGauge.sol
//
// Those contracts no longer exist in this checkout. The old gauge integration
// tests that referenced this base are already commented out, so keeping this
// file as a no-op placeholder lets the full disabled_tests harness compile
// without resurrecting deleted withGauge dependencies.
