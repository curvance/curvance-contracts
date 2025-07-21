// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "tests/market/TestBaseMarketIsolated.sol";
import { MockSimpleCToken } from "contracts/mocks/MockSimpleCToken.sol";
import { MockERC20Token } from "contracts/mocks/MockERC20Token.sol";

import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";
import { WAD } from "contracts/libraries/Constants.sol";
import { PriceReturnData } from "contracts/interfaces/IOracleAdaptor.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

import "forge-std/console2.sol";

// helpers to quickly deploy multiple market managers with different tokens
// helpers to validate liquidations

contract TestBaseMarketManagerMultiMarkets is TestBaseMarketIsolated {

    MarketManagerIsolated[] public marketManagers;

    function setUp() public override {
        super.setUp();
    }

    function _deployMarketManager(address token0, address token1) internal {
        
    }

}