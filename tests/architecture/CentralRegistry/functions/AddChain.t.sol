// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

import { ChainConfig } from "contracts/interfaces/ICentralRegistry.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

contract AddChainTest is TestBaseMarketIsolated {
    event NewChain(uint256 chainId, ChainConfig config);

    address public relayer = makeAddr("Wormhole Relayer");

    function test_addChain_fail_whenCallerIsNotAuthorized() public {
        ChainConfig memory config;
        config.isSupported = true;
        config.messagingChainId = 23;
        config.domain = 3;
        config.messagingHub = address(this);
        config.votingHub = address(this);
        config.cveAddress = address(1);
        config.feeTokenAddress = _USDC_ADDRESS;
        config.crosschainRelayer = relayer;

        vm.prank(address(0));
        
        vm.expectRevert(
            CentralRegistry.CentralRegistry__Unauthorized.selector
        );
        centralRegistry.addChain(42161, config);
    }

    function test_addChain_fail_whenChainAlreadyAdded() public {
        ChainConfig memory config;
        config.isSupported = true;
        config.messagingChainId = 23;
        config.domain = 3;
        config.messagingHub = address(this);
        config.votingHub = address(this);
        config.cveAddress = address(1);
        config.feeTokenAddress = _USDC_ADDRESS;
        config.crosschainRelayer = relayer;

        centralRegistry.addChain(42161, config);
        vm.expectRevert(
            CentralRegistry.CentralRegistry__InvalidParameter.selector
        );
        centralRegistry.addChain(42161, config);
    }

    function test_addChain_fail_whenConfigIsMalformed() public {
        ChainConfig memory config;
        config.messagingChainId = 23;
        config.domain = 3;
        config.messagingHub = address(messagingHub);
        config.votingHub = address(votingHub);
        config.cveAddress = address(1);
        config.feeTokenAddress = _USDC_ADDRESS;
        config.crosschainRelayer = relayer;

        vm.expectRevert(
            CentralRegistry.CentralRegistry__InvalidParameter.selector
        );
        centralRegistry.addChain(42161, config);
    }

    function test_addChain_success() public {
        ChainConfig memory config;
        config.isSupported = true;
        config.messagingChainId = 23;
        config.domain = 3;
        config.messagingHub = address(messagingHub);
        config.votingHub = address(votingHub);
        config.cveAddress = address(1);
        config.feeTokenAddress = _USDC_ADDRESS;
        config.crosschainRelayer = relayer;

        assertEq(centralRegistry.messagingToGETHChainId(42161), 0);
        assertEq(centralRegistry.GETHToMessagingChainId(23), 0);
        uint256 prevSupportedChains = centralRegistry.supportedChains();

        vm.expectEmit(true, true, true, true);
        emit NewChain(42161, config);

        centralRegistry.addChain(42161, config);

        (
            bool isSupported,
            uint16 messagingChainId,
            uint32 domain,
            address messagingHub,
            address votingHub,
            address cveAddress,
            address feeTokenAddress,
            address crosschainRelayer
        ) = centralRegistry.chainConfig(42161);

        assertTrue(isSupported);
        assertEq(messagingChainId, 23);
        assertEq(domain, 3);
        assertEq(messagingHub, address(messagingHub));
        assertEq(votingHub, address(votingHub));
        assertEq(cveAddress, address(1));
        assertEq(feeTokenAddress, _USDC_ADDRESS);
        assertEq(crosschainRelayer, relayer);

        assertEq(centralRegistry.messagingToGETHChainId(23), 42161);
        assertEq(centralRegistry.GETHToMessagingChainId(42161), 23);
        assertEq(prevSupportedChains + 1, centralRegistry.supportedChains());
    }
}
