// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

contract SetGaugeManagerTest is TestBaseMarketIsolated {
    event CoreContractUpdated(string indexed contractType, address newAddress);

    address public newGaugeManager = makeAddr("Gauge Manager");
    address public anotherGaugeManager = makeAddr("Another Gauge Manager");

    function setUp() public override {
        super.setUp();

        centralRegistry = new CentralRegistry(
            _ZERO_ADDRESS,
            _ZERO_ADDRESS,
            block.timestamp + 1,
            address(0),
            _USDC_ADDRESS
        );
    }

    function test_setGaugeManager_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(0));

        vm.expectRevert(
            CentralRegistry.CentralRegistry__Unauthorized.selector
        );
        centralRegistry.setGaugeManager(newGaugeManager);
    }

    function test_setGaugeManager_fail_whenGenesisEpochHasStarted() public {

        centralRegistry.setGaugeManager(address(gaugeManager));
        
        // Set genesis epoch to the past
        vm.warp(block.timestamp + 2);

        vm.expectRevert(
            CentralRegistry.CentralRegistry__EpochHasStarted.selector
        );
        centralRegistry.setGaugeManager(newGaugeManager);
    }

    function test_setGaugeManager_whenZeroAddress() public {

        vm.expectEmit(true, true, true, true);
        emit CoreContractUpdated("Gauge Manager", _ZERO_ADDRESS);
        centralRegistry.setGaugeManager(_ZERO_ADDRESS);

        assertEq(centralRegistry.gaugeManager(), _ZERO_ADDRESS);
    }

    function test_setGaugeManager_success() public {
        assertEq(centralRegistry.gaugeManager(), _ZERO_ADDRESS);

        vm.expectEmit(true, true, true, true);
        emit CoreContractUpdated("Gauge Manager", newGaugeManager);

        centralRegistry.setGaugeManager(newGaugeManager);

        assertEq(centralRegistry.gaugeManager(), newGaugeManager);
    }

    // First set the gauge manager, then update it before genesis epoch
    function test_setGaugeManager_success_whenUpdatedBeforeGenesisEpoch() public {

        centralRegistry.setGaugeManager(newGaugeManager);
         
        vm.expectEmit(true, true, true, true);
        emit CoreContractUpdated("Gauge Manager", anotherGaugeManager);
        
        centralRegistry.setGaugeManager(anotherGaugeManager);
        
        assertEq(centralRegistry.gaugeManager(), anotherGaugeManager);
    }
}
