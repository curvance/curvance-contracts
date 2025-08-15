// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBasePredeposit } from "../TestBasePredeposit.sol";
import { Predeposit } from "contracts/misc/Predeposit.sol";

contract MultiDepositTest is TestBasePredeposit {
    event Deposited(address user, address token, uint256 amount);

    address[] public predepositTokens;
    uint256[] public amounts;

    function setUp() public override {
        super.setUp();

        predepositTokens.push(_USDC_ADDRESS);
        predepositTokens.push(_DAI_ADDRESS);

        amounts.push(100e6);
        amounts.push(100e18);
    }

    function test_multiDeposit_fail_whenPredepositIsEnded() public {
        vm.warp(predeposit.predepositEndTimestamp() + 1);

        vm.expectRevert(
            Predeposit.Predeposit__PredepositDepositsBlocked.selector
        );
        predeposit.multiDeposit(predepositTokens, amounts);
    }

    function test_multiDeposit_fail_whenTokenAndAmountLengthsAreMismatch()
        public
    {
        amounts.push(_ONE);

        vm.expectRevert(
            Predeposit.Predeposit__InvalidParameters.selector
        );
        predeposit.multiDeposit(predepositTokens, amounts);
    }

    function test_deposit_fail_whenTokenIsNotApproved() public {
        address[] memory wethAddress = new address[](1);
        wethAddress[0] = _WETH_ADDRESS;

        uint256[] memory wethAmount = new uint256[](1);
        wethAmount[0] = 100e6;

        vm.expectRevert(
            Predeposit.Predeposit__InvalidParameters.selector
        );

        predeposit.multiDeposit(wethAddress, wethAmount);
    }

    function test_multiDeposit_success() public {
        _prepareUSDC(user1, 100e6);
        _prepareDAI(user1, 100e18);

        vm.startPrank(user1);

        usdc.approve(address(predeposit), 100e6);
        dai.approve(address(predeposit), 100e18);

        vm.expectEmit(true, true, true, true);
        emit Deposited(user1, _USDC_ADDRESS, 100e6);

        vm.expectEmit(true, true, true, true);
        emit Deposited(user1, _DAI_ADDRESS, 100e18);

        predeposit.multiDeposit(predepositTokens, amounts);

        vm.stopPrank();

        assertEq(usdc.balanceOf(user1), 0);
        assertEq(dai.balanceOf(user1), 0);
        assertEq(usdc.balanceOf(address(predeposit)), 100e6);
        assertEq(dai.balanceOf(address(predeposit)), 100e18);
        assertEq(predeposit.balanceOf(user1, _USDC_ADDRESS), 100e6);
        assertEq(predeposit.balanceOf(user1, _DAI_ADDRESS), 100e18);
    }
}
