// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";
import { VelodromeStablePToken } from "contracts/market/token/VelodromeStablePToken.sol";
import { VelodromeStableLPAdaptor } from "contracts/oracles/adaptors/velodrome/VelodromeStableLPAdaptor.sol";
import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { PositionManagementVelodrome } from "contracts/market/position-management/PositionManagementVelodrome.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IEToken } from "contracts/interfaces/IEToken.sol";
import { IPToken } from "contracts/interfaces/IPToken.sol";
import { IVeloGauge } from "contracts/interfaces/external/velodrome/IVeloGauge.sol";
import { IVeloRouter } from "contracts/interfaces/external/velodrome/IVeloRouter.sol";
import { IVeloPairFactory } from "contracts/interfaces/external/velodrome/IVeloPairFactory.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";

contract TestPositionManagementVelodromeStable is TestBaseMarket {
    address internal _VELODROME_DAI_USDC =
        0x19715771E30c93915A5bbDa134d782b81A820076;
    IVeloGauge public gauge =
        IVeloGauge(0x6998089F6bDd9c74C7D8d01b99d7e379ccCcb02D);
    IVeloPairFactory public veloPairFactory =
        IVeloPairFactory(0xF1046053aa5682b4F9a81b5481394DA16BE5FF5a);
    IVeloRouter public veloRouter =
        IVeloRouter(0xa062aE8A9c5e11aaA026fc2670B0D65cCc8B2858);

    VelodromeStablePToken public pUSDCDAI;
    VelodromeStableLPAdaptor public adaptor;
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

        adaptor = new VelodromeStableLPAdaptor(
            ICentralRegistry(address(centralRegistry))
        );
        adaptor.addAsset(_VELODROME_DAI_USDC);
        oracleManager.addApprovedAdaptor(address(adaptor));
        oracleManager.addAssetPriceFeed(_VELODROME_DAI_USDC, address(adaptor));

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

        // setup pUSDCDAI
        {
            pUSDCDAI = new VelodromeStablePToken(
                ICentralRegistry(address(centralRegistry)),
                IERC20(_VELODROME_DAI_USDC),
                address(marketManager),
                gauge,
                veloPairFactory,
                veloRouter
            );
            // add MToken support on price router
            oracleManager.addMTokenSupport(address(pUSDCDAI));

            deal(_VELODROME_DAI_USDC, owner, 1 ether);
            IERC20(_VELODROME_DAI_USDC).approve(address(pUSDCDAI), 1 ether);
            marketManager.listToken(address(pUSDCDAI));

            marketManager.updatePositionToken(
                address(pUSDCDAI),
                7000,
                4000,
                3000,
                200,
                400,
                1000
            );

            address[] memory tokens = new address[](1);
            tokens[0] = address(pUSDCDAI);
            uint256[] memory caps = new uint256[](1);
            caps[0] = 100_000e18;

            marketManager.setCollateralCaps(tokens, caps);
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

        deal(_VELODROME_DAI_USDC, user, 0.0001 ether);
        IERC20(_VELODROME_DAI_USDC).approve(address(pUSDCDAI), 0.0001 ether);

        // mint
        assertGt(pUSDCDAI.deposit(0.0001 ether, user), 0);
        marketManager.postCollateral(user, address(pUSDCDAI), 0.0001 ether);
        assertEq(pUSDCDAI.balanceOf(user), 0.0001 ether);

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
        leverageData.positionToken = IPToken(address(pUSDCDAI));
        leverageData.swapData.inputToken = _DAI_ADDRESS;
        leverageData.swapData.inputAmount = amountForLeverage;
        leverageData.swapData.outputToken = _USDC_ADDRESS;
        leverageData.swapData.target = address(veloRouter);
        leverageData.swapData.slippage = 50e16;
        IVeloRouter.Route[] memory routes = new IVeloRouter.Route[](1);
        routes[0].from = _DAI_ADDRESS;
        routes[0].to = _USDC_ADDRESS;
        routes[0].stable = true;
        routes[0].factory = address(veloPairFactory);
        leverageData.swapData.call = abi.encodeWithSelector(
            IVeloRouter.swapExactTokensForTokens.selector,
            amountForLeverage,
            0,
            routes,
            address(positionManagement),
            type(uint256).max
        );
        leverageData.auxData = abi.encode(0);

        positionManagement.leverage(leverageData, 0.05e18); // 5% slippage

        (uint256 eDAIBalance, uint256 eDAIBorrowed, ) = eDAI.getSnapshot(user);
        assertEq(eDAIBalance, 0);
        assertEq(eDAIBorrowed, 100 ether + amountForLeverage);

        (uint256 pUSDCDAIBalance, uint256 pUSDCDAIBorrowed, ) = pUSDCDAI
            .getSnapshot(user);
        assertGt(pUSDCDAIBalance, 0.00013 ether);
        assertEq(pUSDCDAIBorrowed, 0 ether);

        vm.stopPrank();
    }

    function testLeverageWithFeeEnabled() public {
        // 1% leverage fee
        centralRegistry.setProtocolLeverageFee(100);

        vm.startPrank(user);

        deal(_VELODROME_DAI_USDC, user, 0.0001 ether);
        IERC20(_VELODROME_DAI_USDC).approve(address(pUSDCDAI), 0.0001 ether);

        // mint
        assertGt(pUSDCDAI.deposit(0.0001 ether, user), 0);
        marketManager.postCollateral(user, address(pUSDCDAI), 0.0001 ether);
        assertEq(pUSDCDAI.balanceOf(user), 0.0001 ether);

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
        leverageData.positionToken = IPToken(address(pUSDCDAI));
        leverageData.swapData.inputToken = _DAI_ADDRESS;
        leverageData.swapData.inputAmount = amountForLeverage - leverageFee;
        leverageData.swapData.outputToken = _USDC_ADDRESS;
        leverageData.swapData.target = address(veloRouter);
        leverageData.swapData.slippage = 50e16;
        IVeloRouter.Route[] memory routes = new IVeloRouter.Route[](1);
        routes[0].from = _DAI_ADDRESS;
        routes[0].to = _USDC_ADDRESS;
        routes[0].stable = true;
        routes[0].factory = address(veloPairFactory);
        leverageData.swapData.call = abi.encodeWithSelector(
            IVeloRouter.swapExactTokensForTokens.selector,
            amountForLeverage - leverageFee,
            0,
            routes,
            address(positionManagement),
            type(uint256).max
        );
        leverageData.auxData = abi.encode(0);

        positionManagement.leverage(leverageData, 0.05e18); // 5% slippage

        (uint256 eDAIBalance, uint256 eDAIBorrowed, ) = eDAI.getSnapshot(user);
        assertEq(eDAIBalance, 0);
        assertEq(eDAIBorrowed, 100 ether + amountForLeverage);

        (uint256 pUSDCDAIBalance, uint256 pUSDCDAIBorrowed, ) = pUSDCDAI
            .getSnapshot(user);
        assertGt(pUSDCDAIBalance, 0.00013 ether);
        assertEq(pUSDCDAIBorrowed, 0 ether);

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
        (uint256 pUSDCDAIBalanceBefore, , ) = pUSDCDAI.getSnapshot(user);

        deleverageData.positionToken = IPToken(address(pUSDCDAI));
        deleverageData.collateralAmount = 0.00003 ether;
        deleverageData.borrowToken = IEToken(address(eDAI));

        uint256 usdcAmount = 27451772;
        deleverageData.swapData = new SwapperLib.Swap[](1);
        deleverageData.swapData[0].inputToken = _USDC_ADDRESS;
        deleverageData.swapData[0].inputAmount = usdcAmount;
        deleverageData.swapData[0].outputToken = _DAI_ADDRESS;
        deleverageData.swapData[0].target = address(veloRouter);
        deleverageData.swapData[0].slippage = 50e16;
        IVeloRouter.Route[] memory routes = new IVeloRouter.Route[](1);
        routes[0].from = _USDC_ADDRESS;
        routes[0].to = _DAI_ADDRESS;
        routes[0].stable = true;
        routes[0].factory = address(veloPairFactory);
        deleverageData.swapData[0].call = abi.encodeWithSelector(
            IVeloRouter.swapExactTokensForTokens.selector,
            usdcAmount,
            0,
            routes,
            address(positionManagement),
            type(uint256).max
        );
        deleverageData.repayAmount = 60e18;

        pUSDCDAI.approve(address(positionManagement), type(uint256).max);
        positionManagement.deleverage(deleverageData, 0.05e18); // 5% slippage

        (uint256 eDAIBalance, uint256 eDAIBorrowed, ) = eDAI.getSnapshot(user);
        assertEq(eDAIBalance, 0);
        assertEq(
            eDAIBorrowed,
            eDAIBorrowedBefore - deleverageData.repayAmount
        );

        (uint256 pUSDCDAIBalance, uint256 pUSDCDAIBorrowed, ) = pUSDCDAI
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
        (uint256 pUSDCDAIBalanceBefore, , ) = pUSDCDAI.getSnapshot(user);

        uint256 collateralAmount = 0.00003 ether;
        uint256 leverageFee = collateralAmount / 100;
        uint256 protocolBalanceBeforeDeLeverage = IERC20(_VELODROME_DAI_USDC)
            .balanceOf(centralRegistry.daoAddress());

        deleverageData.positionToken = IPToken(address(pUSDCDAI));
        deleverageData.collateralAmount = collateralAmount;
        deleverageData.borrowToken = IEToken(address(eDAI));

        uint256 usdcAmount = 27177254;
        deleverageData.swapData = new SwapperLib.Swap[](1);
        deleverageData.swapData[0].inputToken = _USDC_ADDRESS;
        deleverageData.swapData[0].inputAmount = usdcAmount;
        deleverageData.swapData[0].outputToken = _DAI_ADDRESS;
        deleverageData.swapData[0].target = address(veloRouter);
        deleverageData.swapData[0].slippage = 50e16;
        IVeloRouter.Route[] memory routes = new IVeloRouter.Route[](1);
        routes[0].from = _USDC_ADDRESS;
        routes[0].to = _DAI_ADDRESS;
        routes[0].stable = true;
        routes[0].factory = address(veloPairFactory);
        deleverageData.swapData[0].call = abi.encodeWithSelector(
            IVeloRouter.swapExactTokensForTokens.selector,
            usdcAmount,
            0,
            routes,
            address(positionManagement),
            type(uint256).max
        );
        deleverageData.repayAmount = 59.3e18;

        pUSDCDAI.approve(address(positionManagement), type(uint256).max);
        positionManagement.deleverage(deleverageData, 0.05e18); // 5% slippage

        (uint256 eDAIBalance, uint256 eDAIBorrowed, ) = eDAI.getSnapshot(user);
        assertEq(eDAIBalance, 0);
        assertEq(
            eDAIBorrowed,
            eDAIBorrowedBefore - deleverageData.repayAmount
        );

        (uint256 pUSDCDAIBalance, uint256 pUSDCDAIBorrowed, ) = pUSDCDAI
            .getSnapshot(user);
        assertEq(
            pUSDCDAIBalance,
            pUSDCDAIBalanceBefore - deleverageData.collateralAmount
        );
        assertEq(pUSDCDAIBorrowed, 0);

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
        IERC20(_VELODROME_DAI_USDC).approve(address(pUSDCDAI), 0.0001 ether);

        // mint
        assertGt(pUSDCDAI.deposit(0.0001 ether, user), 0);
        marketManager.postCollateral(user, address(pUSDCDAI), 0.0001 ether);
        assertEq(pUSDCDAI.balanceOf(user), 0.0001 ether);

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
        leverageData.positionToken = IPToken(address(pUSDCDAI));
        leverageData.swapData.inputToken = _DAI_ADDRESS;
        leverageData.swapData.inputAmount = amountForLeverage;
        leverageData.swapData.outputToken = _USDC_ADDRESS;
        leverageData.swapData.target = address(veloRouter);
        leverageData.swapData.slippage = 50e16;
        IVeloRouter.Route[] memory routes = new IVeloRouter.Route[](1);
        routes[0].from = _DAI_ADDRESS;
        routes[0].to = _USDC_ADDRESS;
        routes[0].stable = true;
        routes[0].factory = address(veloPairFactory);
        leverageData.swapData.call = abi.encodeWithSelector(
            IVeloRouter.swapExactTokensForTokens.selector,
            amountForLeverage,
            0,
            routes,
            address(positionManagement),
            type(uint256).max
        );
        leverageData.auxData = abi.encode(0);

        positionManagement.setDelegateApproval(address(user2), true);
        vm.stopPrank();

        vm.prank(user2);
        positionManagement.leverageFor(leverageData, user, 0.05e18); // 5% slippage

        (uint256 eDAIBalance, uint256 eDAIBorrowed, ) = eDAI.getSnapshot(user);
        assertEq(eDAIBalance, 0);
        assertEq(eDAIBorrowed, 100 ether + amountForLeverage);

        (uint256 pUSDCDAIBalance, uint256 pUSDCDAIBorrowed, ) = pUSDCDAI
            .getSnapshot(user);
        assertGt(pUSDCDAIBalance, 0.00013 ether);
        assertEq(pUSDCDAIBorrowed, 0 ether);

        vm.stopPrank();
    }

    function testDeLeverageFor() public {
        testLeverage();
        // Warp until collateral posting wait time ends
        vm.warp(block.timestamp + 20 minutes);
        eDAI.accrueInterest();

        vm.startPrank(user);

        PositionManagementVelodrome.DeleverageStruct memory deleverageData;

        (, uint256 eDAIBorrowedBefore, ) = eDAI.getSnapshot(user);
        (uint256 pUSDCDAIBalanceBefore, , ) = pUSDCDAI.getSnapshot(user);

        deleverageData.positionToken = IPToken(address(pUSDCDAI));
        deleverageData.collateralAmount = 0.00003 ether;
        deleverageData.borrowToken = IEToken(address(eDAI));

        uint256 usdcAmount = 27451772;
        deleverageData.swapData = new SwapperLib.Swap[](1);
        deleverageData.swapData[0].inputToken = _USDC_ADDRESS;
        deleverageData.swapData[0].inputAmount = usdcAmount;
        deleverageData.swapData[0].outputToken = _DAI_ADDRESS;
        deleverageData.swapData[0].target = address(veloRouter);
        deleverageData.swapData[0].slippage = 50e16;
        IVeloRouter.Route[] memory routes = new IVeloRouter.Route[](1);
        routes[0].from = _USDC_ADDRESS;
        routes[0].to = _DAI_ADDRESS;
        routes[0].stable = true;
        routes[0].factory = address(veloPairFactory);
        deleverageData.swapData[0].call = abi.encodeWithSelector(
            IVeloRouter.swapExactTokensForTokens.selector,
            usdcAmount,
            0,
            routes,
            address(positionManagement),
            type(uint256).max
        );
        deleverageData.repayAmount = 60e18;

        pUSDCDAI.approve(address(positionManagement), type(uint256).max);
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

        (uint256 pUSDCDAIBalance, uint256 pUSDCDAIBorrowed, ) = pUSDCDAI
            .getSnapshot(user);
        assertEq(
            pUSDCDAIBalance,
            pUSDCDAIBalanceBefore - deleverageData.collateralAmount
        );
        assertEq(pUSDCDAIBorrowed, 0);
    }

    function _provideEnoughLiquidityForLeverage() internal {
        address liquidityProvider = makeAddr("liquidityProvider");

        deal(_VELODROME_DAI_USDC, liquidityProvider, 1 ether);
        _prepareDAI(liquidityProvider, 20000000e18);

        vm.startPrank(liquidityProvider);

        // mint eDAI
        dai.approve(address(eDAI), 20000000 ether);
        eDAI.mint(20000000 ether);

        // mint pUSDCDAI
        IERC20(_VELODROME_DAI_USDC).approve(address(pUSDCDAI), 1 ether);
        pUSDCDAI.deposit(1 ether, liquidityProvider);

        vm.stopPrank();
    }
}
