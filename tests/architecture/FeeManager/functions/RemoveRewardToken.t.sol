// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import { TestBaseFeeManager } from "../TestBaseFeeManager.sol";
import { FeeManager } from "contracts/architecture/FeeManager.sol";
import { stdStorage, StdStorage } from "forge-std/Test.sol";

contract RemoveRewardTokenTest is TestBaseFeeManager {
    using stdStorage for StdStorage;

    address[] public tokens;

    function setUp() public override {
        super.setUp();

        tokens.push(_WETH_ADDRESS);
        tokens.push(_DAI_ADDRESS);

        feeManager.addRewardTokens(tokens);
    }

    function test_removeRewardToken_fail_whenCallerIsNotAuthorized() public {
        vm.prank(user1);

        vm.expectRevert(FeeManager.FeeManager__Unauthorized.selector);
        feeManager.removeRewardToken(_WETH_ADDRESS);
    }

    function test_removeRewardToken_fail_whenTokenIsNotRewardToken() public {
        vm.expectRevert(
            FeeManager.FeeManager__RemovalTokenIsNotRewardToken.selector
        );
        feeManager.removeRewardToken(_USDT_ADDRESS);
    }

    function test_removeRewardToken_fail_whenTokenDoesNotExist() public {
        stdstore
            .target(address(feeManager))
            .sig("rewardTokenInfo(address)")
            .with_key(_USDT_ADDRESS)
            .depth(0)
            .checked_write(2);

        vm.expectRevert(
            FeeManager.FeeManager__RemovalTokenDoesNotExist.selector
        );
        feeManager.removeRewardToken(_USDT_ADDRESS);
    }

    function test_removeRewardToken_success() public {
        for (uint256 i = 0; i < tokens.length; i++) {
            (uint256 isRewardToken, uint256 forOTC) = feeManager
                .rewardTokenInfo(tokens[i]);
            assertEq(isRewardToken, 2);
            assertEq(forOTC, 1);

            feeManager.removeRewardToken(tokens[i]);

            (isRewardToken, forOTC) = feeManager.rewardTokenInfo(tokens[i]);
            assertEq(isRewardToken, 1);
            assertEq(forOTC, 1);
        }

        vm.expectRevert();
        feeManager.rewardTokens(0);
    }
}
