// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { LBP } from "contracts/misc/LBP.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import "tests/market/TestBaseMarketIsolated.sol";

contract TestLBPCap is TestBaseMarketIsolated {
    LBP public lbp;

    uint256 public softPrice = 10e18; // 10 weth
    uint256 public hardPrice = 100e18; // 100 weth
    uint256 public cveAmountForSale = 10000e18; // 10k cve

    function setUp() public override {
        super.setUp();

        lbp = new LBP(ICentralRegistry(address(centralRegistry)));

        cve.transfer(address(lbp), cve.balanceOf(address(this)));
    }

    function testCommitExceedingHardCap_ExcessDelivery() public {
        testStartSuccess();

        uint256 hardCap = lbp.hardCap();
        uint256 excessAmount = 1e18;
        uint256 commitAmount = hardCap + excessAmount; 

        _prepareCommit(address(this), commitAmount);

        lbp.commit(commitAmount);
        uint256 wethBalanceAfterCommit = weth.balanceOf(address(this));

        assertEq(wethBalanceAfterCommit, excessAmount);
        LBP.SaleStatus saleStatus = lbp.currentStatus();
        assertEq(uint256(saleStatus), 2); // SaleStatus.Closed
    }

    function testCommitForExceedingHardCapReverts() public {
        testStartSuccess();

        uint256 hardCap = lbp.hardCap();

        _prepareCommit(address(this), hardCap);

        lbp.commit(hardCap); // closes LBP

        vm.expectRevert(LBP.LBP__Closed.selector);
        lbp.commit(1e18); // reverts because LBP is closed

    }

    function _prepareCommit(address user, uint256 amount) internal {
        _prepareWETH(user, amount);
        vm.prank(user);
        weth.approve(address(lbp), amount);
    }

    function testStartSuccess() internal {
        lbp.start(
            block.timestamp,
            softPrice,
            hardPrice,
            cveAmountForSale,
            _WETH_ADDRESS
        );

        assertEq(lbp.startTime(), block.timestamp);
        assertEq(lbp.cveAmountForSale(), cveAmountForSale);
        assertEq(lbp.paymentToken(), _WETH_ADDRESS);
    }
}
