// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseUniversalBalance } from "../TestBaseUniversalBalance.sol";
import { UniversalBalance } from "contracts/architecture/UniversalBalance.sol";
import { GaugeManager } from "contracts/architecture/GaugeManager.sol";

contract ClaimForDAOTest is TestBaseUniversalBalance {
    function setUp() public override {
        super.setUp();

        deal(user1, _ONE * 2);

        vm.startPrank(user1);

        universalBalance.depositETH{ value: _ONE }(true);
        universalBalance.depositETH{ value: _ONE }(false);

        vm.stopPrank();
    }

    function test_claimForDAO_fail_whenNotStarted() public {
        vm.warp(gaugeManager.startTime() - 1);

        vm.expectRevert(GaugeManager.GaugeManager__NotStarted.selector);
        universalBalance.claimForDAO();
    }

    function test_claimForDAO_success() public {
        vm.warp(gaugeManager.startTime());

        _skipEpochDuration(1);

        // set gauge weights
        address[] memory tokensParam = new address[](1);
        uint256[] memory poolWeights = new uint256[](1);
        tokensParam[0] = address(dWETH);
        poolWeights[0] = 100 * 2 weeks;

        vm.startPrank(address(messagingHub));
        gaugeManager.setEmissionRates(1, tokensParam, poolWeights);
        cve.mintGaugeEmissions(address(gaugeManager), 100 * 2 weeks);
        vm.stopPrank();

        skip(1 weeks);

        uint256 cveBalance = cve.balanceOf(address(this));

        universalBalance.claimForDAO();

        assertEq(
            cve.balanceOf(address(this)),
            cveBalance +
                (100 * 1 weeks * _ONE) /
                (gaugeManager.totalSupply(address(dWETH)))
        );
    }
}
