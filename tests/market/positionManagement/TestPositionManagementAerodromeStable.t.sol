// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { AerodromeStablePToken } from "contracts/market/token/AerodromeStablePToken.sol";
import { VelodromeStableLPAdaptor } from "contracts/oracles/adaptors/velodrome/VelodromeStableLPAdaptor.sol";
import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { PositionManagementAerodrome } from "contracts/market/position-management/PositionManagementAerodrome.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IEToken } from "contracts/interfaces/IEToken.sol";
import { IPToken } from "contracts/interfaces/IPToken.sol";
import { IVeloGauge } from "contracts/interfaces/external/velodrome/IVeloGauge.sol";
import { IVeloRouter } from "contracts/interfaces/external/velodrome/IVeloRouter.sol";
import { IVeloPairFactory } from "contracts/interfaces/external/velodrome/IVeloPairFactory.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

contract TestPositionManagementAerodromeStable is TestBaseMarketIsolated {
    address internal _AERODROME_DAI_USDC =
        0x67b00B46FA4f4F24c03855c5C8013C0B938B3eEc;
    IVeloGauge public gauge =
        IVeloGauge(0x640e9ef68e1353112fF18826c4eDa844E1dC5eD0);
    IVeloPairFactory public aeroPairFactory =
        IVeloPairFactory(0x420DD381b31aEf6683db6B902084cB0FFECe40Da);
    IVeloRouter public aeroRouter =
        IVeloRouter(0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43);

    IERC20 public aerodromeDAIUSDC;
    AerodromeStablePToken public pUSDCDAI;
    VelodromeStableLPAdaptor public adaptor;
    PositionManagementAerodrome public positionManagement;

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

        // setup eDAI
        {
            _deployEDAI();
            // add MToken support on price router
            oracleManager.addMTokenSupport(address(eDAI));

            _prepareDAI(owner, 200000e18);
            dai.approve(address(eDAI), 200000e18);
            marketManagerIsolated.listToken(address(eDAI));
        }

        // setup pUSDCDAI
        {
            pUSDCDAI = new AerodromeStablePToken(
                ICentralRegistry(address(centralRegistry)),
                IERC20(_AERODROME_DAI_USDC),
                address(marketManagerIsolated),
                gauge,
                aeroPairFactory,
                aeroRouter
            );
            // add MToken support on price router
            oracleManager.addMTokenSupport(address(pUSDCDAI));

            deal(_AERODROME_DAI_USDC, owner, 1 ether);
            IERC20(_AERODROME_DAI_USDC).approve(address(pUSDCDAI), 1 ether);
            marketManagerIsolated.listToken(address(pUSDCDAI));

            marketManagerIsolated.updatePositionToken(
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

            marketManagerIsolated.setCollateralCaps(tokens, caps);
        }

        positionManagement = new PositionManagementAerodrome(
            ICentralRegistry(address(centralRegistry)),
            address(marketManagerIsolated),
            _WETH_ADDRESS,
            address(aeroRouter),
            address(aeroPairFactory)
        );
        marketManagerIsolated.addPositionManager(address(positionManagement));

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
            address(marketManagerIsolated)
        );
    }

    function testLeverage() public {
        vm.startPrank(user);

        deal(_AERODROME_DAI_USDC, user, 0.0001 ether);
        IERC20(_AERODROME_DAI_USDC).approve(address(pUSDCDAI), 0.0001 ether);

        // mint
        assertGt(pUSDCDAI.deposit(0.0001 ether, user), 0);
        pUSDCDAI.postCollateral(0.0001 ether);
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

        PositionManagementAerodrome.LeverageStruct memory leverageData;
        leverageData.borrowToken = IEToken(address(eDAI));
        leverageData.borrowAmount = amountForLeverage;
        leverageData.positionToken = IPToken(address(pUSDCDAI));
        leverageData.swapData.inputToken = address(0x0);
        leverageData.swapData.inputAmount = 0;
        leverageData.swapData.outputToken = address(0x0);
        leverageData.swapData.target = address(0x0);
        leverageData.swapData.slippage = 0;
        leverageData.swapData.call = bytes("");
        leverageData.auxData = abi.encode(0);

        positionManagement.leverage(leverageData, 0.05e18); // 5% slippage

        (,,,, uint256 eDAIBorrowed, ) = eDAI.getSnapshot(user);
        assertEq(eDAI.balanceOf(user), 0);
        assertEq(eDAIBorrowed, 100 ether + amountForLeverage);

        (,,,, uint256 pUSDCDAIBorrowed, ) = pUSDCDAI.getSnapshot(user);
        assertGt(pUSDCDAI.balanceOf(user), 0.00013 ether);
        assertEq(pUSDCDAIBorrowed, 0 ether);

        vm.stopPrank();
    }

    function testDepositAndLeverage() public {
        vm.startPrank(user);

        deal(_AERODROME_DAI_USDC, user, 0.0001 ether);
        IERC20(_AERODROME_DAI_USDC).approve(
            address(positionManagement),
            0.0001 ether
        );

        // allow delegation for postCollateral
        pUSDCDAI.setDelegateApproval(address(positionManagement), true);

        // try leverage with 50% of max
        uint256 amountForLeverage = 0.66e20;

        PositionManagementAerodrome.LeverageStruct memory leverageData;
        leverageData.borrowToken = IEToken(address(eDAI));
        leverageData.borrowAmount = amountForLeverage;
        leverageData.positionToken = IPToken(address(pUSDCDAI));
        leverageData.swapData.inputToken = address(0x0);
        leverageData.swapData.inputAmount = 0;
        leverageData.swapData.outputToken = address(0x0);
        leverageData.swapData.target = address(0x0);
        leverageData.swapData.slippage = 0;
        leverageData.swapData.call = bytes("");
        leverageData.auxData = abi.encode(0);

        positionManagement.depositAndLeverage(
            0.0001 ether,
            leverageData,
            0.05e18
        ); // 5% slippage

        (,,,, uint256 eDAIBorrowed, ) = eDAI.getSnapshot(user);
        assertEq(eDAI.balanceOf(user), 0);
        assertEq(eDAIBorrowed, amountForLeverage);

        (,,,, uint256 pUSDCDAIBorrowed, ) = pUSDCDAI.getSnapshot(user);
        assertGt(pUSDCDAI.balanceOf(user), 0.00013 ether);
        assertEq(pUSDCDAIBorrowed, 0 ether);

        vm.stopPrank();
    }

    function testDepositAndLeverageMaxWithExistingPosition() public {
        vm.startPrank(user);

        // deposit and borrow (~1k collateral and 500 debt)
        deal(_AERODROME_DAI_USDC, user, 0.001 ether);
        IERC20(_AERODROME_DAI_USDC).approve(address(pUSDCDAI), 0.001 ether);
        pUSDCDAI.deposit(0.001 ether, user);
        pUSDCDAI.postCollateral(0.001 ether);
        assertEq(pUSDCDAI.balanceOf(user), 0.001 ether);
        uint256 balanceBeforeBorrow = dai.balanceOf(user);
        eDAI.borrow(500 ether);
        assertEq(balanceBeforeBorrow + 500 ether, dai.balanceOf(user));

        // deposit and leverage
        deal(_AERODROME_DAI_USDC, user, 0.001 ether);
        IERC20(_AERODROME_DAI_USDC).approve(
            address(positionManagement),
            0.001 ether
        );

        // allow delegation for postCollateral
        pUSDCDAI.setDelegateApproval(address(positionManagement), true);

        // try max leverage
        uint256 amountForLeverage = positionManagement.maxRemainingLeverageOf(
            user,
            address(eDAI)
        );

        PositionManagementAerodrome.LeverageStruct memory leverageData;
        leverageData.borrowToken = IEToken(address(eDAI));
        leverageData.borrowAmount = amountForLeverage;
        leverageData.positionToken = IPToken(address(pUSDCDAI));
        leverageData.swapData.inputToken = address(0x0);
        leverageData.swapData.inputAmount = 0;
        leverageData.swapData.outputToken = address(0x0);
        leverageData.swapData.target = address(0x0);
        leverageData.swapData.slippage = 0;
        leverageData.swapData.call = bytes("");
        leverageData.auxData = abi.encode(0);

        positionManagement.depositAndLeverage(
            0.001 ether,
            leverageData,
            0.05e18 // 5% slippage
        );

        (,,,, uint256 eDAIBorrowed, ) = eDAI.getSnapshot(user);
        assertEq(eDAI.balanceOf(user), 0);
        assertEq(eDAIBorrowed, amountForLeverage + 500 ether);

        (,,,, uint256 pUSDCDAIBorrowed, ) = pUSDCDAI.getSnapshot(user);
        assertGt(pUSDCDAI.balanceOf(user), 0.0034 ether);
        assertEq(pUSDCDAIBorrowed, 0 ether);

        vm.stopPrank();
    }

    function testDepositAndLeverageHalfOfMaxWithExistingPosition() public {
        vm.startPrank(user);

        // deposit and borrow (~1k collateral and 500 debt)
        deal(_AERODROME_DAI_USDC, user, 0.001 ether);
        IERC20(_AERODROME_DAI_USDC).approve(address(pUSDCDAI), 0.001 ether);
        pUSDCDAI.deposit(0.001 ether, user);
        pUSDCDAI.postCollateral(0.001 ether);
        assertEq(pUSDCDAI.balanceOf(user), 0.001 ether);
        uint256 balanceBeforeBorrow = dai.balanceOf(user);
        eDAI.borrow(500 ether);
        assertEq(balanceBeforeBorrow + 500 ether, dai.balanceOf(user));

        // deposit and leverage
        deal(_AERODROME_DAI_USDC, user, 0.001 ether);
        IERC20(_AERODROME_DAI_USDC).approve(
            address(positionManagement),
            0.001 ether
        );

        // allow delegation for postCollateral
        pUSDCDAI.setDelegateApproval(address(positionManagement), true);

        // try half of max leverage
        uint256 amountForLeverage = positionManagement.maxRemainingLeverageOf(
            user,
            address(eDAI)
        ) / 2;

        PositionManagementAerodrome.LeverageStruct memory leverageData;
        leverageData.borrowToken = IEToken(address(eDAI));
        leverageData.borrowAmount = amountForLeverage;
        leverageData.positionToken = IPToken(address(pUSDCDAI));
        leverageData.swapData.inputToken = address(0x0);
        leverageData.swapData.inputAmount = 0;
        leverageData.swapData.outputToken = address(0x0);
        leverageData.swapData.target = address(0x0);
        leverageData.swapData.slippage = 0;
        leverageData.swapData.call = bytes("");
        leverageData.auxData = abi.encode(0);

        positionManagement.depositAndLeverage(
            0.001 ether,
            leverageData,
            0.05e18 // 5% slippage
        );

        (,,,, uint256 eDAIBorrowed, ) = eDAI.getSnapshot(user);
        assertEq(eDAI.balanceOf(user), 0);
        assertEq(eDAIBorrowed, amountForLeverage + 500 ether);

        (,,,, uint256 pUSDCDAIBorrowed, ) = pUSDCDAI.getSnapshot(user);
        assertGt(pUSDCDAI.balanceOf(user), 0.0027 ether);
        assertEq(pUSDCDAIBorrowed, 0 ether);

        vm.stopPrank();
    }

    function testDeLeverage() public {
        testLeverage();
        // Warp until collateral posting wait time ends
        vm.warp(block.timestamp + 20 minutes);
        eDAI.accrueInterest();

        vm.startPrank(user);

        PositionManagementAerodrome.DeleverageStruct memory deleverageData;

        (,,,, uint256 eDAIBorrowedBefore, ) = eDAI.getSnapshot(user);
        uint256 pUSDCDAIBalanceBefore = pUSDCDAI.balanceOf(user);

        deleverageData.positionToken = IPToken(address(pUSDCDAI));
        deleverageData.collateralAmount = 0.00003 ether;
        deleverageData.borrowToken = IEToken(address(eDAI));

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
            address(positionManagement),
            block.timestamp
        );
        deleverageData.repayAmount = 59.56e18;

        pUSDCDAI.approve(address(positionManagement), type(uint256).max);
        positionManagement.deleverage(deleverageData, 0.05e18); // 5% slippage

        (,,,, uint256 eDAIBorrowed, ) = eDAI.getSnapshot(user);
        assertEq(eDAI.balanceOf(user), 0);
        assertEq(
            eDAIBorrowed,
            eDAIBorrowedBefore - deleverageData.repayAmount
        );

        (,,,, uint256 pUSDCDAIBorrowed, ) = pUSDCDAI.getSnapshot(user);
        assertEq(
            pUSDCDAI.balanceOf(user),
            pUSDCDAIBalanceBefore - deleverageData.collateralAmount
        );
        assertEq(pUSDCDAIBorrowed, 0);

        vm.stopPrank();
    }

    function testLeverageFor() public {
        vm.startPrank(user);

        deal(_AERODROME_DAI_USDC, user, 0.0001 ether);
        IERC20(_AERODROME_DAI_USDC).approve(address(pUSDCDAI), 0.0001 ether);

        // mint
        assertGt(pUSDCDAI.deposit(0.0001 ether, user), 0);
        pUSDCDAI.postCollateral(0.0001 ether);
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
        PositionManagementAerodrome.LeverageStruct memory leverageData;
        leverageData.borrowToken = IEToken(address(eDAI));
        leverageData.borrowAmount = amountForLeverage;
        leverageData.positionToken = IPToken(address(pUSDCDAI));
        leverageData.swapData.inputToken = address(0x0);
        leverageData.swapData.inputAmount = 0;
        leverageData.swapData.outputToken = address(0x0);
        leverageData.swapData.target = address(0x0);
        leverageData.swapData.slippage = 0;
        leverageData.swapData.call = bytes("");
        leverageData.auxData = abi.encode(0);

        positionManagement.setDelegateApproval(address(user2), true);
        vm.stopPrank();

        vm.prank(user2);
        positionManagement.leverageFor(leverageData, user, 0.05e18); // 5% slippage

        (,,,, uint256 eDAIBorrowed, ) = eDAI.getSnapshot(user);
        assertEq(eDAI.balanceOf(user), 0);
        assertEq(eDAIBorrowed, 100 ether + amountForLeverage);

        (,,,, uint256 pUSDCDAIBorrowed, ) = pUSDCDAI.getSnapshot(user);
        assertGt(pUSDCDAI.balanceOf(user), 0.00013 ether);
        assertEq(pUSDCDAIBorrowed, 0 ether);
    }

    function testDeLeverageFor() public {
        testLeverage();
        // Warp until collateral posting wait time ends
        vm.warp(block.timestamp + 20 minutes);
        eDAI.accrueInterest();

        vm.startPrank(user);

        PositionManagementAerodrome.DeleverageStruct memory deleverageData;

        (,,,, uint256 eDAIBorrowedBefore, ) = eDAI.getSnapshot(user);
        uint256 pUSDCDAIBalanceBefore = pUSDCDAI.balanceOf(user);

        deleverageData.positionToken = IPToken(address(pUSDCDAI));
        deleverageData.collateralAmount = 0.00003 ether;
        deleverageData.borrowToken = IEToken(address(eDAI));

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
            address(positionManagement),
            block.timestamp
        );
        deleverageData.repayAmount = 59.56e18;

        pUSDCDAI.approve(address(positionManagement), type(uint256).max);
        positionManagement.setDelegateApproval(address(user2), true);
        vm.stopPrank();

        vm.prank(user2);
        positionManagement.deleverageFor(deleverageData, user, 0.05e18); // 5% slippage

        (,,,, uint256 eDAIBorrowed, ) = eDAI.getSnapshot(user);
        assertEq(eDAI.balanceOf(user), 0);
        assertEq(
            eDAIBorrowed,
            eDAIBorrowedBefore - deleverageData.repayAmount
        );

        (,,,, uint256 pUSDCDAIBorrowed, ) = pUSDCDAI.getSnapshot(user);
        assertEq(
            pUSDCDAI.balanceOf(user),
            pUSDCDAIBalanceBefore - deleverageData.collateralAmount
        );
        assertEq(pUSDCDAIBorrowed, 0);

        vm.stopPrank();
    }

    function _provideEnoughLiquidityForLeverage() internal {
        address liquidityProvider = makeAddr("liquidityProvider");

        deal(_AERODROME_DAI_USDC, liquidityProvider, 1 ether);
        _prepareDAI(liquidityProvider, 20000000e18);

        vm.startPrank(liquidityProvider);

        // mint eDAI
        dai.approve(address(eDAI), 20000000 ether);
        eDAI.mint(20000000 ether);

        // mint pUSDCDAI
        IERC20(_AERODROME_DAI_USDC).approve(address(pUSDCDAI), 1 ether);
        pUSDCDAI.deposit(1 ether, liquidityProvider);

        vm.stopPrank();
    }
}
