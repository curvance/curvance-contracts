// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

contract SetVeCVETest is TestBaseMarket {
    event CoreContractSet(string indexed contractType, address newAddress);

    address public newVeCVE = makeAddr("VeCVE");

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

    function test_setVeCVE_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(0));

        vm.expectRevert(
            CentralRegistry.CentralRegistry__Unauthorized.selector
        );
        centralRegistry.setVeCVE(newVeCVE);
    }

    function test_setVeCVE_fail_whenEpochAlreadyStarted() public {
        vm.warp(centralRegistry.genesisEpoch());

        vm.expectRevert(
            CentralRegistry.CentralRegistry__EpochHasStarted.selector
        );
        centralRegistry.setVeCVE(newVeCVE);
    }

    function test_setVeCVE_fail_whenVeCVEIsAlreadySet() public {
        centralRegistry.setVeCVE(newVeCVE);

        vm.expectRevert(
            CentralRegistry.CentralRegistry__ParametersMisconfigured.selector
        );
        centralRegistry.setVeCVE(newVeCVE);
    }

    function test_setVeCVE_success() public {
        assertEq(centralRegistry.veCVE(), _ZERO_ADDRESS);

        vm.expectEmit(true, true, true, true);
        emit CoreContractSet("VeCVE", newVeCVE);

        centralRegistry.setVeCVE(newVeCVE);

        assertEq(centralRegistry.veCVE(), newVeCVE);
    }
}
