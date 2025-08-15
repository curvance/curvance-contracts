// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { TestBaseLiquidations } from "tests/market/liquidations/TestBaseLiquidations.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { console2 } from "forge-std/console2.sol";

contract ExtremeDropTest is TestBaseLiquidations {

    event Repay(uint256 assets, address payer, address account);
    event BadDebtRecognized(uint256 assets, address liquidator);
    
    function setUp() public override {
        super.setUp();
        
        _setUpMarketPreLiquidation();
        _setUpBorrowerCollateral();
        _setUpBorrowerDebt();

        // set DAI price to almost 0
        mockDaiFeed.setMockAnswer(100);
        mockDaiFeed.setMockUpdatedAt(block.timestamp);
    }

    function testLiquidateWithExtremeDrop() public {

        skip(8 weeks);

        mockUsdcFeed.setMockUpdatedAt(block.timestamp);
        mockDaiFeed.setMockUpdatedAt(block.timestamp);

        uint256 initialTotalAssets = borrowableCUSDC.totalAssets();
        uint256 initialOutstandingDebt = borrowableCUSDC.marketOutstandingDebt();
        uint256 initialUserCollateralPosted = borrowableCDAI.collateralPosted(user1);

        borrowableCUSDC.accrueIfNeeded();

        uint256 afterTotalAssets = borrowableCUSDC.totalAssets();
        uint256 afterOutstandingDebt = borrowableCUSDC.marketOutstandingDebt();

        assertEq(afterTotalAssets - initialTotalAssets,afterOutstandingDebt - initialOutstandingDebt, "invariant failed");
        
        ExpectedLiquidationValues memory expectedValues = _calculateExpectedLiquidationValues(
            LiquidationParams({
                borrower: user1,
                collateralToken: address(borrowableCDAI),
                borrowedToken: address(borrowableCUSDC),
                isLiquidateExact: false,
                liquidateExactAmount: 0,
                isAuction: false,
                isMultiMarketTest: false,
                marketManagerId: 0
            })
        );

        address[] memory borrowers = new address[](1);
        borrowers[0] = user1;

        _prepareUSDC(address(this), 100000e6);
        usdc.approve(address(borrowableCUSDC), 100000e6);

        vm.expectEmit(true, true, true, true, address(borrowableCUSDC));
        emit BadDebtRecognized(
            expectedValues.badDebt,
            address(this));
        emit Repay(expectedValues.debtRepaid + expectedValues.badDebt, address(this), user1);

        borrowableCUSDC.liquidate(borrowers, address(borrowableCDAI));

        assertEq(
            afterOutstandingDebt - (expectedValues.debtRepaid + expectedValues.badDebt),
            borrowableCUSDC.marketOutstandingDebt()
        );

        assertEq(
            (initialUserCollateralPosted - expectedValues.collateralLiquidated),
            borrowableCUSDC.collateralPosted(user1)
        );

        assertEq(borrowableCUSDC.collateralPosted(user1), 0);
        assertEq(borrowableCUSDC.marketOutstandingDebt(), 0);
        assertEq(borrowableCUSDC.debtBalance(user1), 0);
        
    }

    function _setUpMarketPreLiquidation() internal {
        mockDaiFeed = new MockDataFeed(_CHAINLINK_DAI_USD);
        chainlinkAdaptor.addAsset(
            _DAI_ADDRESS,
            true,
            address(mockDaiFeed),
            0
        );
        dualChainlinkAdaptor.addAsset(
            _DAI_ADDRESS,
            true,
            address(mockDaiFeed),
            0
        );

        mockDaiFeed.setMockUpdatedAt(block.timestamp);

        // Setup market with tokens.
        deal(address(_DAI_ADDRESS), address(this), 77777);
        dai.approve(address(borrowableCDAI), 77777);

        deal(address(_USDC_ADDRESS), address(this), 77777 + 1_000_000e6);
        usdc.approve(address(borrowableCUSDC), 77777 + 1_000_000e6);

        marketManagerIsolated.listTokens(address(borrowableCDAI), address(borrowableCUSDC));

        _setCTokenConfigBasic(address(borrowableCDAI), 100_000e18, 1_000_000e6);
        _setCTokenConfigBasic(address(borrowableCUSDC), 100_000e18, 1_000_000e6);

        // provide liquidity to the market
        _prepareDAI(address(this), 1_000_000e18);
        dai.approve(address(borrowableCDAI), 1_000_000e18);
        _prepareUSDC(address(this), 1_000_000e6);
        usdc.approve(address(borrowableCUSDC), 1_000_000e6);

        borrowableCUSDC.deposit(1_000_000e6, address(this));
        borrowableCDAI.deposit(1_000_000e18, address(this));
    }

    function _setUpBorrowerCollateral() internal {
        _prepareDAI(user1, 1000e18);

        vm.startPrank(user1);
        dai.approve(address(borrowableCDAI), 1000e18);
        borrowableCDAI.depositAsCollateral(1000e18, user1);
        vm.stopPrank();
    }

    function _setUpBorrowerDebt() internal {
        vm.startPrank(user1);
        borrowableCUSDC.borrow(500e6, user1);
        vm.stopPrank();
    }
}