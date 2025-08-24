// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { ERC20 } from "contracts/libraries/external/ERC20.sol";

import { ChainConfig } from "contracts/interfaces/ICentralRegistry.sol";

import { TestBaseRemoteCVE } from "../TestBaseRemoteCVE.sol";

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
        ChainConfig memory config;
        config.isSupported = true;
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

        uint256 totalSupply = remoteCVE.totalSupply();

        vm.prank(user1);

        remoteCVE.bridge{ value: messageFee }(user1, 42161, _ONE, 0);

        assertEq(remoteCVE.balanceOf(user1), 0);
        assertEq(remoteCVE.totalSupply(), totalSupply - _ONE);
    }
}
