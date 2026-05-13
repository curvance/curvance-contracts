// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {TestBaseNativeUniversalBalance} from "../TestBaseNativeUniversalBalance.sol";
import {UniversalBalance} from "contracts/architecture/UniversalBalance.sol";

contract NativeUniversalBalanceZeroRecipientTest is TestBaseNativeUniversalBalance {
    function test_nativeUniversalBalance_withdrawNative_revertsZeroRecipient() public {
        deal(user1, 1 ether);

        vm.startPrank(user1);
        nativeUniversalBalance.depositNative{value: 1 ether}(false);

        vm.expectRevert(UniversalBalance.UniversalBalance__InvalidParameter.selector);
        nativeUniversalBalance.withdrawNative(1 ether, false, address(0));
        vm.stopPrank();
    }

    function test_nativeUniversalBalance_multiWithdrawNativeFor_revertsZeroRecipient() public {
        deal(user1, 1 ether);

        vm.startPrank(user1);
        nativeUniversalBalance.depositNative{value: 1 ether}(false);
        nativeUniversalBalance.setDelegateApproval(user2, true);
        vm.stopPrank();

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;
        bool[] memory forceLentRedemption = new bool[](1);
        address[] memory owners = new address[](1);
        owners[0] = user1;

        vm.prank(user2);
        vm.expectRevert(UniversalBalance.UniversalBalance__InvalidParameter.selector);
        nativeUniversalBalance.multiWithdrawNativeFor(amounts, forceLentRedemption, address(0), owners);
    }
}
