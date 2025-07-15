// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { AerodromeStableCToken } from "contracts/market/token/AerodromeStableCToken.sol";
import { VelodromeStableLPAdaptor } from "contracts/oracles/adaptors/velodrome/VelodromeStableLPAdaptor.sol";
import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { AerodromePositionManager } from "contracts/market/position-management/AerodromePositionManager.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { ICToken, AccountSnapshot } from "contracts/interfaces/ICToken.sol";
import { IVeloGauge } from "contracts/interfaces/external/velodrome/IVeloGauge.sol";
import { IVeloRouter } from "contracts/interfaces/external/velodrome/IVeloRouter.sol";
import { IVeloPairFactory } from "contracts/interfaces/external/velodrome/IVeloPairFactory.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

contract TestAerodromeStablePositionManager is TestBaseMarketIsolated {
    address internal _AERODROME_DAI_USDC =
        0x67b00B46FA4f4F24c03855c5C8013C0B938B3eEc;
    IVeloGauge public gauge =
        IVeloGauge(0x640e9ef68e1353112fF18826c4eDa844E1dC5eD0);
    IVeloPairFactory public aeroPairFactory =
        IVeloPairFactory(0x420DD381b31aEf6683db6B902084cB0FFECe40Da);
    IVeloRouter public aeroRouter =
        IVeloRouter(0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43);

    IERC20 public aerodromeDAIUSDC;
    AerodromeStableCToken public strategyCTokenUSDCDAI;
    VelodromeStableLPAdaptor public adaptor;
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

        adaptor = new VelodromeStableLPAdaptor(
            ICentralRegistry(address(centralRegistry))
        );
        adaptor.addAsset(_AERODROME_DAI_USDC);
        oracleManager.addApprovedAdaptor(address(adaptor));
        oracleManager.addAssetPriceFeed(_AERODROME_DAI_USDC, address(adaptor));

        owner = address(this);
        user = user1;
        aerodromeDAIUSDC = IERC20(_AERODROME_DAI_USDC);

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
            strategyCTokenUSDCDAI = new AerodromeStableCToken(
                ICentralRegistry(address(centralRegistry)),
                IERC20(_AERODROME_DAI_USDC),
                address(marketManagerIsolated),
                gauge,
                aeroPairFactory,
                aeroRouter,
                1 days
            );
            // Add cToken support on Oracle Manager.
            oracleManager.addCTokenSupport(address(strategyCTokenUSDCDAI));

            deal(_AERODROME_DAI_USDC, owner, 1 ether);
            IERC20(_AERODROME_DAI_USDC).approve(address(strategyCTokenUSDCDAI), 1 ether);



        marketManagerIsolated.listTokens(address(strategyCTokenUSDCDAI),address(borrowableCDAI));

         _setCTokenConfigBasic(address(strategyCTokenUSDCDAI), 100_000e18, 0);
         _setCTokenConfigBasic(address(borrowableCDAI), 100_000e18, 100_000e18);
        }


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

        deal(_AERODROME_DAI_USDC, user, 0.0001 ether);
        IERC20(_AERODROME_DAI_USDC).approve(address(strategyCTokenUSDCDAI), 0.0001 ether);

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

        AerodromePositionManager.LeverageStruct memory leverageData;
        leverageData.debtToken = IBorrowableCToken(address(borrowableCDAI));
        leverageData.borrowAssets = amountForLeverage;
        leverageData.collateralToken = ICToken(address(strategyCTokenUSDCDAI));
        leverageData.swapData.inputToken = address(0x0);
        leverageData.swapData.inputAmount = 0;
        leverageData.swapData.outputToken = address(0x0);
        leverageData.swapData.target = address(0x0);
        leverageData.swapData.slippage = 0;
        leverageData.swapData.call = bytes("");
        leverageData.auxData = abi.encode(0);

        positionManager.leverage(leverageData, 0.05e18); // 5% slippage

        AccountSnapshot memory borrowableCDAISnapshot = borrowableCDAI.getSnapshot(user);
        assertEq(borrowableCDAI.balanceOf(user), 0);
        assertEq(borrowableCDAISnapshot.debtBalance, 100 ether + amountForLeverage);

        AccountSnapshot memory strategyCTokenUSDCDAISnapshot = strategyCTokenUSDCDAI.getSnapshot(user);
        assertGt(strategyCTokenUSDCDAI.balanceOf(user), 0.00013 ether);
        assertEq(strategyCTokenUSDCDAISnapshot.collateralPosted, strategyCTokenUSDCDAI.balanceOf(user));

        vm.stopPrank();
    }

    function testDepositAndLeverage() public {
        vm.startPrank(user);

        deal(_AERODROME_DAI_USDC, user, 0.0001 ether);
        IERC20(_AERODROME_DAI_USDC).approve(
            address(positionManager),
            0.0001 ether
        );

        // allow delegation for postCollateral
        strategyCTokenUSDCDAI.setDelegateApproval(address(positionManager), true);

        // Try leverage with 50% of max.
        uint256 amountForLeverage = 0.66e20;

        AerodromePositionManager.LeverageStruct memory leverageData;
        leverageData.debtToken = IBorrowableCToken(address(borrowableCDAI));
        leverageData.borrowAssets = amountForLeverage;
        leverageData.collateralToken = ICToken(address(strategyCTokenUSDCDAI));
        leverageData.swapData.inputToken = address(0x0);
        leverageData.swapData.inputAmount = 0;
        leverageData.swapData.outputToken = address(0x0);
        leverageData.swapData.target = address(0x0);
        leverageData.swapData.slippage = 0;
        leverageData.swapData.call = bytes("");
        leverageData.auxData = abi.encode(0);

        positionManager.depositAndLeverage(
            0.0001 ether,
            leverageData,
            0.05e18
        ); // 5% slippage

        AccountSnapshot memory borrowableCDAISnapshot = borrowableCDAI.getSnapshot(user);
        assertEq(borrowableCDAI.balanceOf(user), 0);
        assertEq(borrowableCDAISnapshot.debtBalance, amountForLeverage);

        AccountSnapshot memory strategyCTokenUSDCDAISnapshot = strategyCTokenUSDCDAI.getSnapshot(user);
        assertGt(strategyCTokenUSDCDAI.balanceOf(user), 0.00013 ether);
        assertEq(strategyCTokenUSDCDAISnapshot.collateralPosted,strategyCTokenUSDCDAI.balanceOf(user));

        vm.stopPrank();
    }

    function testDepositAndLeverageMaxWithExistingPosition() public {
        vm.startPrank(user);

        // deposit and borrow (~1k collateral and 500 debt)
        deal(_AERODROME_DAI_USDC, user, 0.001 ether);
        IERC20(_AERODROME_DAI_USDC).approve(address(strategyCTokenUSDCDAI), 0.001 ether);
        strategyCTokenUSDCDAI.deposit(0.001 ether, user);
        strategyCTokenUSDCDAI.postCollateral(0.001 ether);
        assertEq(strategyCTokenUSDCDAI.balanceOf(user), 0.001 ether);
        uint256 balanceBeforeBorrow = dai.balanceOf(user);
        borrowableCDAI.borrow(500 ether, user);
        assertEq(balanceBeforeBorrow + 500 ether, dai.balanceOf(user));

        // deposit and leverage
        deal(_AERODROME_DAI_USDC, user, 0.001 ether);
        IERC20(_AERODROME_DAI_USDC).approve(
            address(positionManager),
            0.001 ether
        );

        // allow delegation for postCollateral
        strategyCTokenUSDCDAI.setDelegateApproval(address(positionManager), true);

        // try max leverage
        uint256 amountForLeverage = positionManager.maxRemainingLeverageOf(
            user,
            address(borrowableCDAI)
        );

        AerodromePositionManager.LeverageStruct memory leverageData;
        leverageData.debtToken = IBorrowableCToken(address(borrowableCDAI));
        leverageData.borrowAssets = amountForLeverage;
        leverageData.collateralToken = ICToken(address(strategyCTokenUSDCDAI));
        leverageData.swapData.inputToken = address(0x0);
        leverageData.swapData.inputAmount = 0;
        leverageData.swapData.outputToken = address(0x0);
        leverageData.swapData.target = address(0x0);
        leverageData.swapData.slippage = 0;
        leverageData.swapData.call = bytes("");
        leverageData.auxData = abi.encode(0);

        positionManager.depositAndLeverage(
            0.001 ether,
            leverageData,
            0.05e18 // 5% slippage
        );

        AccountSnapshot memory borrowableCDAISnapshot = borrowableCDAI.getSnapshot(user);
        assertEq(borrowableCDAI.balanceOf(user), 0);
        assertEq(borrowableCDAISnapshot.debtBalance, amountForLeverage + 500 ether);

        AccountSnapshot memory strategyCTokenUSDCDAISnapshot = strategyCTokenUSDCDAI.getSnapshot(user);
        assertGt(strategyCTokenUSDCDAI.balanceOf(user), 0.0034 ether);
        assertEq(strategyCTokenUSDCDAISnapshot.collateralPosted, strategyCTokenUSDCDAI.balanceOf(user));

        vm.stopPrank();
    }

    function testDepositAndLeverageHalfOfMaxWithExistingPosition() public {
        vm.startPrank(user);

        // deposit and borrow (~1k collateral and 500 debt)
        deal(_AERODROME_DAI_USDC, user, 0.001 ether);
        IERC20(_AERODROME_DAI_USDC).approve(address(strategyCTokenUSDCDAI), 0.001 ether);
        strategyCTokenUSDCDAI.deposit(0.001 ether, user);
        strategyCTokenUSDCDAI.postCollateral(0.001 ether);
        assertEq(strategyCTokenUSDCDAI.balanceOf(user), 0.001 ether);
        uint256 balanceBeforeBorrow = dai.balanceOf(user);
        borrowableCDAI.borrow(500 ether, user);
        assertEq(balanceBeforeBorrow + 500 ether, dai.balanceOf(user));

        // deposit and leverage
        deal(_AERODROME_DAI_USDC, user, 0.001 ether);
        IERC20(_AERODROME_DAI_USDC).approve(
            address(positionManager),
            0.001 ether
        );

        // allow delegation for postCollateral
        strategyCTokenUSDCDAI.setDelegateApproval(address(positionManager), true);

        // try half of max leverage
        uint256 amountForLeverage = positionManager.maxRemainingLeverageOf(
            user,
            address(borrowableCDAI)
        ) / 2;

        AerodromePositionManager.LeverageStruct memory leverageData;
        leverageData.debtToken = IBorrowableCToken(address(borrowableCDAI));
        leverageData.borrowAssets = amountForLeverage;
        leverageData.collateralToken = ICToken(address(strategyCTokenUSDCDAI));
        leverageData.swapData.inputToken = address(0x0);
        leverageData.swapData.inputAmount = 0;
        leverageData.swapData.outputToken = address(0x0);
        leverageData.swapData.target = address(0x0);
        leverageData.swapData.slippage = 0;
        leverageData.swapData.call = bytes("");
        leverageData.auxData = abi.encode(0);

        positionManager.depositAndLeverage(
            0.001 ether,
            leverageData,
            0.05e18 // 5% slippage
        );

        AccountSnapshot memory borrowableCDAISnapshot = borrowableCDAI.getSnapshot(user);
        assertEq(borrowableCDAI.balanceOf(user), 0);
        assertEq(borrowableCDAISnapshot.debtBalance, amountForLeverage + 500 ether);

        AccountSnapshot memory strategyCTokenUSDCDAISnapshot = strategyCTokenUSDCDAI.getSnapshot(user);
        assertGt(strategyCTokenUSDCDAI.balanceOf(user), 0.0027 ether);
        assertEq(strategyCTokenUSDCDAISnapshot.collateralPosted, strategyCTokenUSDCDAI.balanceOf(user));

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
        uint256 strategyCTokenUSDCDAIBalanceBefore = strategyCTokenUSDCDAI.balanceOf(user);

        deleverageData.collateralToken = ICToken(address(strategyCTokenUSDCDAI));
        deleverageData.collateralAssets = 0.00003 ether;
        deleverageData.debtToken = IBorrowableCToken(address(borrowableCDAI));

        uint256 usdcAmount = 28430000;
        deleverageData.swapData = new SwapperLib.Swap[](1);
        deleverageData.swapData[0].inputToken = _USDC_ADDRESS;
        deleverageData.swapData[0].inputAmount = usdcAmount;
        deleverageData.swapData[0].outputToken = _DAI_ADDRESS;
        deleverageData.swapData[0].target = address(aeroRouter);
        deleverageData.swapData[0].slippage = 1e18;
        IVeloRouter.Route[] memory routes = new IVeloRouter.Route[](1);
        routes[0].from = _USDC_ADDRESS;
        routes[0].to = _DAI_ADDRESS;
        routes[0].stable = true;
        routes[0].factory = address(aeroPairFactory);
        deleverageData.swapData[0].call = abi.encodeWithSelector(
            IVeloRouter.swapExactTokensForTokens.selector,
            usdcAmount,
            0,
            routes,
            address(positionManager),
            block.timestamp
        );
        deleverageData.repayAssets = 59.56e18;

        strategyCTokenUSDCDAI.approve(address(positionManager), type(uint256).max);
        positionManager.deleverage(deleverageData, 0.05e18); // 5% slippage

        AccountSnapshot memory borrowableCDAISnapshot = borrowableCDAI.getSnapshot(user);
        assertEq(borrowableCDAI.balanceOf(user), 0);
        assertEq(
            borrowableCDAISnapshot.debtBalance,
            borrowableCDAISnapshotBefore.debtBalance - deleverageData.repayAssets,
            "debt balance mismatch"
        );

        AccountSnapshot memory strategyCTokenUSDCDAISnapshot = strategyCTokenUSDCDAI.getSnapshot(user);
        assertEq(
            strategyCTokenUSDCDAI.balanceOf(user),
            strategyCTokenUSDCDAIBalanceBefore - deleverageData.collateralAssets,
            "strategyCTokenUSDCDAIBalance mismatch"
        );
        assertEq(
            strategyCTokenUSDCDAISnapshot.collateralPosted,
            strategyCTokenUSDCDAIBalanceBefore - deleverageData.collateralAssets,
            "strategyCTokenUSDCDAISnapshot.collateralPosted mismatch"
        );

        vm.stopPrank();
    }

    function testLeverageFor() public {
        vm.startPrank(user);

        deal(_AERODROME_DAI_USDC, user, 0.0001 ether);
        IERC20(_AERODROME_DAI_USDC).approve(address(strategyCTokenUSDCDAI), 0.0001 ether);

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
        AerodromePositionManager.LeverageStruct memory leverageData;
        leverageData.debtToken = IBorrowableCToken(address(borrowableCDAI));
        leverageData.borrowAssets = amountForLeverage;
        leverageData.collateralToken = ICToken(address(strategyCTokenUSDCDAI));
        leverageData.swapData.inputToken = address(0x0);
        leverageData.swapData.inputAmount = 0;
        leverageData.swapData.outputToken = address(0x0);
        leverageData.swapData.target = address(0x0);
        leverageData.swapData.slippage = 0;
        leverageData.swapData.call = bytes("");
        leverageData.auxData = abi.encode(0);

        positionManager.setDelegateApproval(address(user2), true);
        vm.stopPrank();

        vm.prank(user2);
        positionManager.leverageFor(leverageData, user, 0.05e18); // 5% slippage

        AccountSnapshot memory borrowableCDAISnapshot = borrowableCDAI.getSnapshot(user);
        assertEq(borrowableCDAI.balanceOf(user), 0);
        assertEq(borrowableCDAISnapshot.debtBalance, 100 ether + amountForLeverage);

        AccountSnapshot memory strategyCTokenUSDCDAISnapshot = strategyCTokenUSDCDAI.getSnapshot(user);
        assertGt(strategyCTokenUSDCDAI.balanceOf(user), 0.00013 ether);
        assertEq(strategyCTokenUSDCDAISnapshot.collateralPosted, strategyCTokenUSDCDAI.balanceOf(user));

        vm.stopPrank();
    }

    function testDeLeverageFor() public {
        testLeverage();

        // Warp until collateralization cooldown period ends.
        vm.warp(block.timestamp + 20 minutes);
        borrowableCDAI.accrueIfNeeded();

        vm.startPrank(user);

        AerodromePositionManager.DeleverageStruct memory deleverageData;

        AccountSnapshot memory borrowableCDAISnapshotBefore = borrowableCDAI.getSnapshot(user);
        uint256 strategyCTokenUSDCDAIBalanceBefore = strategyCTokenUSDCDAI.balanceOf(user);

        deleverageData.collateralToken = ICToken(address(strategyCTokenUSDCDAI));
        deleverageData.collateralAssets = 0.00003 ether;
        deleverageData.debtToken = IBorrowableCToken(address(borrowableCDAI));

        uint256 usdcAmount = 28430000;
        deleverageData.swapData = new SwapperLib.Swap[](1);
        deleverageData.swapData[0].inputToken = _USDC_ADDRESS;
        deleverageData.swapData[0].inputAmount = usdcAmount;
        deleverageData.swapData[0].outputToken = _DAI_ADDRESS;
        deleverageData.swapData[0].target = address(aeroRouter);
        deleverageData.swapData[0].slippage = 1e18;
        IVeloRouter.Route[] memory routes = new IVeloRouter.Route[](1);
        routes[0].from = _USDC_ADDRESS;
        routes[0].to = _DAI_ADDRESS;
        routes[0].stable = true;
        routes[0].factory = address(aeroPairFactory);
        deleverageData.swapData[0].call = abi.encodeWithSelector(
            IVeloRouter.swapExactTokensForTokens.selector,
            usdcAmount,
            0,
            routes,
            address(positionManager),
            block.timestamp
        );
        deleverageData.repayAssets = 59.56e18;

        strategyCTokenUSDCDAI.approve(address(positionManager), type(uint256).max);
        positionManager.setDelegateApproval(address(user2), true);
        vm.stopPrank();

        vm.prank(user2);
        positionManager.deleverageFor(deleverageData, user, 0.05e18); // 5% slippage

        AccountSnapshot memory borrowableCDAISnapshot = borrowableCDAI.getSnapshot(user);
        assertEq(borrowableCDAI.balanceOf(user), 0);
        assertEq(
            borrowableCDAISnapshot.debtBalance,
            borrowableCDAISnapshotBefore.debtBalance - deleverageData.repayAssets
        );

        AccountSnapshot memory strategyCTokenUSDCDAISnapshot = strategyCTokenUSDCDAI.getSnapshot(user);
        assertEq(
            strategyCTokenUSDCDAI.balanceOf(user),
            strategyCTokenUSDCDAIBalanceBefore - deleverageData.collateralAssets
        );
        assertEq(strategyCTokenUSDCDAISnapshot.collateralPosted, strategyCTokenUSDCDAIBalanceBefore - deleverageData.collateralAssets);

        vm.stopPrank();
    }

    function _provideEnoughLiquidityForLeverage() internal {
        address liquidityProvider = makeAddr("liquidityProvider");

        deal(_AERODROME_DAI_USDC, liquidityProvider, 1 ether);
        _prepareDAI(liquidityProvider, 20000000e18);

        vm.startPrank(liquidityProvider);

        // Deposit borrowable cDAI.
        dai.approve(address(borrowableCDAI), 20000000 ether);
        borrowableCDAI.deposit(20000000 ether, liquidityProvider);

        // Deposit strategyCTokenUSDCDAI.
        IERC20(_AERODROME_DAI_USDC).approve(address(strategyCTokenUSDCDAI), 1 ether);
        strategyCTokenUSDCDAI.deposit(1 ether, liquidityProvider);

        vm.stopPrank();
    }
}
