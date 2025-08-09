// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

import { ChainConfig } from "contracts/interfaces/ICentralRegistry.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { stdStorage, StdStorage } from "forge-std/Test.sol";

contract RemoveChainTest is TestBaseMarketIsolated {
    using stdStorage for StdStorage;

    event RemovedChain(
        uint256 chainId,
        address messagingHub,
        address votingHub
    );

    address public relayer = makeAddr("Wormhole Relayer");

    function setUp() public override {
        super.setUp();

        ChainConfig memory config;
        config.isSupported = true;
        config.messagingChainId = 24;
        config.domain = 2;
        config.messagingHub = address(this);
        config.votingHub = address(this);
        config.cveAddress = address(1);
        config.feeTokenAddress = _USDC_ADDRESSES[10];
        config.crosschainRelayer = relayer;

        // Support chainId 10.
        centralRegistry.addChain(10, config);

        config.messagingChainId = 23;
        config.domain = 3;
        config.feeTokenAddress = _USDC_ADDRESSES[42161];

        // Support chainId 42161.
        centralRegistry.addChain(42161, config);

        config.messagingChainId = 30;
        config.domain = 6;
        config.feeTokenAddress = _USDC_ADDRESSES[8453];

        // Support chainId 8453.
        centralRegistry.addChain(8453, config);
    }

    function test_removeChain_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(0));

        vm.expectRevert(
            CentralRegistry.CentralRegistry__Unauthorized.selector
        );
        centralRegistry.removeChain(42161, user1, user1);
    }

    function test_removeChain_fail_whenMessagingHubIsInvalid() public {
        vm.expectRevert(
            CentralRegistry.CentralRegistry__InvalidParameter.selector
        );
        centralRegistry.removeChain(42161, address(1), address(this));
    }

    function test_removeChain_fail_whenVotingHubIsInvalid() public {
        vm.expectRevert(
            CentralRegistry.CentralRegistry__InvalidParameter.selector
        );
        centralRegistry.removeChain(42161, address(this), address(1));
    }

    function test_removeChain_fail_whenChainIdIsNotAuthorized() public {
        vm.expectRevert(
            CentralRegistry.CentralRegistry__InvalidParameter.selector
        );
        centralRegistry.removeChain(42160, address(this), address(this));
    }

    function test_removeChain_success() public {
        uint256 prevSupportedChains = centralRegistry.supportedChains();

        (
            uint256 isSupported,
            uint16 messagingChainId,
            uint32 domain,
            address messagingHub,
            address votingHub,
            address cveAddress,
            address feeTokenAddress,
            address crosschainRelayer
        ) = centralRegistry.chainConfig(42161);

        assertEq(isSupported, 2);
        assertEq(messagingChainId, 23);
        assertEq(domain, 3);
        assertEq(messagingHub, address(this));
        assertEq(votingHub, address(this));
        assertEq(cveAddress, address(1));
        assertEq(feeTokenAddress, _USDC_ADDRESSES[42161]);
        assertEq(crosschainRelayer, relayer);

        assertEq(centralRegistry.messagingToGETHChainId(23), 42161);
        assertEq(centralRegistry.GETHToMessagingChainId(42161), 23);

        vm.expectEmit(true, true, true, true);
        emit RemovedChain(42161, messagingHub, votingHub);
        centralRegistry.removeChain(42161, messagingHub, votingHub);

        (isSupported, , , , , , , ) = centralRegistry.chainConfig(42161);

        assertEq(isSupported, 0);
        assertEq(centralRegistry.messagingToGETHChainId(42161), 0);
        assertEq(centralRegistry.GETHToMessagingChainId(23), 0);

        assertEq(prevSupportedChains - 1, centralRegistry.supportedChains());
    }
}
