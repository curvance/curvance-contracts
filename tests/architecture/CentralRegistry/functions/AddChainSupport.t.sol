// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

contract AddChainSupportTest is TestBaseMarket {
    event NewChainAdded(uint256 chainId, address operatorAddress);

    address public relayer = makeAddr("Wormhole Relayer");

    function test_addChainSupport_fail_whenUnauthorized() public {
        vm.prank(address(0));

        vm.expectRevert(
            CentralRegistry.CentralRegistry__Unauthorized.selector
        );
        centralRegistry.addChainSupport(
            address(this),
            address(1),
            _USDC_ADDRESS,
            42161,
            23,
            relayer,
            3
        );
    }

    function test_addChainSupport_fail_whenChainOperatorAlreadyAdded() public {
        centralRegistry.addChainSupport(
            address(this),
            address(1),
            _USDC_ADDRESS,
            42161,
            23,
            relayer,
            3
        );
        vm.expectRevert(
            CentralRegistry.CentralRegistry__ParametersMisconfigured.selector
        );
        centralRegistry.addChainSupport(
            address(this),
            address(1),
            _USDC_ADDRESS,
            42161,
            23,
            relayer,
            3
        );
    }

    function test_addChainSupport_fail_whenChainAlreadyAdded() public {
        centralRegistry.addChainSupport(
            address(this),
            address(1),
            _USDC_ADDRESS,
            42161,
            23,
            relayer,
            3
        );
        vm.expectRevert(
            CentralRegistry.CentralRegistry__ParametersMisconfigured.selector
        );
        centralRegistry.addChainSupport(
            address(this),
            address(1),
            _USDC_ADDRESS,
            42161,
            23,
            relayer,
            3
        );
    }

    function test_addChainSupport_success() public {
        assertEq(centralRegistry.messagingToGETHChainId(42161), 0);
        assertEq(centralRegistry.GETHToMessagingChainId(23), 0);
        uint256 prevSupportedChains = centralRegistry.supportedChains();

        vm.expectEmit(true, true, true, true);
        emit NewChainAdded(42161, user1);
        centralRegistry.addChainSupport(
            address(this),
            address(1),
            _USDC_ADDRESS,
            42161,
            23,
            relayer,
            3
        );

        (
            uint256 isSupported,
            address messagingHub,
            address cveAddress,
            address feeTokenAddress,
            uint16 messagingChainId,
            address wormholeRelayer,
            uint32 cctpDomain
        ) = centralRegistry.supportedChainData(42161);

        assertEq(isSupported, 2);
        assertEq(messagingHub, address(this));
        assertEq(cveAddress, address(1));
        assertEq(feeTokenAddress, _USDC_ADDRESS);
        assertEq(messagingChainId, 23);
        assertEq(wormholeRelayer, relayer);
        assertEq(cctpDomain, 3);

        assertEq(centralRegistry.messagingToGETHChainId(23), 42161);
        assertEq(centralRegistry.GETHToMessagingChainId(42161), 23);
        assertEq(prevSupportedChains + 1, centralRegistry.supportedChains());
    }
}
