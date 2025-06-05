// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { SimpleRewardZapper } from "contracts/plugins/rewards/SimpleRewardZapper.sol";
import { ZapperBase } from "contracts/plugins/ZapperBase.sol";

contract TestBaseSimpleRewardZapper is TestBaseMarketIsolated {}
