// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import { AccountSnapshot } from "contracts/interfaces/ICToken.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IPendlePTOracle } from "contracts/interfaces/external/pendle/IPendlePtOracle.sol";
import { IPMarket } from "contracts/interfaces/external/pendle/IPMarket.sol";

import { SimpleCToken, IERC20 } from "contracts/market/token/SimpleCToken.sol";
import { PendlePrincipalTokenAdaptor } from "contracts/oracles/adaptors/pendle/PendlePrincipalTokenAdaptor.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { LiquidityManagerIsolated } from "contracts/market/isolated/LiquidityManagerIsolated.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";
import { WAD, WAD_SQUARED } from "contracts/libraries/Constants.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { console2 } from "forge-std/console2.sol";

contract TestPendlePTSimpleCToken is TestBaseMarketIsolated {
    address public owner;

    address internal constant _PT_ORACLE =
        0x14030836AEc15B2ad48bB097bd57032559339c92;

    address internal _STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address internal _PT_STETH = 0x7758896b6AC966BbABcf143eFA963030f17D3EdF; // PT-stETH-26DEC24
    address internal _LP_STETH = 0xD0354D4e7bCf345fB117cabe41aCaDb724eccCa2; // PT-stETH-26DEC24/SY-stETH Market

    PendlePrincipalTokenAdaptor public adapter;

    MockDataFeed public mockStethFeed;

    SimpleCToken public pendleCTokenPTSTETH;
    IERC20 public pendlePT = IERC20(_PT_STETH);

    receive() external payable {}

    fallback() external payable {}

    function setUp() public override {
        super.setUp();

        owner = address(this);

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
        mockStethFeed = new MockDataFeed(_CHAINLINK_ETH_USD);
        chainlinkAdaptor.addAsset(_STETH, address(mockStethFeed), 0, true);
        dualChainlinkAdaptor.addAsset(_STETH, address(mockStethFeed), 0, true);

        oracleManager.addAssetPriceFeed(_STETH, address(chainlinkAdaptor));
        oracleManager.addAssetPriceFeed(_STETH, address(dualChainlinkAdaptor));

        adapter = new PendlePrincipalTokenAdaptor(
            ICentralRegistry(address(centralRegistry)),
            IPendlePTOracle(_PT_ORACLE)
        );
        PendlePrincipalTokenAdaptor.AdaptorData memory adapterData;
        adapterData.market = IPMarket(_LP_STETH);
        adapterData.twapDuration = 12;
        adapterData.quoteAsset = _STETH;
        adapterData.quoteAssetDecimals = 18;
        adapter.addAsset(_PT_STETH, adapterData);

        oracleManager.addApprovedAdaptor(address(adapter));
        oracleManager.addAssetPriceFeed(_PT_STETH, address(adapter));

        // start epoch
        vm.warp(gaugeManager.gaugeStartTime());
        _skipEpochDuration(1);
        vm.roll(block.number + 1000);

        mockUsdcFeed.setMockUpdatedAt(block.timestamp);
        mockWethFeed.setMockUpdatedAt(block.timestamp);
        mockStethFeed.setMockUpdatedAt(block.timestamp);

        // Setup borrowable cUSDC.
        {
            _deployBorrowableCUSDC();

            _prepareUSDC(owner, 200000e6);
            usdc.approve(address(borrowableCUSDC), 200000e6);
            // Add cToken support on Oracle Manager.
            oracleManager.addCTokenSupport(address(borrowableCUSDC));
        }

        // Setup pendleCTokenPTSTETH.
        {
            pendleCTokenPTSTETH = new SimpleCToken(
                ICentralRegistry(address(centralRegistry)),
                pendlePT,
                address(marketManagerIsolated)
            );

            _preparePT(owner, 1 ether);
            pendlePT.approve(address(pendleCTokenPTSTETH), 1 ether);
            // Add cToken support on Oracle Manager.
            oracleManager.addCTokenSupport(address(pendleCTokenPTSTETH));
        }

        marketManagerIsolated.listTokens(address(pendleCTokenPTSTETH), address(borrowableCUSDC));

        _setCTokenConfigBasic(address(pendleCTokenPTSTETH), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 100_000e18, 100_000e18);

        // Provide enough liquidity for leverage actions.
        provideEnoughLiquidityForLeverage();
    }

    function _preparePT(address user, uint256 amount) internal {
        deal(_PT_STETH, user, amount);
    }

    function provideEnoughLiquidityForLeverage() internal {
        address liquidityProvider = makeAddr("Liquidity Provider");
        _prepareUSDC(liquidityProvider, 200000e6);
        _preparePT(liquidityProvider, 10 ether);

        // Mint borrowable cUSDC.
        vm.startPrank(liquidityProvider);
        usdc.approve(address(borrowableCUSDC), 200000e6);
        borrowableCUSDC.deposit(200000e6, liquidityProvider);

        // Mint cBALETH.
        pendlePT.approve(address(pendleCTokenPTSTETH), 10 ether);
        pendleCTokenPTSTETH.deposit(10 ether, liquidityProvider);
        vm.stopPrank();
    }

    function testSimpleCTokenMintRedeem() public {
        _preparePT(user1, 2 ether);

        // Try deposit().
        vm.startPrank(user1);
        pendlePT.approve(address(pendleCTokenPTSTETH), 1 ether);
        pendleCTokenPTSTETH.deposit(1 ether, user1);

        assertEq(pendleCTokenPTSTETH.balanceOf(user1), 1 ether);

        // Try deposit().
        pendlePT.approve(address(pendleCTokenPTSTETH), 1 ether);
        pendleCTokenPTSTETH.deposit(1 ether, user2);

        assertEq(pendleCTokenPTSTETH.balanceOf(user1), 1 ether);
        assertEq(pendleCTokenPTSTETH.balanceOf(user2), 1 ether);

        // Try redeem().
        pendleCTokenPTSTETH.redeem(1 ether, user1, user1);
        vm.stopPrank();
        assertEq(pendleCTokenPTSTETH.balanceOf(user1), 0);
    }

    function testBorrowableCTokenMintRedeem() public {
        _prepareUSDC(user1, 2e6);

        // Try deposit().
        vm.startPrank(user1);
        usdc.approve(address(borrowableCUSDC), 1e6);
        borrowableCUSDC.deposit(1e6, user1);

        assertEq(borrowableCUSDC.balanceOf(user1), 1e6);

        // Try deposit() for a different user (user2).
        usdc.approve(address(borrowableCUSDC), 1e6);
        borrowableCUSDC.deposit(1e6, user2);

        assertEq(borrowableCUSDC.balanceOf(user1), 1e6);
        assertEq(borrowableCUSDC.balanceOf(user2), 1e6);

        // Try redeem().
        borrowableCUSDC.redeem(1e6, address(this), user1);
        vm.stopPrank();
        assertEq(borrowableCUSDC.balanceOf(user1), 0);
    }

    function testBorrowableCTokenBorrowRepay() public {
        _preparePT(user1, 1 ether);

        // Try deposit().
        vm.startPrank(user1);
        pendlePT.approve(address(pendleCTokenPTSTETH), 1 ether);
        pendleCTokenPTSTETH.deposit(1 ether, user1);

        AccountSnapshot memory snapshot = pendleCTokenPTSTETH.getSnapshot(user1);
        assertEq(pendleCTokenPTSTETH.balanceOf(user1), 1 ether);
        assertEq(snapshot.debtBalance, 0);
        assertEq(snapshot.exchangeRate, 1 ether);

        pendleCTokenPTSTETH.postCollateral(1 ether);

        // Try borrow().
        borrowableCUSDC.borrow(500e6, user1);

        assertEq(borrowableCUSDC.balanceOf(user1), 0);
        assertEq(borrowableCUSDC.debtBalance(user1), 500e6);
        assertEq(borrowableCUSDC.exchangeRate(), 1 ether);

        // Try borrow().
        skip(1200);

        borrowableCUSDC.borrow(100e6, user1);
        assertEq(borrowableCUSDC.balanceOf(user1), 0);
        assertGt(borrowableCUSDC.debtBalance(user1), 600e6);
        assertGt(borrowableCUSDC.exchangeRate(), 1 ether);

        // Warp until repayment cooldown period ends.
        skip(20 minutes);

        // Try partial repayment.
        AccountSnapshot memory borrowableCUSDCSnapshot;
        borrowableCUSDCSnapshot = borrowableCUSDC.getSnapshot(user1);
        _prepareUSDC(user1, 200e6);
        usdc.approve(address(borrowableCUSDC), 200e6);
        borrowableCUSDC.repay(200e6);
        assertEq(borrowableCUSDC.balanceOf(user1), 0);
        assertGt(borrowableCUSDC.debtBalance(user1), borrowableCUSDCSnapshot.debtBalance - 200e6);
        assertGt(borrowableCUSDC.exchangeRate(), borrowableCUSDCSnapshot.exchangeRate);

        // Warp more to simulate interest being applied on debt.
        skip(30 minutes);

        borrowableCUSDC.accrueIfNeeded();

        // Try full repayment.
        borrowableCUSDCSnapshot = borrowableCUSDC.getSnapshot(user1);
        _prepareUSDC(user1, borrowableCUSDCSnapshot.debtBalance);
        usdc.approve(address(borrowableCUSDC), borrowableCUSDCSnapshot.debtBalance);
        borrowableCUSDC.repay(borrowableCUSDCSnapshot.debtBalance);
        vm.stopPrank();

        assertEq(borrowableCUSDC.balanceOf(user1), 0);
        assertEq(borrowableCUSDC.debtBalance(user1), 0);
        assertEq(borrowableCUSDC.exchangeRate(), borrowableCUSDCSnapshot.exchangeRate, "exchange rate mismatch");
    }

    function testCTokenRedeemOnBorrow() public {
        _preparePT(user1, 1 ether);

        // Try deposit().
        vm.startPrank(user1);
        pendlePT.approve(address(pendleCTokenPTSTETH), 1 ether);
        pendleCTokenPTSTETH.deposit(1 ether, user1);

        pendleCTokenPTSTETH.postCollateral(1 ether);

        // Try borrow().
        borrowableCUSDC.borrow(500e6, user1);

        // Warp until collateralization cooldown period ends.
        skip(20 minutes);

        // Test that full redemption should not be possible.
        vm.expectRevert(
            bytes4(keccak256("MarketManager__InsufficientCollateral()"))
        );
        pendleCTokenPTSTETH.redeem(1 ether, user1, user1);

        // Try partial redemption.
        pendleCTokenPTSTETH.redeem(0.2 ether, user1, user1);
        vm.stopPrank();
        assertEq(pendleCTokenPTSTETH.balanceOf(user1), 0.8 ether);
        assertEq(pendleCTokenPTSTETH.exchangeRate(), 1 ether);
    }

    function testBorrowableCTokenRedeemOnBorrow() public {
        // Try deposit().
        _preparePT(user1, 1 ether);
        vm.startPrank(user1);
        pendlePT.approve(address(pendleCTokenPTSTETH), 1 ether);
        pendleCTokenPTSTETH.deposit(1 ether, user1);

        pendleCTokenPTSTETH.postCollateral(1 ether);

        // Try deposit().
        _prepareUSDC(user1, 1000e6);
        usdc.approve(address(borrowableCUSDC), 1000e6);
        borrowableCUSDC.deposit(1000e6, user1);

        // Try borrow().
        borrowableCUSDC.borrow(500e6, user1);

        // Test that redemption before minimum holding period should not be possible.
        vm.expectRevert(
            MarketManagerIsolated.MarketManager__MinimumHoldPeriod.selector
        );
        borrowableCUSDC.redeem(1000e6, user1, user1);

        // Warp until repayment cooldown period ends.
        skip(20 minutes);

        // Test full redemption.
        borrowableCUSDC.redeem(1000e6, user1, user1);
        vm.stopPrank();

        assertEq(pendleCTokenPTSTETH.balanceOf(user1), 1 ether);
        assertEq(pendleCTokenPTSTETH.exchangeRate(), 1 ether);

        assertEq(borrowableCUSDC.balanceOf(user1), 0);
        assertGt(borrowableCUSDC.debtBalance(user1), 500e6);
        assertGt(borrowableCUSDC.exchangeRate(), 1 ether);
    }

    function testCTokenTransferOnBorrow() public {
        _preparePT(user1, 1 ether);

        // Try deposit().
        vm.startPrank(user1);
        pendlePT.approve(address(pendleCTokenPTSTETH), 1 ether);
        pendleCTokenPTSTETH.deposit(1 ether, user1);

        pendleCTokenPTSTETH.postCollateral(1 ether);

        // Try borrow().
        borrowableCUSDC.borrow(500e6, user1);

        // Warp until collateralization cooldown period ends.
        skip(20 minutes);

        // Test full collateral transfer should not be possible due to
        // outstanding debt.
        vm.expectRevert(
            bytes4(keccak256("MarketManager__InsufficientCollateral()"))
        );
        pendleCTokenPTSTETH.transfer(user2, 1 ether);

        // Test partial redemption.
        pendleCTokenPTSTETH.transfer(user2, 0.2 ether);
        vm.stopPrank();

        assertEq(pendleCTokenPTSTETH.balanceOf(user1), 0.8 ether);
        assertEq(pendleCTokenPTSTETH.balanceOf(user2), 0.2 ether);
        assertEq(pendleCTokenPTSTETH.exchangeRate(), 1 ether);
    }

    function testBorrowableCTokenTransferOnBorrow() public {
        // Try deposit().
        _preparePT(user1, 1 ether);
        vm.startPrank(user1);
        pendlePT.approve(address(pendleCTokenPTSTETH), 1 ether);
        pendleCTokenPTSTETH.deposit(1 ether, user1);

        pendleCTokenPTSTETH.postCollateral(1 ether);

        // Try deposit().
        _prepareUSDC(user1, 1000e6);
        usdc.approve(address(borrowableCUSDC), 1000e6);
        borrowableCUSDC.deposit(1000e6, user1);

        // Try borrow().
        borrowableCUSDC.borrow(500e6, user1);

        // Warp until collateralization cooldown period ends.
        skip(20 minutes);

        // Try full collateral transfer.
        borrowableCUSDC.transfer(user2, 1000e6);
        vm.stopPrank();

        assertEq(pendleCTokenPTSTETH.balanceOf(user1), 1 ether);
        assertEq(pendleCTokenPTSTETH.exchangeRate(), 1 ether);

        assertEq(borrowableCUSDC.balanceOf(user1), 0);
        assertEq(borrowableCUSDC.debtBalance(user1), 500e6);

        assertEq(borrowableCUSDC.balanceOf(user2), 1000e6);
        assertEq(borrowableCUSDC.debtBalance(user2), 0);
        assertEq(borrowableCUSDC.exchangeRate(), 1 ether);
    }

    function testLiquidationExact() public {
        _preparePT(user1, 1 ether);

        // Try deposit().
        vm.startPrank(user1);
        pendlePT.approve(address(pendleCTokenPTSTETH), 1 ether);
        pendleCTokenPTSTETH.deposit(1 ether, user1);

        pendleCTokenPTSTETH.postCollateral(1 ether);

        // Try borrow().
        borrowableCUSDC.borrow(1000e6, user1);
        vm.stopPrank();

        // Warp time to simulate interest being applied on debt.
        skip(20 minutes);

        (uint256 pendlePTPrice, ) = oracleManager.getPrice(
            address(pendlePT),
            true,
            true
        );

        mockUsdcFeed.setMockAnswer(120000000);

        // Try 50% liquidation.
        _prepareUSDC(user2, 250e6);
        vm.startPrank(user2);
        usdc.approve(address(borrowableCUSDC), 250e6);

        address[] memory accounts = new address[](1);
        accounts[0] = user1;
        uint256[] memory debtAmounts = new uint256[](1);
        debtAmounts[0] = 250e6;

        borrowableCUSDC.liquidateExact(
            debtAmounts,
            accounts,
            address(pendleCTokenPTSTETH)
        );
        vm.stopPrank();

        uint256 liquidatedAmount = 250e6;
        assertApproxEqRel(
            pendleCTokenPTSTETH.balanceOf(user1),
            1 ether - (liquidatedAmount * 12e11 * 1 ether) / pendlePTPrice,
            0.03e18
        );
        assertEq(pendleCTokenPTSTETH.exchangeRate(), 1 ether);

        assertEq(borrowableCUSDC.balanceOf(user1), 0);
        assertApproxEqRel(borrowableCUSDC.debtBalance(user1), 750e6, 0.01e18);
        assertApproxEqRel(borrowableCUSDC.exchangeRate(), 1 ether, 0.01e18);
    }

    function testLiquidationFull() public {
        _preparePT(user1, 1 ether);

        // Try deposit().
        vm.startPrank(user1);
        pendlePT.approve(address(pendleCTokenPTSTETH), 1 ether);
        pendleCTokenPTSTETH.deposit(1 ether, user1);

        pendleCTokenPTSTETH.postCollateral(1 ether);

        // Try borrow().
        borrowableCUSDC.borrow(1000e6, user1);
        vm.stopPrank();

        // Warp time to simulate interest being applied on debt.
        skip(20 minutes);

        (uint256 pendlePTPrice, ) = oracleManager.getPrice(
            address(pendlePT),
            true,
            true
        );

        mockUsdcFeed.setMockAnswer(120000000);

        // cache liquidation values

        (uint256 lFactor, uint256 collateralTokenPrice, uint256 debtTokenPrice) = 
            marketManagerIsolated.liquidationStatusOf(user1, address(pendleCTokenPTSTETH), address(borrowableCUSDC));

        (uint256 maxAmount, uint256 liquidatedCollateral, uint256 collateralRequired) = _getLiquidationValuesWithHigherPrecision_NonAuction(
            debtTokenPrice,
            collateralTokenPrice,
            lFactor,
            pendleCTokenPTSTETH.balanceOf(user1),
            borrowableCUSDC.debtBalance(user1)
        );

        uint256 expectedBadDebt = _calculateBadDebt(
            borrowableCUSDC.debtBalance(user1),
            maxAmount,
            pendleCTokenPTSTETH.balanceOf(user1),
            collateralRequired,
            liquidatedCollateral,
            collateralTokenPrice,
            debtTokenPrice,
            pendleCTokenPTSTETH.exchangeRate()
        );
        

        // Try full liquidation.
        _prepareUSDC(user2, 1000e6);
        vm.startPrank(user2);
        usdc.approve(address(borrowableCUSDC), 1000e6);
        address[] memory accounts = new address[](1);
        accounts[0] = user1;

        borrowableCUSDC.liquidate(
            accounts,
            address(pendleCTokenPTSTETH)
        );
        vm.stopPrank();

        uint256 liquidatedAmount = 590e6;

        AccountSnapshot memory snapshot = pendleCTokenPTSTETH.getSnapshot(user1);
        assertApproxEqRel(
            pendleCTokenPTSTETH.balanceOf(user1),
            1 ether - liquidatedCollateral,
            0.03e18, 
            "balance of user1 mismatch"
        );
        assertEq(snapshot.debtBalance, 0);
        assertEq(snapshot.exchangeRate, 1 ether);

        assertEq(borrowableCUSDC.balanceOf(user1), 0);
        assertApproxEqRel(
            borrowableCUSDC.debtBalance(user1),
            1000e6 - (maxAmount + expectedBadDebt),
            0.01e18, 
            "debt balance of user1 mismatch"
        );
        assertApproxEqRel(borrowableCUSDC.exchangeRate(), 1 ether, 0.01e18);
    }

   function _getLiquidationValuesWithHigherPrecision_NonAuction(
        uint256 debtTokenPrice,
        uint256 collateralTokenPrice,
        uint256 lFactor,
        uint256 collateralAmount,
        uint256 borrowAmount
    ) internal view returns (
        uint256 maxAmount, 
        uint256 liquidatedCollateral,
        uint256 collateralRequired
    ) {

            if (lFactor == 0) return (0, 0, 0);

        (uint256 highPrecisionD2C, uint256 auctionCFactor) = _getDebtToCollateralMultiplierAndAuctionCFactor(lFactor, debtTokenPrice, collateralTokenPrice);
                
            maxAmount = (auctionCFactor * borrowAmount) / WAD;
            
            // Calculate with extra precision
            liquidatedCollateral = (maxAmount * highPrecisionD2C) / (WAD_SQUARED);
            
            if (liquidatedCollateral > collateralAmount) {
                // Use the contract's exact formula
                maxAmount = FixedPointMathLib.mulDivUp(
                    maxAmount,
                    collateralAmount,
                    liquidatedCollateral
                );
                liquidatedCollateral = collateralAmount;
            }
            
            // Use the contract's exact formula
            collateralRequired = (borrowAmount * highPrecisionD2C) / (WAD_SQUARED);
    }

    function _getDebtToCollateralMultiplierAndAuctionCFactor(uint256 lFactor, uint256 debtTokenPrice, uint256 collateralTokenPrice) internal view returns (uint256, uint256) {
        uint256 cTokenExchangeRate = pendleCTokenPTSTETH.exchangeRate();

            (
        ,
        ,
        ,
        ,
        uint256 liqIncBase,
        uint256 liqIncCurve,
        ,
        ,
        ,
        ,
        uint256 baseCFactor,
        uint256 cFactorCurve
            ) = marketManagerIsolated.tokenData(address(pendleCTokenPTSTETH));
            
            // Follow the contract's exact calculations but with higher precision
            uint256 auctionCFactor = baseCFactor + ((cFactorCurve * lFactor) / WAD);
            uint256 auctionLiqIncentive = liqIncBase + ((liqIncCurve * lFactor) / WAD);

            console2.log("auctionLiqIncentive", auctionLiqIncentive);
            console2.log("debtTokenPrice", debtTokenPrice);
            console2.log("collateralTokenPrice", collateralTokenPrice);
            console2.log("cTokenExchangeRate", cTokenExchangeRate);
            
            // Calculate with extra precision
            uint256 highPrecisionD2C = (((auctionLiqIncentive * debtTokenPrice * WAD_SQUARED) /
                (collateralTokenPrice * cTokenExchangeRate)) * 1e18) / 1e6;

        return (highPrecisionD2C, auctionCFactor);
    }

    function _calculateBadDebt(
        uint256 _debtBalance,
        uint256 _debtAmount,
        uint256 _collateralAvailable,
        uint256 _collateralRequired,
        uint256 _collateralLiquidated,
        uint256 _collateralTokenUnderlyingPrice,
        uint256 _debtTokenUnderlyingPrice,
        uint256 _cTokenExchangeRate
    ) internal pure returns (uint256 badDebt) {

        if(_collateralRequired > _collateralAvailable) {
    
        badDebt = (_debtBalance - _debtAmount) -
        FixedPointMathLib.mulDivUp(
            ((_collateralAvailable - _collateralLiquidated) * _cTokenExchangeRate) / WAD,
            _collateralTokenUnderlyingPrice,
            (_debtTokenUnderlyingPrice * WAD) / 1e6
        );

        } else {
            return 0;
        }
        
    }

}
