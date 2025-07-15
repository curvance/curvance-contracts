// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { AerodromeVolatileCToken } from "contracts/market/token/AerodromeVolatileCToken.sol";
import { VelodromeVolatileLPAdaptor } from "contracts/oracles/adaptors/velodrome/VelodromeVolatileLPAdaptor.sol";
import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { AerodromePositionManager } from "contracts/market/position-management/AerodromePositionManager.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { ICToken, AccountSnapshot } from "contracts/interfaces/ICToken.sol";
import { IVeloGauge } from "contracts/interfaces/external/velodrome/IVeloGauge.sol";
import { IVeloRouter } from "contracts/interfaces/external/velodrome/IVeloRouter.sol";
import { IVeloPairFactory } from "contracts/interfaces/external/velodrome/IVeloPairFactory.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

contract AerodromeVolatilePositionManager is TestBaseMarketIsolated {
    address internal _AERODROME_WETH_USDC =
        0xcDAC0d6c6C59727a65F871236188350531885C43;
    IVeloGauge public gauge =
        IVeloGauge(0x519BBD1Dd8C6A94C46080E24f316c14Ee758C025);
    IVeloPairFactory public aeroPairFactory =
        IVeloPairFactory(0x420DD381b31aEf6683db6B902084cB0FFECe40Da);
    IVeloRouter public aeroRouter =
        IVeloRouter(0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43);

    AerodromeVolatileCToken public strategyCTokenWETHUSDC;
    VelodromeVolatileLPAdaptor public adaptor;
    AerodromePositionManager public positionManager;

    address public owner;
    address public user;

    receive() external payable {}

    fallback() external payable {}

    function setUp() public override {
        _fork("ETH_NODE_URI_BASE", 19000000);

        _deployCentralRegistry();
        _deployCVE();
        _deployRewardManager();
        _deployVeCVE();
        _deployGaugeManager();
        _deployMarketManager();
        _deployOracleManager();

        chainlinkAdaptor = new ChainlinkAdaptor(
            ICentralRegistry(address(centralRegistry))
        );
        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));

        chainlinkDaiUsd = new MockV3Aggregator(8, 1e8, 1e50, 1e6);
        chainlinkAdaptor.addAsset(
            _DAI_ADDRESS,
            address(chainlinkDaiUsd),
            0,
            true
        );
        oracleManager.addAssetPriceFeed(
            _DAI_ADDRESS,
            address(chainlinkAdaptor)
        );
        chainlinkUsdcUsd = new MockV3Aggregator(8, 1e8, 1e50, 1e6);
        chainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            address(chainlinkUsdcUsd),
            0,
            true
        );
        oracleManager.addAssetPriceFeed(
            _USDC_ADDRESS,
            address(chainlinkAdaptor)
        );

        chainlinkEthUsd = new MockV3Aggregator(8, 2700e8, 1e50, 1e6);
        chainlinkAdaptor.addAsset(
            _ETH_ADDRESS,
            address(chainlinkEthUsd),
            0,
            true
        );
        chainlinkAdaptor.addAsset(
            _WETH_ADDRESS,
            address(chainlinkEthUsd),
            0,
            true
        );
        oracleManager.addAssetPriceFeed(
            _ETH_ADDRESS,
            address(chainlinkAdaptor)
        );
        oracleManager.addAssetPriceFeed(
            _WETH_ADDRESS,
            address(chainlinkAdaptor)
        );

        adaptor = new VelodromeVolatileLPAdaptor(
            ICentralRegistry(address(centralRegistry))
        );
        adaptor.addAsset(_AERODROME_WETH_USDC);
        oracleManager.addApprovedAdaptor(address(adaptor));
        oracleManager.addAssetPriceFeed(
            _AERODROME_WETH_USDC,
            address(adaptor)
        );

        owner = address(this);
        user = user1;

        // Setup borrowable cDAI.
        {
            _deployBorrowableCDAI();
            // Add cToken support on Oracle Manager.
            oracleManager.addCTokenSupport(address(borrowableCDAI));

            _prepareDAI(owner, 200000e18);
            dai.approve(address(borrowableCDAI), 200000e18);

        }

        // Setup strategyCTokenWETHUSDC.
        {
            strategyCTokenWETHUSDC = new AerodromeVolatileCToken(
                ICentralRegistry(address(centralRegistry)),
                IERC20(_AERODROME_WETH_USDC),
                address(marketManagerIsolated),
                gauge,
                aeroPairFactory,
                aeroRouter,
                1 days
            );
            // Add cToken support on Oracle Manager.
            oracleManager.addCTokenSupport(address(strategyCTokenWETHUSDC));

            deal(_AERODROME_WETH_USDC, owner, 1 ether);
            IERC20(_AERODROME_WETH_USDC).approve(address(strategyCTokenWETHUSDC), 1 ether);

        }

        marketManagerIsolated.listTokens(address(strategyCTokenWETHUSDC),address(borrowableCDAI));

         _setCTokenConfigBasic(address(strategyCTokenWETHUSDC), 100_000e18, 0);
         _setCTokenConfigBasic(address(borrowableCDAI), 100_000e18, 100_000e18);

        positionManager = new AerodromePositionManager(
            ICentralRegistry(address(centralRegistry)),
            address(marketManagerIsolated),
            _WETH_ADDRESS,
            address(aeroRouter),
            address(aeroPairFactory)
        );
        marketManagerIsolated.addPositionManager(address(positionManager));

        _provideEnoughLiquidityForLeverage();

        centralRegistry.setExternalCalldataChecker(
            _UNISWAP_V2_ROUTER,
            address(new MockCalldataChecker(_UNISWAP_V2_ROUTER))
        );

        centralRegistry.setExternalCalldataChecker(
            address(aeroRouter),
            address(new MockCalldataChecker(address(aeroRouter)))
        );

        centralRegistry.setSlippageLimit(60000);
    }

    function testInitialize() public {
        assertEq(
            address(positionManager.centralRegistry()),
            address(centralRegistry)
        );
        assertEq(
            address(positionManager.marketManager()),
            address(marketManagerIsolated)
        );
    }

    function testLeverage() public {
        vm.startPrank(user);

        deal(_AERODROME_WETH_USDC, user, 0.0001 ether);
        IERC20(_AERODROME_WETH_USDC).approve(address(strategyCTokenWETHUSDC), 0.0001 ether);

        // Mint strategyCTokenWETHUSDC.
        assertGt(strategyCTokenWETHUSDC.deposit(0.0001 ether, user), 0);
        strategyCTokenWETHUSDC.postCollateral(0.0001 ether);
        assertEq(strategyCTokenWETHUSDC.balanceOf(user), 0.0001 ether);

        uint256 balanceBeforeBorrow = dai.balanceOf(user);
        
        // Borrow borrowable cDAI.
        borrowableCDAI.borrow(100 ether);
        assertEq(balanceBeforeBorrow + 100 ether, dai.balanceOf(user));

        // Try leverage with 50% of max.
        uint256 amountForLeverage = (positionManager.maxRemainingLeverageOf(
            user,
            address(borrowableCDAI)
        ) * 50) / 100;

        AerodromePositionManager.LeverageStruct memory leverageData;
        leverageData.debtToken = IBorrowableCToken(address(borrowableCDAI));
        leverageData.borrowAssets = amountForLeverage;
        leverageData.collateralToken = ICToken(address(strategyCTokenWETHUSDC));
        leverageData.swapData.inputToken = _DAI_ADDRESS;
        leverageData.swapData.inputAmount = amountForLeverage;
        leverageData.swapData.outputToken = _WETH_ADDRESS;
        leverageData.swapData.target = address(aeroRouter);
        IVeloRouter.Route[] memory routes = new IVeloRouter.Route[](2);
        routes[0].from = _DAI_ADDRESS;
        routes[0].to = _USDC_ADDRESS;
        routes[0].stable = true;
        routes[0].factory = address(aeroPairFactory);
        routes[1].from = _USDC_ADDRESS;
        routes[1].to = _WETH_ADDRESS;
        routes[1].stable = false;
        routes[1].factory = address(aeroPairFactory);
        leverageData.swapData.call = abi.encodeWithSelector(
            IVeloRouter.swapExactTokensForTokens.selector,
            amountForLeverage,
            0,
            routes,
            address(positionManager),
            type(uint256).max
        );
        leverageData.swapData.slippage = 2e18;
        leverageData.auxData = abi.encode(0);

        positionManager.leverage(leverageData, 0.05e18); // 5% slippage

        AccountSnapshot memory borrowableCDAISnapshot = borrowableCDAI.getSnapshot(user);
        assertEq(borrowableCDAI.balanceOf(user), 0);
        assertEq(borrowableCDAISnapshot.debtBalance, 100 ether + amountForLeverage);

        AccountSnapshot memory strategyCTokenWETHUSDCSnapshot = strategyCTokenWETHUSDC.getSnapshot(user);
        assertGt(strategyCTokenWETHUSDC.balanceOf(user), 0.00013 ether);
        assertEq(strategyCTokenWETHUSDCSnapshot.collateralPosted, 0 ether);

        vm.stopPrank();
    }

    function testDepositAndLeverage() public {
        vm.startPrank(user);

        deal(_AERODROME_WETH_USDC, user, 0.0001 ether);
        IERC20(_AERODROME_WETH_USDC).approve(
            address(positionManager),
            0.0001 ether
        );

        // allow delegation for postCollateral
        strategyCTokenWETHUSDC.setDelegateApproval(address(positionManager), true);

        // Try leverage with 50% of max.
        uint256 amountForLeverage = 1.204e22;

        AerodromePositionManager.LeverageStruct memory leverageData;
        leverageData.debtToken = IBorrowableCToken(address(borrowableCDAI));
        leverageData.borrowAssets = amountForLeverage;
        leverageData.collateralToken = ICToken(address(strategyCTokenWETHUSDC));
        leverageData.swapData.inputToken = _DAI_ADDRESS;
        leverageData.swapData.inputAmount = amountForLeverage;
        leverageData.swapData.outputToken = _WETH_ADDRESS;
        leverageData.swapData.target = address(aeroRouter);
        IVeloRouter.Route[] memory routes = new IVeloRouter.Route[](2);
        routes[0].from = _DAI_ADDRESS;
        routes[0].to = _USDC_ADDRESS;
        routes[0].stable = true;
        routes[0].factory = address(aeroPairFactory);
        routes[1].from = _USDC_ADDRESS;
        routes[1].to = _WETH_ADDRESS;
        routes[1].stable = false;
        routes[1].factory = address(aeroPairFactory);
        leverageData.swapData.call = abi.encodeWithSelector(
            IVeloRouter.swapExactTokensForTokens.selector,
            amountForLeverage,
            0,
            routes,
            address(positionManager),
            type(uint256).max
        );
        leverageData.swapData.slippage = 2e18;
        leverageData.auxData = abi.encode(0);

        positionManager.depositAndLeverage(
            0.0001 ether,
            leverageData,
            0.05e18
        ); // 5% slippage

        AccountSnapshot memory borrowableCDAISnapshot = borrowableCDAI.getSnapshot(user);
        assertEq(borrowableCDAI.balanceOf(user), 0);
        assertEq(borrowableCDAISnapshot.debtBalance, amountForLeverage);

        AccountSnapshot memory strategyCTokenWETHUSDCSnapshot = strategyCTokenWETHUSDC.getSnapshot(user);
        assertGt(strategyCTokenWETHUSDC.balanceOf(user), 0.00013 ether);
        assertEq(strategyCTokenWETHUSDCSnapshot.collateralPosted, 0 ether);

        vm.stopPrank();
    }

    function testDepositAndLeverageMaxWithExistingPosition() public {
        vm.startPrank(user);

        // deposit and borrow
        deal(_AERODROME_WETH_USDC, user, 0.0001 ether);
        IERC20(_AERODROME_WETH_USDC).approve(address(strategyCTokenWETHUSDC), 0.0001 ether);
        assertGt(strategyCTokenWETHUSDC.deposit(0.0001 ether, user), 0);
        strategyCTokenWETHUSDC.postCollateral(0.0001 ether);
        assertEq(strategyCTokenWETHUSDC.balanceOf(user), 0.0001 ether);
        uint256 balanceBeforeBorrow = dai.balanceOf(user);
        borrowableCDAI.borrow(100 ether, user);
        assertEq(balanceBeforeBorrow + 100 ether, dai.balanceOf(user));

        // deposit and leverage
        deal(_AERODROME_WETH_USDC, user, 0.0001 ether);
        IERC20(_AERODROME_WETH_USDC).approve(
            address(positionManager),
            0.0001 ether
        );

        // allow delegation for postCollateral
        strategyCTokenWETHUSDC.setDelegateApproval(address(positionManager), true);

        // try max leverage
        uint256 amountForLeverage = positionManager.maxRemainingLeverageOf(
            user,
            address(borrowableCDAI)
        );

        AerodromePositionManager.LeverageStruct memory leverageData;
        leverageData.debtToken = IBorrowableCToken(address(borrowableCDAI));
        leverageData.borrowAssets = amountForLeverage;
        leverageData.collateralToken = ICToken(address(strategyCTokenWETHUSDC));
        leverageData.swapData.inputToken = _DAI_ADDRESS;
        leverageData.swapData.inputAmount = amountForLeverage;
        leverageData.swapData.outputToken = _WETH_ADDRESS;
        leverageData.swapData.target = address(aeroRouter);
        IVeloRouter.Route[] memory routes = new IVeloRouter.Route[](2);
        routes[0].from = _DAI_ADDRESS;
        routes[0].to = _USDC_ADDRESS;
        routes[0].stable = true;
        routes[0].factory = address(aeroPairFactory);
        routes[1].from = _USDC_ADDRESS;
        routes[1].to = _WETH_ADDRESS;
        routes[1].stable = false;
        routes[1].factory = address(aeroPairFactory);
        leverageData.swapData.call = abi.encodeWithSelector(
            IVeloRouter.swapExactTokensForTokens.selector,
            amountForLeverage,
            0,
            routes,
            address(positionManager),
            type(uint256).max
        );
        leverageData.swapData.slippage = 2e18;
        leverageData.auxData = abi.encode(0);

        positionManager.depositAndLeverage(
            0.0001 ether,
            leverageData,
            0.05e18 // 5% slippage
        );

        AccountSnapshot memory borrowableCDAISnapshot = borrowableCDAI.getSnapshot(user);
        assertEq(borrowableCDAI.balanceOf(user), 0);
        assertEq(borrowableCDAISnapshot.debtBalance, amountForLeverage + 100 ether);

        AccountSnapshot memory strategyCTokenWETHUSDCSnapshot = strategyCTokenWETHUSDC.getSnapshot(user);
        assertGt(strategyCTokenWETHUSDC.balanceOf(user), 0.00042 ether);
        assertEq(strategyCTokenWETHUSDCSnapshot.collateralPosted, 0 ether);

        vm.stopPrank();
    }

    function testDepositAndLeverageHalfOfMaxWithExistingPosition() public {
        vm.startPrank(user);

        // deposit and borrow
        deal(_AERODROME_WETH_USDC, user, 0.0001 ether);
        IERC20(_AERODROME_WETH_USDC).approve(address(strategyCTokenWETHUSDC), 0.0001 ether);
        assertGt(strategyCTokenWETHUSDC.deposit(0.0001 ether, user), 0);
        strategyCTokenWETHUSDC.postCollateral(0.0001 ether);
        assertEq(strategyCTokenWETHUSDC.balanceOf(user), 0.0001 ether);
        uint256 balanceBeforeBorrow = dai.balanceOf(user);
        borrowableCDAI.borrow(100 ether, user);
        assertEq(balanceBeforeBorrow + 100 ether, dai.balanceOf(user));

        // deposit and leverage
        deal(_AERODROME_WETH_USDC, user, 0.0001 ether);
        IERC20(_AERODROME_WETH_USDC).approve(
            address(positionManager),
            0.0001 ether
        );

        // allow delegation for postCollateral
        strategyCTokenWETHUSDC.setDelegateApproval(address(positionManager), true);

        // Try leverage with 50% of max.
        uint256 amountForLeverage = positionManager.maxRemainingLeverageOf(
            user,
            address(borrowableCDAI)
        ) / 2;

        AerodromePositionManager.LeverageStruct memory leverageData;
        leverageData.debtToken = IBorrowableCToken(address(borrowableCDAI));
        leverageData.borrowAssets = amountForLeverage;
        leverageData.collateralToken = ICToken(address(strategyCTokenWETHUSDC));
        leverageData.swapData.inputToken = _DAI_ADDRESS;
        leverageData.swapData.inputAmount = amountForLeverage;
        leverageData.swapData.outputToken = _WETH_ADDRESS;
        leverageData.swapData.target = address(aeroRouter);
        IVeloRouter.Route[] memory routes = new IVeloRouter.Route[](2);
        routes[0].from = _DAI_ADDRESS;
        routes[0].to = _USDC_ADDRESS;
        routes[0].stable = true;
        routes[0].factory = address(aeroPairFactory);
        routes[1].from = _USDC_ADDRESS;
        routes[1].to = _WETH_ADDRESS;
        routes[1].stable = false;
        routes[1].factory = address(aeroPairFactory);
        leverageData.swapData.call = abi.encodeWithSelector(
            IVeloRouter.swapExactTokensForTokens.selector,
            amountForLeverage,
            0,
            routes,
            address(positionManager),
            type(uint256).max
        );
        leverageData.swapData.slippage = 2e18;
        leverageData.auxData = abi.encode(0);

        positionManager.depositAndLeverage(
            0.0001 ether,
            leverageData,
            0.05e18 // 5% slippage
        );

        AccountSnapshot memory borrowableCDAISnapshot = borrowableCDAI.getSnapshot(user);
        assertEq(borrowableCDAI.balanceOf(user), 0);
        assertEq(borrowableCDAISnapshot.debtBalance, amountForLeverage + 100 ether);

        AccountSnapshot memory strategyCTokenWETHUSDCSnapshot = strategyCTokenWETHUSDC.getSnapshot(user);
        assertGt(strategyCTokenWETHUSDC.balanceOf(user), 0.00031 ether);
        assertEq(strategyCTokenWETHUSDCSnapshot.collateralPosted, 0 ether);

        vm.stopPrank();
    }

    function testDeLeverage() public {
        testLeverage();

        // Warp until collateralization cooldown period ends.
        vm.warp(block.timestamp + 20 minutes);
        borrowableCDAI.accrueIfNeeded();

        vm.startPrank(user);

        AerodromePositionManager.DeleverageStruct memory deleverageData;

        AccountSnapshot memory borrowableCDAISnapshotBefore = borrowableCDAI.getSnapshot(user);
        uint256 strategyCTokenWETHUSDCBalanceBefore = strategyCTokenWETHUSDC.balanceOf(user);

        deleverageData.collateralToken = ICToken(address(strategyCTokenWETHUSDC));
        deleverageData.collateralAssets = 0.00003 ether;
        deleverageData.debtToken = IBorrowableCToken(address(borrowableCDAI));

        deleverageData.swapData = new SwapperLib.Swap[](2);
        deleverageData.swapData[0].inputToken = _WETH_ADDRESS;
        deleverageData.swapData[0].inputAmount = 0.6 ether;
        deleverageData.swapData[0].outputToken = _USDC_ADDRESS;
        deleverageData.swapData[0].target = address(aeroRouter);
        deleverageData.swapData[0].slippage = 1e18;
        IVeloRouter.Route[] memory routes = new IVeloRouter.Route[](1);
        routes[0].from = _WETH_ADDRESS;
        routes[0].to = _USDC_ADDRESS;
        routes[0].stable = false;
        routes[0].factory = address(aeroPairFactory);
        deleverageData.swapData[0].call = abi.encodeWithSelector(
            IVeloRouter.swapExactTokensForTokens.selector,
            0.6 ether,
            0,
            routes,
            address(positionManager),
            block.timestamp
        );
        deleverageData.swapData[1].inputToken = _USDC_ADDRESS;
        deleverageData.swapData[1].inputAmount = 3098e6;
        deleverageData.swapData[1].outputToken = _DAI_ADDRESS;
        deleverageData.swapData[1].target = address(aeroRouter);
        deleverageData.swapData[1].slippage = 1e18;
        routes = new IVeloRouter.Route[](1);
        routes[0].from = _USDC_ADDRESS;
        routes[0].to = _DAI_ADDRESS;
        routes[0].stable = true;
        routes[0].factory = address(aeroPairFactory);
        deleverageData.swapData[1].call = abi.encodeWithSelector(
            IVeloRouter.swapExactTokensForTokens.selector,
            3098e6,
            0,
            routes,
            address(positionManager),
            block.timestamp
        );
        deleverageData.repayAmount = 3097e18;

        strategyCTokenWETHUSDC.approve(address(positionManager), type(uint256).max);
        positionManager.deleverage(deleverageData, 0.05e18); // 5% slippage

        AccountSnapshot memory borrowableCDAISnapshot = borrowableCDAI.getSnapshot(user);
        assertEq(borrowableCDAI.balanceOf(user), 0);
        assertEq(
            borrowableCDAISnapshot.debtBalance,
            borrowableCDAISnapshotBefore.debtBalance - deleverageData.repayAmount
        );

        AccountSnapshot memory strategyCTokenWETHUSDCSnapshot = strategyCTokenWETHUSDC.getSnapshot(user);
        assertEq(
            strategyCTokenWETHUSDC.balanceOf(user),
            strategyCTokenWETHUSDCBalanceBefore - deleverageData.collateralAssets
        );
        assertEq(strategyCTokenWETHUSDCSnapshot.collateralPosted, 0 ether);

        vm.stopPrank();
    }

    function testLeverageFor() public {
        vm.startPrank(user);

        deal(_AERODROME_WETH_USDC, user, 0.0001 ether);
        IERC20(_AERODROME_WETH_USDC).approve(address(strategyCTokenWETHUSDC), 0.0001 ether);

        // Mint strategyCTokenWETHUSDC.
        assertGt(strategyCTokenWETHUSDC.deposit(0.0001 ether, user), 0);
        strategyCTokenWETHUSDC.postCollateral(0.0001 ether);
        assertEq(strategyCTokenWETHUSDC.balanceOf(user), 0.0001 ether);

        uint256 balanceBeforeBorrow = dai.balanceOf(user);
        
        // Borrow borrowable cDAI.
        borrowableCDAI.borrow(100 ether, user);
        assertEq(balanceBeforeBorrow + 100 ether, dai.balanceOf(user));

        // Try leverage with 50% of max.
        uint256 amountForLeverage = (positionManager.maxRemainingLeverageOf(
            user,
            address(borrowableCDAI)
        ) * 50) / 100;

        AerodromePositionManager.LeverageStruct memory leverageData;
        leverageData.debtToken = IBorrowableCToken(address(borrowableCDAI));
        leverageData.borrowAssets = amountForLeverage;
        leverageData.collateralToken = ICToken(address(strategyCTokenWETHUSDC));
        leverageData.swapData.inputToken = _DAI_ADDRESS;
        leverageData.swapData.inputAmount = amountForLeverage;
        leverageData.swapData.outputToken = _WETH_ADDRESS;
        leverageData.swapData.target = address(aeroRouter);
        IVeloRouter.Route[] memory routes = new IVeloRouter.Route[](2);
        routes[0].from = _DAI_ADDRESS;
        routes[0].to = _USDC_ADDRESS;
        routes[0].stable = true;
        routes[0].factory = address(aeroPairFactory);
        routes[1].from = _USDC_ADDRESS;
        routes[1].to = _WETH_ADDRESS;
        routes[1].stable = false;
        routes[1].factory = address(aeroPairFactory);
        leverageData.swapData.call = abi.encodeWithSelector(
            IVeloRouter.swapExactTokensForTokens.selector,
            amountForLeverage,
            0,
            routes,
            address(positionManager),
            type(uint256).max
        );
        leverageData.swapData.slippage = 2e18;
        leverageData.auxData = abi.encode(0);

        positionManager.setDelegateApproval(address(user2), true);
        vm.stopPrank();

        vm.prank(user2);
        positionManager.leverageFor(leverageData, user, 0.05e18); // 5% slippage

        AccountSnapshot memory borrowableCDAISnapshot = borrowableCDAI.getSnapshot(user);
        assertEq(borrowableCDAI.balanceOf(user), 0);
        assertEq(borrowableCDAISnapshot.debtBalance, 100 ether + amountForLeverage);

        AccountSnapshot memory strategyCTokenWETHUSDCSnapshot = strategyCTokenWETHUSDC.getSnapshot(user);
        assertGt(strategyCTokenWETHUSDC.balanceOf(user), 0.00013 ether);
        assertEq(strategyCTokenWETHUSDCSnapshot.collateralPosted, 0 ether);
    }

    function testDeLeverageFor() public {
        testLeverage();

        // Warp until collateralization cooldown period ends.
        vm.warp(block.timestamp + 20 minutes);
        borrowableCDAI.accrueIfNeeded();

        vm.startPrank(user);

        AerodromePositionManager.DeleverageStruct memory deleverageData;

        AccountSnapshot memory borrowableCDAISnapshotBefore = borrowableCDAI.getSnapshot(user);
        uint256 strategyCTokenWETHUSDCBalanceBefore = strategyCTokenWETHUSDC.balanceOf(user);

        deleverageData.collateralToken = ICToken(address(strategyCTokenWETHUSDC));
        deleverageData.collateralAssets = 0.00003 ether;
        deleverageData.debtToken = IBorrowableCToken(address(borrowableCDAI));

        deleverageData.swapData = new SwapperLib.Swap[](2);
        deleverageData.swapData[0].inputToken = _WETH_ADDRESS;
        deleverageData.swapData[0].inputAmount = 0.6 ether;
        deleverageData.swapData[0].outputToken = _USDC_ADDRESS;
        deleverageData.swapData[0].target = address(aeroRouter);
        deleverageData.swapData[0].slippage = 1e18;
        IVeloRouter.Route[] memory routes = new IVeloRouter.Route[](1);
        routes[0].from = _WETH_ADDRESS;
        routes[0].to = _USDC_ADDRESS;
        routes[0].stable = false;
        routes[0].factory = address(aeroPairFactory);
        deleverageData.swapData[0].call = abi.encodeWithSelector(
            IVeloRouter.swapExactTokensForTokens.selector,
            0.6 ether,
            0,
            routes,
            address(positionManager),
            block.timestamp
        );
        deleverageData.swapData[1].inputToken = _USDC_ADDRESS;
        deleverageData.swapData[1].inputAmount = 3098e6;
        deleverageData.swapData[1].outputToken = _DAI_ADDRESS;
        deleverageData.swapData[1].target = address(aeroRouter);
        deleverageData.swapData[1].slippage = 1e18;
        routes = new IVeloRouter.Route[](1);
        routes[0].from = _USDC_ADDRESS;
        routes[0].to = _DAI_ADDRESS;
        routes[0].stable = true;
        routes[0].factory = address(aeroPairFactory);
        deleverageData.swapData[1].call = abi.encodeWithSelector(
            IVeloRouter.swapExactTokensForTokens.selector,
            3098e6,
            0,
            routes,
            address(positionManager),
            block.timestamp
        );
        deleverageData.repayAmount = 3097e18;

        strategyCTokenWETHUSDC.approve(address(positionManager), type(uint256).max);
        positionManager.setDelegateApproval(address(user2), true);
        vm.stopPrank();

        vm.prank(user2);
        positionManager.deleverageFor(deleverageData, user, 0.05e18); // 5% slippage

        AccountSnapshot memory borrowableCDAISnapshot = borrowableCDAI.getSnapshot(user);
        assertEq(borrowableCDAI.balanceOf(user), 0);
        assertEq(
            borrowableCDAISnapshot.debtBalance,
            borrowableCDAISnapshotBefore.debtBalance - deleverageData.repayAmount
        );

        AccountSnapshot memory strategyCTokenWETHUSDCSnapshot = strategyCTokenWETHUSDC.getSnapshot(user);
        assertEq(
            strategyCTokenWETHUSDC.balanceOf(user),
            strategyCTokenWETHUSDCBalanceBefore - deleverageData.collateralAssets
        );
        assertEq(strategyCTokenWETHUSDCSnapshot.collateralPosted, 0);

        vm.stopPrank();
    }

    function _provideEnoughLiquidityForLeverage() internal {
        address liquidityProvider = makeAddr("liquidityProvider");

        deal(_AERODROME_WETH_USDC, liquidityProvider, 1 ether);
        _prepareDAI(liquidityProvider, 20000000e18);

        vm.startPrank(liquidityProvider);

        // Deposit borrowable cDAI.
        dai.approve(address(borrowableCDAI), 20000000 ether);
        borrowableCDAI.deposit(20000000 ether, liquidityProvider);

        // Deposit strategyCTokenWETHUSDC.
        IERC20(_AERODROME_WETH_USDC).approve(address(strategyCTokenWETHUSDC), 1 ether);
        strategyCTokenWETHUSDC.deposit(1 ether, liquidityProvider);

        vm.stopPrank();
    }
}
