// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { AccountSnapshot } from "contracts/interfaces/IMToken.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IPendlePTOracle } from "contracts/interfaces/external/pendle/IPendlePtOracle.sol";
import { IPMarket } from "contracts/interfaces/external/pendle/IPMarket.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";

import { SimpleCToken, IERC20 } from "contracts/market/token/SimpleCToken.sol";
import { PendlePrincipalTokenAdaptor } from "contracts/oracles/adaptors/pendle/PendlePrincipalTokenAdaptor.sol";

import "tests/market/TestBaseMarketIsolated.sol";

contract User {}

contract TestPTokenForPendlePT is TestBaseMarketIsolated {
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

        // deploy eUSDC
        {
            _deployEUSDC();
            // support market
            _prepareUSDC(owner, 200000e6);
            usdc.approve(address(eUSDC), 200000e6);
            // add MToken support on oracle manager
            oracleManager.addMTokenSupport(address(eUSDC));
            address[] memory markets = new address[](1);
            markets[0] = address(eUSDC);
            // vm.prank(user1);
            // marketManager.enterMarkets(markets);
            // vm.prank(user2);
            // marketManager.enterMarkets(markets);
        }

        // deploy cPendlePT
        {
            // deploy aura position vault
            cPendlePT = new SimpleCToken(
                ICentralRegistry(address(centralRegistry)),
                pendlePT,
                address(marketManagerIsolated)
            );

            // support market
            _preparePT(owner, 1 ether);
            pendlePT.approve(address(cPendlePT), 1 ether);
            // add MToken support on oracle manager
            oracleManager.addMTokenSupport(address(cPendlePT));
            


            // address[] memory markets = new address[](1);
            // markets[0] = address(cPendlePT);
            // vm.prank(user1);
            // marketManager.enterMarkets(markets);
            // vm.prank(user2);
            // marketManager.enterMarkets(markets);
        }

        marketManagerIsolated.listTokens(address(cPendlePT), address(eUSDC));

        // set collateral factor
        marketManagerIsolated.updatePositionToken(
            7000,    // collRatio 70%
            4000,    // collReqSoft 40%
            3000,    // collReqHard 25%
            1000,    // liqIncBase 10%
            1500,    // liqIncHard 15%
            500,     // liqIncMin 5%
            2000,    // liqIncMax 20%
            2000,    // minEffectiveCFactor 20%
            5000,    // maxEffectiveCFactor 50%
            1000     // baseCFactor 10%
        );

        address[] memory mTokens = new address[](1);
        mTokens[0] = address(cPendlePT);
        uint256[] memory caps = new uint256[](1);
        caps[0] = 100 ether;
        marketManagerIsolated.setCollateralCaps(mTokens, caps);

        // provide enough liquidity
        provideEnoughLiquidityForLeverage();
    }

    function _preparePT(address user, uint256 amount) internal {
        deal(_PT_STETH, user, amount);
    }

    function provideEnoughLiquidityForLeverage() internal {
        address liquidityProvider = address(new User());
        _prepareUSDC(liquidityProvider, 200000e6);
        _preparePT(liquidityProvider, 10 ether);
        // mint eUSDC
        vm.startPrank(liquidityProvider);
        usdc.approve(address(eUSDC), 200000e6);
        eUSDC.mint(200000e6);
        // mint cBALETH
        pendlePT.approve(address(cPendlePT), 10 ether);
        cPendlePT.mint(10 ether, liquidityProvider);
        vm.stopPrank();
    }

    function testInitialize() public {
        assertTrue(cPendlePT.isCollateralizable());
        assertTrue(eUSDC.isBorrowable());
    }

    function testPTokenMintRedeem() public {
        _preparePT(user1, 2 ether);

        // try mint()
        vm.startPrank(user1);
        pendlePT.approve(address(cPendlePT), 1 ether);
        cPendlePT.mint(1 ether, user1);

        assertEq(cPendlePT.balanceOf(user1), 1 ether);

        // try mint()
        pendlePT.approve(address(cPendlePT), 1 ether);
        cPendlePT.mint(1 ether, user2);

        assertEq(cPendlePT.balanceOf(user1), 1 ether);
        assertEq(cPendlePT.balanceOf(user2), 1 ether);

        // try redeem()
        cPendlePT.redeem(1 ether, user1, user1);
        vm.stopPrank();
        assertEq(cPendlePT.balanceOf(user1), 0);
    }

    function testETokenMintRedeem() public {
        _prepareUSDC(user1, 2e6);

        // try mint()
        vm.startPrank(user1);
        usdc.approve(address(eUSDC), 1e6);
        eUSDC.mint(1e6);

        assertEq(eUSDC.balanceOf(user1), 1e6);

        // try mintFor()
        usdc.approve(address(eUSDC), 1e6);
        eUSDC.mintFor(1e6, user2);

        assertEq(eUSDC.balanceOf(user1), 1e6);
        assertEq(eUSDC.balanceOf(user2), 1e6);

        // try redeem()
        eUSDC.redeem(1e6, address(this));
        vm.stopPrank();
        assertEq(eUSDC.balanceOf(user1), 0);
    }

    function testETokenBorrowRepay() public {
        _preparePT(user1, 1 ether);

        // try mint()
        vm.startPrank(user1);
        pendlePT.approve(address(cPendlePT), 1 ether);
        cPendlePT.mint(1 ether, user1);

        AccountSnapshot memory snapshot = cPendlePT.getSnapshot(user1);
        assertEq(cPendlePT.balanceOf(user1), 1 ether);
        assertEq(snapshot.debtBalance, 0);
        assertEq(snapshot.exchangeRate, 1 ether);

        cPendlePT.postCollateral(1 ether);

        // try borrow()
        eUSDC.borrow(500e6);

        assertEq(eUSDC.balanceOf(user1), 0);
        assertEq(eUSDC.debtBalanceCached(user1), 500e6);
        assertEq(eUSDC.exchangeRateCached(), 1 ether);

        // try borrow()
        skip(1200);

        eUSDC.borrow(100e6);
        assertEq(eUSDC.balanceOf(user1), 0);
        assertGt(eUSDC.debtBalanceCached(user1), 600e6);
        assertGt(eUSDC.exchangeRateCached(), 1 ether);

        // skip min hold period
        skip(20 minutes);

        // try partial repay
        (, uint256 borrowBalanceBefore, uint256 exchangeRateBefore) = eUSDC
            .getSnapshot(user1);
        _prepareUSDC(user1, 200e6);
        usdc.approve(address(eUSDC), 200e6);
        eUSDC.repay(200e6);
        assertEq(eUSDC.balanceOf(user1), 0);
        assertGt(eUSDC.debtBalanceCached(user1), borrowBalanceBefore - 200e6);
        assertGt(eUSDC.exchangeRateCached(), exchangeRateBefore);

        // skip some period
        skip(1200);

        // try repay full
        (, borrowBalanceBefore, exchangeRateBefore) = eUSDC.getSnapshot(user1);
        _prepareUSDC(user1, borrowBalanceBefore);
        usdc.approve(address(eUSDC), borrowBalanceBefore);
        eUSDC.repay(borrowBalanceBefore);
        vm.stopPrank();
        assertEq(eUSDC.balanceOf(user1), 0);
        assertGt(eUSDC.debtBalanceCached(user1), 0);
        assertGt(eUSDC.exchangeRateCached(), exchangeRateBefore);
    }

    function testPTokenRedeemOnBorrow() public {
        _preparePT(user1, 1 ether);

        // try mint()
        vm.startPrank(user1);
        pendlePT.approve(address(cPendlePT), 1 ether);
        cPendlePT.mint(1 ether, user1);

        cPendlePT.postCollateral(1 ether);

        // try borrow()
        eUSDC.borrow(500e6);

        // skip min hold period
        skip(20 minutes);

        // can't redeem full
        vm.expectRevert(
            bytes4(keccak256("MarketManager__InsufficientCollateral()"))
        );
        cPendlePT.redeem(1 ether, user1, user1);

        // can redeem partially
        cPendlePT.redeem(0.2 ether, user1, user1);
        vm.stopPrank();
        assertEq(cPendlePT.balanceOf(user1), 0.8 ether);
        assertEq(cPendlePT.exchangeRate(), 1 ether);
    }

    function testETokenRedeemOnBorrow() public {
        // try mint()
        _preparePT(user1, 1 ether);
        vm.startPrank(user1);
        pendlePT.approve(address(cPendlePT), 1 ether);
        cPendlePT.mint(1 ether, user1);

        cPendlePT.postCollateral(1 ether);

        // try mint()
        _prepareUSDC(user1, 1000e6);
        usdc.approve(address(eUSDC), 1000e6);
        eUSDC.mint(1000e6);

        // try borrow()
        eUSDC.borrow(500e6);

        // fail to redeem before minimum hold time pass
        vm.expectRevert(
            MarketManagerIsolated.MarketManager__MinimumHoldPeriod.selector
        );
        eUSDC.redeem(1000e6, address(this));

        // skip min hold period
        skip(20 minutes);

        // can redeem fully
        eUSDC.redeem(1000e6, address(this));
        vm.stopPrank();

        assertEq(cPendlePT.balanceOf(user1), 1 ether);
        assertEq(cPendlePT.exchangeRate(), 1 ether);

        assertEq(eUSDC.balanceOf(user1), 0);
        assertGt(eUSDC.debtBalanceCached(user1), 500e6);
        assertGt(eUSDC.exchangeRateCached(), 1 ether);
    }

    function testPTokenTransferOnBorrow() public {
        _preparePT(user1, 1 ether);

        // try mint()
        vm.startPrank(user1);
        pendlePT.approve(address(cPendlePT), 1 ether);
        cPendlePT.mint(1 ether, user1);

        cPendlePT.postCollateral(1 ether);

        // try borrow()
        eUSDC.borrow(500e6);

        // skip min hold period
        skip(20 minutes);

        // can't transfer full
        vm.expectRevert(
            bytes4(keccak256("MarketManager__InsufficientCollateral()"))
        );
        cPendlePT.transfer(user2, 1 ether);

        // can redeem partially
        cPendlePT.transfer(user2, 0.2 ether);
        vm.stopPrank();

        assertEq(cPendlePT.balanceOf(user1), 0.8 ether);
        assertEq(cPendlePT.balanceOf(user2), 0.2 ether);
        assertEq(cPendlePT.exchangeRate(), 1 ether);
    }

    function testETokenTransferOnBorrow() public {
        // try mint()
        _preparePT(user1, 1 ether);
        vm.startPrank(user1);
        pendlePT.approve(address(cPendlePT), 1 ether);
        cPendlePT.mint(1 ether, user1);

        cPendlePT.postCollateral(1 ether);

        // try mint()
        _prepareUSDC(user1, 1000e6);
        usdc.approve(address(eUSDC), 1000e6);
        eUSDC.mint(1000e6);

        // try borrow()
        eUSDC.borrow(500e6);

        // skip min hold period
        skip(20 minutes);

        // try full transfer
        eUSDC.transfer(user2, 1000e6);
        vm.stopPrank();

        assertEq(cPendlePT.balanceOf(user1), 1 ether);
        assertEq(cPendlePT.exchangeRate(), 1 ether);

        assertEq(eUSDC.balanceOf(user1), 0);
        assertEq(eUSDC.debtBalanceCached(user1), 500e6);

        assertEq(eUSDC.balanceOf(user2), 1000e6);
        assertEq(eUSDC.debtBalanceCached(user2), 0);
        assertEq(eUSDC.exchangeRateCached(), 1 ether);
    }

    // function testLiquidationExact() public {
    //     _preparePT(user1, 1 ether);

    //     // try mint()
    //     vm.startPrank(user1);
    //     pendlePT.approve(address(cPendlePT), 1 ether);
    //     cPendlePT.mint(1 ether, user1);

    //     cPendlePT.postCollateral(1 ether);

    //     // try borrow()
    //     eUSDC.borrow(1000e6);
    //     vm.stopPrank();

    //     // skip min hold period
    //     skip(20 minutes);

    //     (uint256 pendlePTPrice, ) = oracleManager.getPrice(
    //         address(pendlePT),
    //         true,
    //         true
    //     );

    //     mockUsdcFeed.setMockAnswer(120000000);

    //     // try liquidate half
    //     _prepareUSDC(user2, 250e6);
    //     vm.startPrank(user2);
    //     usdc.approve(address(eUSDC), 250e6);

    //     address[] memory accounts = new address[](1);
    //     accounts[0] = user1;
    //     uint256[] memory debtAmounts = new uint256[](1);
    //     debtAmounts[0] = 250e6;

    //     eUSDC.liquidateExact(
    //         accounts,
    //         debtAmounts,
    //         address(cPendlePT)
    //     );
    //     vm.stopPrank();

    //     uint256 liquidatedAmount = 250e6;
    //     assertApproxEqRel(
    //         cPendlePT.balanceOf(user1),
    //         1 ether - (liquidatedAmount * 12e11 * 1 ether) / pendlePTPrice,
    //         0.03e18
    //     );
    //     assertEq(cPendlePT.exchangeRateCached(), 1 ether);

    //     assertEq(eUSDC.balanceOf(user1), 0);
    //     assertApproxEqRel(eUSDC.debtBalanceCached(user1), 750e6, 0.01e18);
    //     assertApproxEqRel(eUSDC.exchangeRateCached(), 1 ether, 0.01e18);
    // }

    // function testLiquidationFull() public {
    //     _preparePT(user1, 1 ether);

    //     // try mint()
    //     vm.startPrank(user1);
    //     pendlePT.approve(address(cPendlePT), 1 ether);
    //     cPendlePT.mint(1 ether, user1);

    //     cPendlePT.postCollateral(1 ether);

    //     // try borrow()
    //     eUSDC.borrow(1000e6);
    //     vm.stopPrank();

    //     // skip min hold period
    //     skip(20 minutes);

    //     (uint256 pendlePTPrice, ) = oracleManager.getPrice(
    //         address(pendlePT),
    //         true,
    //         true
    //     );

    //     mockUsdcFeed.setMockAnswer(120000000);

    //     // try liquidate
    //     _prepareUSDC(user2, 1000e6);
    //     vm.startPrank(user2);
    //     usdc.approve(address(eUSDC), 1000e6);
    //     address[] memory accounts = new address[](1);
    //     accounts[0] = user1;

    //     eUSDC.liquidate(
    //         accounts,
    //         address(cPendlePT)
    //     );
    //     vm.stopPrank();

    //     uint256 liquidatedAmount = 590e6;

    //     AccountSnapshot memory snapshot = cPendlePT.getSnapshot(user1);
    //     assertApproxEqRel(
    //         cPendlePT.balanceOf(user1),
    //         1 ether - (liquidatedAmount * 12e11 * 1 ether) / pendlePTPrice,
    //         0.03e18
    //     );
    //     assertEq(snapshot.debtBalance, 0);
    //     assertEq(snapshot.exchangeRate, 1 ether);

    //     assertEq(eUSDC.balanceOf(user1), 0);
    //     assertApproxEqRel(
    //         eUSDC.debtBalanceCached(user1),
    //         1000e6 - liquidatedAmount,
    //         0.01e18
    //     );
    //     assertApproxEqRel(eUSDC.exchangeRateCached(), 1 ether, 0.01e18);
    // }
}
