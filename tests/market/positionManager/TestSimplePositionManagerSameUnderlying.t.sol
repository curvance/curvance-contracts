// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { SimplePositionManager } from "contracts/market/position-management/SimplePositionManager.sol";
import { SimpleCToken } from "contracts/market/token/SimpleCToken.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { ICToken, AccountSnapshot } from "contracts/interfaces/ICToken.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

contract TestSimplePositionManagerSameUnderlying is TestBaseMarketIsolated {
    SimplePositionManager public positionManager;

    function setUp() public override {
        super.setUp();

        oracleManager.addCTokenSupport(address(simpleCUSDC));

        _prepareUSDC(address(this), 77777 * 2);
        usdc.approve(address(simpleCUSDC), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);

        // List SimpleCToken as collateral, Borrowable as debt
        marketManagerIsolated.listTokens(address(simpleCUSDC), address(borrowableCUSDC));

        _setCTokenConfigBasic(address(simpleCUSDC), 2_000_000e6, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 0, 2_000_000e6);

        // Provide liquidity
        address lp = makeAddr("liquidityProvider");
        _prepareUSDC(lp, 2_000_000e6);
        vm.startPrank(lp);
        usdc.approve(address(borrowableCUSDC), 2_000_000e6);
        borrowableCUSDC.deposit(2_000_000e6, lp);
        vm.stopPrank();

        positionManager = new SimplePositionManager(
            ICentralRegistry(address(centralRegistry)),
            address(marketManagerIsolated),
            _WETH_ADDRESS
        );
        marketManagerIsolated.addPositionManager(address(positionManager));

        vm.startPrank(user1);
        _prepareUSDC(user1, 1_000_000e6);
        usdc.approve(address(simpleCUSDC), 1_000_000e6);
        simpleCUSDC.depositAsCollateral(1_000_000e6, user1);
        vm.stopPrank();
    }

    function testLeverage_sameAsset_success_noSwap() public {
        vm.startPrank(user1);

        uint256 borrowAmount = 100_000e6;

        SimplePositionManager.LeverageAction memory action;
        action.borrowableCToken = IBorrowableCToken(address(borrowableCUSDC));
        action.borrowAssets = borrowAmount;
        action.cToken = ICToken(address(simpleCUSDC));

        positionManager.leverage(action, 0.05e18);

        AccountSnapshot memory afterDebt = borrowableCUSDC.getSnapshot(user1);
        AccountSnapshot memory afterColl = simpleCUSDC.getSnapshot(user1);
        assertEq(afterDebt.debtBalance, borrowAmount);
        assertGt(afterColl.collateralPosted, 1_000_000e6);

        vm.stopPrank();
    }

    function testDeleverage_sameAsset_success_noSwap() public {
        testLeverage_sameAsset_success_noSwap();

        skip(20 minutes);
        _refreshMockFeeds();

        vm.startPrank(user1);
        AccountSnapshot memory beforeDebt = borrowableCUSDC.getSnapshot(user1);
        AccountSnapshot memory beforeColl = simpleCUSDC.getSnapshot(user1);

        SimplePositionManager.DeleverageAction memory action;
        action.cToken = ICToken(address(simpleCUSDC));
        action.collateralAssets = 50_000e6;
        action.borrowableCToken = IBorrowableCToken(address(borrowableCUSDC));
        action.swapActions = new SwapperLib.Swap[](1);
        action.repayAssets = 50_000e6;

        positionManager.deleverage(action, 0.05e18);

        AccountSnapshot memory afterDebt = borrowableCUSDC.getSnapshot(user1);
        AccountSnapshot memory afterColl = simpleCUSDC.getSnapshot(user1);

        assertEq(afterDebt.debtBalance, 50000038051, "debt balance should be the remaining debt + interest");
        assertEq(afterColl.collateralPosted, beforeColl.collateralPosted - action.collateralAssets);

        vm.stopPrank();
    }

    function testLeverage_sameAsset_fail_whenSwapProvided() public {
        vm.startPrank(user1);

        uint256 borrowAmount = 100_000e6;
        SimplePositionManager.LeverageAction memory action;
        action.borrowableCToken = IBorrowableCToken(address(borrowableCUSDC));
        action.borrowAssets = borrowAmount;
        action.cToken = ICToken(address(simpleCUSDC));
        
        // provide swap calldata and target to revert.
        action.swapAction.inputToken = address(usdc);
        action.swapAction.inputAmount = borrowAmount;
        action.swapAction.outputToken = address(usdc);
        action.swapAction.target = _UNISWAP_V2_ROUTER; // non empty target
        action.swapAction.call = hex"01"; // non empty calldata
        action.swapAction.slippage = 0.3e18;

        vm.expectRevert(bytes4(keccak256("BasePositionManager__InvalidParam()")));
        positionManager.leverage(action, 0.05e18);

        vm.stopPrank();
    }

    function testDeleverage_sameAsset_fail_whenSwapProvided() public {
        testLeverage_sameAsset_success_noSwap();

        skip(20 minutes);
        _refreshMockFeeds();

        vm.startPrank(user1);
        SimplePositionManager.DeleverageAction memory action;
        action.cToken = ICToken(address(simpleCUSDC));
        action.collateralAssets = 50_000e6;
        action.borrowableCToken = IBorrowableCToken(address(borrowableCUSDC));
        action.swapActions = new SwapperLib.Swap[](1);

        // provide swap calldata and target to revert.
        action.swapActions[0].inputToken = address(usdc);
        action.swapActions[0].inputAmount = 50_000e6;
        action.swapActions[0].outputToken = address(usdc);
        action.swapActions[0].target = _UNISWAP_V2_ROUTER; // non empty target
        action.swapActions[0].call = hex"01"; // non empty calldata
        action.swapActions[0].slippage = 0.3e18;
        action.repayAssets = 50_000e6;

        vm.expectRevert(bytes4(keccak256("BasePositionManager__InvalidParam()")));
        positionManager.deleverage(action, 0.05e18);

        vm.stopPrank();
    }
}


