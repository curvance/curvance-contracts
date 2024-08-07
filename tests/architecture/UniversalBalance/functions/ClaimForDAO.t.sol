// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseUniversalBalance } from "../TestBaseUniversalBalance.sol";
import { UniversalBalance } from "contracts/architecture/UniversalBalance.sol";
import { MarketManager } from "contracts/market/MarketManager.sol";
import { GaugeErrors } from "contracts/gauge/GaugeErrors.sol";

contract ClaimForDAOTest is TestBaseUniversalBalance {
    function setUp() public override {
        super.setUp();

        deal(_WETH_ADDRESS, address(this), 10e18);
        deal(user1, _ONE * 2);

        weth.approve(address(dWETH), 10e18);
        marketManager.listToken(address(dWETH));
        oracleRouter.addMTokenSupport(address(dWETH));
        gaugePool.start(address(marketManager));

        vm.startPrank(user1);

        universalBalance.depositETH{ value: _ONE }(true);
        universalBalance.depositETH{ value: _ONE }(false);

        vm.stopPrank();
    }

    function test_claimForDAO_fail_whenNotStarted() public {
        vm.expectRevert(GaugeErrors.NotStarted.selector);
        universalBalance.claimForDAO();
    }

    function test_claimForDAO_success() public {
        vm.warp(gaugePool.startTime());

        _skipEpochDuration(1);

        // set gauge weights
        address[] memory tokensParam = new address[](1);
        uint256[] memory poolWeights = new uint256[](1);
        tokensParam[0] = address(dWETH);
        poolWeights[0] = 100 * 2 weeks;

        vm.startPrank(address(messagingHub));
        gaugePool.setEmissionRates(1, tokensParam, poolWeights);
        cve.mintGaugeEmissions(address(gaugePool), 100 * 2 weeks);
        vm.stopPrank();

        skip(1 weeks);

        uint256 cveBalance = cve.balanceOf(address(this));

        universalBalance.claimForDAO();

        assertEq(cve.balanceOf(address(this)), cveBalance + 100 * 1 weeks);
    }
}
