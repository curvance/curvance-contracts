// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseOracleManager } from "../TestBaseOracleManager.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";

contract SetChainlinkDelayTest is TestBaseOracleManager {
    function test_setChainlinkDelay_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(1));

        vm.expectRevert(OracleManager.OracleManager__Unauthorized.selector);
        oracleManager.setChainlinkDelay(0.5 days);
    }

    function test_setChainlinkDelay_fail_whenDelayIsTooLarge() public {
        vm.expectRevert(
            OracleManager.OracleManager__InvalidParameter.selector
        );
        oracleManager.setChainlinkDelay(1 days + 1);
    }

    function test_setChainlinkDelay_success() public {
        assertEq(oracleManager.CHAINLINK_MAX_DELAY(), 1 days);

        oracleManager.setChainlinkDelay(0.5 days);

        assertEq(oracleManager.CHAINLINK_MAX_DELAY(), 0.5 days);
    }
}
