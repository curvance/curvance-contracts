// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import { TestBaseSimpleRewardZapper, BaseZapper, SimpleRewardZapper } from "../TestBaseSimpleRewardZapper.sol";

contract RemoveAuthorizedRewardTokenTest is TestBaseSimpleRewardZapper {
    function test_removeAuthorizedRewardToken_fail_whenCallerIsNotAuthorized()
        public
    {
        vm.prank(address(1));

        vm.expectRevert(
            BaseZapper.BaseZapper__Unauthorized.selector
        );
        simpleRewardZapper.removeAuthorizedOutputToken(_USDC_ADDRESS);
    }

    function test_removeAuthorizedRewardToken_fail_whenTokenIsZeroAddress()
        public
    {
        vm.expectRevert(
            SimpleRewardZapper.SimpleRewardZapper__UnknownOutputToken.selector
        );
        simpleRewardZapper.removeAuthorizedOutputToken(address(0));
    }

    function test_removeAuthorizedRewardToken_fail_whenTokenIsNotAuthorized()
        public
    {
        vm.expectRevert(
            SimpleRewardZapper.SimpleRewardZapper__IsNotAuthorized.selector
        );
        simpleRewardZapper.removeAuthorizedOutputToken(_USDC_ADDRESS);
    }

    function test_removeAuthorizedRewardToken_success() public {
        simpleRewardZapper.addAuthorizedOutputToken(_USDC_ADDRESS);

        assertEq(simpleRewardZapper.authorizedOutputToken(_USDC_ADDRESS), 2);

        simpleRewardZapper.removeAuthorizedOutputToken(_USDC_ADDRESS);

        assertEq(simpleRewardZapper.authorizedOutputToken(_USDC_ADDRESS), 1);
    }
}
