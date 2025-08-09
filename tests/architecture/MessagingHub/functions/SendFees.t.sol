// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { MessagingHub } from "contracts/architecture/MessagingHub.sol";

import { ChainConfig } from "contracts/interfaces/ICentralRegistry.sol";

import { TestBaseMessagingHub } from "../TestBaseMessagingHub.sol";
import { stdStorage, StdStorage } from "forge-std/Test.sol";

contract SendFeesTest is TestBaseMessagingHub {
    using stdStorage for StdStorage;

    function setUp() public override {
        super.setUp();

        ChainConfig memory config;
        config.isSupported = 2;
        config.messagingChainId = 23;
        config.domain = 3;
        config.messagingHub = address(this);
        config.votingHub = address(this);
        config.cveAddress = address(cve);
        config.feeTokenAddress = _USDC_ADDRESS;
        config.crosschainRelayer = makeAddr("Wormhole Relayer");

        // Support chainId 42161.
        centralRegistry.addChain(42161, config);
    }

    function test_sendFees_fail_whenMessagingHubIsPaused() public {
        messagingHub.setMessagingHubStatus(2);

        vm.expectRevert(
            MessagingHub.MessagingHub__MessagingHubPaused.selector
        );
        messagingHub.sendFees(42161, 10e6, 0);
    }

    function test_sendFees_fail_whenCallerIsNotAuthorized() public {
        vm.prank(user1);

        vm.expectRevert(MessagingHub.MessagingHub__Unauthorized.selector);
        messagingHub.sendFees(42161, 10e6, 0);
    }

    function test_sendFees_fail_whenChainIdIsNotSupported() public {
        stdstore
            .target(address(centralRegistry))
            .sig("chainConfig(uint256)")
            .with_key(42161)
            .depth(0)
            .checked_write(1);

        vm.expectRevert(MessagingHub.MessagingHub__InvalidParameter.selector);
        messagingHub.sendFees(42161, 10e6, 0);
    }

    function test_sendFees_fail_whenHasNoEnoughNativeAssetForMessageFee()
        public
    {
        _prepareUSDC(address(feeManager), _ONE);

        vm.expectRevert(
            MessagingHub.MessagingHub__InsufficientGasToken.selector
        );
        messagingHub.sendFees(42161, 10e6, 0);
    }

    function test_sendFees_fail_whenHasNoEnoughFeeToken() public {
        deal(address(messagingHub), _ONE);

        vm.expectRevert("Amount must be nonzero");
        messagingHub.sendFees(42161, 10e6, 0);
    }

    function test_sendFees_fail_whenCCTPIsNotConfigured() public {
        deal(address(messagingHub), _ONE);
        _prepareUSDC(address(feeManager), _ONE);

        centralRegistry.setTokenMessager(address(0));

        vm.expectRevert(MessagingHub.MessagingHub__InvalidParameter.selector);
        messagingHub.sendFees(42161, 10e6, 0);
    }

    function test_sendFees_success() public {
        deal(address(messagingHub), _ONE);
        _prepareUSDC(address(feeManager), _ONE);

        assertEq(usdc.balanceOf(address(feeManager)), _ONE);

        messagingHub.sendFees(42161, 10e6, 100);

        assertEq(usdc.balanceOf(address(feeManager)), _ONE - 10e6);
    }
}
