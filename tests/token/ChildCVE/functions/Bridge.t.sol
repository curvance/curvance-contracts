// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import { TestBaseChildCVE } from "../TestBaseChildCVE.sol";
import { ERC20 } from "contracts/libraries/external/ERC20.sol";

contract BridgeTest is TestBaseChildCVE {
    function setUp() public override {
        super.setUp();

        centralRegistry.setCVE(address(childCVE));
        _deployProtocolMessagingHub();

        vm.prank(centralRegistry.protocolMessagingHub());
        childCVE.mintGaugeEmissions(user1, _ONE);

        deal(user1, _ONE);
    }

    function test_bridge_fail_whenUserHasNoEnoughCVE() public {
        vm.prank(user1);

        vm.expectRevert(ERC20.InsufficientBalance.selector);
        childCVE.bridge(42161, user1, _ONE + 1, 0);
    }

    function test_bridge_fail_whenDestinationChainIsNotRegistered() public {
        vm.prank(user1);

        vm.expectRevert();
        childCVE.bridge(138, user1, _ONE, 0);
    }

    function test_bridge_fail_whenRecipientIsZeroAddress() public {
        vm.prank(user1);

        vm.expectRevert();
        childCVE.bridge(42161, address(0), _ONE, 0);
    }

    function test_bridge_success() public {
        centralRegistry.addChainSupport(
            address(this),
            address(protocolMessagingHub),
            address(cve),
            _USDC_ADDRESS,
            42161,
            1,
            1,
            23,
            makeAddr("Wormhole Relayer"),
            3
        );

        uint256 messageFee = protocolMessagingHub.quoteMessageFee(
            42161,
            true,
            0
        );

        vm.prank(user1);

        childCVE.bridge{ value: messageFee }(42161, user1, _ONE, 0);

        assertEq(childCVE.balanceOf(user1), 0);
        assertEq(childCVE.balanceOf(_TOKEN_BRIDGE), _ONE);
    }
}
