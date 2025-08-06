// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";
import { VelodromeVolatileCToken } from "contracts/market/token/VelodromeVolatileCToken.sol";
import { VelodromeVolatileLPAdaptor } from "contracts/oracles/adaptors/velodrome/VelodromeVolatileLPAdaptor.sol";
import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { VelodromePositionManager } from "contracts/market/position-management/VelodromePositionManager.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { ICToken, AccountSnapshot } from "contracts/interfaces/ICToken.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IVeloGauge } from "contracts/interfaces/external/velodrome/IVeloGauge.sol";
import { IVeloPairFactory } from "contracts/interfaces/external/velodrome/IVeloPairFactory.sol";
import { IVeloRouter } from "contracts/interfaces/external/velodrome/IVeloRouter.sol";
import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

contract TestVelodromeVolatilePositionManager is TestBaseMarketIsolated {
    address internal _VELODROME_WETH_USDC =
        0x0493Bf8b6DBB159Ce2Db2E0E8403E753Abd1235b;
    IVeloGauge public gauge =
        IVeloGauge(0xE7630c9560C59CCBf5EEd8f33dd0ccA2E67a3981);
    IVeloPairFactory public veloPairFactory =
        IVeloPairFactory(0xF1046053aa5682b4F9a81b5481394DA16BE5FF5a);
    IVeloRouter public veloRouter =
        IVeloRouter(0xa062aE8A9c5e11aaA026fc2670B0D65cCc8B2858);

    VelodromeVolatileCToken public strategyCTokenWETHUSDC;
    VelodromeVolatileLPAdaptor public adaptor;
    VelodromePositionManager public positionManager;

    address public owner;
    address public user;

    receive() external payable {}

    fallback() external payable {}

    function setUp() public override {
        _fork("ETH_NODE_URI_OPTIMISM", 109095500);

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
        adaptor.addAsset(_VELODROME_WETH_USDC);
        oracleManager.addApprovedAdaptor(address(adaptor));
        oracleManager.addAssetPriceFeed(
            _VELODROME_WETH_USDC,
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
            strategyCTokenWETHUSDC = new VelodromeVolatileCToken(
                ICentralRegistry(address(centralRegistry)),
                IERC20(_VELODROME_WETH_USDC),
                address(marketManagerIsolated),
                gauge,
                veloPairFactory,
                veloRouter,
                1 days
            );
            // Add cToken support on Oracle Manager.
            oracleManager.addCTokenSupport(address(strategyCTokenWETHUSDC));

            deal(_VELODROME_WETH_USDC, owner, 1 ether);
            IERC20(_VELODROME_WETH_USDC).approve(address(strategyCTokenWETHUSDC), 1 ether);




        }
        marketManagerIsolated.listTokens(address(strategyCTokenWETHUSDC), address(borrowableCDAI));

         _setCTokenConfigBasic(address(strategyCTokenWETHUSDC), 100_000e18, 0);
         _setCTokenConfigBasic(address(borrowableCDAI), 100_000e18, 100_000e18);

        positionManager = new VelodromePositionManager(
            ICentralRegistry(address(centralRegistry)),
            address(marketManagerIsolated),
            _WETH_ADDRESS,
            address(veloRouter),
            address(veloPairFactory)
        );
        marketManagerIsolated.addPositionManager(address(positionManager));

        _provideEnoughLiquidityForLeverage();

        centralRegistry.setExternalCalldataChecker(
            _UNISWAP_V2_ROUTER,
            address(new MockCalldataChecker(_UNISWAP_V2_ROUTER))
        );

        centralRegistry.setExternalCalldataChecker(
            address(veloRouter),
            address(new MockCalldataChecker(address(veloRouter)))
        );

        centralRegistry.setSlippageLimit(6000);
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

        deal(_VELODROME_WETH_USDC, user, 0.0001 ether);
        IERC20(_VELODROME_WETH_USDC).approve(address(strategyCTokenWETHUSDC), 0.0001 ether);

        // Mint strategyCTokenWETHUSDC.
        assertGt(strategyCTokenWETHUSDC.deposit(0.0001 ether, user), 0);
        strategyCTokenWETHUSDC.postCollateral(0.0001 ether);
        assertEq(strategyCTokenWETHUSDC.balanceOf(user), 0.0001 ether);

        uint256 balanceBeforeBorrow = dai.balanceOf(user);
        
        // Borrow borrowable cDAI.
        borrowableCDAI.borrow(100 ether, user);
        assertEq(balanceBeforeBorrow + 100 ether, dai.balanceOf(user));

        // Try leveraging with 50% of limit.
        uint256 amountForLeverage = positionManager.maxRemainingLeverageOf(
            user,
            address(borrowableCDAI)
        ) / 2;

        VelodromePositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCDAI));
        leverageAction.borrowAssets = amountForLeverage;
        leverageAction.cToken = ICToken(address(strategyCTokenWETHUSDC));
        leverageAction.swapAction.inputToken = _DAI_ADDRESS;
        leverageAction.swapAction.inputAmount = amountForLeverage;
        leverageAction.swapAction.outputToken = _WETH_ADDRESS;
        leverageAction.swapAction.target = address(veloRouter);
        IVeloRouter.Route[] memory routes = new IVeloRouter.Route[](2);
        routes[0].from = _DAI_ADDRESS;
        routes[0].to = _USDC_ADDRESS;
        routes[0].stable = true;
        routes[0].factory = address(veloPairFactory);
        routes[1].from = _USDC_ADDRESS;
        routes[1].to = _WETH_ADDRESS;
        routes[1].stable = false;
        routes[1].factory = address(veloPairFactory);
        leverageAction.swapAction.call = abi.encodeWithSelector(
            IVeloRouter.swapExactTokensForTokens.selector,
            amountForLeverage,
            0,
            routes,
            address(positionManager),
            type(uint256).max
        );
        leverageAction.swapAction.slippage = 2e18;
        leverageAction.auxData = abi.encode(0);

        positionManager.leverage(leverageAction, 0.05e18); // 5% slippage

        AccountSnapshot memory borrowableCDAISnapshot = borrowableCDAI.getSnapshot(user);
        assertEq(borrowableCDAI.balanceOf(user), 0);
        assertEq(borrowableCDAISnapshot.debtBalance, 100 ether + amountForLeverage);

        AccountSnapshot memory strategyCTokenWETHUSDCSnapshot = strategyCTokenWETHUSDC.getSnapshot(user);
        assertGt(strategyCTokenWETHUSDC.balanceOf(user), 0.000245 ether);
        assertEq(strategyCTokenWETHUSDCSnapshot.debtBalance, 0 ether);

        vm.stopPrank();
    }

    function testLeverageWithFeeEnabled() public {
        // 1% leverage fee
        centralRegistry.setProtocolLeverageFee(100);

        vm.startPrank(user);

        deal(_VELODROME_WETH_USDC, user, 0.0001 ether);
        IERC20(_VELODROME_WETH_USDC).approve(address(strategyCTokenWETHUSDC), 0.0001 ether);

        // Mint strategyCTokenWETHUSDC.
        assertGt(strategyCTokenWETHUSDC.deposit(0.0001 ether, user), 0);
        strategyCTokenWETHUSDC.postCollateral(0.0001 ether);
        assertEq(strategyCTokenWETHUSDC.balanceOf(user), 0.0001 ether);

        uint256 balanceBeforeBorrow = dai.balanceOf(user);
        
        // Borrow borrowable cDAI.
        borrowableCDAI.borrow(100 ether, user);
        assertEq(balanceBeforeBorrow + 100 ether, dai.balanceOf(user));

        // Try leveraging with 50% of limit.
        uint256 amountForLeverage = positionManager.maxRemainingLeverageOf(
            user,
            address(borrowableCDAI)
        ) / 2;

        uint256 protocolBalanceBeforeLeverage = dai.balanceOf(
            centralRegistry.daoAddress()
        );
        uint256 leverageFee = FixedPointMathLib.mulDivUp(
            amountForLeverage,
            centralRegistry.protocolLeverageFee(),
            1e18
        );

        VelodromePositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCDAI));
        leverageAction.borrowAssets = amountForLeverage;
        leverageAction.cToken = ICToken(address(strategyCTokenWETHUSDC));
        leverageAction.swapAction.inputToken = _DAI_ADDRESS;
        leverageAction.swapAction.inputAmount = amountForLeverage - leverageFee;
        leverageAction.swapAction.outputToken = _WETH_ADDRESS;
        leverageAction.swapAction.target = address(veloRouter);
        IVeloRouter.Route[] memory routes = new IVeloRouter.Route[](2);
        routes[0].from = _DAI_ADDRESS;
        routes[0].to = _USDC_ADDRESS;
        routes[0].stable = true;
        routes[0].factory = address(veloPairFactory);
        routes[1].from = _USDC_ADDRESS;
        routes[1].to = _WETH_ADDRESS;
        routes[1].stable = false;
        routes[1].factory = address(veloPairFactory);
        leverageAction.swapAction.call = abi.encodeWithSelector(
            IVeloRouter.swapExactTokensForTokens.selector,
            amountForLeverage - leverageFee,
            0,
            routes,
            address(positionManager),
            type(uint256).max
        );
        leverageAction.swapAction.slippage = 2e18;
        leverageAction.auxData = abi.encode(0);

        positionManager.leverage(leverageAction, 0.05e18); // 5% slippage

        AccountSnapshot memory borrowableCDAISnapshot = borrowableCDAI.getSnapshot(user);
        assertEq(borrowableCDAI.balanceOf(user), 0);
        assertEq(borrowableCDAISnapshot.debtBalance, 100 ether + amountForLeverage);

        AccountSnapshot memory strategyCTokenWETHUSDCSnapshot = strategyCTokenWETHUSDC.getSnapshot(user);
        assertGt(strategyCTokenWETHUSDC.balanceOf(user), 0.00024 ether);
        assertEq(strategyCTokenWETHUSDCSnapshot.debtBalance, 0 ether);

        uint256 protocolBalanceAfterLeverage = dai.balanceOf(
            centralRegistry.daoAddress()
        );
        assertEq(
            protocolBalanceAfterLeverage,
            protocolBalanceBeforeLeverage + leverageFee
        );

        vm.stopPrank();
    }

    function testDeLeverage() public {
        testLeverage();

        // Warp until collateralization cooldown period ends.
        vm.warp(block.timestamp + 20 minutes);
        borrowableCDAI.accrueIfNeeded();

        vm.startPrank(user);

        VelodromePositionManager.DeleverageAction memory deleverageAction;

        AccountSnapshot memory borrowableCDAIBeforeSnapshot = borrowableCDAI.getSnapshot(user);
        uint256 strategyCTokenWETHUSDCBalanceBefore = strategyCTokenWETHUSDC.collateralPosted(user);

        deleverageAction.cToken = ICToken(address(strategyCTokenWETHUSDC));
        deleverageAction.collateralAssets = 0.000033 ether;
        deleverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCDAI));

        uint256 wethAmount = 0.7488 ether;
        deleverageAction.swapActions = new SwapperLib.Swap[](2);
        deleverageAction.swapActions[0].inputToken = _WETH_ADDRESS;
        deleverageAction.swapActions[0].inputAmount = wethAmount;
        deleverageAction.swapActions[0].outputToken = _USDC_ADDRESS;
        deleverageAction.swapActions[0].target = address(veloRouter);
        deleverageAction.swapActions[0].slippage = 1e18;
        IVeloRouter.Route[] memory routes = new IVeloRouter.Route[](1);
        routes[0].from = _WETH_ADDRESS;
        routes[0].to = _USDC_ADDRESS;
        routes[0].stable = false;
        routes[0].factory = address(veloPairFactory);
        deleverageAction.swapActions[0].call = abi.encodeWithSelector(
            IVeloRouter.swapExactTokensForTokens.selector,
            wethAmount,
            0,
            routes,
            address(positionManager),
            block.timestamp
        );

        deleverageAction.swapActions[1].inputToken = _USDC_ADDRESS;
        deleverageAction.swapActions[1].inputAmount = 2424e6;
        deleverageAction.swapActions[1].outputToken = _DAI_ADDRESS;
        deleverageAction.swapActions[1].target = address(veloRouter);
        deleverageAction.swapActions[1].slippage = 1e18;
        routes = new IVeloRouter.Route[](1);
        routes[0].from = _USDC_ADDRESS;
        routes[0].to = _DAI_ADDRESS;
        routes[0].stable = true;
        routes[0].factory = address(veloPairFactory);
        deleverageAction.swapActions[1].call = abi.encodeWithSelector(
            IVeloRouter.swapExactTokensForTokens.selector,
            2424e6,
            0,
            routes,
            address(positionManager),
            block.timestamp
        );
        deleverageAction.repayAssets = 2420e18;

        strategyCTokenWETHUSDC.approve(address(positionManager), type(uint256).max);
        positionManager.deleverage(deleverageAction, 0.08e18); // 8% slippage

        AccountSnapshot memory borrowableCDAISnapshot = borrowableCDAI.getSnapshot(user);
        assertEq(borrowableCDAI.balanceOf(user), 0);
        assertEq(
            borrowableCDAISnapshot.debtBalance,
            borrowableCDAIBeforeSnapshot.debtBalance - deleverageAction.repayAssets
        );

        AccountSnapshot memory strategyCTokenWETHUSDCSnapshot = strategyCTokenWETHUSDC.getSnapshot(user);
        assertEq(
            strategyCTokenWETHUSDC.balanceOf(user),
            strategyCTokenWETHUSDCBalanceBefore - deleverageAction.collateralAssets
        );
        assertEq(strategyCTokenWETHUSDCSnapshot.debtBalance, 0);

        vm.stopPrank();
    }

    function testDeLeverageWithFeeEnabled() public {
        testLeverage();

        // Warp until collateralization cooldown period ends.
        vm.warp(block.timestamp + 20 minutes);
        borrowableCDAI.accrueIfNeeded();

        // 1% leverage fee
        centralRegistry.setProtocolLeverageFee(100);

        vm.startPrank(user);

        VelodromePositionManager.DeleverageAction memory deleverageAction;

        AccountSnapshot memory borrowableCDAIBeforeSnapshot = borrowableCDAI.getSnapshot(user);
        uint256 strategyCTokenWETHUSDCBalanceBefore = strategyCTokenWETHUSDC.collateralPosted(user);

        uint256 collateralAmount = 0.000033 ether;
        uint256 leverageFee = collateralAmount / 100;
        uint256 protocolBalanceBeforeDeLeverage = IERC20(_VELODROME_WETH_USDC)
            .balanceOf(centralRegistry.daoAddress());

        deleverageAction.cToken = ICToken(address(strategyCTokenWETHUSDC));
        deleverageAction.collateralAssets = collateralAmount;
        deleverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCDAI));

        uint256 wethAmount = 0.7413 ether;
        deleverageAction.swapActions = new SwapperLib.Swap[](2);
        deleverageAction.swapActions[0].inputToken = _WETH_ADDRESS;
        deleverageAction.swapActions[0].inputAmount = wethAmount;
        deleverageAction.swapActions[0].outputToken = _USDC_ADDRESS;
        deleverageAction.swapActions[0].target = address(veloRouter);
        deleverageAction.swapActions[0].slippage = 1e18;
        IVeloRouter.Route[] memory routes = new IVeloRouter.Route[](1);
        routes[0].from = _WETH_ADDRESS;
        routes[0].to = _USDC_ADDRESS;
        routes[0].stable = false;
        routes[0].factory = address(veloPairFactory);
        deleverageAction.swapActions[0].call = abi.encodeWithSelector(
            IVeloRouter.swapExactTokensForTokens.selector,
            wethAmount,
            0,
            routes,
            address(positionManager),
            block.timestamp
        );

        deleverageAction.swapActions[1].inputToken = _USDC_ADDRESS;
        deleverageAction.swapActions[1].inputAmount = 2400e6;
        deleverageAction.swapActions[1].outputToken = _DAI_ADDRESS;
        deleverageAction.swapActions[1].target = address(veloRouter);
        deleverageAction.swapActions[1].slippage = 1e18;
        routes = new IVeloRouter.Route[](1);
        routes[0].from = _USDC_ADDRESS;
        routes[0].to = _DAI_ADDRESS;
        routes[0].stable = true;
        routes[0].factory = address(veloPairFactory);
        deleverageAction.swapActions[1].call = abi.encodeWithSelector(
            IVeloRouter.swapExactTokensForTokens.selector,
            2400e6,
            0,
            routes,
            address(positionManager),
            block.timestamp
        );
        deleverageAction.repayAssets = 2402e6;

        strategyCTokenWETHUSDC.approve(address(positionManager), type(uint256).max);
        positionManager.deleverage(deleverageAction, 0.5e18); // 5.2% slippage

        AccountSnapshot memory borrowableCDAISnapshot = borrowableCDAI.getSnapshot(user);
        assertEq(borrowableCDAI.balanceOf(user), 0);
        assertEq(
            borrowableCDAISnapshot.debtBalance,
            borrowableCDAIBeforeSnapshot.debtBalance - deleverageAction.repayAssets
        );

        AccountSnapshot memory strategyCTokenWETHUSDCSnapshot = strategyCTokenWETHUSDC.getSnapshot(user);
        assertEq(
            strategyCTokenWETHUSDC.balanceOf(user),
            strategyCTokenWETHUSDCBalanceBefore - deleverageAction.collateralAssets
        );
        assertEq(strategyCTokenWETHUSDCSnapshot.debtBalance, 0);

        uint256 protocolBalanceAfterDeLeverage = IERC20(_VELODROME_WETH_USDC)
            .balanceOf(centralRegistry.daoAddress());
        assertEq(
            protocolBalanceAfterDeLeverage,
            protocolBalanceBeforeDeLeverage + leverageFee
        );

        vm.stopPrank();
    }

    function testLeverageFor() public {
        vm.startPrank(user);

        deal(_VELODROME_WETH_USDC, user, 0.0001 ether);
        IERC20(_VELODROME_WETH_USDC).approve(address(strategyCTokenWETHUSDC), 0.0001 ether);

        // Mint strategyCTokenWETHUSDC.
        assertGt(strategyCTokenWETHUSDC.deposit(0.0001 ether, user), 0);
        strategyCTokenWETHUSDC.postCollateral(0.0001 ether);
        assertEq(strategyCTokenWETHUSDC.balanceOf(user), 0.0001 ether);

        uint256 balanceBeforeBorrow = dai.balanceOf(user);

        // Borrow borrowable cDAI.
        borrowableCDAI.borrow(100 ether, user);
        assertEq(balanceBeforeBorrow + 100 ether, dai.balanceOf(user));

        // Try leveraging with 50% of limit.
        uint256 amountForLeverage = positionManager.maxRemainingLeverageOf(
            user,
            address(borrowableCDAI)
        ) / 2;

        VelodromePositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCDAI));
        leverageAction.borrowAssets = amountForLeverage;
        leverageAction.cToken = ICToken(address(strategyCTokenWETHUSDC));
        leverageAction.swapAction.inputToken = _DAI_ADDRESS;
        leverageAction.swapAction.inputAmount = amountForLeverage;
        leverageAction.swapAction.outputToken = _WETH_ADDRESS;
        leverageAction.swapAction.target = address(veloRouter);
        IVeloRouter.Route[] memory routes = new IVeloRouter.Route[](2);
        routes[0].from = _DAI_ADDRESS;
        routes[0].to = _USDC_ADDRESS;
        routes[0].stable = true;
        routes[0].factory = address(veloPairFactory);
        routes[1].from = _USDC_ADDRESS;
        routes[1].to = _WETH_ADDRESS;
        routes[1].stable = false;
        routes[1].factory = address(veloPairFactory);
        leverageAction.swapAction.call = abi.encodeWithSelector(
            IVeloRouter.swapExactTokensForTokens.selector,
            amountForLeverage,
            0,
            routes,
            address(positionManager),
            type(uint256).max
        );
        leverageAction.swapAction.slippage = 2e18;
        leverageAction.auxData = abi.encode(0);

        positionManager.setDelegateApproval(address(user2), true);
        vm.stopPrank();

        vm.prank(user2);
        positionManager.leverageFor(leverageAction, user, 0.05e18); // 5% slippage

        AccountSnapshot memory borrowableCDAISnapshot = borrowableCDAI.getSnapshot(user);
        assertEq(borrowableCDAI.balanceOf(user), 0);
        assertEq(borrowableCDAISnapshot.debtBalance, 100 ether + amountForLeverage);

        AccountSnapshot memory strategyCTokenWETHUSDCSnapshot = strategyCTokenWETHUSDC.getSnapshot(user);
        assertGt(strategyCTokenWETHUSDC.balanceOf(user), 0.00013 ether);
        assertEq(strategyCTokenWETHUSDCSnapshot.debtBalance, 0 ether);
    }

    function testDeLeverageFor() public {
        testLeverage();

        // Warp until collateralization cooldown period ends.
        vm.warp(block.timestamp + 20 minutes);
        borrowableCDAI.accrueIfNeeded();

        vm.startPrank(user);

        VelodromePositionManager.DeleverageAction memory deleverageAction;

        AccountSnapshot memory borrowableCDAIBeforeSnapshot = borrowableCDAI.getSnapshot(user);
        uint256 strategyCTokenWETHUSDCBalanceBefore = strategyCTokenWETHUSDC.collateralPosted(user);

        deleverageAction.cToken = ICToken(address(strategyCTokenWETHUSDC));
        deleverageAction.collateralAssets = 0.000033 ether;
        deleverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCDAI));

        uint256 wethAmount = 0.7488 ether;
        deleverageAction.swapActions = new SwapperLib.Swap[](2);
        deleverageAction.swapActions[0].inputToken = _WETH_ADDRESS;
        deleverageAction.swapActions[0].inputAmount = wethAmount;
        deleverageAction.swapActions[0].outputToken = _USDC_ADDRESS;
        deleverageAction.swapActions[0].target = address(veloRouter);
        deleverageAction.swapActions[0].slippage = 1e18;
        IVeloRouter.Route[] memory routes = new IVeloRouter.Route[](1);
        routes[0].from = _WETH_ADDRESS;
        routes[0].to = _USDC_ADDRESS;
        routes[0].stable = false;
        routes[0].factory = address(veloPairFactory);
        deleverageAction.swapActions[0].call = abi.encodeWithSelector(
            IVeloRouter.swapExactTokensForTokens.selector,
            wethAmount,
            0,
            routes,
            address(positionManager),
            block.timestamp
        );
        deleverageAction.swapActions[1].inputToken = _USDC_ADDRESS;
        deleverageAction.swapActions[1].inputAmount = 2424e6;
        deleverageAction.swapActions[1].outputToken = _DAI_ADDRESS;
        deleverageAction.swapActions[1].target = address(veloRouter);
        deleverageAction.swapActions[1].slippage = 1e18;
        routes = new IVeloRouter.Route[](1);
        routes[0].from = _USDC_ADDRESS;
        routes[0].to = _DAI_ADDRESS;
        routes[0].stable = true;
        routes[0].factory = address(veloPairFactory);
        deleverageAction.swapActions[1].call = abi.encodeWithSelector(
            IVeloRouter.swapExactTokensForTokens.selector,
            2424e6,
            0,
            routes,
            address(positionManager),
            block.timestamp
        );
        deleverageAction.repayAssets = 2420e18;

        strategyCTokenWETHUSDC.approve(address(positionManager), type(uint256).max);
        positionManager.setDelegateApproval(address(user2), true);
        vm.stopPrank();

        vm.prank(user2);
        positionManager.deleverageFor(deleverageAction, user, 0.08e18); // 8% slippage

        AccountSnapshot memory borrowableCDAISnapshot = borrowableCDAI.getSnapshot(user);
        assertEq(borrowableCDAI.balanceOf(user), 0);
        assertEq(
            borrowableCDAISnapshot.debtBalance,
            borrowableCDAIBeforeSnapshot.debtBalance - deleverageAction.repayAssets
        );

        AccountSnapshot memory strategyCTokenWETHUSDCSnapshot = strategyCTokenWETHUSDC.getSnapshot(user);
        assertEq(
            strategyCTokenWETHUSDC.balanceOf(user),
            strategyCTokenWETHUSDCBalanceBefore - deleverageAction.collateralAssets
        );
        assertEq(strategyCTokenWETHUSDCSnapshot.debtBalance, 0);

        vm.stopPrank();
    }

    function _provideEnoughLiquidityForLeverage() internal {
        address liquidityProvider = makeAddr("liquidityProvider");

        deal(_VELODROME_WETH_USDC, liquidityProvider, 1 ether);
        _prepareDAI(liquidityProvider, 20000000e18);

        vm.startPrank(liquidityProvider);

        // Deposit borrowable cDAI.
        dai.approve(address(borrowableCDAI), 20000000 ether);
        borrowableCDAI.deposit(20000000 ether, liquidityProvider);

        // Deposit strategyCTokenWETHUSDC.
        IERC20(_VELODROME_WETH_USDC).approve(address(strategyCTokenWETHUSDC), 1 ether);
        strategyCTokenWETHUSDC.deposit(1 ether, liquidityProvider);

        vm.stopPrank();
    }
}
