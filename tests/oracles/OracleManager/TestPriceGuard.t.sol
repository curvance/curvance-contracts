// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { BaseOracleAdaptor } from "contracts/oracles/adaptors/BaseOracleAdaptor.sol";

import { SECONDS_PER_YEAR, WAD } from "contracts/libraries/ConstantsLib.sol";

import { IOracleAdaptor } from "contracts/interfaces/IOracleAdaptor.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { console2 } from "forge-std/console2.sol";

contract PriceGuardTest is TestBaseMarketIsolated {

    function setUp() public virtual override {
        super.setUp();

        mockWethFeed.setMockUpdatedAt(block.timestamp);
        mockWethFeed.setMockAnswer(3500e8);
        // Make ETH feed match WETH for dual adaptor
        chainlinkEthUsd.updateAnswer(3500e8);
    }

    // Guard type cannot be 0 or > 2
    function test_fail_whenGuardTypeIsInvalid() public {

        vm.expectRevert(BaseOracleAdaptor.BaseOracleAdaptor__InvalidConfig.selector);
        chainlinkAdaptor.setGuardedPriceConfig(
            _ETH_ADDRESS,
            true,
            3,
            0,
            block.timestamp,
            3400e18,
            3600e18);

        vm.expectRevert(BaseOracleAdaptor.BaseOracleAdaptor__InvalidConfig.selector);
        chainlinkAdaptor.setGuardedPriceConfig(
            _ETH_ADDRESS,
            true,
            0,
            0,
            block.timestamp,
            3400e18,
            3600e18);
    }

    function test_fail_when_timestampStartIsSoonerThanBuffer() public {

        vm.expectRevert(BaseOracleAdaptor.BaseOracleAdaptor__InvalidConfig.selector);
        chainlinkAdaptor.setGuardedPriceConfig(
            _ETH_ADDRESS,
            true,
            1,
            0,
            (block.timestamp - (7 days - 1)),
            3400e18,
            3600e18);
    }

    function test_fail_whenBasePriceIsLessThanMinPrice() public {

        vm.expectRevert(BaseOracleAdaptor.BaseOracleAdaptor__InvalidConfig.selector);
        chainlinkAdaptor.setGuardedPriceConfig(
            _ETH_ADDRESS,
            true,
            1,
            0,
            block.timestamp,
            3600e18,
            3400e18);
    }

    function test_fail_whenBasePriceAfterOverflowCheckTooHigh() public {

        uint256 timestampStart = block.timestamp - 8 days;
        uint256 basePrice = ((type(uint240).max) / WAD) - 1;
        uint256 increasePerYearBps = 1;

        vm.expectRevert(BaseOracleAdaptor.BaseOracleAdaptor__InvalidConfig.selector);
        chainlinkAdaptor.setGuardedPriceConfig(
            _ETH_ADDRESS,
            true,
            1,
            increasePerYearBps,
            timestampStart,
            0,
            basePrice
        );
    }

    function test_fail_whenPriceDifferenceMoreThanMaximumAllowed() public {
        uint256 timestampStart = block.timestamp - 8 days;

        // basePrice too low: upper bound = 3,300
        vm.expectRevert(BaseOracleAdaptor.BaseOracleAdaptor__InvalidConfig.selector);
        chainlinkAdaptor.setGuardedPriceConfig(
            _WETH_ADDRESS,
            true,
            1,
            0,
            timestampStart,
            3000e18,
            0
        );

        // basePrice too high: lower bound = 3,600
        vm.expectRevert(BaseOracleAdaptor.BaseOracleAdaptor__InvalidConfig.selector);
        chainlinkAdaptor.setGuardedPriceConfig(
            _WETH_ADDRESS,
            true,
            1,
            0,
            timestampStart,
            0,
            4000e18
        );
    }

    function test_fail_whenTimestampStartEarlierThanExisting() public {
        // Initial valid config
        uint256 timestampStart1 = block.timestamp - 8 days;

        IOracleAdaptor.PriceGuard memory pg;
        pg.guardType = 1;
        pg.timestampStart = timestampStart1;
        pg.increasePerSecond = 0;
        pg.minPrice = 3400e18;
        pg.basePrice = 3600e18;

        vm.expectEmit(true, true, true, true, address(chainlinkAdaptor));
        emit BaseOracleAdaptor.PriceGuardUpdated(pg);
        chainlinkAdaptor.setGuardedPriceConfig(
            _WETH_ADDRESS,
            true,
            1,
            0,
            timestampStart1,
            3400e18,
            3600e18
        );

        // Attempt to set with earlier timestampStart
        uint256 timestampStart2 = block.timestamp - 10 days;
        vm.expectRevert(BaseOracleAdaptor.BaseOracleAdaptor__InvalidConfig.selector);
        chainlinkAdaptor.setGuardedPriceConfig(
            _WETH_ADDRESS,
            true,
            1,
            0,
            timestampStart2,
            3400e18,
            3600e18
        );
    }

    // Static guard: enforce min and max constraints
    function test_success_StaticGuardAdjustPriceMinMax() public {
        uint256 timestampStart = block.timestamp - 8 days;
        IOracleAdaptor.PriceGuard memory pg;
        pg.guardType = 1;
        pg.timestampStart = timestampStart;
        pg.increasePerSecond = 0;
        pg.minPrice = 3400e18;
        pg.basePrice = 3600e18;

        // Static constraints [3400, 3600]
        vm.expectEmit(true, true, true, true, address(chainlinkAdaptor));
        emit BaseOracleAdaptor.PriceGuardUpdated(pg);
        chainlinkAdaptor.setGuardedPriceConfig(
            _ETH_ADDRESS,
            true,
            1,
            0,
            timestampStart,
            3400e18,
            3600e18
        );

        // Below floor: adjust to 3400
        chainlinkEthUsd.updateAnswer(3300e8);
        (uint256 price, uint256 err) = oracleManager.getPrice(_ETH_ADDRESS, true, true);
        assertEq(err, 0);
        assertEq(price, 3400e18);

        // Above cap: adjust to 3600
        chainlinkEthUsd.updateAnswer(3700e8);
        (price, err) = oracleManager.getPrice(_ETH_ADDRESS, true, true);
        assertEq(err, 0);
        assertEq(price, 3600e18);

        // Inside constraints: no adjustment
        chainlinkEthUsd.updateAnswer(3550e8);
        (price, err) = oracleManager.getPrice(_ETH_ADDRESS, true, true);
        assertEq(err, 0);
        assertEq(price, 3550e18);
    }

    // Dynamic guard: constraints scale up
    function test_success_dynamicGuardAdjustsAndGrows() public {
        uint256 timestampStart = block.timestamp - 8 days;
        uint256 increasePerYearBps = 1_000; // 10% per year
        uint256 incPerSecond = (increasePerYearBps * 1e14) / SECONDS_PER_YEAR;
        uint256 basePrice = 3600e18;
        uint256 minPrice = 3400e18;

        // Set dynamic guard (guardType = 2)
        uint256 expectedIncreaseWad = increasePerYearBps * 1e14;

        IOracleAdaptor.PriceGuard memory pg;
        pg.guardType = 2;
        pg.timestampStart = timestampStart;
        pg.increasePerSecond = incPerSecond;
        pg.minPrice = minPrice;
        pg.basePrice = basePrice;

        vm.expectEmit(true, true, true, true, address(chainlinkAdaptor));
        emit BaseOracleAdaptor.PriceGuardUpdated(pg);

        chainlinkAdaptor.setGuardedPriceConfig(
            _ETH_ADDRESS, 
            true, 
            2, 
            increasePerYearBps,
            timestampStart,
            minPrice,
            basePrice
        );

        // Calculate bounds
        uint256 timeElapsed = block.timestamp - timestampStart;
        uint256 minBound = (minPrice * (WAD + timeElapsed * incPerSecond)) / WAD;
        uint256 maxBound = (basePrice * (WAD + timeElapsed * incPerSecond)) / WAD;
        console2.log("timeElapsed", timeElapsed);
        console2.log("incPerSecond", incPerSecond);
        console2.log("minBound", minBound);
        console2.log("maxBound", maxBound);

        // Below floor: adjust to dynamic floor
        chainlinkEthUsd.updateAnswer(3000e8);
        (uint256 price, uint256 err) = oracleManager.getPrice(_ETH_ADDRESS, true, true);
        assertEq(err, 0);
        assertEq(price, minBound);

        // Above cap: adjust to dynamic cap
        chainlinkEthUsd.updateAnswer(4500e8);
        (price, err) = oracleManager.getPrice(_ETH_ADDRESS, true, true);
        assertEq(err, 0);
        assertEq(price, maxBound);

        // Inside constraints: no adjustment
        chainlinkEthUsd.updateAnswer(3550e8);
        (price, err) = oracleManager.getPrice(_ETH_ADDRESS, true, true);
        assertEq(err, 0);
        assertEq(price, 3550e18);

        // Advance time and verify bounds grew
        skip(30 days);

        chainlinkEthUsd.updateAnswer(5000e8);

        timeElapsed = block.timestamp - timestampStart;
        uint256 newMinBound = (minPrice * (WAD + timeElapsed * incPerSecond)) / WAD;
        uint256 newMaxBound = (basePrice * (WAD + timeElapsed * incPerSecond)) / WAD;
        console2.log("timeElapsed", timeElapsed);
        console2.log("newMinBound", newMinBound);
        console2.log("newMaxBound", newMaxBound);

        // Above cap after time: adjust to new, higher dynamic cap
        (price, err) = oracleManager.getPrice(_ETH_ADDRESS, true, true);
        assertEq(err, 0);
        assertEq(price, newMaxBound);

        // Below floor after time: adjust to new, higher dynamic floor
        chainlinkEthUsd.updateAnswer(3000e8);
        (price, err) = oracleManager.getPrice(_ETH_ADDRESS, true, true);
        assertEq(err, 0);
        assertEq(price, newMinBound);
    }

    // Dynamic guard with zero increase: behaves as static constraints
    function test_success_dynamicGuardZeroIncreaseBehavesStatic() public {
        uint256 timestampStart = block.timestamp - 8 days;
        uint256 increasePerYearBps = 0; // 0% per year
        uint256 basePrice = 3600e18;
        uint256 minPrice = 3400e18;

        IOracleAdaptor.PriceGuard memory pg;
        pg.guardType = 2;
        pg.timestampStart = timestampStart;
        pg.increasePerSecond = (increasePerYearBps * 1e14) / SECONDS_PER_YEAR;
        pg.minPrice = minPrice;
        pg.basePrice = basePrice;

        vm.expectEmit(true, true, true, true, address(chainlinkAdaptor));
        emit BaseOracleAdaptor.PriceGuardUpdated(pg);

        chainlinkAdaptor.setGuardedPriceConfig(
            _ETH_ADDRESS,
            true,
            2,
            increasePerYearBps,
            timestampStart,
            minPrice,
            basePrice
        );

        // Below floor: adjust to min
        chainlinkEthUsd.updateAnswer(3300e8);
        (uint256 price, uint256 err) = oracleManager.getPrice(_ETH_ADDRESS, true, true);
        assertEq(err, 0);
        assertEq(price, minPrice);

        // Above cap: adjust to base
        chainlinkEthUsd.updateAnswer(3700e8);
        (price, err) = oracleManager.getPrice(_ETH_ADDRESS, true, true);
        assertEq(err, 0);
        assertEq(price, basePrice);

        // Inside constraints: no adjustment
        chainlinkEthUsd.updateAnswer(3550e8);
        (price, err) = oracleManager.getPrice(_ETH_ADDRESS, true, true);
        assertEq(err, 0);
        assertEq(price, 3550e18);
    }
}
