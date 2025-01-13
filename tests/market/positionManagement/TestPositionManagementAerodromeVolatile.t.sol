// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { AerodromeVolatilePToken, IVeloGauge, IVeloRouter, IVeloPairFactory, IERC20 } from "contracts/market/token/AerodromeVolatilePToken.sol";
import { VelodromeVolatileLPAdaptor } from "contracts/oracles/adaptors/velodrome/VelodromeVolatileLPAdaptor.sol";
import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { PositionManagementAerodromeVolatile } from "contracts/market/position-management/PositionManagementAerodromeVolatile.sol";
import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { IEToken } from "contracts/interfaces/IEToken.sol";
import { IPToken } from "contracts/interfaces/IPToken.sol";

contract TestPositionManagementAerodromeVolatile is TestBaseMarket {
    address internal _AERODROME_WETH_USDC =
        0xcDAC0d6c6C59727a65F871236188350531885C43;
    IVeloGauge public gauge =
        IVeloGauge(0x519BBD1Dd8C6A94C46080E24f316c14Ee758C025);
    IVeloPairFactory public aeroPairFactory =
        IVeloPairFactory(0x420DD381b31aEf6683db6B902084cB0FFECe40Da);
    IVeloRouter public aeroRouter =
        IVeloRouter(0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43);

    AerodromeVolatilePToken public pWETHUSDC;
    VelodromeVolatileLPAdaptor public adaptor;
    PositionManagementAerodromeVolatile public positionManagement;

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

        // setup eDAI
        {
            _deployEDAI();
            // add MToken support on price router
            oracleManager.addMTokenSupport(address(eDAI));

            _prepareDAI(owner, 200000e18);
            dai.approve(address(eDAI), 200000e18);
            marketManager.listToken(address(eDAI));
        }

        // setup pWETHUSDC
        {
            pWETHUSDC = new AerodromeVolatilePToken(
                ICentralRegistry(address(centralRegistry)),
                IERC20(_AERODROME_WETH_USDC),
                address(marketManager),
                gauge,
                aeroPairFactory,
                aeroRouter
            );
            // add MToken support on price router
            oracleManager.addMTokenSupport(address(pWETHUSDC));

            deal(_AERODROME_WETH_USDC, owner, 1 ether);
            IERC20(_AERODROME_WETH_USDC).approve(address(pWETHUSDC), 1 ether);
            marketManager.listToken(address(pWETHUSDC));

            marketManager.updatePositionToken(
                address(pWETHUSDC),
                7000,
                4000,
                3000,
                200,
                400,
                10,
                1000
            );

            address[] memory tokens = new address[](1);
            tokens[0] = address(pWETHUSDC);
            uint256[] memory caps = new uint256[](1);
            caps[0] = 100_000e18;

            marketManager.setPTokenCollateralCaps(tokens, caps);
        }

        positionManagement = new PositionManagementAerodromeVolatile(
            ICentralRegistry(address(centralRegistry)),
            address(marketManager),
            _WETH_ADDRESS,
            address(aeroRouter),
            address(aeroPairFactory)
        );
        marketManager.setPositionManagement(address(positionManagement));

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
            address(positionManagement.centralRegistry()),
            address(centralRegistry)
        );
        assertEq(
            address(positionManagement.marketManager()),
            address(marketManager)
        );
    }

    function testLeverage() public {
        vm.startPrank(user);

        deal(_AERODROME_WETH_USDC, user, 0.0001 ether);
        IERC20(_AERODROME_WETH_USDC).approve(address(pWETHUSDC), 0.0001 ether);

        // mint
        assertGt(pWETHUSDC.deposit(0.0001 ether, user), 0);
        marketManager.postCollateral(user, address(pWETHUSDC), 0.0001 ether);
        assertEq(pWETHUSDC.balanceOf(user), 0.0001 ether);

        uint256 balanceBeforeBorrow = dai.balanceOf(user);
        // borrow
        eDAI.borrow(100 ether);
        assertEq(balanceBeforeBorrow + 100 ether, dai.balanceOf(user));

        // try leverage with 50% of max
        uint256 amountForLeverage = (positionManagement.maxRemainingLeverageOf(
            user,
            address(eDAI)
        ) * 50) / 100;

        PositionManagementAerodromeVolatile.LeverageStruct memory leverageData;
        leverageData.borrowToken = IEToken(address(eDAI));
        leverageData.borrowAmount = amountForLeverage;
        leverageData.positionToken = IPToken(address(pWETHUSDC));
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
            address(positionManagement),
            type(uint256).max
        );
        leverageData.swapData.slippage = 2e18;
        leverageData.auxData = bytes("");

        positionManagement.leverage(leverageData, 0.05e18); // 5% slippage

        (uint256 eDAIBalance, uint256 eDAIBorrowed, ) = eDAI.getSnapshot(user);
        assertEq(eDAIBalance, 0);
        assertEq(eDAIBorrowed, 100 ether + amountForLeverage);

        (uint256 pUSDCDAIBalance, uint256 pUSDCDAIBorrowed, ) = pWETHUSDC
            .getSnapshot(user);
        assertGt(pUSDCDAIBalance, 0.00013 ether);
        assertEq(pUSDCDAIBorrowed, 0 ether);

        vm.stopPrank();
    }

    function testDepositAndLeverage() public {
        vm.startPrank(user);

        deal(_AERODROME_WETH_USDC, user, 0.0001 ether);
        IERC20(_AERODROME_WETH_USDC).approve(
            address(positionManagement),
            0.0001 ether
        );

        // allow delegation for postCollateral
        pWETHUSDC.setDelegateApproval(address(positionManagement), true);

        // try leverage with 50% of max
        uint256 amountForLeverage = 1.204e22;

        PositionManagementAerodromeVolatile.LeverageStruct memory leverageData;
        leverageData.borrowToken = IEToken(address(eDAI));
        leverageData.borrowAmount = amountForLeverage;
        leverageData.positionToken = IPToken(address(pWETHUSDC));
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
            address(positionManagement),
            type(uint256).max
        );
        leverageData.swapData.slippage = 2e18;
        leverageData.auxData = bytes("");

        positionManagement.depositAndLeverage(
            0.0001 ether,
            leverageData,
            0.05e18
        ); // 5% slippage

        (uint256 eDAIBalance, uint256 eDAIBorrowed, ) = eDAI.getSnapshot(user);
        assertEq(eDAIBalance, 0);
        assertEq(eDAIBorrowed, amountForLeverage);

        (uint256 pUSDCDAIBalance, uint256 pUSDCDAIBorrowed, ) = pWETHUSDC
            .getSnapshot(user);
        assertGt(pUSDCDAIBalance, 0.00013 ether);
        assertEq(pUSDCDAIBorrowed, 0 ether);

        vm.stopPrank();
    }

    function testDepositAndLeverageMaxWithExistingPosition() public {
        vm.startPrank(user);

        // deposit and borrow
        deal(_AERODROME_WETH_USDC, user, 0.0001 ether);
        IERC20(_AERODROME_WETH_USDC).approve(address(pWETHUSDC), 0.0001 ether);
        assertGt(pWETHUSDC.deposit(0.0001 ether, user), 0);
        marketManager.postCollateral(user, address(pWETHUSDC), 0.0001 ether);
        assertEq(pWETHUSDC.balanceOf(user), 0.0001 ether);
        uint256 balanceBeforeBorrow = dai.balanceOf(user);
        eDAI.borrow(100 ether);
        assertEq(balanceBeforeBorrow + 100 ether, dai.balanceOf(user));

        // deposit and leverage
        deal(_AERODROME_WETH_USDC, user, 0.0001 ether);
        IERC20(_AERODROME_WETH_USDC).approve(
            address(positionManagement),
            0.0001 ether
        );

        // allow delegation for postCollateral
        pWETHUSDC.setDelegateApproval(address(positionManagement), true);

        // try max leverage
        uint256 amountForLeverage = positionManagement.maxRemainingLeverageOf(
            user,
            address(eDAI)
        );

        PositionManagementAerodromeVolatile.LeverageStruct memory leverageData;
        leverageData.borrowToken = IEToken(address(eDAI));
        leverageData.borrowAmount = amountForLeverage;
        leverageData.positionToken = IPToken(address(pWETHUSDC));
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
            address(positionManagement),
            type(uint256).max
        );
        leverageData.swapData.slippage = 2e18;
        leverageData.auxData = bytes("");

        positionManagement.depositAndLeverage(
            0.0001 ether,
            leverageData,
            0.05e18 // 5% slippage
        );

        (uint256 eDAIBalance, uint256 eDAIBorrowed, ) = eDAI.getSnapshot(user);
        assertEq(eDAIBalance, 0);
        assertEq(eDAIBorrowed, amountForLeverage + 100 ether);

        (uint256 pUSDCDAIBalance, uint256 pUSDCDAIBorrowed, ) = pWETHUSDC
            .getSnapshot(user);
        assertGt(pUSDCDAIBalance, 0.00042 ether);
        assertEq(pUSDCDAIBorrowed, 0 ether);

        vm.stopPrank();
    }

    function testDepositAndLeverageHalfOfMaxWithExistingPosition() public {
        vm.startPrank(user);

        // deposit and borrow
        deal(_AERODROME_WETH_USDC, user, 0.0001 ether);
        IERC20(_AERODROME_WETH_USDC).approve(address(pWETHUSDC), 0.0001 ether);
        assertGt(pWETHUSDC.deposit(0.0001 ether, user), 0);
        marketManager.postCollateral(user, address(pWETHUSDC), 0.0001 ether);
        assertEq(pWETHUSDC.balanceOf(user), 0.0001 ether);
        uint256 balanceBeforeBorrow = dai.balanceOf(user);
        eDAI.borrow(100 ether);
        assertEq(balanceBeforeBorrow + 100 ether, dai.balanceOf(user));

        // deposit and leverage
        deal(_AERODROME_WETH_USDC, user, 0.0001 ether);
        IERC20(_AERODROME_WETH_USDC).approve(
            address(positionManagement),
            0.0001 ether
        );

        // allow delegation for postCollateral
        pWETHUSDC.setDelegateApproval(address(positionManagement), true);

        // try leverage with 50% of max
        uint256 amountForLeverage = positionManagement.maxRemainingLeverageOf(
            user,
            address(eDAI)
        ) / 2;

        PositionManagementAerodromeVolatile.LeverageStruct memory leverageData;
        leverageData.borrowToken = IEToken(address(eDAI));
        leverageData.borrowAmount = amountForLeverage;
        leverageData.positionToken = IPToken(address(pWETHUSDC));
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
            address(positionManagement),
            type(uint256).max
        );
        leverageData.swapData.slippage = 2e18;
        leverageData.auxData = bytes("");

        positionManagement.depositAndLeverage(
            0.0001 ether,
            leverageData,
            0.05e18 // 5% slippage
        );

        (uint256 eDAIBalance, uint256 eDAIBorrowed, ) = eDAI.getSnapshot(user);
        assertEq(eDAIBalance, 0);
        assertEq(eDAIBorrowed, amountForLeverage + 100 ether);

        (uint256 pUSDCDAIBalance, uint256 pUSDCDAIBorrowed, ) = pWETHUSDC
            .getSnapshot(user);
        assertGt(pUSDCDAIBalance, 0.00031 ether);
        assertEq(pUSDCDAIBorrowed, 0 ether);

        vm.stopPrank();
    }

    function testDeLeverage() public {
        testLeverage();
        // Warp until collateral posting wait time ends
        vm.warp(block.timestamp + 20 minutes);
        eDAI.accrueInterest();

        vm.startPrank(user);

        PositionManagementAerodromeVolatile.DeleverageStruct
            memory deleverageData;

        (, uint256 eDAIBorrowedBefore, ) = eDAI.getSnapshot(user);
        (uint256 pUSDCDAIBalanceBefore, , ) = pWETHUSDC.getSnapshot(user);

        deleverageData.positionToken = IPToken(address(pWETHUSDC));
        deleverageData.collateralAmount = 0.00003 ether;
        deleverageData.borrowToken = IEToken(address(eDAI));

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
            address(positionManagement),
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
            address(positionManagement),
            block.timestamp
        );
        deleverageData.repayAmount = 3097e18;

        pWETHUSDC.approve(address(positionManagement), type(uint256).max);
        positionManagement.deleverage(deleverageData, 0.05e18); // 5% slippage

        (uint256 eDAIBalance, uint256 eDAIBorrowed, ) = eDAI.getSnapshot(user);
        assertEq(eDAIBalance, 0);
        assertEq(
            eDAIBorrowed,
            eDAIBorrowedBefore - deleverageData.repayAmount
        );

        (uint256 pUSDCDAIBalance, uint256 pUSDCDAIBorrowed, ) = pWETHUSDC
            .getSnapshot(user);
        assertEq(
            pUSDCDAIBalance,
            pUSDCDAIBalanceBefore - deleverageData.collateralAmount
        );
        assertEq(pUSDCDAIBorrowed, 0);

        vm.stopPrank();
    }

    function testLeverageFor() public {
        vm.startPrank(user);

        deal(_AERODROME_WETH_USDC, user, 0.0001 ether);
        IERC20(_AERODROME_WETH_USDC).approve(address(pWETHUSDC), 0.0001 ether);

        // mint
        assertGt(pWETHUSDC.deposit(0.0001 ether, user), 0);
        marketManager.postCollateral(user, address(pWETHUSDC), 0.0001 ether);
        assertEq(pWETHUSDC.balanceOf(user), 0.0001 ether);

        uint256 balanceBeforeBorrow = dai.balanceOf(user);
        // borrow
        eDAI.borrow(100 ether);
        assertEq(balanceBeforeBorrow + 100 ether, dai.balanceOf(user));

        // try leverage with 50% of max
        uint256 amountForLeverage = (positionManagement.maxRemainingLeverageOf(
            user,
            address(eDAI)
        ) * 50) / 100;

        PositionManagementAerodromeVolatile.LeverageStruct memory leverageData;
        leverageData.borrowToken = IEToken(address(eDAI));
        leverageData.borrowAmount = amountForLeverage;
        leverageData.positionToken = IPToken(address(pWETHUSDC));
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
            address(positionManagement),
            type(uint256).max
        );
        leverageData.swapData.slippage = 2e18;
        leverageData.auxData = bytes("");

        positionManagement.setDelegateApproval(address(user2), true);
        vm.stopPrank();

        vm.prank(user2);
        positionManagement.leverageFor(leverageData, user, 0.05e18); // 5% slippage

        (uint256 eDAIBalance, uint256 eDAIBorrowed, ) = eDAI.getSnapshot(user);
        assertEq(eDAIBalance, 0);
        assertEq(eDAIBorrowed, 100 ether + amountForLeverage);

        (uint256 pUSDCDAIBalance, uint256 pUSDCDAIBorrowed, ) = pWETHUSDC
            .getSnapshot(user);
        assertGt(pUSDCDAIBalance, 0.00013 ether);
        assertEq(pUSDCDAIBorrowed, 0 ether);
    }

    function testDeLeverageFor() public {
        testLeverage();
        // Warp until collateral posting wait time ends
        vm.warp(block.timestamp + 20 minutes);
        eDAI.accrueInterest();

        vm.startPrank(user);

        PositionManagementAerodromeVolatile.DeleverageStruct
            memory deleverageData;

        (, uint256 eDAIBorrowedBefore, ) = eDAI.getSnapshot(user);
        (uint256 pUSDCDAIBalanceBefore, , ) = pWETHUSDC.getSnapshot(user);

        deleverageData.positionToken = IPToken(address(pWETHUSDC));
        deleverageData.collateralAmount = 0.00003 ether;
        deleverageData.borrowToken = IEToken(address(eDAI));

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
            address(positionManagement),
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
            address(positionManagement),
            block.timestamp
        );
        deleverageData.repayAmount = 3097e18;

        pWETHUSDC.approve(address(positionManagement), type(uint256).max);
        positionManagement.setDelegateApproval(address(user2), true);
        vm.stopPrank();

        vm.prank(user2);
        positionManagement.deleverageFor(deleverageData, user, 0.05e18); // 5% slippage

        (uint256 eDAIBalance, uint256 eDAIBorrowed, ) = eDAI.getSnapshot(user);
        assertEq(eDAIBalance, 0);
        assertEq(
            eDAIBorrowed,
            eDAIBorrowedBefore - deleverageData.repayAmount
        );

        (uint256 pUSDCDAIBalance, uint256 pUSDCDAIBorrowed, ) = pWETHUSDC
            .getSnapshot(user);
        assertEq(
            pUSDCDAIBalance,
            pUSDCDAIBalanceBefore - deleverageData.collateralAmount
        );
        assertEq(pUSDCDAIBorrowed, 0);

        vm.stopPrank();
    }

    function _provideEnoughLiquidityForLeverage() internal {
        address liquidityProvider = makeAddr("liquidityProvider");

        deal(_AERODROME_WETH_USDC, liquidityProvider, 1 ether);
        _prepareDAI(liquidityProvider, 20000000e18);

        vm.startPrank(liquidityProvider);

        // mint eDAI
        dai.approve(address(eDAI), 20000000 ether);
        eDAI.mint(20000000 ether);

        // mint pWETHUSDC
        IERC20(_AERODROME_WETH_USDC).approve(address(pWETHUSDC), 1 ether);
        pWETHUSDC.deposit(1 ether, liquidityProvider);

        vm.stopPrank();
    }
}
