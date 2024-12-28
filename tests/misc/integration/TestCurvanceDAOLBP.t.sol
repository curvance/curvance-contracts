// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { CurvanceDAOLBP } from "contracts/misc/CurvanceDAOLBP.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

import "tests/market/TestBaseMarket.sol";

contract TestCurvanceDAOLBP is TestBaseMarket {
    CurvanceDAOLBP public lbp;

    uint256 public softPrice = 10e18; // $10
    uint256 public hardPrice = 100e18; // $100
    uint256 public cveAmountForSale = 10000e18;

    function setUp() public override {
        super.setUp();

        lbp = new CurvanceDAOLBP(ICentralRegistry(address(centralRegistry)));

        cve.transfer(address(lbp), cve.balanceOf(address(this)));

        centralRegistry.setExternalCalldataChecker(
            _UNISWAP_V2_ROUTER,
            address(new MockCalldataChecker(_UNISWAP_V2_ROUTER))
        );
    }

    function testInitialize() public {
        assertEq(lbp.cve(), address(cve));
    }

    function testStartRevertWhenInvalidStartTime() public {
        vm.expectRevert(
            CurvanceDAOLBP.CurvanceDAOLBP__InvalidStartTime.selector
        );
        lbp.start(
            block.timestamp - 1,
            softPrice,
            hardPrice,
            cveAmountForSale,
            _WETH_ADDRESS
        );
    }

    function testStartRevertWhenInvalidPrice() public {
        vm.expectRevert(CurvanceDAOLBP.CurvanceDAOLBP__InvalidPrice.selector);
        lbp.start(
            block.timestamp,
            hardPrice + 1,
            hardPrice,
            cveAmountForSale,
            _WETH_ADDRESS
        );
    }

    function testStartRevertWhenAlreadyStarted() public {
        lbp.start(
            block.timestamp,
            softPrice,
            hardPrice,
            cveAmountForSale,
            _WETH_ADDRESS
        );

        vm.expectRevert(
            CurvanceDAOLBP.CurvanceDAOLBP__AlreadyStarted.selector
        );
        lbp.start(
            block.timestamp,
            softPrice,
            hardPrice,
            cveAmountForSale,
            _WETH_ADDRESS
        );
    }

    function testStartSuccess() public {
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
        assertApproxEqRel(
            lbp.softCap(),
            (cveAmountForSale * softPrice) / lbp.paymentTokenPrice(),
            0.0001e18
        );
        assertApproxEqRel(
            lbp.hardCap(),
            (cveAmountForSale * hardPrice) / lbp.paymentTokenPrice(),
            0.0001e18
        );
    }

    function testCommitRevertWhenlbpNotStarted() public {
        _prepareCommit(address(this), 1e18);

        vm.expectRevert(CurvanceDAOLBP.CurvanceDAOLBP__NotStarted.selector);
        lbp.commit(1e18);
    }

    function testCommitRevertWhenlbpClosed() public {
        testStartSuccess();

        _prepareCommit(address(this), 1e18);

        skip(lbp.SALE_PERIOD() + 1);

        vm.expectRevert(CurvanceDAOLBP.CurvanceDAOLBP__Closed.selector);
        lbp.commit(1e18);
    }

    function testCommitSuccess() public {
        testStartSuccess();

        // before softcap
        uint256 commitAmount = lbp.softCap();
        _prepareCommit(address(this), commitAmount);

        lbp.commit(commitAmount);
        assertEq(lbp.saleCommitted(), commitAmount);
        assertEq(lbp.userCommitted(address(this)), commitAmount);
        assertEq(lbp.currentPrice(), lbp.softPriceInpaymentToken());

        // before hardcap
        commitAmount = lbp.hardCap();
        _prepareCommit(address(this), commitAmount);
        lbp.commit(commitAmount);
        assertEq(lbp.saleCommitted(), commitAmount);
        assertEq(lbp.userCommitted(address(this)), commitAmount);
        assertEq(lbp.currentPrice(), lbp.hardPriceInpaymentToken());
    }

    function testCommitForRevertWhenlbpNotStarted() public {
        _prepareCommit(address(this), 1e18);

        vm.expectRevert(CurvanceDAOLBP.CurvanceDAOLBP__NotStarted.selector);
        lbp.commitFor(1e18, address(1));
    }

    function testCommitForRevertWhenlbpClosed() public {
        testStartSuccess();

        _prepareCommit(address(this), 1e18);

        skip(lbp.SALE_PERIOD() + 1);

        vm.expectRevert(CurvanceDAOLBP.CurvanceDAOLBP__Closed.selector);
        lbp.commitFor(1e18, address(1));
    }

    function testCommitForSuccess() public {
        testStartSuccess();

        // before softcap
        uint256 commitAmount = lbp.softCap();
        _prepareCommit(address(this), commitAmount);

        lbp.commitFor(commitAmount, address(1));
        assertEq(lbp.saleCommitted(), commitAmount);
        assertEq(lbp.userCommitted(address(1)), commitAmount);
        assertEq(lbp.currentPrice(), lbp.softPriceInpaymentToken());
    }

    function testClaimRevertWhenPubliSaleNotStarted() public {
        vm.expectRevert(CurvanceDAOLBP.CurvanceDAOLBP__NotStarted.selector);
        lbp.claim();
    }

    function testClaimRevertWhenPubliSaleInProgress() public {
        testStartSuccess();

        vm.expectRevert(CurvanceDAOLBP.CurvanceDAOLBP__InSale.selector);
        lbp.claim();
    }

    function testClaimSuccess() public {
        testStartSuccess();

        uint256 commitAmount = lbp.softCap();
        _prepareCommit(address(this), commitAmount);
        lbp.commit(commitAmount);

        skip(lbp.SALE_PERIOD() + 1);

        assertEq(lbp.currentPrice(), lbp.softPriceInpaymentToken());

        lbp.claim();

        assertEq(lbp.userCommitted(address(this)), 0);
        assertEq(
            cve.balanceOf(address(this)),
            (commitAmount * 1e18) / lbp.currentPrice()
        );
    }

    function testCommitSaleAmount() public {
        testStartSuccess();

        uint256 commitAmount = 100e18;
        _prepareCommit(user1, commitAmount);
        _prepareCommit(user2, commitAmount);

        vm.prank(user1);
        lbp.commit(commitAmount);
        vm.prank(user2);
        lbp.commit(commitAmount);

        skip(lbp.SALE_PERIOD() + 1);

        vm.prank(user1);
        lbp.claim();
        vm.prank(user2);
        lbp.claim();

        assertGt(cve.balanceOf(user1), 0);
        assertEq(cve.balanceOf(user1), cve.balanceOf(user2));
    }

    function _prepareCommit(address user, uint256 amount) internal {
        _prepareWETH(user, amount);
        vm.prank(user);
        weth.approve(address(lbp), amount);
    }

    function testSwapAndCommitForSuccess() public {
        testStartSuccess();

        uint256 daiAmount = 10000e18;
        uint256 commitAmount = 1e18;
        deal(address(dai), address(this), daiAmount);
        dai.approve(address(lbp), daiAmount);

        SwapperLib.Swap memory swapperData;
        swapperData.inputToken = address(dai);
        swapperData.inputAmount = daiAmount;
        swapperData.outputToken = _WETH_ADDRESS;
        swapperData.target = _UNISWAP_V2_ROUTER;
        swapperData.slippage = 50e16;
        address[] memory path = new address[](2);
        path[0] = address(dai);
        path[1] = _WETH_ADDRESS;
        swapperData.call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            daiAmount,
            0,
            path,
            address(lbp),
            block.timestamp
        );

        lbp.swapAndCommitFor(swapperData, commitAmount, address(1));
        assertEq(lbp.saleCommitted(), commitAmount);
        assertEq(lbp.userCommitted(address(1)), commitAmount);
        assertEq(lbp.currentPrice(), lbp.softPriceInpaymentToken());
    }
}
