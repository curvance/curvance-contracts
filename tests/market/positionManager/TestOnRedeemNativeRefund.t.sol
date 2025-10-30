// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { SimplePositionManager } from "contracts/market/position-management/SimplePositionManager.sol";
import { BasePositionManager } from "contracts/market/position-management/BasePositionManager.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { ICToken } from "contracts/interfaces/ICToken.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IWETH } from "contracts/interfaces/IWETH.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";

// Using an empty PositionManager to hit the correct code path
contract FuturePositionManager is BasePositionManager {
    constructor(
        ICentralRegistry cr,
        address mm,
        address wNative
    ) BasePositionManager(cr, mm, wNative) {}

    function _swapDebtAssetToCollateralAsset(
        LeverageAction memory, // action
        address // receiver
    ) internal override {}

    function _swapCollateralAssetToDebtAsset(
        DeleverageAction memory // action
    ) internal override {}
}

contract TestOnRedeemNativeRefund is TestBaseMarketIsolated {
    FuturePositionManager positionManager;

    receive() external payable {}

    function setUp() public override {
        super.setUp();

        positionManager = new FuturePositionManager(
            ICentralRegistry(address(centralRegistry)),
            address(marketManagerIsolated),
            _WETH_ADDRESS
        );
        marketManagerIsolated.addPositionManager(address(positionManager));

        _prepareUSDC(address(this), 77777);
        _prepareDAI(address(this), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);
        dai.approve(address(borrowableCDAI), 77777);

        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(borrowableCDAI));
        _setCTokenConfigBasic(address(borrowableCUSDC), 1_000_000e6, 1_000_000e6);
        _setCTokenConfigBasic(address(borrowableCDAI), 1_000_000e18, 1_000_000e18);

        address lp = makeAddr("liquidityProvider");
        _prepareDAI(lp, 1_000_000e18);
        vm.startPrank(lp);
        dai.approve(address(borrowableCDAI), 1_000_000e18);
        borrowableCDAI.deposit(1_000_000e18, lp);
        vm.stopPrank();
    }

    function test_onRedeem_refunds_native_dust_by_wrapping() public {

        _prepareUSDC(user1, 1_000e6);
        vm.startPrank(user1);
        usdc.approve(address(borrowableCUSDC), 1_000e6);
        borrowableCUSDC.depositAsCollateral(1_000e6, user1);
        borrowableCDAI.borrow(100e18, user1);
        vm.stopPrank();

        skip(20 minutes);
        borrowableCDAI.accrueIfNeeded();

        // Dummy deleverage action that has the native token as the output
        BasePositionManager.DeleverageAction memory action;
        action.cToken = ICToken(address(borrowableCUSDC));
        action.collateralAssets = 100e6;
        action.borrowableCToken = IBorrowableCToken(address(borrowableCDAI));
        action.repayAssets = 10e18; 

        action.swapActions = new SwapperLib.Swap[](1);
        action.swapActions[0].inputToken = address(usdc);
        action.swapActions[0].inputAmount = action.collateralAssets;
        action.swapActions[0].outputToken = address(0); // native output token
        action.swapActions[0].target = address(this);
        action.swapActions[0].call = hex"";
        action.swapActions[0].slippage = 0.5e18;

        vm.startPrank(user1);
        borrowableCUSDC.approve(address(positionManager), type(uint256).max);
        vm.stopPrank();

        // Give manager enough DAI to repay without swapping
        _prepareDAI(address(positionManager), action.repayAssets);

        // Give dust to the manager 
        vm.deal(address(positionManager), .001 ether);
        assertEq(address(positionManager).balance, 0.001 ether, "positionManager should have 0.001 ether");

        uint256 wethBefore = IERC20(_WETH_ADDRESS).balanceOf(user1);
        
        vm.prank(user1);
        positionManager.deleverage(action, 0.5e18);

        uint256 wethAfter = IERC20(_WETH_ADDRESS).balanceOf(user1);
        assertGt(wethAfter, wethBefore, "user1 should receive wrapped native from refund");
    }
}


