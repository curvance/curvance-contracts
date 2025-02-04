// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { SimpleRewardZapper } from "contracts/plugins/rewards/SimpleRewardZapper.sol";
import { ZapperBase } from "contracts/plugins/ZapperBase.sol";

contract TestBaseSimpleRewardZapper is TestBaseMarket {}
