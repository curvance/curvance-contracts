// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

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
}
