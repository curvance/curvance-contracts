// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseFeeManager } from "../TestBaseFeeManager.sol";
import { FeeManager } from "contracts/architecture/FeeManager.sol";

contract PullFeesAsDAOTest is TestBaseFeeManager {
    function test_pullFeesAsDAO_fail_whenCallerIsNotAuthorized() public {
        vm.prank(user1);

        vm.expectRevert(FeeManager.FeeManager__Unauthorized.selector);
        feeManager.pullFeesAsDAO(100e6);
    }

    function test_pullFeesAsDAO_fail_whenNoFeeToken() public {
        vm.expectRevert(FeeManager.FeeManager__ConfigurationError.selector);
        feeManager.pullFeesAsDAO(100e6);
    }

    function test_pullFeesAsDAO_success() public {
        _prepareUSDC(address(feeManager), 100e6);

        uint256 daoBalance = usdc.balanceOf(centralRegistry.daoAddress());

        feeManager.pullFeesAsDAO(100e6);

        assertEq(
            usdc.balanceOf(centralRegistry.daoAddress()),
            daoBalance + 100e6
        );
        assertEq(usdc.balanceOf(address(feeManager)), 0);
    }
}
