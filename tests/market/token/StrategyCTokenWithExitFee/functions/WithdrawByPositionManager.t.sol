// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseStrategyCTokenWithExitFee } from "../TestBaseStrategyCTokenWithExitFee.sol";
import { StrategyCToken } from "contracts/market/token/StrategyCToken.sol";
import { IPositionManager } from "contracts/interfaces/IPositionManager.sol";
import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { ERC165 } from "contracts/libraries/external/ERC165.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { ICToken } from "contracts/interfaces/ICToken.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

import { MockPositionManager } from "contracts/mocks/MockPositionManager.sol";

contract WithdrawByPositionManagerWithExitFeeTest is TestBaseMarketIsolated {


    MockPositionManager public mockPositionManager;

    event Transfer(address indexed from, address indexed to, uint256 amount);

    function setUp() public virtual override {
        super.setUp();

        // use mock pricing for testing
        mockUsdcFeed = new MockDataFeed(_CHAINLINK_USDC_USD);
        chainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            address(mockUsdcFeed),
            0,
            true
        );
        dualChainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            address(mockUsdcFeed),
            0,
            true
        );
        mockWethFeed = new MockDataFeed(_CHAINLINK_ETH_USD);
        chainlinkAdaptor.addAsset(
            _WETH_ADDRESS,
            address(mockWethFeed),
            0,
            true
        );
        dualChainlinkAdaptor.addAsset(
            _WETH_ADDRESS,
            address(mockWethFeed),
            0,
            true
        );
        mockRethFeed = new MockDataFeed(_CHAINLINK_RETH_ETH);
        chainlinkAdaptor.addAsset(
            _RETH_ADDRESS,
            address(mockRethFeed),
            0,
            false
        );
        dualChainlinkAdaptor.addAsset(
            _RETH_ADDRESS,
            address(mockRethFeed),
            0,
            false
        );

        // vm.warp(gaugeManager.startTime()); // does not need to be changed, since we are not using gaugeManager nor updating anything in it
        vm.roll(block.number + 1000);

        chainlinkEthUsd.updateAnswer(1500e8);
        mockUsdcFeed.setMockUpdatedAt(block.timestamp);
        mockWethFeed.setMockUpdatedAt(block.timestamp);
        mockRethFeed.setMockUpdatedAt(block.timestamp);

        _prepareUSDC(address(this), _ONE);
        usdc.approve(address(borrowableCUSDC), _ONE);

        _prepareBALRETH(address(this), 77777);
        
        SafeTransferLib.safeApprove(
            _BAL_WETH_RETH_ADDRESS,
            address(strategyCBALRETHWithExitFee),
            77777
        );

        marketManagerIsolated.listTokens(address(strategyCBALRETHWithExitFee), address(borrowableCUSDC));

        _setCTokenConfigBasic(address(strategyCBALRETHWithExitFee), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 100_000e18, 1_000_000e6);

        mockPositionManager = new MockPositionManager();
        marketManagerIsolated.addPositionManager(address(mockPositionManager));

        // Mint borrowable cUSDC.
        borrowableCUSDC.deposit(1000e6, address(this));

        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareUSDC(liquidityProvider, 200000e6);
        _prepareBALRETH(liquidityProvider, 10e18);
        vm.startPrank(liquidityProvider);
        balRETH.approve(address(strategyCBALRETHWithExitFee), 10e18);
        strategyCBALRETHWithExitFee.mint(10e18, liquidityProvider);
        usdc.approve(address(borrowableCUSDC), 200000e6);
        borrowableCUSDC.mint(200000e6, liquidityProvider);

        vm.stopPrank();
    }

    function test_strategyCTokenWithExitFeeWithdrawByPositionManager_success() public {

        _prepareBALRETH(user1, 1000e18);

        vm.startPrank(user1);

        balRETH.approve(address(strategyCBALRETHWithExitFee), 1000e18);

        strategyCBALRETHWithExitFee.deposit(100e18, user1);

        strategyCBALRETHWithExitFee.postCollateral(100e18);

        borrowableCUSDC.borrow(100e6, user1);

        SwapperLib.Swap[] memory swapData; // empty swap data
        
        // we aren't using this struct, only for required arguments
        IPositionManager.DeleverageStruct memory deleverageData;
        deleverageData.collateralToken = ICToken(address(strategyCBALRETHWithExitFee));
        deleverageData.debtToken = IBorrowableCToken(address(borrowableCUSDC));
        deleverageData.swapData = swapData;

        vm.stopPrank();

        vm.warp(block.timestamp + 21 minutes);

        uint256 collateralRemoveAmount = 5e18;
        uint256 collateralReceivedWithExitFee = _removeExitFeeFromAssets(collateralRemoveAmount);

        vm.prank(address(mockPositionManager));
        strategyCBALRETHWithExitFee.withdrawByPositionManager(collateralRemoveAmount, user1, deleverageData);

        // a usual workflow would swap the collateral for the borrowToken, repay the borrowToken
        // we are checking that the exit fee is applied
        uint256 balRETHBalanceAfter = balRETH.balanceOf(address(mockPositionManager));

        assert(balRETHBalanceAfter == collateralReceivedWithExitFee);       
    }

    // the same logic from the StrategyCTokenWithExitFee contract which removes the exit fee
    function _removeExitFeeFromAssets(
        uint256 assets
    ) internal view returns (uint256) {
        // Rounds up with an enforced minimum of assets = 1,
        // so this can never underflow.
        uint256 exitFee = .02e18; // implemented with max exit fee of 2%
        uint256 WAD = 1e18;
        return assets - FixedPointMathLib.mulDivUp(exitFee, assets, WAD);
    }

}
