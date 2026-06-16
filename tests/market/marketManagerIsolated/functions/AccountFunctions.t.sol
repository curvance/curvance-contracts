// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { ICToken } from "contracts/interfaces/ICToken.sol";

import { BAD_SOURCE } from "contracts/libraries/ConstantsLib.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";

import { TestBaseLiquidations } from "tests/market/liquidations/TestBaseLiquidations.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";

contract AccountFunctionsTest is TestBaseLiquidations {

    function setUp() public override {
        super.setUp();

        _prepareLiquidation();
    }

    function test_assetsOf() public view {
        address[] memory assets = marketManagerIsolated.assetsOf(user1);
        assertEq(assets.length, 2);
        assertEq(address(assets[0]), address(pendleStrategyCTokenSTETH));
        assertEq(address(assets[1]), address(borrowableCUSDC));
    }

    function test_statusOf() public {
        mockUsdcFeed.setMockAnswer(1e8); // reset price back to $1

        pendleStrategyCTokenSTETH.accrueIfNeeded();
        borrowableCUSDC.accrueIfNeeded();

        (uint256 accountCollateral, uint256 maxDebt, uint256 accountDebt) = marketManagerIsolated.statusOf(user1);

        uint256 expectedMaxDebt = 7000 * accountCollateral / 10000; // 70% LTV
        assertEq(maxDebt, expectedMaxDebt,"max debt mismatch");

        uint256 expectedDebt = borrowableCUSDC.debtBalance(user1) * 1e12;
        assertEq(accountDebt, expectedDebt, "account debt mismatch");
    }

    function test_statusOf_fail_whenDebtOracleIsStale() public {
        uint256 staleTimestamp =
            block.timestamp - chainlinkAdaptor.DEFAULT_HEARTBEAT() - 1;
        mockUsdcFeed.setMockUpdatedAt(staleTimestamp);

        (, uint256 errorCode) =
            oracleManager.getPrice(_USDC_ADDRESS, true, true);
        assertEq(errorCode, BAD_SOURCE, "unexpected stale USDC status");

        vm.expectRevert(OracleManager.OracleManager__ErrorCodeFlagged.selector);
        marketManagerIsolated.statusOf(user1);
    }

    function test_statusOf_fail_whenDebtOracleIsFutureDated() public {
        uint256 futureTimestamp = block.timestamp + 1;
        mockUsdcFeed.setMockUpdatedAt(futureTimestamp);

        (, uint256 errorCode) =
            oracleManager.getPrice(_USDC_ADDRESS, true, true);
        assertEq(errorCode, BAD_SOURCE, "unexpected future USDC status");

        vm.expectRevert(OracleManager.OracleManager__ErrorCodeFlagged.selector);
        marketManagerIsolated.statusOf(user1);
    }

}
