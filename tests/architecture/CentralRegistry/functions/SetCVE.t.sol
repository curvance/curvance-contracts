// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

contract SetCVETest is TestBaseMarketIsolated {
    event CoreContractUpdated(string indexed contractType, address newAddress);

    address public newCVE = makeAddr("CVE");

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

    function test_setCVE_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(0));

        vm.expectRevert(
            CentralRegistry.CentralRegistry__Unauthorized.selector
        );
        centralRegistry.setCVE(newCVE);
    }

    function test_setCVE_fail_whenEpochAlreadyStarted() public {
        centralRegistry.setCVE(newCVE);

        vm.warp(centralRegistry.genesisEpoch());

        vm.expectRevert(
            CentralRegistry.CentralRegistry__EpochHasStarted.selector
        );
        centralRegistry.setCVE(newCVE);
    }

    function test_setCVE_success() public {
        assertEq(centralRegistry.cve(), _ZERO_ADDRESS);

        vm.expectEmit(true, true, true, true);
        emit CoreContractUpdated("CVE", newCVE);

        centralRegistry.setCVE(newCVE);

        assertEq(centralRegistry.cve(), newCVE);

        vm.warp(centralRegistry.genesisEpoch() - 1);

        address newCVE1 = makeAddr("CVE1");

        vm.expectEmit(true, true, true, true);
        emit CoreContractUpdated("CVE", newCVE1);

        centralRegistry.setCVE(newCVE1);
    }
}
