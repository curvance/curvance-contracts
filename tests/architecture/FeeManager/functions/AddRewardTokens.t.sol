// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseFeeManager } from "../TestBaseFeeManager.sol";
import { FeeManager } from "contracts/architecture/FeeManager.sol";

contract AddRewardTokensTest is TestBaseFeeManager {
    address[] public tokens;

    function setUp() public override {
        super.setUp();

        tokens.push(_WETH_ADDRESS);
        tokens.push(_DAI_ADDRESS);
    }

    function test_addRewardTokens_fail_whenCallerIsNotAuthorized() public {
        vm.prank(user1);

        vm.expectRevert(FeeManager.FeeManager__Unauthorized.selector);
        feeManager.addRewardTokens(tokens);
    }

    function test_addRewardTokens_fail_whenTokenLengthIsZero() public {
        tokens.pop();
        tokens.pop();

        vm.expectRevert(FeeManager.FeeManager__TokenLengthIsZero.selector);
        feeManager.addRewardTokens(tokens);
    }

    function test_addRewardTokens_success() public {
        for (uint256 i = 0; i < tokens.length; i++) {
            (uint256 isRewardToken, uint256 forOTC) = feeManager
                .rewardTokenInfo(tokens[i]);
            assertEq(isRewardToken, 0);
            assertEq(forOTC, 0);
        }

        feeManager.addRewardTokens(tokens);

        for (uint256 i = 0; i < tokens.length; i++) {
            (uint256 isRewardToken, uint256 forOTC) = feeManager
                .rewardTokenInfo(tokens[i]);
            assertEq(isRewardToken, 2);
            assertEq(forOTC, 1);
            assertEq(feeManager.rewardTokens(i), tokens[i]);
        }
    }
}
