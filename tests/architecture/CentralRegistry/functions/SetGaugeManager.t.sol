// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

contract SetGaugeManagerTest is TestBaseMarketIsolated {
    event CoreContractSet(string indexed contractType, address newAddress);

    address public newGaugeManager = makeAddr("Gauge Manager");

    function setUp() public override {
        super.setUp();

        centralRegistry = new CentralRegistry(
            _ZERO_ADDRESS,
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

    function test_setGaugeManager_fail_whenGaugeManagerIsAlreadySet() public {
        centralRegistry.setGaugeManager(newGaugeManager);

        vm.expectRevert(
            CentralRegistry.CentralRegistry__ParametersMisconfigured.selector
        );
        centralRegistry.setGaugeManager(newGaugeManager);
    }

    function test_setGaugeManager_success() public {
        assertEq(centralRegistry.gaugeManager(), _ZERO_ADDRESS);

        vm.expectEmit(true, true, true, true);
        emit CoreContractSet("Gauge Manager", newGaugeManager);

        centralRegistry.setGaugeManager(newGaugeManager);
    }
}
