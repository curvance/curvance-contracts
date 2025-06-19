// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

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
            address(daoTimelock),
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


    // No more check to see if the gauge manager is already set
    
    // function test_setGaugeManager_fail_whenGaugeManagerIsAlreadySet() public {
    //     centralRegistry.setGaugeManager(newGaugeManager);

    //     vm.expectRevert(
    //         CentralRegistry.CentralRegistry__ParametersMisconfigured.selector
    //     );
    //     centralRegistry.setGaugeManager(newGaugeManager);
    // }

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
