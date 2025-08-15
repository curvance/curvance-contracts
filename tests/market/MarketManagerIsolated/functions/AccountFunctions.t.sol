// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import { ICToken } from "contracts/interfaces/ICToken.sol";

import { TestBaseLiquidations } from "tests/market/liquidations/TestBaseLiquidations.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";

contract AccountFunctionsTest is TestBaseLiquidations {

    function setUp() public override {
        super.setUp();

        _prepareLiquidation();
    }

    function test_assetsOf() public {
        address[] memory assets = marketManagerIsolated.assetsOf(user1);
        assertEq(assets.length, 2);
        assertEq(address(assets[0]), address(strategyCBALRETH));
        assertEq(address(assets[1]), address(borrowableCUSDC));
    }

    function test_statusOf() public {
        mockUsdcFeed.setMockAnswer(1e8); // reset price back to $1

        (uint256 accountCollateral, uint256 maxDebt, uint256 accountDebt) = marketManagerIsolated.statusOf(user1);

        uint256 expectedMaxDebt = 7000 * accountCollateral / 10000; // 70% LTV

        assertEq(maxDebt, expectedMaxDebt,"max debt mismatch");

        assertEq(accountDebt, 1e21, "account debt mismatch");

    }

}