// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { MessagingHub } from "contracts/architecture/MessagingHub.sol";

import { ERC20 } from "contracts/libraries/external/ERC20.sol";

import { ChainConfig } from "contracts/interfaces/ICentralRegistry.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

contract BridgeTest is TestBaseMarketIsolated {
    function setUp() public override {
        super.setUp();

        _prepareCVE(user1, _ONE);
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
        ChainConfig memory config;
        config.isSupported = 2;
        config.messagingChainId = 23;
        config.domain = 3;
        config.messagingHub = address(messagingHub);
        config.votingHub = address(votingHub);
        config.cveAddress = address(cve);
        config.feeTokenAddress = _USDC_ADDRESS;
        config.crosschainRelayer = makeAddr("Wormhole Relayer");

        // Support chainId 42161.
        centralRegistry.addChain(42161, config);

        uint256 messageFee = messagingHub.quoteMessageFee(42161, 0);

        uint256 totalSupply = cve.totalSupply();

        vm.prank(user1);

        cve.bridge{ value: messageFee }(user1, 42161, _ONE, 0);

        assertEq(cve.balanceOf(user1), 0);
        assertEq(cve.totalSupply(), totalSupply - _ONE);
    }
}
