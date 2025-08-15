// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { console2 } from "forge-std/console2.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract TestDynamicLiquidations is TestBaseMarketIsolated {
    address public owner;

    uint256 lFactorsPreLiquidation;

    receive() external payable {}

    fallback() external payable {}

    function setUp() public override {
        super.setUp();

        owner = address(this);

        // use mock pricing for testing
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
        mockWethFeed = new MockDataFeed(_CHAINLINK_ETH_USD);
        chainlinkAdaptor.addAsset(
            _WETH_ADDRESS,
            true,
            address(mockWethFeed),
            0
        );
        dualChainlinkAdaptor.addAsset(
            _WETH_ADDRESS,
            true,
            address(mockWethFeed),
            0
        );
        mockRethFeed = new MockDataFeed(_CHAINLINK_RETH_ETH);
        chainlinkAdaptor.addAsset(
            _RETH_ADDRESS,
            false,
            address(mockRethFeed),
            0
        );
        dualChainlinkAdaptor.addAsset(
            _RETH_ADDRESS,
            false,
            address(mockRethFeed),
            0
        );

        // start epoch
        vm.warp(gaugeManager.gaugeStartTime());
        vm.roll(block.number + 1000);

        mockDaiFeed.setMockUpdatedAt(block.timestamp);
        mockWethFeed.setMockUpdatedAt(block.timestamp);
        mockRethFeed.setMockUpdatedAt(block.timestamp);

        (, int256 ethPrice, , , ) = mockWethFeed.latestRoundData();
        chainlinkEthUsd.updateAnswer(ethPrice);

        // Setup borrowable CDAI.
        {
            _prepareDAI(owner, 200000e18);
            dai.approve(address(borrowableCDAI), 200000e18);
            
        }

        // Setup strategyCBALRETH.
        {
            _prepareBALRETH(owner, 1 ether);
            balRETH.approve(address(strategyCBALRETH), 1 ether);

        }

        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCDAI));

        _setCTokenConfigBasic(address(strategyCBALRETH), 100e18, 0);
        _setCTokenConfigBasic(address(borrowableCDAI), 100e18, 100_000e18);

        // provide enough liquidity
        provideEnoughLiquidityForLeverage();
    }

    function provideEnoughLiquidityForLeverage() internal {
        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareDAI(liquidityProvider, 200000e18);
        _prepareBALRETH(liquidityProvider, 10 ether);
        // Mint borrowable cDAI.
        vm.startPrank(liquidityProvider);
        dai.approve(address(borrowableCDAI), 200000 ether);
        borrowableCDAI.mint(200000 ether, liquidityProvider);
        // Mint cBALETH.
        balRETH.approve(address(strategyCBALRETH), 10 ether);
        strategyCBALRETH.deposit(10 ether, liquidityProvider);
        vm.stopPrank();
    }

    function testLiquidateRevertWhenBelowColReq() public {
        _prepareBALRETH(user1, 1 ether);

        // try mint()
        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), 1 ether);
        strategyCBALRETH.deposit(1 ether, user1);
        strategyCBALRETH.postCollateral(1 ether - 1);

        // try borrow()
        borrowableCDAI.borrow(1000 ether, user1);
        vm.stopPrank();

        // skip sec hold period
        skip(900);

        (uint256 balRETHPrice, ) = oracleManager.getPrice(
            address(balRETH),
            true,
            true
        );

        // adjust dai price, a bit lower than colReqA
        // 1000 dai > 1 strategyCBALRETH / colReqA
        mockDaiFeed.setMockAnswer(
            int256(
                (balRETHPrice * 1 ether * 1e8) / 1000 ether / 1.4 ether - 100
            )
        );

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__NoLiquidationAvailable.selector
        );

        address[] memory accounts = new address[](1);
        accounts[0] = user1;
        uint256[] memory debtAmounts = new uint256[](1);
        debtAmounts[0] = 250 ether;

        borrowableCDAI.liquidateExact(
            debtAmounts, 
            accounts,
            address(strategyCBALRETH));
    }

    function testLiquidateWorksWhenAboveColReq() public {
        _prepareBALRETH(user1, 1 ether);

        // try mint()
        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), 1 ether);
        strategyCBALRETH.deposit(1 ether, user1);
        strategyCBALRETH.postCollateral(1 ether - 1);

        // try borrow()
        borrowableCDAI.borrow(1000 ether, user1);
        vm.stopPrank();

        // skip min hold period
        skip(20 minutes);

        mockDaiFeed.setMockAnswer(200000000);

        ExpectedLiquidationValues memory expectedLiqValues = _calculateExpectedLiquidationValues(
            LiquidationParams({
                borrower: user1,
                collateralToken: address(strategyCBALRETH),
                borrowedToken: address(borrowableCDAI),
                isLiquidateExact: true,
                liquidateExactAmount: 250 ether,
                isAuction: false,
                isMultiMarketTest: false,
                marketManagerId: 0
            })
        );

        // try liquidate half
        _prepareDAI(user2, 250 ether);
        vm.startPrank(user2);
        dai.approve(address(borrowableCDAI), 250 ether);

        address[] memory accounts = new address[](1);
        accounts[0] = user1;
        uint256[] memory debtAmounts = new uint256[](1);
        debtAmounts[0] = 250 ether;
        
        borrowableCDAI.liquidateExact(
            debtAmounts, 
            accounts,
            address(strategyCBALRETH)
        );
        vm.stopPrank();

        uint256 borrowerCollateralAfter = strategyCBALRETH.balanceOf(user1);
        uint256 expectedBorrowerCollateralAfter = (1 ether) - expectedLiqValues.collateralLiquidated;

        console2.log("borrowerCollateralAfter", borrowerCollateralAfter);
        console2.log("expectedBorrowerCollateralAfter", expectedBorrowerCollateralAfter);
        
        assertApproxEqAbs(
            borrowerCollateralAfter,
            expectedBorrowerCollateralAfter,
            1000,
            "Borrower collateral should be reduced by liquidatedPTokens"
        );

        assertEq(strategyCBALRETH.exchangeRate(), 1 ether);

        assertEq(borrowableCDAI.balanceOf(user1), 0);
        assertApproxEqRel(borrowableCDAI.debtBalance(user1), 1000 ether - (expectedLiqValues.badDebt + 250 ether), 0.01e18, "something funky");
        assertApproxEqRel(borrowableCDAI.exchangeRateUpdated(), 1 ether, 0.01e18);
    }
}
