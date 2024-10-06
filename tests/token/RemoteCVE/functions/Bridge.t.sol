// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseRemoteCVE } from "../TestBaseRemoteCVE.sol";
import { ERC20 } from "contracts/libraries/external/ERC20.sol";

contract BridgeTest is TestBaseRemoteCVE {
    function setUp() public override {
        super.setUp();

        vm.prank(centralRegistry.messagingHub());
        remoteCVE.mintGaugeEmissions(user1, _ONE);

        deal(user1, _ONE);
    }

    function test_bridge_fail_whenUserHasNoEnoughCVE() public {
        vm.prank(user1);

        vm.expectRevert(ERC20.InsufficientBalance.selector);
        remoteCVE.bridge(user1, 42161, _ONE + 1, 0);
    }

    function test_bridge_fail_whenDestinationChainIsNotRegistered() public {
        vm.prank(user1);

        vm.expectRevert();
        remoteCVE.bridge(user1, 138, _ONE, 0);
    }

    function test_bridge_fail_whenRecipientIsZeroAddress() public {
        vm.prank(user1);

        vm.expectRevert();
        remoteCVE.bridge(address(0), 42161, _ONE, 0);
    }

    function test_bridge_success() public {
        centralRegistry.addChainSupport(
            address(messagingHub),
            address(votingHub),
            address(cve),
            _USDC_ADDRESS,
            42161,
            23,
            makeAddr("Wormhole Relayer"),
            3
        );

        uint256 messageFee = messagingHub.quoteMessageFee(42161, true, 0);

        uint256 totalSupply = remoteCVE.totalSupply();

        vm.prank(user1);

        remoteCVE.bridge{ value: messageFee }(user1, 42161, _ONE, 0);

        assertEq(remoteCVE.balanceOf(user1), 0);
        assertEq(remoteCVE.totalSupply(), totalSupply - _ONE);
    }
}
