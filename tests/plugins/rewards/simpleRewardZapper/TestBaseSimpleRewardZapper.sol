// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { SimpleRewardZapper } from "contracts/plugins/rewards/SimpleRewardZapper.sol";
import { BaseZapper } from "contracts/plugins/BaseZapper.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

contract TestBaseSimpleRewardZapper is TestBaseMarketIsolated {}
