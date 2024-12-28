// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";
import { stdStorage, StdStorage } from "forge-std/Test.sol";

contract RemoveChainSupportTest is TestBaseMarket {
    using stdStorage for StdStorage;

    event RemovedChain(
        uint256 chainId,
        address messagingHub,
        address votingHub
    );

    address public relayer = makeAddr("Wormhole Relayer");

    function setUp() public override {
        super.setUp();

        centralRegistry.addChainSupport(
            address(this),
            address(this),
            address(1),
            _USDC_ADDRESSES[10],
            10,
            24,
            relayer,
            2
        );

        centralRegistry.addChainSupport(
            address(this),
            address(this),
            address(1),
            _USDC_ADDRESSES[42161],
            42161,
            23,
            relayer,
            3
        );

        centralRegistry.addChainSupport(
            address(this),
            address(this),
            address(1),
            _USDC_ADDRESSES[8453],
            8453,
            30,
            relayer,
            6
        );
    }

    function test_removeChainSupport_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(0));

        vm.expectRevert(
            CentralRegistry.CentralRegistry__Unauthorized.selector
        );
        centralRegistry.removeChainSupport(user1, user1, 42161);
    }

    function test_removeChainSupport_fail_whenMessagingHubIsInvalid() public {
        vm.expectRevert(
            CentralRegistry.CentralRegistry__ParametersMisconfigured.selector
        );
        centralRegistry.removeChainSupport(address(1), address(this), 42161);
    }

    function test_removeChainSupport_fail_whenVotingHubIsInvalid() public {
        vm.expectRevert(
            CentralRegistry.CentralRegistry__ParametersMisconfigured.selector
        );
        centralRegistry.removeChainSupport(address(this), address(1), 42161);
    }

    function test_removeChainSupport_fail_whenChainIdIsNotAuthorized() public {
        vm.expectRevert(
            CentralRegistry.CentralRegistry__ParametersMisconfigured.selector
        );
        centralRegistry.removeChainSupport(
            address(this),
            address(this),
            42160
        );
    }

    function test_removeChainSupport_success() public {
        uint256 prevSupportedChains = centralRegistry.supportedChains();

        (
            uint256 isSupported,
            address messagingHub,
            address votingHub,
            address cveAddress,
            address feeTokenAddress,
            uint16 messagingChainId,
            address wormholeRelayer,
            uint32 cctpDomain
        ) = centralRegistry.supportedChainData(42161);

        assertEq(isSupported, 2);
        assertEq(messagingHub, address(this));
        assertEq(votingHub, address(this));
        assertEq(cveAddress, address(1));
        assertEq(feeTokenAddress, _USDC_ADDRESSES[42161]);
        assertEq(messagingChainId, 23);
        assertEq(wormholeRelayer, relayer);
        assertEq(cctpDomain, 3);

        assertEq(centralRegistry.messagingToGETHChainId(23), 42161);
        assertEq(centralRegistry.GETHToMessagingChainId(42161), 23);

        vm.expectEmit(true, true, true, true);
        emit RemovedChain(42161, messagingHub, votingHub);
        centralRegistry.removeChainSupport(messagingHub, votingHub, 42161);

        (isSupported, , , , , , , ) = centralRegistry.supportedChainData(
            42161
        );

        assertEq(isSupported, 1);
        assertEq(centralRegistry.messagingToGETHChainId(42161), 0);
        assertEq(centralRegistry.GETHToMessagingChainId(23), 0);

        assertEq(prevSupportedChains - 1, centralRegistry.supportedChains());
    }
}
