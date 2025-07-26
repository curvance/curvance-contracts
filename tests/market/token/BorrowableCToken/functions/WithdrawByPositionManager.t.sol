// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { IPositionManager } from "contracts/interfaces/IPositionManager.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { ICToken } from "contracts/interfaces/ICToken.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

import { MockPositionManager } from "contracts/mocks/MockPositionManager.sol";

contract WithdrawByPositionManagerTest is TestBaseMarketIsolated {
    MockPositionManager public mockPositionManager;

    event Transfer(address indexed from, address indexed to, uint256 amount);

    function setUp() public virtual override {
        super.setUp();

        _prepareUSDC(address(this), _ONE);
        usdc.approve(address(borrowableCUSDC), _ONE);

        _prepareDAI(address(this), 77777);
        dai.approve(address(borrowableCDAI), 77777);
        
        marketManagerIsolated.listTokens(address(borrowableCDAI), address(borrowableCUSDC));

        _setCTokenConfigBasic(address(borrowableCDAI), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 100_000e6, 100_000e6);

        // Mint borrowable cUSDC.
        borrowableCUSDC.deposit(1000e6, address(this));

        mockPositionManager = new MockPositionManager();
        marketManagerIsolated.addPositionManager(address(mockPositionManager));

        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareUSDC(liquidityProvider, 200000e6);
        _prepareDAI(liquidityProvider, 10e18);

        vm.startPrank(liquidityProvider);

        dai.approve(address(borrowableCDAI), 10e18);
        borrowableCDAI.mint(10e18, liquidityProvider);
        usdc.approve(address(borrowableCUSDC), 200000e6);
        borrowableCUSDC.mint(200000e6, liquidityProvider);

        vm.stopPrank();
    }

    function test_borrowableCTokenWithdrawByPositionManager_success() public {
        _prepareDAI(user1, 1000e18);

        vm.startPrank(user1);

        dai.approve(address(borrowableCDAI), 1000e18);

        borrowableCDAI.deposit(1000e18, user1);

        borrowableCDAI.postCollateral(1000e18);

        borrowableCUSDC.borrow(100e6, user1);

        SwapperLib.Swap[] memory swapAction; // empty swap data
        
        // We aren't using this struct, only for required arguments.
        IPositionManager.DeleverageStruct memory deleverageData;
        deleverageData.collateralToken = ICToken(address(borrowableCDAI));
        deleverageData.debtToken = IBorrowableCToken(address(borrowableCUSDC));
        deleverageData.swapAction = swapAction;

        vm.stopPrank();

        vm.warp(block.timestamp + 21 minutes);

        uint256 collateralRemoveAmount = 5e18;

        vm.prank(address(mockPositionManager));
        borrowableCDAI.withdrawByPositionManager(collateralRemoveAmount, user1, deleverageData);
        
        uint256 daiBalanceAfter = dai.balanceOf(address(mockPositionManager));

        assert(daiBalanceAfter == collateralRemoveAmount);       
    }

}
