// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseStrategyCTokenWithExitFee } from "../TestBaseStrategyCTokenWithExitFee.sol";
import { CompoundingPToken } from "contracts/market/token/CompoundingPToken.sol";
import { IPositionManager } from "contracts/interfaces/IPositionManager.sol";
import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { ERC165 } from "contracts/libraries/external/ERC165.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { IPToken } from "contracts/interfaces/IPToken.sol";
import { IEToken } from "contracts/interfaces/IEToken.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";

contract StrategyCTokenWithExitFeeWithdrawByPositionManager is
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
        usdc.approve(address(eUSDC), _ONE);
        marketManagerIsolated.listToken(address(eUSDC));
        // deposit reserves
        eUSDC.depositReserves(1000e6);

        // list pBALRETHWithExitFee
        _prepareBALRETH(address(this), 77777);
        
        SafeTransferLib.safeApprove(
            _BAL_WETH_RETH_ADDRESS,
            address(pBALRETHWithExitFee),
            77777
        );
        marketManagerIsolated.listToken(address(pBALRETHWithExitFee));

        marketManagerIsolated.updatePositionToken(
            address(pBALRETHWithExitFee),
            7000,
            4000, // liquidate at 71%
            3000,
            200, // 2% liq incentive
            400,
            1000
        );

        address[] memory tokens = new address[](1);
        tokens[0] = address(pBALRETHWithExitFee);
        uint256[] memory caps = new uint256[](1);
        caps[0] = 100_000e18;
        marketManagerIsolated.setCollateralCaps(tokens, caps);

        addPositionManagement();

        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareUSDC(liquidityProvider, 200000e6);
        _prepareBALRETH(liquidityProvider, 10e18);
        vm.startPrank(liquidityProvider);
        balRETH.approve(address(pBALRETHWithExitFee), 10e18);
        pBALRETHWithExitFee.mint(10e18, liquidityProvider);
        usdc.approve(address(eUSDC), 200000e6);
        eUSDC.mint(200000e6);

        vm.stopPrank();
    }

    function test_strategyCTokenWithExitFeeWithdrawByPositionManager_success() public {

        _prepareBALRETH(user1, 1000e18);

        vm.startPrank(user1);

        balRETH.approve(address(pBALRETHWithExitFee), 1000e18);

        pBALRETHWithExitFee.deposit(100e18, user1);

        pBALRETHWithExitFee.postCollateral(100e18);

        eUSDC.borrow(100e6);

        SwapperLib.Swap[] memory swapData; // empty swap data
        
        // we aren't using this struct, only for required arguments
        DeleverageStruct memory deleverageData = DeleverageStruct({
            positionToken: IPToken(address(pBALRETHWithExitFee)),
            collateralAmount: 0,
            borrowToken: IEToken(address(eUSDC)),
            swapData: swapData,
            repayAmount: 0,
            auxData: ""
        });
        vm.stopPrank();

        vm.warp(block.timestamp + 21 minutes);

        uint256 balRETHBalanceBefore = balRETH.balanceOf(address(this));

        uint256 collateralRemoveAmount = 5e18;
        uint256 collateralReceivedWithExitFee = _removeExitFeeFromAssets(collateralRemoveAmount);


        pBALRETHWithExitFee.withdrawByPositionManager(user1, collateralRemoveAmount, deleverageData);

        // a usual workflow would swap the collateral for the borrowToken, repay the borrowToken
        // we are checking that the exit fee is applied
        uint256 balRETHBalanceAfter = balRETH.balanceOf(address(this));

        assert(balRETHBalanceAfter == collateralReceivedWithExitFee);       
    }

    function addPositionManagement() public {
        // Set this contract as a position management handler in the MarketManager
        marketManagerIsolated.addPositionManager(address(this));
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
        address positionToken,
        address redeemer,
        uint256 collateralAmount,
        DeleverageStruct memory deleverageData
    ) external override {
        // Implementation not required for the test
        // we would usually ensure:
        // 1. if the positionManagement contract has >= deleveragedata.collateralAmount
        // 2. if the positionToken is the same as deleverageData.postionToken
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
