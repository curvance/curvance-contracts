// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import { AccountSnapshot } from "contracts/interfaces/ICToken.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IPendlePTOracle } from "contracts/interfaces/external/pendle/IPendlePtOracle.sol";
import { IPMarket } from "contracts/interfaces/external/pendle/IPMarket.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";

import { SimpleCToken, IERC20 } from "contracts/market/token/SimpleCToken.sol";
import { PendlePrincipalTokenAdaptor } from "contracts/oracles/adaptors/pendle/PendlePrincipalTokenAdaptor.sol";

import "tests/market/TestBaseMarketIsolated.sol";

contract User {}

contract TestPendlePTSimpleCToken is TestBaseMarketIsolated {
    address public owner;

    address internal constant _PT_ORACLE =
        0x14030836AEc15B2ad48bB097bd57032559339c92;

    address internal _STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address internal _PT_STETH = 0x7758896b6AC966BbABcf143eFA963030f17D3EdF; // PT-stETH-26DEC24
    address internal _LP_STETH = 0xD0354D4e7bCf345fB117cabe41aCaDb724eccCa2; // PT-stETH-26DEC24/SY-stETH Market

    PendlePrincipalTokenAdaptor public adapter;

    MockDataFeed public mockUsdcFeed;
    MockDataFeed public mockWethFeed;
    MockDataFeed public mockStethFeed;

    SimpleCToken public cPendlePT;
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

        // Deploy borrowable cUSDC.
        {
            _deployBorrowableCUSDC();

            _prepareUSDC(owner, 200000e6);
            usdc.approve(address(borrowableCUSDC), 200000e6);
            // Add cToken support on Oracle Manager.
            oracleManager.addCTokenSupport(address(borrowableCUSDC));
        }

        // Deploy Pendle stETH principal token.
        {
            cPendlePT = new SimpleCToken(
                ICentralRegistry(address(centralRegistry)),
                pendlePT,
                address(marketManagerIsolated)
            );

            _preparePT(owner, 1 ether);
            pendlePT.approve(address(cPendlePT), 1 ether);
            // Add cToken support on Oracle Manager.
            oracleManager.addCTokenSupport(address(cPendlePT));
        }

        marketManagerIsolated.listTokens(address(cPendlePT), address(borrowableCUSDC));

        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = address(cPendlePT);
        tokenConfig.collRatio = 7000;
        tokenConfig.collReqSoft = 4000;
        tokenConfig.collReqHard = 3000;
        tokenConfig.liqIncBase = 1000;
        tokenConfig.liqIncHard = 1500;
        tokenConfig.liqIncMin = 500;
        tokenConfig.liqIncMax = 2000;
        tokenConfig.minEffectiveCloseFactor = 2000;
        tokenConfig.maxEffectiveCloseFactor = 5000;
        tokenConfig.baseCFactor = 2000;
        tokenConfig.collateralCap = 100_000e18;
        tokenConfig.debtCap = 0;

        marketManagerIsolated.updateTokenConfig(tokenConfig);

        tokenConfig.cToken = address(borrowableCUSDC);
        tokenConfig.debtCap = 100_000e18;
        marketManagerIsolated.updateTokenConfig(tokenConfig);

        // Provide enough liquidity for leverage actions.
        provideEnoughLiquidityForLeverage();
    }

    function _preparePT(address user, uint256 amount) internal {
        deal(_PT_STETH, user, amount);
    }

    function provideEnoughLiquidityForLeverage() internal {
        address liquidityProvider = address(new User());
        _prepareUSDC(liquidityProvider, 200000e6);
        _preparePT(liquidityProvider, 10 ether);
        // Deposit borrowable cUSDC.
        vm.startPrank(liquidityProvider);
        usdc.approve(address(borrowableCUSDC), 200000e6);
        borrowableCUSDC.deposit(200000e6, liquidityProvider);
        // Deposit cBALETH.
        pendlePT.approve(address(cPendlePT), 10 ether);
        cPendlePT.deposit(10 ether, liquidityProvider);
        vm.stopPrank();
    }

    function testSimpleCTokenMintRedeem() public {
        _preparePT(user1, 2 ether);

        // Try deposit().
        vm.startPrank(user1);
        pendlePT.approve(address(cPendlePT), 1 ether);
        cPendlePT.deposit(1 ether, user1);

        assertEq(cPendlePT.balanceOf(user1), 1 ether);

        // Try deposit().
        pendlePT.approve(address(cPendlePT), 1 ether);
        cPendlePT.deposit(1 ether, user2);

        assertEq(cPendlePT.balanceOf(user1), 1 ether);
        assertEq(cPendlePT.balanceOf(user2), 1 ether);

        // Try redeem().
        cPendlePT.redeem(1 ether, user1, user1);
        vm.stopPrank();
        assertEq(cPendlePT.balanceOf(user1), 0);
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
        pendlePT.approve(address(cPendlePT), 1 ether);
        cPendlePT.deposit(1 ether, user1);

        AccountSnapshot memory snapshot = cPendlePT.getSnapshot(user1);
        assertEq(cPendlePT.balanceOf(user1), 1 ether);
        assertEq(snapshot.debtBalance, 0);
        assertEq(snapshot.exchangeRate, 1 ether);

        cPendlePT.postCollateral(1 ether);

        // Try borrow().
        borrowableCUSDC.borrow(500e6);

        assertEq(borrowableCUSDC.balanceOf(user1), 0);
        assertEq(borrowableCUSDC.debtBalance(user1), 500e6);
        assertEq(borrowableCUSDC.exchangeRateCached(), 1 ether);

        // Try borrow().
        skip(1200);

        borrowableCUSDC.borrow(100e6);
        assertEq(borrowableCUSDC.balanceOf(user1), 0);
        assertGt(borrowableCUSDC.debtBalance(user1), 600e6);
        assertGt(borrowableCUSDC.exchangeRateCached(), 1 ether);

        // Warp until repayment cooldown period ends.
        skip(20 minutes);

        // Try partial repayment.
        (, uint256 borrowBalanceBefore, uint256 exchangeRateBefore) = eUSDC
            .getSnapshot(user1);
        _prepareUSDC(user1, 200e6);
        usdc.approve(address(borrowableCUSDC), 200e6);
        borrowableCUSDC.repay(200e6);
        assertEq(borrowableCUSDC.balanceOf(user1), 0);
        assertGt(borrowableCUSDC.debtBalance(user1), borrowBalanceBefore - 200e6);
        assertGt(borrowableCUSDC.exchangeRateCached(), exchangeRateBefore);

        // Warp more to simulate interest being applied on debt.
        skip(30 minutes);

        // Try full repayment.
        (, borrowBalanceBefore, exchangeRateBefore) = borrowableCUSDC.getSnapshot(user1);
        _prepareUSDC(user1, borrowBalanceBefore);
        usdc.approve(address(borrowableCUSDC), borrowBalanceBefore);
        borrowableCUSDC.repay(borrowBalanceBefore);
        vm.stopPrank();
        assertEq(borrowableCUSDC.balanceOf(user1), 0);
        assertGt(borrowableCUSDC.debtBalance(user1), 0);
        assertGt(borrowableCUSDC.exchangeRateCached(), exchangeRateBefore);
    }

    function testCTokenRedeemOnBorrow() public {
        _preparePT(user1, 1 ether);

        // Try deposit().
        vm.startPrank(user1);
        pendlePT.approve(address(cPendlePT), 1 ether);
        cPendlePT.deposit(1 ether, user1);

        cPendlePT.postCollateral(1 ether);

        // Try borrow().
        borrowableCUSDC.borrow(500e6);

        // Warp until collateralization cooldown period ends.
        skip(20 minutes);

        // Test that full redemption should not be possible.
        vm.expectRevert(
            bytes4(keccak256("MarketManager__InsufficientCollateral()"))
        );
        cPendlePT.redeem(1 ether, user1, user1);

        // Try partial redemption.
        cPendlePT.redeem(0.2 ether, user1, user1);
        vm.stopPrank();
        assertEq(cPendlePT.balanceOf(user1), 0.8 ether);
        assertEq(cPendlePT.exchangeRate(), 1 ether);
    }

    function testBorrowableCTokenRedeemOnBorrow() public {
        // Try deposit().
        _preparePT(user1, 1 ether);
        vm.startPrank(user1);
        pendlePT.approve(address(cPendlePT), 1 ether);
        cPendlePT.deposit(1 ether, user1);

        cPendlePT.postCollateral(1 ether);

        // Try deposit().
        _prepareUSDC(user1, 1000e6);
        usdc.approve(address(borrowableCUSDC), 1000e6);
        borrowableCUSDC.deposit(1000e6, user1);

        // Try borrow().
        borrowableCUSDC.borrow(500e6);

        // Test that redemption before minimum holding period should not be possible.
        vm.expectRevert(
            MarketManagerIsolated.MarketManager__MinimumHoldPeriod.selector
        );
        borrowableCUSDC.redeem(1000e6, address(this));

        // Warp until repayment cooldown period ends.
        skip(20 minutes);

        // Test full redemption.
        borrowableCUSDC.redeem(1000e6, address(this));
        vm.stopPrank();

        assertEq(cPendlePT.balanceOf(user1), 1 ether);
        assertEq(cPendlePT.exchangeRate(), 1 ether);

        assertEq(borrowableCUSDC.balanceOf(user1), 0);
        assertGt(borrowableCUSDC.debtBalance(user1), 500e6);
        assertGt(borrowableCUSDC.exchangeRateCached(), 1 ether);
    }

    function testCTokenTransferOnBorrow() public {
        _preparePT(user1, 1 ether);

        // Try deposit().
        vm.startPrank(user1);
        pendlePT.approve(address(cPendlePT), 1 ether);
        cPendlePT.deposit(1 ether, user1);

        cPendlePT.postCollateral(1 ether);

        // Try borrow().
        borrowableCUSDC.borrow(500e6);

        // Warp until collateralization cooldown period ends.
        skip(20 minutes);

        // Test full collateral transfer should not be possible due to
        // outstanding debt.
        vm.expectRevert(
            bytes4(keccak256("MarketManager__InsufficientCollateral()"))
        );
        cPendlePT.transfer(user2, 1 ether);

        // Test partial redemption.
        cPendlePT.transfer(user2, 0.2 ether);
        vm.stopPrank();

        assertEq(cPendlePT.balanceOf(user1), 0.8 ether);
        assertEq(cPendlePT.balanceOf(user2), 0.2 ether);
        assertEq(cPendlePT.exchangeRate(), 1 ether);
    }

    function testBorrowableCTokenTransferOnBorrow() public {
        // Try deposit().
        _preparePT(user1, 1 ether);
        vm.startPrank(user1);
        pendlePT.approve(address(cPendlePT), 1 ether);
        cPendlePT.deposit(1 ether, user1);

        cPendlePT.postCollateral(1 ether);

        // Try deposit().
        _prepareUSDC(user1, 1000e6);
        usdc.approve(address(borrowableCUSDC), 1000e6);
        borrowableCUSDC.deposit(1000e6, user1);

        // Try borrow().
        borrowableCUSDC.borrow(500e6);

        // Warp until collateralization cooldown period ends.
        skip(20 minutes);

        // Try full collateral transfer.
        borrowableCUSDC.transfer(user2, 1000e6);
        vm.stopPrank();

        assertEq(cPendlePT.balanceOf(user1), 1 ether);
        assertEq(cPendlePT.exchangeRate(), 1 ether);

        assertEq(borrowableCUSDC.balanceOf(user1), 0);
        assertEq(borrowableCUSDC.debtBalance(user1), 500e6);

        assertEq(borrowableCUSDC.balanceOf(user2), 1000e6);
        assertEq(borrowableCUSDC.debtBalance(user2), 0);
        assertEq(borrowableCUSDC.exchangeRateCached(), 1 ether);
    }

    function testLiquidationExact() public {
        _preparePT(user1, 1 ether);

        // Try deposit().
        vm.startPrank(user1);
        pendlePT.approve(address(cPendlePT), 1 ether);
        cPendlePT.deposit(1 ether, user1);

        cPendlePT.postCollateral(1 ether);

        // Try borrow().
        borrowableCUSDC.borrow(1000e6);
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
            accounts,
            debtAmounts,
            address(cPendlePT)
        );
        vm.stopPrank();

        uint256 liquidatedAmount = 250e6;
        assertApproxEqRel(
            cPendlePT.balanceOf(user1),
            1 ether - (liquidatedAmount * 12e11 * 1 ether) / pendlePTPrice,
            0.03e18
        );
        assertEq(cPendlePT.exchangeRateCached(), 1 ether);

        assertEq(borrowableCUSDC.balanceOf(user1), 0);
        assertApproxEqRel(borrowableCUSDC.debtBalance(user1), 750e6, 0.01e18);
        assertApproxEqRel(borrowableCUSDC.exchangeRateCached(), 1 ether, 0.01e18);
    }

    function testLiquidationFull() public {
        _preparePT(user1, 1 ether);

        // Try deposit().
        vm.startPrank(user1);
        pendlePT.approve(address(cPendlePT), 1 ether);
        cPendlePT.deposit(1 ether, user1);

        cPendlePT.postCollateral(1 ether);

        // Try borrow().
        borrowableCUSDC.borrow(1000e6);
        vm.stopPrank();

        // Warp time to simulate interest being applied on debt.
        skip(20 minutes);

        (uint256 pendlePTPrice, ) = oracleManager.getPrice(
            address(pendlePT),
            true,
            true
        );

        mockUsdcFeed.setMockAnswer(120000000);

        // Try full liquidation.
        _prepareUSDC(user2, 1000e6);
        vm.startPrank(user2);
        usdc.approve(address(borrowableCUSDC), 1000e6);
        address[] memory accounts = new address[](1);
        accounts[0] = user1;

        borrowableCUSDC.liquidate(
            accounts,
            address(cPendlePT)
        );
        vm.stopPrank();

        uint256 liquidatedAmount = 590e6;

        AccountSnapshot memory snapshot = cPendlePT.getSnapshot(user1);
        assertApproxEqRel(
            cPendlePT.balanceOf(user1),
            1 ether - (liquidatedAmount * 12e11 * 1 ether) / pendlePTPrice,
            0.03e18
        );
        assertEq(snapshot.debtBalance, 0);
        assertEq(snapshot.exchangeRate, 1 ether);

        assertEq(borrowableCUSDC.balanceOf(user1), 0);
        assertApproxEqRel(
            borrowableCUSDC.debtBalance(user1),
            1000e6 - liquidatedAmount,
            0.01e18
        );
        assertApproxEqRel(borrowableCUSDC.exchangeRateCached(), 1 ether, 0.01e18);
    }
}
