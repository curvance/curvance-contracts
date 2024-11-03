// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { ERC20 } from "contracts/libraries/external/ERC20.sol";
import { MessagingHub } from "contracts/architecture/MessagingHub.sol";

contract BridgeTest is TestBaseMarket {
    function setUp() public override {
        super.setUp();

        deal(address(cve), user1, _ONE);
        deal(user1, _ONE);
    }

    function test_bridge_fail_whenUserHasNoEnoughCVE() public {
        vm.prank(user1);

        vm.expectRevert(ERC20.InsufficientBalance.selector);
        cve.bridge(user1, 42161, _ONE + 1, 0);
    }

    function test_bridge_fail_whenDestinationChainIsNotRegistered() public {
        vm.prank(user1);

        vm.expectRevert(MessagingHub.MessagingHub__InvalidParameter.selector);
        cve.bridge(user1, 138, _ONE, 0);
    }

    function test_bridge_fail_whenRecipientIsZeroAddress() public {
        vm.prank(user1);

        vm.expectRevert(MessagingHub.MessagingHub__InvalidParameter.selector);
        cve.bridge(address(0), 42161, _ONE, 0);
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

        uint256 messageFee = messagingHub.quoteMessageFee(42161, 0);

        uint256 totalSupply = cve.totalSupply();

        vm.prank(user1);

        cve.bridge{ value: messageFee }(user1, 42161, _ONE, 0);

        assertEq(cve.balanceOf(user1), 0);
        assertEq(cve.totalSupply(), totalSupply - _ONE);
    }
}
