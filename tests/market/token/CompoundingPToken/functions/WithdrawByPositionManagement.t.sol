// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseCompoundingPToken } from "../TestBaseCompoundingPToken.sol";
import { CompoundingPToken } from "contracts/market/token/CompoundingPToken.sol";
import { IPositionManagement } from "contracts/interfaces/IPositionManagement.sol";
import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { ERC165 } from "contracts/libraries/external/ERC165.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { IPToken } from "contracts/interfaces/IPToken.sol";
import { IEToken } from "contracts/interfaces/IEToken.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";

// This test contract acts as a position management contract to 
// check the withdrawByPositionManagement function in the
// CompoundingPToken contract.
// We are checking to see if this contract can properly call 
// the withdrawByPositionManagement function in the CompoundingPToken contract
contract CompoundingPTokenWithdrawByPositionManagementTest is
    TestBaseMarketIsolated,
    IPositionManagement,
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

        // list pBALRETH
        _prepareBALRETH(address(this), 77777);
        
        SafeTransferLib.safeApprove(
            _BAL_WETH_RETH_ADDRESS,
            address(pBALRETH),
            77777
        );
        marketManagerIsolated.listToken(address(pBALRETH));

        marketManagerIsolated.updatePositionToken(
            address(pBALRETH),
            7000,
            4000, // liquidate at 71%
            3000,
            200, // 2% liq incentive
            400,
            1000
        );

        address[] memory tokens = new address[](1);
        tokens[0] = address(pBALRETH);
        uint256[] memory caps = new uint256[](1);
        caps[0] = 100_000e18;
        marketManagerIsolated.setCollateralCaps(tokens, caps);

        addPositionManagement();

        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareUSDC(liquidityProvider, 200000e6);
        _prepareBALRETH(liquidityProvider, 10e18);
        vm.startPrank(liquidityProvider);
        balRETH.approve(address(pBALRETH), 10e18);
        pBALRETH.mint(10e18, liquidityProvider);
        usdc.approve(address(eUSDC), 200000e6);
        eUSDC.mint(200000e6);

        vm.stopPrank();
    }

    function test_compoundingPTokenWithdrawByPositionManagement_success() public {

        _prepareBALRETH(user1, 1000e18);

        vm.startPrank(user1);

        balRETH.approve(address(pBALRETH), 1000e18);

        pBALRETH.deposit(100e18, user1);

        pBALRETH.postCollateral(100e18);

        eUSDC.borrow(100e6);

        SwapperLib.Swap[] memory swapData; // empty swap data
        
        // we aren't using this struct, only for required arguments
        DeleverageStruct memory deleverageData = DeleverageStruct({
            positionToken: IPToken(address(pBALRETH)),
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

        pBALRETH.withdrawByPositionManagement(user1, collateralRemoveAmount, deleverageData);

        // a usual workflow would swap the collateral for the borrowToken, repay the borrowToken
        // we are checking that withdraw can be called on the pToken
        
        uint256 balRETHBalanceAfter = balRETH.balanceOf(address(this));

        assert(balRETHBalanceAfter == collateralRemoveAmount);       
    }

    function addPositionManagement() public {
        // Set this contract as a position management handler in the MarketManager
        marketManagerIsolated.addPositionManager(address(this));
    }

    /// @inheritdoc IPositionManagement
    function onBorrow(
        address borrowToken,
        address borrower,
        uint256 borrowAmount,
        LeverageStruct memory leverageData
    ) external override {
        // Implementation not required for the test
    }

    /// @inheritdoc IPositionManagement
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
            interfaceId == type(IPositionManagement).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
