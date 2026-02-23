// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { SimpleRewardZapper } from "contracts/plugins/rewards/SimpleRewardZapper.sol";
import { BaseZapper } from "contracts/plugins/BaseZapper.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

contract TestBaseSimpleRewardZapper is TestBaseMarketIsolated {}
