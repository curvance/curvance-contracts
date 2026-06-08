// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseFeeManager } from "../TestBaseFeeManager.sol";
import { FeeManager } from "contracts/architecture/FeeManager.sol";
import { console2 } from "forge-std/console2.sol";

contract PullFeesTest is TestBaseFeeManager {
    function test_pullFees_fail_whenCallerIsNotMessagingHub() public {
        vm.expectRevert(FeeManager.FeeManager__Unauthorized.selector);
        feeManager.pullFees(100e6);
    }

    function test_pullFees_success_whenNoFeeToken() public {
        uint256 messagingHubBalance = usdc.balanceOf(address(messagingHub));

        vm.prank(address(messagingHub));
        feeManager.pullFees(100e6);

        assertEq(usdc.balanceOf(address(messagingHub)), messagingHubBalance);
    }

    function test_pullFees_successA() public {
        _prepareUSDC(address(feeManager), 100e6);

        uint256 messagingHubBalance = usdc.balanceOf(address(messagingHub));
        uint256 daoBalance = usdc.balanceOf(centralRegistry.daoAddress());
        
        uint256 compoundingFee = (uint256(100e6) *
            centralRegistry.protocolCompoundFee()) /
            centralRegistry.protocolHarvestFee();

        vm.prank(address(messagingHub));
        feeManager.pullFees(100e6);

        assertEq(
            usdc.balanceOf(address(messagingHub)),
            messagingHubBalance + 100e6 - compoundingFee
        );
        assertEq(
            usdc.balanceOf(centralRegistry.daoAddress()),
            daoBalance + compoundingFee
        );
        assertEq(usdc.balanceOf(address(feeManager)), 0);
    }

    function test_pullFees_success_whenProtocolHarvestFeeIsZero() public {
        centralRegistry.setProtocolCompoundFee(0);
        centralRegistry.setProtocolYieldFee(0);
        assertEq(centralRegistry.protocolHarvestFee(), 0);

        _prepareUSDC(address(feeManager), 100e6);

        uint256 messagingHubBalance = usdc.balanceOf(address(messagingHub));
        uint256 daoBalance = usdc.balanceOf(centralRegistry.daoAddress());

        vm.prank(address(messagingHub));
        feeManager.pullFees(100e6);

        assertEq(
            usdc.balanceOf(address(messagingHub)),
            messagingHubBalance + 100e6
        );
        assertEq(usdc.balanceOf(centralRegistry.daoAddress()), daoBalance);
        assertEq(usdc.balanceOf(address(feeManager)), 0);
    }
}
