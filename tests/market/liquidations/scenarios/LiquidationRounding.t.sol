// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import "tests/market/TestBaseMarketIsolated.sol";
import { WAD, WAD_SQUARED } from "contracts/libraries/ConstantsLib.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";
import { console2 } from "forge-std/console2.sol";

contract TestLiquidationRounding is TestBaseMarketIsolated {
    address public owner;

    receive() external payable {}

    fallback() external payable {}

    function setUp() public override {
        super.setUp();

        owner = address(this);

        // use mock pricing for testing
        mockUsdcFeed = new MockDataFeed(_CHAINLINK_USDC_USD);
        chainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            true,
            address(mockUsdcFeed),
            0
        );
        dualChainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            true,
            address(mockUsdcFeed),
            0
        );
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

        // start epoch
        vm.warp(gaugeManager.gaugeStartTime());
        vm.roll(block.number + 1000);

        mockUsdcFeed.setMockUpdatedAt(block.timestamp);
        mockDaiFeed.setMockUpdatedAt(block.timestamp);

        (, int256 ethPrice, , , ) = mockWethFeed.latestRoundData();
        chainlinkEthUsd.updateAnswer(ethPrice);

        // Setup borrowable cUSDC.
        {
            _prepareUSDC(owner, 200000e6);
            usdc.approve(address(borrowableCUSDC), 200000e6);
        }

        // Setup cDAI.
        {
            _prepareDAI(owner, 200000e18);
            dai.approve(address(borrowableCDAI), 200000e18);
        }

        marketManagerIsolated.listTokens(address(borrowableCDAI), address(borrowableCUSDC));
        // soft = 1.4 | hard = 1.3
        _setCTokenConfigBasic(address(borrowableCDAI), 1_000_000e18, 1_000_000e18); // debt cap = 1m | debt asset
        _setCTokenConfigBasic(address(borrowableCUSDC), 1_000_000e6, 0); // debt cap = 0 | collateral asset

        mockDaiFeed.setMockAnswer(100_000e8); // debt
        mockUsdcFeed.setMockAnswer(100_000e8); // collateral

        // provide enough liquidity
        provideEnoughLiquidityForLeverage();
    }

    function provideEnoughLiquidityForLeverage() internal {
        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareUSDC(liquidityProvider, 200000e6);
        _prepareDAI(liquidityProvider, 200000e18);

        // Mint borrowable cUSDC.
        vm.startPrank(liquidityProvider);
        usdc.approve(address(borrowableCUSDC), 200000e6);
        borrowableCUSDC.deposit(200000e6, liquidityProvider);
        // Mint cDAI.
        dai.approve(address(borrowableCDAI), 200000e18);
        borrowableCDAI.deposit(200000e18, liquidityProvider);

        vm.stopPrank();
    }

    function testLiquidationRounding() public {
        _prepareUSDC(user1, 10e6); // user1 is related to liquidator
        _prepareUSDC(user2, 10e6); // user2 is normal user pending liquidation
        _prepareDAI(user3, 1e18); // user3 = liquidator

        
        vm.startPrank(user1); // user1 is aligned with liquidator
        usdc.approve(address(borrowableCUSDC), 1e6);
        borrowableCUSDC.deposit(1e6, user1);
        borrowableCUSDC.postCollateral(1e6);

        borrowableCDAI.borrow(0.7e18, user1);
        vm.stopPrank(); // end of user1

        vm.startPrank(user2); // user2 is normal user pending liquidation
        usdc.approve(address(borrowableCUSDC), 1e6);
        borrowableCUSDC.deposit(1e6, user2);
        borrowableCUSDC.postCollateral(1e6);

        borrowableCDAI.borrow(0.7e18, user2);
        vm.stopPrank(); // end of user2

        mockUsdcFeed.setMockAnswer(95_000e8); // Decrease the collateral to trigger soft liquidation on both user1 and user2

        vm.startPrank(user3); // user3 = liquidator
        uint256 liquidatorBalanceBefore = dai.balanceOf(user3);
        dai.approve(address(borrowableCDAI), 1e18);

        uint256 user1DebtBefore = borrowableCDAI.debtBalance(user1);
        uint256 user2DebtBefore = borrowableCDAI.debtBalance(user2);
        
        address[] memory accounts = new address[](2);
        accounts[0] = user1;
        accounts[1] = user2;
        // accounts[2] = user1; // Only if want to test bundling same account twice to optimize
        uint256[] memory debtAmounts = new uint256[](2);
        debtAmounts[0] = 8.47e11;
        debtAmounts[1] = 8.5e11;
        // debtAmounts[2] = 8.47e11;  // Only if want to test bundling same account twice to optimize
        borrowableCDAI.liquidateExact( // Current adata.liqInc = 11205
            debtAmounts,
            accounts,
            address(borrowableCUSDC));
        console2.log("Liquidator is supposed to repay/spent %d for liquidating user1 + user2", debtAmounts[0] + debtAmounts[1]);

        uint256 liquidatorBalanceAfter = dai.balanceOf(user3);
        console2.log("Liquidator balance only decrease by %d", liquidatorBalanceBefore - liquidatorBalanceAfter);
        uint256 liquidatorSpent = liquidatorBalanceBefore - liquidatorBalanceAfter;
        assertEq(liquidatorSpent, debtAmounts[0] + debtAmounts[1], "liquidator must pay total requested debt");

        uint256 user1DebtAfter = borrowableCDAI.debtBalance(user1);
        uint256 user2DebtAfter = borrowableCDAI.debtBalance(user2);
        console2.log("User1 debt decrease by %d", user1DebtBefore - user1DebtAfter);
        console2.log("User2 debt decrease by %d", user2DebtBefore - user2DebtAfter);

        assertEq(user1DebtBefore - user1DebtAfter, debtAmounts[0], "user1 debt reduced by expected amount");
        assertEq(user2DebtBefore - user2DebtAfter, debtAmounts[1], "user2 debt reduced by expected amount");

        assertEq(
            (user1DebtBefore - user1DebtAfter) + (user2DebtBefore - user2DebtAfter),
            liquidatorSpent,
            "all debts reduced equals liquidator paid"
        );

        vm.stopPrank();
    }
}