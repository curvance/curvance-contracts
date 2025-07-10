// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseStrategyCToken } from "../TestBaseStrategyCToken.sol";
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

// This test contract acts as a position management contract to 
// check the withdrawByPositionManager function in the
// StrategyCToken contract.
// We are checking to see if this contract can properly call 
// the withdrawByPositionManager function in the StrategyCToken contract
contract StrategyCTokenWithdrawByPositionManagerTest is
    TestBaseMarketIsolated,
    IPositionManager,
    ERC165
{

    MockDataFeed public mockUsdcFeed;
    MockDataFeed public mockWethFeed;
    MockDataFeed public mockRethFeed;

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

        // list eUSDC
        _prepareUSDC(address(this), _ONE);
        usdc.approve(address(borrowableCUSDC), _ONE);

        // list strategyCBALRETH
        _prepareBALRETH(address(this), 77777);
        
        SafeTransferLib.safeApprove(
            _BAL_WETH_RETH_ADDRESS,
            address(strategyCBALRETH),
            77777
        );
        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCUSDC));

        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = address(strategyCBALRETH);
        tokenConfig.collRatio = 7000;
        tokenConfig.collReqSoft = 4000;
        tokenConfig.collReqHard = 3000;
        tokenConfig.liqIncBase = 1000;
        tokenConfig.liqIncHard = 1500;
        tokenConfig.liqIncMin = 500;
        tokenConfig.liqIncMax = 2000;
        tokenConfig.minEffectiveCloseFactor = 2000;
        tokenConfig.maxEffectiveCloseFactor = 3000;
        tokenConfig.baseCFactor = 1000;
        tokenConfig.collateralCap = 100_000e18;
        tokenConfig.debtCap = 0;

        marketManagerIsolated.updateTokenConfig(tokenConfig);

        tokenConfig.cToken = address(borrowableCUSDC);
        tokenConfig.debtCap = 100_000e6;
        marketManagerIsolated.updateTokenConfig(tokenConfig);

        // deposit reserves
        borrowableCUSDC.deposit(1000e6, address(this));

        addPositionManagement();

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

        borrowableCUSDC.borrow(100e6);

        SwapperLib.Swap[] memory swapData; // empty swap data
        
        // we aren't using this struct, only for required arguments
        DeleverageStruct memory deleverageData = DeleverageStruct({
            collateralToken: ICToken(address(strategyCBALRETH)),
            collateralAmount: 0,
            debtToken: IBorrowableCToken(address(borrowableCUSDC)),
            swapData: swapData,
            repayAmount: 0,
            auxData: ""
        });
        vm.stopPrank();

        vm.warp(block.timestamp + 21 minutes);

        uint256 balRETHBalanceBefore = balRETH.balanceOf(address(this));

        uint256 collateralRemoveAmount = 5e18;

        strategyCBALRETH.withdrawByPositionManager(collateralRemoveAmount, user1, deleverageData);

        // a usual workflow would swap the collateral for the borrowToken, repay the borrowToken
        // we are checking that withdraw can be called on the pToken
        
        uint256 balRETHBalanceAfter = balRETH.balanceOf(address(this));

        assert(balRETHBalanceAfter == collateralRemoveAmount);       
    }

    function addPositionManagement() public {
        // Set this contract as a position management handler in the MarketManager
        marketManagerIsolated.addPositionManager(address(this));
    }

    /// @inheritdoc IPositionManager
    function onBorrow(
        address borrowToken,
        address borrower,
        uint256 borrowAmount,
        LeverageStruct memory leverageData
    ) external override {
        // Implementation not required for the test
    }

    /// @inheritdoc IPositionManager
    function onRedeem(
        address collateralToken,
        address redeemer,
        uint256 collateralAmount,
        DeleverageStruct memory deleverageData
    ) external override {
        // Implementation not required for the test
        // we would usually ensure:
        // 1. if the positionManagement contract has >= deleveragedata.collateralAmount
        // 2. if the collateralToken is the same as deleverageData.collateralToken
        // 3. if the collateralAmount argument is the same as deleverageData.collateralAmount argument
        // 4. then take a protocol fee if necessary

        // we would then swap the collateral for the borrowToken, repay the borrowToken
        // and transfer any remaining borrowed tokens to the user
        // and transfer any remaining tokenOut tokens to the user
    }

    /// @inheritdoc ERC165
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return
            interfaceId == type(IPositionManager).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
