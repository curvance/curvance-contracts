// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";

import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";
import { LBP } from "contracts/misc/LBP.sol";
import { MockCve } from "contracts/mocks/MockCve.sol";
import { MockToken } from "contracts/mocks/MockToken.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract MockOracleManagerForLBP {
    uint256 internal constant PRICE = 1e18;

    function getPrice(
        address,
        bool,
        bool
    ) external pure returns (uint256 price, uint256 errorCode) {
        return (PRICE, 0);
    }
}

contract TestLBP is Test {
    uint256 internal constant SALE_START = 1_700_000_000;
    uint256 internal constant SOFT_PRICE = 1e18;
    uint256 internal constant HARD_PRICE = 2e18;
    uint256 internal constant CVE_FOR_SALE = 100e18;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    CentralRegistry internal centralRegistry;
    MockCve internal cve;
    MockOracleManagerForLBP internal oracleManager;

    function setUp() public {
        vm.warp(SALE_START);

        centralRegistry = new CentralRegistry(
            address(this),
            address(this),
            1_640_926_800,
            address(0),
            address(0)
        );

        cve = new MockCve("Curvance", "CVE");
        oracleManager = new MockOracleManagerForLBP();

        centralRegistry.setCVE(address(cve));
        centralRegistry.setOracleManager(address(oracleManager));
    }

    function test_commit_capsAtRemainingForSixDecimalPaymentToken() public {
        MockToken usdc = new MockToken("USD Coin", "USDC", 6);
        LBP sale = _deploySale(address(usdc));

        _mintAndApprove(usdc, ALICE, 300e6, address(sale));

        vm.prank(ALICE);
        sale.commit(300e6);

        assertEq(sale.saleCommitted(), 200e6);
        assertEq(sale.userCommitted(ALICE), 200e6);
        assertEq(usdc.balanceOf(address(sale)), 200e6);
        assertEq(
            uint256(sale.currentStatus()),
            uint256(LBP.SaleStatus.Closed)
        );

        _mintAndApprove(usdc, BOB, 1e6, address(sale));
        vm.expectRevert(LBP.LBP__Closed.selector);
        vm.prank(BOB);
        sale.commit(1e6);

        vm.prank(ALICE);
        uint256 claimed = sale.claim();

        assertEq(claimed, CVE_FOR_SALE);
        assertEq(cve.balanceOf(ALICE), CVE_FOR_SALE);
        assertEq(cve.balanceOf(address(sale)), 0);
    }

    function test_commitFor_capsAtRemainingForEighteenDecimalPaymentToken()
        public
    {
        MockToken weth = new MockToken("Wrapped Ether", "WETH", 18);
        LBP sale = _deploySale(address(weth));

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
        assertEq(
            uint256(sale.currentStatus()),
            uint256(LBP.SaleStatus.Closed)
        );
    }

    function test_claim_staysBoundedToSaleInventoryForSixDecimalPaymentToken()
        public
    {
        MockToken usdc = new MockToken("USD Coin", "USDC", 6);
        LBP sale = _deploySale(address(usdc));

        _mintAndApprove(usdc, ALICE, 300e6, address(sale));

        vm.prank(ALICE);
        sale.commit(300e6);

        vm.prank(ALICE);
        sale.claim();

        assertEq(cve.balanceOf(ALICE), CVE_FOR_SALE);
        assertEq(cve.balanceOf(address(sale)), 0);
    }

    function _deploySale(address paymentToken) internal returns (LBP sale) {
        sale = new LBP(ICentralRegistry(address(centralRegistry)));

        cve.mint(address(sale), CVE_FOR_SALE);
        sale.start(
            block.timestamp,
            SOFT_PRICE,
            HARD_PRICE,
            CVE_FOR_SALE,
            paymentToken
        );
    }

    function _mintAndApprove(
        MockToken token,
        address user,
        uint256 amount,
        address spender
    ) internal {
        vm.startPrank(user);
        token.mint(amount);
        token.approve(spender, type(uint256).max);
        vm.stopPrank();
    }
}
