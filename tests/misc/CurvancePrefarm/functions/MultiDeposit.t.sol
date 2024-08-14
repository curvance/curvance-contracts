// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseCurvancePrefarm } from "../TestBaseCurvancePrefarm.sol";
import { CurvancePrefarm } from "contracts/misc/CurvancePrefarm.sol";

contract MultiDepositTest is TestBaseCurvancePrefarm {
    event Deposited(address user, address token, uint256 amount);

    address[] public prefarmTokens;
    uint256[] public amounts;

    function setUp() public override {
        super.setUp();

        prefarmTokens.push(_USDC_ADDRESS);
        prefarmTokens.push(_DAI_ADDRESS);

        amounts.push(100e6);
        amounts.push(100e18);
    }

    function test_multiDeposit_fail_whenPrefarmIsEnded() public {
        vm.warp(curvancePrefarm.prefarmEndTimestamp() + 1);

        vm.expectRevert(
            CurvancePrefarm.CurvancePrefarm__PrefarmDepositsBlocked.selector
        );
        curvancePrefarm.multiDeposit(prefarmTokens, amounts);
    }

    function test_multiDeposit_fail_whenTokenAndAmountLengthsAreMismatch()
        public
    {
        amounts.push(_ONE);

        vm.expectRevert(
            CurvancePrefarm.CurvancePrefarm__InvalidParameters.selector
        );
        curvancePrefarm.multiDeposit(prefarmTokens, amounts);
    }

    function test_deposit_fail_whenUnapprovedToken() public {
        deal(_DAI_ADDRESS, user1, 100e6);

        address[] memory wethAddress = new address[](1);
        wethAddress[0] = _DAI_ADDRESS;

        uint256[] memory wethAmount = new uint256[](1);
        wethAmount[0] = 100e6;

        vm.startPrank(user1);

        weth.approve(address(curvancePrefarm), 100e6);

        vm.expectRevert(
            CurvancePrefarm.CurvancePrefarm__InvalidParameters.selector
        );

        curvancePrefarm.deposit(wethAddress, wethAmount);
    }

    function test_multiDeposit_success() public {
        deal(_USDC_ADDRESS, user1, 100e6);
        deal(_DAI_ADDRESS, user1, 100e18);

        vm.startPrank(user1);

        usdc.approve(address(curvancePrefarm), 100e6);
        dai.approve(address(curvancePrefarm), 100e18);

        vm.expectEmit(true, true, true, true);
        emit Deposited(user1, _USDC_ADDRESS, 100e6);

        vm.expectEmit(true, true, true, true);
        emit Deposited(user1, _DAI_ADDRESS, 100e18);

        curvancePrefarm.multiDeposit(prefarmTokens, amounts);

        vm.stopPrank();

        assertEq(usdc.balanceOf(user1), 0);
        assertEq(dai.balanceOf(user1), 0);
        assertEq(usdc.balanceOf(address(curvancePrefarm)), 100e6);
        assertEq(dai.balanceOf(address(curvancePrefarm)), 100e18);
        assertEq(curvancePrefarm.balanceOf(user1, _USDC_ADDRESS), 100e6);
        assertEq(curvancePrefarm.balanceOf(user1, _DAI_ADDRESS), 100e18);
    }
}
