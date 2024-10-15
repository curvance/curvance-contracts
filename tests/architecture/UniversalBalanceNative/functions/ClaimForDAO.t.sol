// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseUniversalBalanceNative } from "../TestBaseUniversalBalanceNative.sol";
import { UniversalBalanceNative } from "contracts/architecture/UniversalBalanceNative.sol";
import { GaugeManager } from "contracts/architecture/GaugeManager.sol";

contract ClaimForDAOTest is TestBaseUniversalBalanceNative {
    function setUp() public override {
        super.setUp();

        deal(user1, _ONE * 2);

        vm.startPrank(user1);

        universalBalanceNative.depositETH{ value: _ONE }(true);
        universalBalanceNative.depositETH{ value: _ONE }(false);

        vm.stopPrank();
    }

    function test_claimForDAO_fail_whenNotStarted() public {
        vm.expectRevert(GaugeManager.GaugeManager__NotStarted.selector);
        universalBalanceNative.claimForDAO();
    }

    function test_claimForDAO_success() public {
        vm.warp(gaugeManager.startTime());

        _skipEpochDuration(1);

        // set gauge weights
        address[] memory tokensParam = new address[](1);
        uint256[] memory poolWeights = new uint256[](1);
        tokensParam[0] = address(eWETH);
        poolWeights[0] = 100 * 2 weeks;

        vm.startPrank(address(messagingHub));
        gaugeManager.setEmissionRates(1, tokensParam, poolWeights);
        cve.mintGaugeEmissions(address(gaugeManager), 100 * 2 weeks);
        vm.stopPrank();

        skip(1 weeks);

        uint256 cveBalance = cve.balanceOf(address(this));

        universalBalanceNative.claimForDAO();

        assertEq(
            cve.balanceOf(address(this)),
            cveBalance +
                (100 * 1 weeks * _ONE) /
                (gaugeManager.totalSupply(address(eWETH)))
        );
    }
}
