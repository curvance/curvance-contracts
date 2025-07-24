// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseStrategyCToken } from "../TestBaseStrategyCToken.sol";
import { StrategyCToken } from "contracts/market/token/StrategyCToken.sol";
import { IPositionManager } from "contracts/interfaces/IPositionManager.sol";
import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { ERC165 } from "contracts/libraries/external/ERC165.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { ICToken } from "contracts/interfaces/ICToken.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

import { MockPositionManager } from "contracts/mocks/MockPositionManager.sol";

contract WithdrawByPositionManagerTest is TestBaseMarketIsolated {
    MockPositionManager public mockPositionManager;

    event Transfer(address indexed from, address indexed to, uint256 amount);

    function setUp() public virtual override {
        super.setUp();

        _prepareUSDC(address(this), _ONE);
        usdc.approve(address(borrowableCUSDC), _ONE);

        _prepareBALRETH(address(this), 77777);
        
        SafeTransferLib.safeApprove(
            _BAL_WETH_RETH_ADDRESS,
            address(strategyCBALRETH),
            77777
        );
        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCUSDC));

        _setCTokenConfigBasic(address(strategyCBALRETH), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 100_000e18, 100_000e6);

        // Mint borrowable cUSDC.
        borrowableCUSDC.deposit(1000e6, address(this));

        mockPositionManager = new MockPositionManager();
        marketManagerIsolated.addPositionManager(address(mockPositionManager));

        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareUSDC(liquidityProvider, 200000e6);
        _prepareBALRETH(liquidityProvider, 10e18);

        vm.startPrank(liquidityProvider);
        
        balRETH.approve(address(strategyCBALRETH), 10e18);
        strategyCBALRETH.mint(10e18, liquidityProvider);
        usdc.approve(address(borrowableCUSDC), 200000e6);
        borrowableCUSDC.mint(200000e6, liquidityProvider);

        vm.stopPrank();
    }

    function test_strategyCTokenWithdrawByPositionManager_success() public {
        _prepareBALRETH(user1, 1000e18);

        vm.startPrank(user1);

        balRETH.approve(address(strategyCBALRETH), 1000e18);

        strategyCBALRETH.deposit(100e18, user1);

        strategyCBALRETH.postCollateral(100e18);

        borrowableCUSDC.borrow(100e6, user1);

        SwapperLib.Swap[] memory swapData; // empty swap data
        
        // We aren't using this struct, only for required arguments.
        IPositionManager.DeleverageStruct memory deleverageData;
        deleverageData.collateralToken = ICToken(address(strategyCBALRETH));
        deleverageData.debtToken = IBorrowableCToken(address(borrowableCUSDC));
        deleverageData.swapData = swapData;

        vm.stopPrank();

        vm.warp(block.timestamp + 21 minutes);

        uint256 collateralRemoveAmount = 5e18;

        vm.prank(address(mockPositionManager));
        strategyCBALRETH.withdrawByPositionManager(collateralRemoveAmount, user1, deleverageData);
        
        uint256 balRETHBalanceAfter = balRETH.balanceOf(address(mockPositionManager));

        assert(balRETHBalanceAfter == collateralRemoveAmount);       
    }

}
