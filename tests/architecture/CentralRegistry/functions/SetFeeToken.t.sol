// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

contract SetFeeTokenTest is TestBaseMarket {
    event FeeTokenSet(address newAddress);

    address public newFeeToken = makeAddr("Fee Token");

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

    function test_setFeeToken_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(0));

        vm.expectRevert(
            CentralRegistry.CentralRegistry__Unauthorized.selector
        );
        centralRegistry.setFeeToken(newFeeToken);
    }

    function test_setFeeToken_fail_whenEpochAlreadyStarted() public {
        centralRegistry.setFeeToken(newFeeToken);

        vm.warp(centralRegistry.genesisEpoch());

        vm.expectRevert(
            CentralRegistry.CentralRegistry__EpochHasStarted.selector
        );
        centralRegistry.setFeeToken(newFeeToken);
    }

    function test_setFeeToken_success() public {
        assertEq(centralRegistry.feeToken(), _USDC_ADDRESS);

        vm.expectEmit(true, true, true, true);
        emit FeeTokenSet(newFeeToken);

        centralRegistry.setFeeToken(newFeeToken);

        assertEq(centralRegistry.feeToken(), newFeeToken);

        vm.warp(centralRegistry.genesisEpoch() - 1);

        address newFeeToken1 = makeAddr("Fee Token1");

        vm.expectEmit(true, true, true, true);
        emit FeeTokenSet(newFeeToken1);

        centralRegistry.setFeeToken(newFeeToken1);
    }
}
