// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";
import { VelodromeVolatilePToken } from "contracts/market/token/VelodromeVolatilePToken.sol";
import { VelodromeVolatileLPAdaptor } from "contracts/oracles/adaptors/velodrome/VelodromeVolatileLPAdaptor.sol";
import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { PositionManagementVelodrome } from "contracts/market/position-management/PositionManagementVelodrome.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IEToken } from "contracts/interfaces/IEToken.sol";
import { IPToken } from "contracts/interfaces/IPToken.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IVeloGauge } from "contracts/interfaces/external/velodrome/IVeloGauge.sol";
import { IVeloPairFactory } from "contracts/interfaces/external/velodrome/IVeloPairFactory.sol";
import { IVeloRouter } from "contracts/interfaces/external/velodrome/IVeloRouter.sol";
import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";

contract TestPositionManagementVelodromeVolatile is TestBaseMarket {
    address internal _VELODROME_WETH_USDC =
        0x0493Bf8b6DBB159Ce2Db2E0E8403E753Abd1235b;
    IVeloGauge public gauge =
        IVeloGauge(0xE7630c9560C59CCBf5EEd8f33dd0ccA2E67a3981);
    IVeloPairFactory public veloPairFactory =
        IVeloPairFactory(0xF1046053aa5682b4F9a81b5481394DA16BE5FF5a);
    IVeloRouter public veloRouter =
        IVeloRouter(0xa062aE8A9c5e11aaA026fc2670B0D65cCc8B2858);

    VelodromeVolatilePToken public pWETHUSDC;
    VelodromeVolatileLPAdaptor public adaptor;
    PositionManagementVelodrome public positionManagement;

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
            pWETHUSDC = new VelodromeVolatilePToken(
                ICentralRegistry(address(centralRegistry)),
                IERC20(_VELODROME_WETH_USDC),
                address(marketManager),
                gauge,
                veloPairFactory,
                veloRouter
            );
            // add MToken support on price router
            oracleManager.addMTokenSupport(address(pWETHUSDC));

            deal(_VELODROME_WETH_USDC, owner, 1 ether);
            IERC20(_VELODROME_WETH_USDC).approve(address(pWETHUSDC), 1 ether);
            marketManager.listToken(address(pWETHUSDC));

            marketManager.updatePositionToken(
                address(pWETHUSDC),
                7000,
                4000,
                3000,
                200,
                400,
                1000
            );

            address[] memory tokens = new address[](1);
            tokens[0] = address(pWETHUSDC);
            uint256[] memory caps = new uint256[](1);
            caps[0] = 100_000e18;

            marketManager.setPTokenCollateralCaps(tokens, caps);
        }

        positionManagement = new PositionManagementVelodrome(
            ICentralRegistry(address(centralRegistry)),
            address(marketManager),
            _WETH_ADDRESS,
            address(veloRouter),
            address(veloPairFactory)
        );
        marketManager.setPositionManagement(address(positionManagement));

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

        deal(_VELODROME_WETH_USDC, user, 0.0001 ether);
        IERC20(_VELODROME_WETH_USDC).approve(address(pWETHUSDC), 0.0001 ether);

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

        PositionManagementVelodrome.LeverageStruct memory leverageData;
        leverageData.borrowToken = IEToken(address(eDAI));
        leverageData.borrowAmount = amountForLeverage;
        leverageData.positionToken = IPToken(address(pWETHUSDC));
        leverageData.swapData.inputToken = _DAI_ADDRESS;
        leverageData.swapData.inputAmount = amountForLeverage;
        leverageData.swapData.outputToken = _WETH_ADDRESS;
        leverageData.swapData.target = address(veloRouter);
        IVeloRouter.Route[] memory routes = new IVeloRouter.Route[](2);
        routes[0].from = _DAI_ADDRESS;
        routes[0].to = _USDC_ADDRESS;
        routes[0].stable = true;
        routes[0].factory = address(veloPairFactory);
        routes[1].from = _USDC_ADDRESS;
        routes[1].to = _WETH_ADDRESS;
        routes[1].stable = false;
        routes[1].factory = address(veloPairFactory);
        leverageData.swapData.call = abi.encodeWithSelector(
            IVeloRouter.swapExactTokensForTokens.selector,
            amountForLeverage,
            0,
            routes,
            address(positionManagement),
            type(uint256).max
        );
        leverageData.swapData.slippage = 2e18;
        leverageData.auxData = abi.encode(0);

        positionManagement.leverage(leverageData, 0.05e18); // 5% slippage

        (uint256 eDAIBalance, uint256 eDAIBorrowed, ) = eDAI.getSnapshot(user);
        assertEq(eDAIBalance, 0);
        assertEq(eDAIBorrowed, 100 ether + amountForLeverage);

        (uint256 pWETHUSDCBalance, uint256 pWETHUSDCBorrowed, ) = pWETHUSDC
            .getSnapshot(user);
        assertGt(pWETHUSDCBalance, 0.000245 ether);
        assertEq(pWETHUSDCBorrowed, 0 ether);

        vm.stopPrank();
    }

    function testLeverageWithFeeEnabled() public {
        // 1% leverage fee
        centralRegistry.setProtocolLeverageFee(100);

        vm.startPrank(user);

        deal(_VELODROME_WETH_USDC, user, 0.0001 ether);
        IERC20(_VELODROME_WETH_USDC).approve(address(pWETHUSDC), 0.0001 ether);

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

        uint256 protocolBalanceBeforeLeverage = dai.balanceOf(
            centralRegistry.daoAddress()
        );
        uint256 leverageFee = FixedPointMathLib.mulDivUp(
            amountForLeverage,
            centralRegistry.protocolLeverageFee(),
            1e18
        );

        PositionManagementVelodrome.LeverageStruct memory leverageData;
        leverageData.borrowToken = IEToken(address(eDAI));
        leverageData.borrowAmount = amountForLeverage;
        leverageData.positionToken = IPToken(address(pWETHUSDC));
        leverageData.swapData.inputToken = _DAI_ADDRESS;
        leverageData.swapData.inputAmount = amountForLeverage - leverageFee;
        leverageData.swapData.outputToken = _WETH_ADDRESS;
        leverageData.swapData.target = address(veloRouter);
        IVeloRouter.Route[] memory routes = new IVeloRouter.Route[](2);
        routes[0].from = _DAI_ADDRESS;
        routes[0].to = _USDC_ADDRESS;
        routes[0].stable = true;
        routes[0].factory = address(veloPairFactory);
        routes[1].from = _USDC_ADDRESS;
        routes[1].to = _WETH_ADDRESS;
        routes[1].stable = false;
        routes[1].factory = address(veloPairFactory);
        leverageData.swapData.call = abi.encodeWithSelector(
            IVeloRouter.swapExactTokensForTokens.selector,
            amountForLeverage - leverageFee,
            0,
            routes,
            address(positionManagement),
            type(uint256).max
        );
        leverageData.swapData.slippage = 2e18;
        leverageData.auxData = abi.encode(0);

        positionManagement.leverage(leverageData, 0.05e18); // 5% slippage

        (uint256 eDAIBalance, uint256 eDAIBorrowed, ) = eDAI.getSnapshot(user);
        assertEq(eDAIBalance, 0);
        assertEq(eDAIBorrowed, 100 ether + amountForLeverage);

        (uint256 pWETHUSDCBalance, uint256 pWETHUSDCBorrowed, ) = pWETHUSDC
            .getSnapshot(user);
        assertGt(pWETHUSDCBalance, 0.00024 ether);
        assertEq(pWETHUSDCBorrowed, 0 ether);

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
        // Warp until collateral posting wait time ends
        vm.warp(block.timestamp + 20 minutes);
        eDAI.accrueInterest();

        vm.startPrank(user);

        PositionManagementVelodrome.DeleverageStruct memory deleverageData;

        (, uint256 eDAIBorrowedBefore, ) = eDAI.getSnapshot(user);
        (uint256 pUSDCDAIBalanceBefore, , ) = pWETHUSDC.getSnapshot(user);

        deleverageData.positionToken = IPToken(address(pWETHUSDC));
        deleverageData.collateralAmount = 0.00003 ether;
        deleverageData.borrowToken = IEToken(address(eDAI));

        deleverageData.swapData = new SwapperLib.Swap[](2);
        deleverageData.swapData[0].inputToken = _WETH_ADDRESS;
        deleverageData.swapData[0].inputAmount = 0.7413 ether;
        deleverageData.swapData[0].outputToken = _USDC_ADDRESS;
        deleverageData.swapData[0].target = address(veloRouter);
        deleverageData.swapData[0].slippage = 1e18;
        IVeloRouter.Route[] memory routes = new IVeloRouter.Route[](1);
        routes[0].from = _WETH_ADDRESS;
        routes[0].to = _USDC_ADDRESS;
        routes[0].stable = false;
        routes[0].factory = address(veloPairFactory);
        deleverageData.swapData[0].call = abi.encodeWithSelector(
            IVeloRouter.swapExactTokensForTokens.selector,
            0.7413 ether,
            0,
            routes,
            address(positionManagement),
            block.timestamp
        );

        deleverageData.swapData[1].inputToken = _USDC_ADDRESS;
        deleverageData.swapData[1].inputAmount = 2424e6;
        deleverageData.swapData[1].outputToken = _DAI_ADDRESS;
        deleverageData.swapData[1].target = address(veloRouter);
        deleverageData.swapData[1].slippage = 1e18;
        routes = new IVeloRouter.Route[](1);
        routes[0].from = _USDC_ADDRESS;
        routes[0].to = _DAI_ADDRESS;
        routes[0].stable = true;
        routes[0].factory = address(veloPairFactory);
        deleverageData.swapData[1].call = abi.encodeWithSelector(
            IVeloRouter.swapExactTokensForTokens.selector,
            2424e6,
            0,
            routes,
            address(positionManagement),
            block.timestamp
        );
        deleverageData.repayAmount = 2420e18;

        pWETHUSDC.approve(address(positionManagement), type(uint256).max);
        positionManagement.deleverage(deleverageData, 0.052e18); // 5.2% slippage

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

    function testDeLeverageWithFeeEnabled() public {
        testLeverage();
        // Warp until collateral posting wait time ends
        vm.warp(block.timestamp + 20 minutes);
        eDAI.accrueInterest();

        // 1% leverage fee
        centralRegistry.setProtocolLeverageFee(100);

        vm.startPrank(user);

        PositionManagementVelodrome.DeleverageStruct memory deleverageData;

        (, uint256 eDAIBorrowedBefore, ) = eDAI.getSnapshot(user);
        (uint256 pUSDCDAIBalanceBefore, , ) = pWETHUSDC.getSnapshot(user);

        uint256 collateralAmount = 0.00003 ether;
        uint256 leverageFee = collateralAmount / 100;
        uint256 protocolBalanceBeforeDeLeverage = IERC20(_VELODROME_WETH_USDC)
            .balanceOf(centralRegistry.daoAddress());

        deleverageData.positionToken = IPToken(address(pWETHUSDC));
        deleverageData.collateralAmount = collateralAmount;
        deleverageData.borrowToken = IEToken(address(eDAI));

        deleverageData.swapData = new SwapperLib.Swap[](2);
        deleverageData.swapData[0].inputToken = _WETH_ADDRESS;
        deleverageData.swapData[0].inputAmount = 0.733897 ether;
        deleverageData.swapData[0].outputToken = _USDC_ADDRESS;
        deleverageData.swapData[0].target = address(veloRouter);
        deleverageData.swapData[0].slippage = 1e18;
        IVeloRouter.Route[] memory routes = new IVeloRouter.Route[](1);
        routes[0].from = _WETH_ADDRESS;
        routes[0].to = _USDC_ADDRESS;
        routes[0].stable = false;
        routes[0].factory = address(veloPairFactory);
        deleverageData.swapData[0].call = abi.encodeWithSelector(
            IVeloRouter.swapExactTokensForTokens.selector,
            0.733897 ether,
            0,
            routes,
            address(positionManagement),
            block.timestamp
        );

        deleverageData.swapData[1].inputToken = _USDC_ADDRESS;
        deleverageData.swapData[1].inputAmount = 2400e6;
        deleverageData.swapData[1].outputToken = _DAI_ADDRESS;
        deleverageData.swapData[1].target = address(veloRouter);
        deleverageData.swapData[1].slippage = 1e18;
        routes = new IVeloRouter.Route[](1);
        routes[0].from = _USDC_ADDRESS;
        routes[0].to = _DAI_ADDRESS;
        routes[0].stable = true;
        routes[0].factory = address(veloPairFactory);
        deleverageData.swapData[1].call = abi.encodeWithSelector(
            IVeloRouter.swapExactTokensForTokens.selector,
            2400e6,
            0,
            routes,
            address(positionManagement),
            block.timestamp
        );
        deleverageData.repayAmount = 2402e6;

        pWETHUSDC.approve(address(positionManagement), type(uint256).max);
        positionManagement.deleverage(deleverageData, 0.5e18); // 5.2% slippage

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
        IERC20(_VELODROME_WETH_USDC).approve(address(pWETHUSDC), 0.0001 ether);

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

        PositionManagementVelodrome.LeverageStruct memory leverageData;
        leverageData.borrowToken = IEToken(address(eDAI));
        leverageData.borrowAmount = amountForLeverage;
        leverageData.positionToken = IPToken(address(pWETHUSDC));
        leverageData.swapData.inputToken = _DAI_ADDRESS;
        leverageData.swapData.inputAmount = amountForLeverage;
        leverageData.swapData.outputToken = _WETH_ADDRESS;
        leverageData.swapData.target = address(veloRouter);
        IVeloRouter.Route[] memory routes = new IVeloRouter.Route[](2);
        routes[0].from = _DAI_ADDRESS;
        routes[0].to = _USDC_ADDRESS;
        routes[0].stable = true;
        routes[0].factory = address(veloPairFactory);
        routes[1].from = _USDC_ADDRESS;
        routes[1].to = _WETH_ADDRESS;
        routes[1].stable = false;
        routes[1].factory = address(veloPairFactory);
        leverageData.swapData.call = abi.encodeWithSelector(
            IVeloRouter.swapExactTokensForTokens.selector,
            amountForLeverage,
            0,
            routes,
            address(positionManagement),
            type(uint256).max
        );
        leverageData.swapData.slippage = 2e18;
        leverageData.auxData = abi.encode(0);

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

        PositionManagementVelodrome.DeleverageStruct memory deleverageData;

        (, uint256 eDAIBorrowedBefore, ) = eDAI.getSnapshot(user);
        (uint256 pUSDCDAIBalanceBefore, , ) = pWETHUSDC.getSnapshot(user);

        deleverageData.positionToken = IPToken(address(pWETHUSDC));
        deleverageData.collateralAmount = 0.00003 ether;
        deleverageData.borrowToken = IEToken(address(eDAI));

        deleverageData.swapData = new SwapperLib.Swap[](2);
        deleverageData.swapData[0].inputToken = _WETH_ADDRESS;
        deleverageData.swapData[0].inputAmount = 0.7413 ether;
        deleverageData.swapData[0].outputToken = _USDC_ADDRESS;
        deleverageData.swapData[0].target = address(veloRouter);
        deleverageData.swapData[0].slippage = 1e18;
        IVeloRouter.Route[] memory routes = new IVeloRouter.Route[](1);
        routes[0].from = _WETH_ADDRESS;
        routes[0].to = _USDC_ADDRESS;
        routes[0].stable = false;
        routes[0].factory = address(veloPairFactory);
        deleverageData.swapData[0].call = abi.encodeWithSelector(
            IVeloRouter.swapExactTokensForTokens.selector,
            0.7413 ether,
            0,
            routes,
            address(positionManagement),
            block.timestamp
        );
        deleverageData.swapData[1].inputToken = _USDC_ADDRESS;
        deleverageData.swapData[1].inputAmount = 2424e6;
        deleverageData.swapData[1].outputToken = _DAI_ADDRESS;
        deleverageData.swapData[1].target = address(veloRouter);
        deleverageData.swapData[1].slippage = 1e18;
        routes = new IVeloRouter.Route[](1);
        routes[0].from = _USDC_ADDRESS;
        routes[0].to = _DAI_ADDRESS;
        routes[0].stable = true;
        routes[0].factory = address(veloPairFactory);
        deleverageData.swapData[1].call = abi.encodeWithSelector(
            IVeloRouter.swapExactTokensForTokens.selector,
            2424e6,
            0,
            routes,
            address(positionManagement),
            block.timestamp
        );
        deleverageData.repayAmount = 2420e18;

        pWETHUSDC.approve(address(positionManagement), type(uint256).max);
        positionManagement.setDelegateApproval(address(user2), true);
        vm.stopPrank();

        vm.prank(user2);
        positionManagement.deleverageFor(deleverageData, user, 0.052e18); // 5.2% slippage

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

        deal(_VELODROME_WETH_USDC, liquidityProvider, 1 ether);
        _prepareDAI(liquidityProvider, 20000000e18);

        vm.startPrank(liquidityProvider);

        // mint eDAI
        dai.approve(address(eDAI), 20000000 ether);
        eDAI.mint(20000000 ether);

        // mint pWETHUSDC
        IERC20(_VELODROME_WETH_USDC).approve(address(pWETHUSDC), 1 ether);
        pWETHUSDC.deposit(1 ether, liquidityProvider);

        vm.stopPrank();
    }
}
