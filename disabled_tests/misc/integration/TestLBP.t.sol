// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {CentralRegistry} from "contracts/architecture/CentralRegistry.sol";
import {LBP} from "contracts/misc/LBP.sol";
import {SwapperLib} from "contracts/libraries/SwapperLib.sol";
import {MockCalldataChecker} from "contracts/mocks/MockCalldataChecker.sol";
import {MockCve} from "contracts/mocks/MockCve.sol";
import {MockToken} from "contracts/mocks/MockToken.sol";

import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";

import "tests/market/TestBaseMarketIsolated.sol";

contract MockOracleManagerForLBP {
    uint256 internal constant PRICE = 1e18;

    function getPrice(address, bool, bool) external pure returns (uint256 price, uint256 errorCode) {
        return (PRICE, 0);
    }
}

contract TestLBP is TestBaseMarketIsolated {
    LBP public lbp;

    uint256 public softPrice = 10e18; // $10
    uint256 public hardPrice = 100e18; // $100
    uint256 public cveAmountForSale = 10000e18;
    uint256 internal constant STANDALONE_SALE_START = 1_700_000_000;
    uint256 internal constant STANDALONE_SOFT_PRICE = 1e18;
    uint256 internal constant STANDALONE_HARD_PRICE = 2e18;
    uint256 internal constant STANDALONE_CVE_FOR_SALE = 100e18;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    function setUp() public override {
        super.setUp();

        lbp = new LBP(ICentralRegistry(address(centralRegistry)));

        cve.transfer(address(lbp), cve.balanceOf(address(this)));

        centralRegistry.setExternalCalldataChecker(
            _UNISWAP_V2_ROUTER, address(new MockCalldataChecker(_UNISWAP_V2_ROUTER))
        );
    }

    function testInitialize() public {
        assertEq(lbp.cve(), address(cve));
    }

    function testStartRevertWhenInvalidStartTime() public {
        vm.expectRevert(LBP.LBP__InvalidStartTime.selector);
        lbp.start(block.timestamp - 1, softPrice, hardPrice, cveAmountForSale, _WETH_ADDRESS);
    }

    function testStartRevertWhenInvalidPrice() public {
        vm.expectRevert(LBP.LBP__InvalidPrice.selector);
        lbp.start(block.timestamp, hardPrice + 1, hardPrice, cveAmountForSale, _WETH_ADDRESS);
    }

    function testStartRevertWhenAlreadyStarted() public {
        lbp.start(block.timestamp, softPrice, hardPrice, cveAmountForSale, _WETH_ADDRESS);

        vm.expectRevert(LBP.LBP__AlreadyStarted.selector);
        lbp.start(block.timestamp, softPrice, hardPrice, cveAmountForSale, _WETH_ADDRESS);
    }

    function testStartSuccess() public {
        lbp.start(block.timestamp, softPrice, hardPrice, cveAmountForSale, _WETH_ADDRESS);

        assertEq(lbp.startTime(), block.timestamp);
        assertEq(lbp.cveAmountForSale(), cveAmountForSale);
        assertEq(lbp.paymentToken(), _WETH_ADDRESS);
        assertApproxEqRel(lbp.softCap(), (cveAmountForSale * softPrice) / lbp.paymentTokenPrice(), 0.0001e18);
        assertApproxEqRel(lbp.hardCap(), (cveAmountForSale * hardPrice) / lbp.paymentTokenPrice(), 0.0001e18);
    }

    function testStartRevertWhenSaleIsUnderfunded() public {
        LBP underfunded = new LBP(ICentralRegistry(address(centralRegistry)));

        vm.expectRevert(LBP.LBP__InsufficientCVEForSale.selector);
        underfunded.start(block.timestamp, softPrice, hardPrice, cveAmountForSale, _WETH_ADDRESS);
    }

    function testCommitRevertWhenlbpNotStarted() public {
        _prepareCommit(address(this), 1e18);

        vm.expectRevert(LBP.LBP__NotStarted.selector);
        lbp.commit(1e18);
    }

    function testCommitRevertWhenlbpClosed() public {
        testStartSuccess();

        _prepareCommit(address(this), 1e18);

        skip(lbp.SALE_PERIOD() + 1);

        vm.expectRevert(LBP.LBP__Closed.selector);
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

        vm.expectRevert(LBP.LBP__NotStarted.selector);
        lbp.commitFor(1e18, address(1));
    }

    function testCommitForRevertWhenlbpClosed() public {
        testStartSuccess();

        _prepareCommit(address(this), 1e18);

        skip(lbp.SALE_PERIOD() + 1);

        vm.expectRevert(LBP.LBP__Closed.selector);
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

    function test_commit_capsAtRemainingForSixDecimalPaymentToken() public {
        MockToken usdc = new MockToken("USD Coin", "USDC", 6);
        (LBP sale, MockCve standaloneCve) = _deployStandaloneSale(address(usdc));

        _mintAndApprove(usdc, ALICE, 300e6, address(sale));

        vm.prank(ALICE);
        sale.commit(300e6);

        assertEq(sale.saleCommitted(), 200e6);
        assertEq(sale.userCommitted(ALICE), 200e6);
        assertEq(usdc.balanceOf(address(sale)), 200e6);
        assertEq(uint256(sale.currentStatus()), uint256(LBP.SaleStatus.Closed));

        _mintAndApprove(usdc, BOB, 1e6, address(sale));
        vm.expectRevert(LBP.LBP__Closed.selector);
        vm.prank(BOB);
        sale.commit(1e6);

        vm.prank(ALICE);
        uint256 claimed = sale.claim();

        assertEq(claimed, STANDALONE_CVE_FOR_SALE);
        assertEq(standaloneCve.balanceOf(ALICE), STANDALONE_CVE_FOR_SALE);
        assertEq(standaloneCve.balanceOf(address(sale)), 0);
    }

    function test_commitFor_capsAtRemainingForEighteenDecimalPaymentToken() public {
        MockToken weth = new MockToken("Wrapped Ether", "WETH", 18);
        (LBP sale,) = _deployStandaloneSale(address(weth));

        _mintAndApprove(weth, ALICE, 150e18, address(sale));
        _mintAndApprove(weth, BOB, 100e18, address(sale));

        vm.prank(ALICE);
        sale.commit(150e18);

        vm.prank(BOB);
        sale.commitFor(100e18, ALICE);

        assertEq(sale.saleCommitted(), 200e18);
        assertEq(sale.userCommitted(ALICE), 200e18);
        assertEq(weth.balanceOf(address(sale)), 200e18);
        assertEq(weth.balanceOf(BOB), 50e18);
        assertEq(uint256(sale.currentStatus()), uint256(LBP.SaleStatus.Closed));
    }

    function test_commitFor_revertsZeroRecipient() public {
        MockToken weth = new MockToken("Wrapped Ether", "WETH", 18);
        (LBP sale,) = _deployStandaloneSale(address(weth));

        _mintAndApprove(weth, BOB, 10e18, address(sale));

        vm.expectRevert(LBP.LBP__InvalidRecipient.selector);
        vm.prank(BOB);
        sale.commitFor(10e18, address(0));

        assertEq(sale.saleCommitted(), 0);
        assertEq(sale.userCommitted(address(0)), 0);
        assertEq(weth.balanceOf(address(sale)), 0);
        assertEq(weth.balanceOf(BOB), 10e18);
    }

    function test_claim_staysBoundedToSaleInventoryForSixDecimalPaymentToken() public {
        MockToken usdc = new MockToken("USD Coin", "USDC", 6);
        (LBP sale, MockCve standaloneCve) = _deployStandaloneSale(address(usdc));

        _mintAndApprove(usdc, ALICE, 300e6, address(sale));

        vm.prank(ALICE);
        sale.commit(300e6);

        vm.prank(ALICE);
        sale.claim();

        assertEq(standaloneCve.balanceOf(ALICE), STANDALONE_CVE_FOR_SALE);
        assertEq(standaloneCve.balanceOf(address(sale)), 0);
    }

    function test_priceAtReturnsHardPriceForOverflowSizedSixDecimalAmount() public {
        MockToken usdc = new MockToken("USD Coin", "USDC", 6);
        (LBP sale,) = _deployStandaloneSale(address(usdc));

        assertEq(sale.priceAt(type(uint256).max), sale.hardPriceInpaymentToken());
    }

    function test_priceAtPreservesSixDecimalPricingBands() public {
        MockToken usdc = new MockToken("USD Coin", "USDC", 6);
        (LBP sale,) = _deployStandaloneSale(address(usdc));

        uint256 scalar = 10 ** (18 - usdc.decimals());
        uint256 softCapRaw = sale.softCap() / scalar;
        if (sale.softCap() % scalar != 0) {
            ++softCapRaw;
        }
        uint256 hardCapRaw = sale.hardCap() / scalar;
        if (sale.hardCap() % scalar != 0) {
            ++hardCapRaw;
        }

        assertEq(sale.priceAt(0), sale.softPriceInpaymentToken());
        assertEq(sale.priceAt(softCapRaw - 1), sale.softPriceInpaymentToken());
        assertEq(sale.priceAt(hardCapRaw), sale.hardPriceInpaymentToken());
    }
    function testClaimRevertWhenPubliSaleNotStarted() public {
        vm.expectRevert(LBP.LBP__NotStarted.selector);
        lbp.claim();
    }

    function testClaimRevertWhenPubliSaleInProgress() public {
        testStartSuccess();

        vm.expectRevert(LBP.LBP__InSale.selector);
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
        assertEq(cve.balanceOf(address(this)), (commitAmount * 1e18) / lbp.currentPrice());
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

    function _deployStandaloneSale(address paymentToken) internal returns (LBP sale, MockCve standaloneCve) {
        vm.warp(STANDALONE_SALE_START);

        CentralRegistry standaloneCentralRegistry =
            new CentralRegistry(address(this), address(this), 1_640_926_800, address(0), address(0));

        standaloneCve = new MockCve("Curvance", "CVE");
        MockOracleManagerForLBP oracleManager = new MockOracleManagerForLBP();

        standaloneCentralRegistry.setCVE(address(standaloneCve));
        standaloneCentralRegistry.setOracleManager(address(oracleManager));

        sale = new LBP(ICentralRegistry(address(standaloneCentralRegistry)));

        standaloneCve.mint(address(sale), STANDALONE_CVE_FOR_SALE);
        sale.start(block.timestamp, STANDALONE_SOFT_PRICE, STANDALONE_HARD_PRICE, STANDALONE_CVE_FOR_SALE, paymentToken);
    }

    function _mintAndApprove(MockToken token, address user, uint256 amount, address spender) internal {
        vm.startPrank(user);
        token.mint(amount);
        token.approve(spender, type(uint256).max);
        vm.stopPrank();
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

    function testSwapAndCommitForRevertWhenCommitExceedsRemainingCapacity() public {
        testStartSuccess();

        uint256 remainingCapacity = lbp.hardCap();
        _prepareCommit(address(this), remainingCapacity - 1e18);
        lbp.commit(remainingCapacity - 1e18);

        uint256 daiAmount = 10000e18;
        deal(address(dai), address(this), daiAmount);
        dai.approve(address(lbp), daiAmount);

        SwapperLib.Swap memory swapperData = _buildDaiToWethSwap(daiAmount);

        vm.expectRevert(LBP.LBP__InvalidSwapAction.selector);
        lbp.swapAndCommitFor(swapperData, 2e18, address(1));

        assertEq(dai.balanceOf(address(this)), daiAmount);
        assertEq(lbp.saleCommitted(), remainingCapacity - 1e18);
    }

    function testSwapAndCommitForRevertWhenERC20InputIncludesNativeValue() public {
        testStartSuccess();

        uint256 daiAmount = 10000e18;
        deal(address(dai), address(this), daiAmount);
        dai.approve(address(lbp), daiAmount);
        vm.deal(address(this), 1 ether);

        SwapperLib.Swap memory swapperData = _buildDaiToWethSwap(daiAmount);

        vm.expectRevert(LBP.LBP__InvalidSwapAction.selector);
        lbp.swapAndCommitFor{value: 1}(swapperData, 1e18, address(1));

        assertEq(dai.balanceOf(address(this)), daiAmount);
        assertEq(address(lbp).balance, 0);
    }

    function _buildDaiToWethSwap(uint256 daiAmount) internal view returns (SwapperLib.Swap memory swapperData) {
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
    }
}
