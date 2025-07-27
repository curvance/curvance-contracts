// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";
import { VelodromeStableCToken } from "contracts/market/token/VelodromeStableCToken.sol";
import { VelodromeStableLPAdaptor } from "contracts/oracles/adaptors/velodrome/VelodromeStableLPAdaptor.sol";
import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { VelodromePositionManager } from "contracts/market/position-management/VelodromePositionManager.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { ICToken, AccountSnapshot } from "contracts/interfaces/ICToken.sol";
import { IVeloGauge } from "contracts/interfaces/external/velodrome/IVeloGauge.sol";
import { IVeloRouter } from "contracts/interfaces/external/velodrome/IVeloRouter.sol";
import { IVeloPairFactory } from "contracts/interfaces/external/velodrome/IVeloPairFactory.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

contract TestVelodromeStablePositionManager is TestBaseMarketIsolated {
    address internal _VELODROME_DAI_USDC =
        0x19715771E30c93915A5bbDa134d782b81A820076;
    IVeloGauge public gauge =
        IVeloGauge(0x6998089F6bDd9c74C7D8d01b99d7e379ccCcb02D);
    IVeloPairFactory public veloPairFactory =
        IVeloPairFactory(0xF1046053aa5682b4F9a81b5481394DA16BE5FF5a);
    IVeloRouter public veloRouter =
        IVeloRouter(0xa062aE8A9c5e11aaA026fc2670B0D65cCc8B2858);

    VelodromeStableCToken public strategyCTokenUSDCDAI;
    VelodromeStableLPAdaptor public adaptor;
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

        adaptor = new VelodromeStableLPAdaptor(
            ICentralRegistry(address(centralRegistry))
        );
        adaptor.addAsset(_VELODROME_DAI_USDC);
        oracleManager.addApprovedAdaptor(address(adaptor));
        oracleManager.addAssetPriceFeed(_VELODROME_DAI_USDC, address(adaptor));

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

        // Setup strategyCTokenUSDCDAI.
        {
            strategyCTokenUSDCDAI = new VelodromeStableCToken(
                ICentralRegistry(address(centralRegistry)),
                IERC20(_VELODROME_DAI_USDC),
                address(marketManagerIsolated),
                gauge,
                veloPairFactory,
                veloRouter,
                1 days
            );
            // Add cToken support on Oracle Manager.
            oracleManager.addCTokenSupport(address(strategyCTokenUSDCDAI));

            deal(_VELODROME_DAI_USDC, owner, 1 ether);
            IERC20(_VELODROME_DAI_USDC).approve(address(strategyCTokenUSDCDAI), 1 ether);
        }

        positionManager = new VelodromePositionManager(
            ICentralRegistry(address(centralRegistry)),
            address(marketManagerIsolated),
            _WETH_ADDRESS,
            address(veloRouter),
            address(veloPairFactory)
        );

        marketManagerIsolated.listTokens(address(strategyCTokenUSDCDAI), address(borrowableCDAI));

         _setCTokenConfigBasic(address(strategyCTokenUSDCDAI), 100_000e18, 0);
         _setCTokenConfigBasic(address(borrowableCDAI), 100_000e18, 100_000e18);

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

        deal(_VELODROME_DAI_USDC, user, 0.0001 ether);
        IERC20(_VELODROME_DAI_USDC).approve(address(strategyCTokenUSDCDAI), 0.0001 ether);

        // Mint strategyCTokenUSDCDAI.
        assertGt(strategyCTokenUSDCDAI.deposit(0.0001 ether, user), 0);
        strategyCTokenUSDCDAI.postCollateral(0.0001 ether);
        assertEq(strategyCTokenUSDCDAI.balanceOf(user), 0.0001 ether);

        uint256 balanceBeforeBorrow = dai.balanceOf(user);
        
        // Borrow borrowable cDAI.
        borrowableCDAI.borrow(100 ether, user);
        assertEq(balanceBeforeBorrow + 100 ether, dai.balanceOf(user));

        // Try leverage with 50% of max.
        uint256 amountForLeverage = (positionManager.maxRemainingLeverageOf(
            user,
            address(borrowableCDAI)
        ) * 50) / 100;

        VelodromePositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCDAI));
        leverageAction.borrowAssets = amountForLeverage;
        leverageAction.cToken = ICToken(address(strategyCTokenUSDCDAI));
        leverageAction.swapAction.inputToken = _DAI_ADDRESS;
        leverageAction.swapAction.inputAmount = amountForLeverage;
        leverageAction.swapAction.outputToken = _USDC_ADDRESS;
        leverageAction.swapAction.target = address(veloRouter);
        leverageAction.swapAction.slippage = 50e16;
        IVeloRouter.Route[] memory routes = new IVeloRouter.Route[](1);
        routes[0].from = _DAI_ADDRESS;
        routes[0].to = _USDC_ADDRESS;
        routes[0].stable = true;
        routes[0].factory = address(veloPairFactory);
        leverageAction.swapAction.call = abi.encodeWithSelector(
            IVeloRouter.swapExactTokensForTokens.selector,
            amountForLeverage,
            0,
            routes,
            address(positionManager),
            type(uint256).max
        );
        leverageAction.auxData = abi.encode(0);

        positionManager.leverage(leverageAction, 0.05e18); // 5% slippage

        AccountSnapshot memory borrowableCDAISnapshot = borrowableCDAI.getSnapshot(user);
        assertEq(borrowableCDAI.balanceOf(user), 0);
        assertEq(borrowableCDAISnapshot.debtBalance, 100 ether + amountForLeverage);

        AccountSnapshot memory strategyCTokenUSDCDAISnapshot = strategyCTokenUSDCDAI.getSnapshot(user);
        assertGt(strategyCTokenUSDCDAI.balanceOf(user), 0.00013 ether);
        assertEq(strategyCTokenUSDCDAISnapshot.debtBalance, 0 ether);

        vm.stopPrank();
    }

    function testLeverageWithFeeEnabled() public {
        // 1% leverage fee
        centralRegistry.setProtocolLeverageFee(100);

        vm.startPrank(user);

        deal(_VELODROME_DAI_USDC, user, 0.0001 ether);
        IERC20(_VELODROME_DAI_USDC).approve(address(strategyCTokenUSDCDAI), 0.0001 ether);

        // Mint strategyCTokenUSDCDAI.
        assertGt(strategyCTokenUSDCDAI.deposit(0.0001 ether, user), 0);
        strategyCTokenUSDCDAI.postCollateral(0.0001 ether);
        assertEq(strategyCTokenUSDCDAI.balanceOf(user), 0.0001 ether);

        uint256 balanceBeforeBorrow = dai.balanceOf(user);
        
        // Borrow borrowable cDAI.
        borrowableCDAI.borrow(100 ether, user);
        assertEq(balanceBeforeBorrow + 100 ether, dai.balanceOf(user));

        // Try leverage with 50% of max.
        uint256 amountForLeverage = (positionManager.maxRemainingLeverageOf(
            user,
            address(borrowableCDAI)
        ) * 50) / 100;

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
        leverageAction.cToken = ICToken(address(strategyCTokenUSDCDAI));
        leverageAction.swapAction.inputToken = _DAI_ADDRESS;
        leverageAction.swapAction.inputAmount = amountForLeverage - leverageFee;
        leverageAction.swapAction.outputToken = _USDC_ADDRESS;
        leverageAction.swapAction.target = address(veloRouter);
        leverageAction.swapAction.slippage = 50e16;
        IVeloRouter.Route[] memory routes = new IVeloRouter.Route[](1);
        routes[0].from = _DAI_ADDRESS;
        routes[0].to = _USDC_ADDRESS;
        routes[0].stable = true;
        routes[0].factory = address(veloPairFactory);
        leverageAction.swapAction.call = abi.encodeWithSelector(
            IVeloRouter.swapExactTokensForTokens.selector,
            amountForLeverage - leverageFee,
            0,
            routes,
            address(positionManager),
            type(uint256).max
        );
        leverageAction.auxData = abi.encode(0);

        positionManager.leverage(leverageAction, 0.05e18); // 5% slippage

        AccountSnapshot memory borrowableCDAISnapshot = borrowableCDAI.getSnapshot(user);
        assertEq(borrowableCDAI.balanceOf(user), 0);
        assertEq(borrowableCDAISnapshot.debtBalance, 100 ether + amountForLeverage);

        AccountSnapshot memory strategyCTokenUSDCDAISnapshot = strategyCTokenUSDCDAI.getSnapshot(user);
        assertGt(strategyCTokenUSDCDAI.balanceOf(user), 0.00013 ether);
        assertEq(strategyCTokenUSDCDAISnapshot.debtBalance, 0 ether);

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
        AccountSnapshot memory strategyCTokenUSDCDAIBeforeSnapshot = strategyCTokenUSDCDAI.getSnapshot(user);

        deleverageAction.cToken = ICToken(address(strategyCTokenUSDCDAI));
        deleverageAction.collateralAssets = 0.00003 ether;
        deleverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCDAI));

        uint256 usdcAmount = 27451772;
        deleverageAction.swapActions = new SwapperLib.Swap[](1);
        deleverageAction.swapActions[0].inputToken = _USDC_ADDRESS;
        deleverageAction.swapActions[0].inputAmount = usdcAmount;
        deleverageAction.swapActions[0].outputToken = _DAI_ADDRESS;
        deleverageAction.swapActions[0].target = address(veloRouter);
        deleverageAction.swapActions[0].slippage = 50e16;
        IVeloRouter.Route[] memory routes = new IVeloRouter.Route[](1);
        routes[0].from = _USDC_ADDRESS;
        routes[0].to = _DAI_ADDRESS;
        routes[0].stable = true;
        routes[0].factory = address(veloPairFactory);
        deleverageAction.swapActions[0].call = abi.encodeWithSelector(
            IVeloRouter.swapExactTokensForTokens.selector,
            usdcAmount,
            0,
            routes,
            address(positionManager),
            type(uint256).max
        );
        deleverageAction.repayAssets = 60e18;

        strategyCTokenUSDCDAI.approve(address(positionManager), type(uint256).max);
        positionManager.deleverage(deleverageAction, 0.05e18); // 5% slippage

        AccountSnapshot memory borrowableCDAISnapshot = borrowableCDAI.getSnapshot(user);
        assertEq(borrowableCDAI.balanceOf(user), 0);
        assertEq(
            borrowableCDAISnapshot.debtBalance,
            borrowableCDAIBeforeSnapshot.debtBalance - deleverageAction.repayAssets
        );

        AccountSnapshot memory strategyCTokenUSDCDAISnapshot = strategyCTokenUSDCDAI.getSnapshot(user);
        assertEq(
            strategyCTokenUSDCDAI.collateralPosted(user),
            strategyCTokenUSDCDAIBeforeSnapshot.collateralPosted - deleverageAction.collateralAssets
        );
        assertEq(strategyCTokenUSDCDAISnapshot.debtBalance, 0);

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
        AccountSnapshot memory strategyCTokenUSDCDAIBeforeSnapshot = strategyCTokenUSDCDAI.getSnapshot(user);

        uint256 collateralAmount = 0.00003 ether;
        uint256 leverageFee = collateralAmount / 100;
        uint256 protocolBalanceBeforeDeLeverage = IERC20(_VELODROME_DAI_USDC)
            .balanceOf(centralRegistry.daoAddress());

        deleverageAction.cToken = ICToken(address(strategyCTokenUSDCDAI));
        deleverageAction.collateralAssets = collateralAmount;
        deleverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCDAI));

        uint256 usdcAmount = 27177254;
        deleverageAction.swapActions = new SwapperLib.Swap[](1);
        deleverageAction.swapActions[0].inputToken = _USDC_ADDRESS;
        deleverageAction.swapActions[0].inputAmount = usdcAmount;
        deleverageAction.swapActions[0].outputToken = _DAI_ADDRESS;
        deleverageAction.swapActions[0].target = address(veloRouter);
        deleverageAction.swapActions[0].slippage = 50e16;
        IVeloRouter.Route[] memory routes = new IVeloRouter.Route[](1);
        routes[0].from = _USDC_ADDRESS;
        routes[0].to = _DAI_ADDRESS;
        routes[0].stable = true;
        routes[0].factory = address(veloPairFactory);
        deleverageAction.swapActions[0].call = abi.encodeWithSelector(
            IVeloRouter.swapExactTokensForTokens.selector,
            usdcAmount,
            0,
            routes,
            address(positionManager),
            type(uint256).max
        );
        deleverageAction.repayAssets = 59.3e18;

        strategyCTokenUSDCDAI.approve(address(positionManager), type(uint256).max);
        positionManager.deleverage(deleverageAction, 0.05e18); // 5% slippage

        AccountSnapshot memory borrowableCDAISnapshot = borrowableCDAI.getSnapshot(user);
        assertEq(borrowableCDAI.balanceOf(user), 0);
        assertEq(
            borrowableCDAISnapshot.debtBalance,
            borrowableCDAIBeforeSnapshot.debtBalance - deleverageAction.repayAssets
        );

        AccountSnapshot memory strategyCTokenUSDCDAISnapshot = strategyCTokenUSDCDAI.getSnapshot(user);
        assertEq(
            strategyCTokenUSDCDAI.collateralPosted(user),
            strategyCTokenUSDCDAIBeforeSnapshot.collateralPosted - deleverageAction.collateralAssets
        );
        assertEq(strategyCTokenUSDCDAISnapshot.debtBalance, 0);

        uint256 protocolBalanceAfterDeLeverage = IERC20(_VELODROME_DAI_USDC)
            .balanceOf(centralRegistry.daoAddress());
        assertEq(
            protocolBalanceAfterDeLeverage,
            protocolBalanceBeforeDeLeverage + leverageFee
        );

        vm.stopPrank();
    }

    function testLeverageFor() public {
        vm.startPrank(user);

        deal(_VELODROME_DAI_USDC, user, 0.0001 ether);
        IERC20(_VELODROME_DAI_USDC).approve(address(strategyCTokenUSDCDAI), 0.0001 ether);

        // Mint strategyCTokenUSDCDAI.
        assertGt(strategyCTokenUSDCDAI.deposit(0.0001 ether, user), 0);
        strategyCTokenUSDCDAI.postCollateral(0.0001 ether);
        assertEq(strategyCTokenUSDCDAI.balanceOf(user), 0.0001 ether);

        uint256 balanceBeforeBorrow = dai.balanceOf(user);
        
        // Borrow borrowable cDAI.
        borrowableCDAI.borrow(100 ether, user);
        assertEq(balanceBeforeBorrow + 100 ether, dai.balanceOf(user));

        // Try leverage with 50% of max.
        uint256 amountForLeverage = (positionManager.maxRemainingLeverageOf(
            user,
            address(borrowableCDAI)
        ) * 50) / 100;

        VelodromePositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCDAI));
        leverageAction.borrowAssets = amountForLeverage;
        leverageAction.cToken = ICToken(address(strategyCTokenUSDCDAI));
        leverageAction.swapAction.inputToken = _DAI_ADDRESS;
        leverageAction.swapAction.inputAmount = amountForLeverage;
        leverageAction.swapAction.outputToken = _USDC_ADDRESS;
        leverageAction.swapAction.target = address(veloRouter);
        leverageAction.swapAction.slippage = 50e16;
        IVeloRouter.Route[] memory routes = new IVeloRouter.Route[](1);
        routes[0].from = _DAI_ADDRESS;
        routes[0].to = _USDC_ADDRESS;
        routes[0].stable = true;
        routes[0].factory = address(veloPairFactory);
        leverageAction.swapAction.call = abi.encodeWithSelector(
            IVeloRouter.swapExactTokensForTokens.selector,
            amountForLeverage,
            0,
            routes,
            address(positionManager),
            type(uint256).max
        );
        leverageAction.auxData = abi.encode(0);

        positionManager.setDelegateApproval(address(user2), true);
        vm.stopPrank();

        vm.prank(user2);
        positionManager.leverageFor(leverageAction, user, 0.05e18); // 5% slippage

        AccountSnapshot memory borrowableCDAISnapshot = borrowableCDAI.getSnapshot(user);
        assertEq(borrowableCDAI.balanceOf(user), 0);
        assertEq(borrowableCDAISnapshot.debtBalance, 100 ether + amountForLeverage);

        
        AccountSnapshot memory strategyCTokenUSDCDAISnapshot = strategyCTokenUSDCDAI.getSnapshot(user);
        assertGt(strategyCTokenUSDCDAI.balanceOf(user), 0.00013 ether);
        assertEq(strategyCTokenUSDCDAISnapshot.debtBalance, 0 ether);

        vm.stopPrank();
    }

    function testDeLeverageFor() public {
        testLeverage();

        // Warp until collateralization cooldown period ends.
        vm.warp(block.timestamp + 20 minutes);
        borrowableCDAI.accrueIfNeeded();

        vm.startPrank(user);

        VelodromePositionManager.DeleverageAction memory deleverageAction;

        AccountSnapshot memory borrowableCDAIBeforeSnapshot = borrowableCDAI.getSnapshot(user);
        AccountSnapshot memory strategyCTokenUSDCDAIBeforeSnapshot = strategyCTokenUSDCDAI.getSnapshot(user);

        deleverageAction.cToken = ICToken(address(strategyCTokenUSDCDAI));
        deleverageAction.collateralAssets = 0.00003 ether;
        deleverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCDAI));

        uint256 usdcAmount = 27451772;
        deleverageAction.swapActions = new SwapperLib.Swap[](1);
        deleverageAction.swapActions[0].inputToken = _USDC_ADDRESS;
        deleverageAction.swapActions[0].inputAmount = usdcAmount;
        deleverageAction.swapActions[0].outputToken = _DAI_ADDRESS;
        deleverageAction.swapActions[0].target = address(veloRouter);
        deleverageAction.swapActions[0].slippage = 50e16;
        IVeloRouter.Route[] memory routes = new IVeloRouter.Route[](1);
        routes[0].from = _USDC_ADDRESS;
        routes[0].to = _DAI_ADDRESS;
        routes[0].stable = true;
        routes[0].factory = address(veloPairFactory);
        deleverageAction.swapActions[0].call = abi.encodeWithSelector(
            IVeloRouter.swapExactTokensForTokens.selector,
            usdcAmount,
            0,
            routes,
            address(positionManager),
            type(uint256).max
        );
        deleverageAction.repayAssets = 60e18;

        strategyCTokenUSDCDAI.approve(address(positionManager), type(uint256).max);
        positionManager.setDelegateApproval(address(user2), true);
        vm.stopPrank();

        vm.prank(user2);
        positionManager.deleverageFor(deleverageAction, user, 0.05e18); // 5% slippage

        AccountSnapshot memory borrowableCDAISnapshot = borrowableCDAI.getSnapshot(user);
        assertEq(borrowableCDAI.balanceOf(user), 0);
        assertEq(
            borrowableCDAISnapshot.debtBalance,
            borrowableCDAIBeforeSnapshot.debtBalance - deleverageAction.repayAssets
        );

        AccountSnapshot memory strategyCTokenUSDCDAISnapshot = strategyCTokenUSDCDAI.getSnapshot(user);
        assertEq(
            strategyCTokenUSDCDAI.collateralPosted(user),
            strategyCTokenUSDCDAIBeforeSnapshot.collateralPosted - deleverageAction.collateralAssets
        );
        assertEq(strategyCTokenUSDCDAISnapshot.debtBalance, 0);
    }

    function _provideEnoughLiquidityForLeverage() internal {
        address liquidityProvider = makeAddr("liquidityProvider");

        deal(_VELODROME_DAI_USDC, liquidityProvider, 1 ether);
        _prepareDAI(liquidityProvider, 20000000e18);

        vm.startPrank(liquidityProvider);

        // Deposit borrowable cDAI.
        dai.approve(address(borrowableCDAI), 20000000 ether);
        borrowableCDAI.deposit(20000000 ether, liquidityProvider);

        // Deposit strategyCTokenUSDCDAI.
        IERC20(_VELODROME_DAI_USDC).approve(address(strategyCTokenUSDCDAI), 1 ether);
        strategyCTokenUSDCDAI.deposit(1 ether, liquidityProvider);

        vm.stopPrank();
    }
}
