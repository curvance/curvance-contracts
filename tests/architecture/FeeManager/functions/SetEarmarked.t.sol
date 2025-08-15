// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { TestBaseFeeManager } from "../TestBaseFeeManager.sol";
import { FeeManager } from "contracts/architecture/FeeManager.sol";

contract SetEarmarkedTest is TestBaseFeeManager {
    function test_setEarmarked_fail_whenCallerIsNotAuthorized() public {
        vm.prank(user1);

        vm.expectRevert(FeeManager.FeeManager__Unauthorized.selector);
        feeManager.setEarmarked(_WETH_ADDRESS, true);
    }

    function test_setEarmarked_success() public {
        (, uint256 forOTC) = feeManager.rewardTokenInfo(_WETH_ADDRESS);
        assertEq(forOTC, 0);

        feeManager.setEarmarked(_WETH_ADDRESS, true);

        (, forOTC) = feeManager.rewardTokenInfo(_WETH_ADDRESS);
        assertEq(forOTC, 2);

        feeManager.setEarmarked(_WETH_ADDRESS, false);

        (, forOTC) = feeManager.rewardTokenInfo(_WETH_ADDRESS);
        assertEq(forOTC, 1);
    }
}
