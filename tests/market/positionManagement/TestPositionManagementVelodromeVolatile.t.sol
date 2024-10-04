// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { VelodromeVolatileCToken, IVeloGauge, IVeloRouter, IVeloPairFactory, IERC20 } from "contracts/market/collateral/VelodromeVolatileCToken.sol";
import { VelodromeVolatileLPAdaptor } from "contracts/oracles/adaptors/velodrome/VelodromeVolatileLPAdaptor.sol";
import { MockCallDataChecker } from "contracts/mocks/MockCallDataChecker.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { PositionManagementVelodromeVolatile } from "contracts/market/position-management/PositionManagementVelodromeVolatile.sol";
import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { IMToken } from "contracts/market/LiquidityManager.sol";
import { CTokenPrimitive } from "contracts/market/collateral/CTokenPrimitive.sol";

contract TestPositionManagementVelodromeVolatile is TestBaseMarket {
    address internal _VELODROME_WETH_USDC =
        0x0493Bf8b6DBB159Ce2Db2E0E8403E753Abd1235b;
    IVeloGauge public gauge =
        IVeloGauge(0xE7630c9560C59CCBf5EEd8f33dd0ccA2E67a3981);
    IVeloPairFactory public veloPairFactory =
        IVeloPairFactory(0xF1046053aa5682b4F9a81b5481394DA16BE5FF5a);
    IVeloRouter public veloRouter =
        IVeloRouter(0xa062aE8A9c5e11aaA026fc2670B0D65cCc8B2858);

    VelodromeVolatileCToken public cWETHUSDC;
    VelodromeVolatileLPAdaptor public adaptor;
    PositionManagementVelodromeVolatile public positionManagement;

    address public owner;
    address public user;

    receive() external payable {}

    fallback() external payable {}

    function _provideEnoughLiquidityForLeverage() internal {
        address liquidityProvider = makeAddr("liquidityProvider");

        deal(_VELODROME_WETH_USDC, liquidityProvider, 1 ether);
        _prepareDAI(liquidityProvider, 20000000e18);

        vm.startPrank(liquidityProvider);

        // mint dDAI
        dai.approve(address(dDAI), 20000000 ether);
        dDAI.mint(20000000 ether);

        // mint cWETHUSDC
        IERC20(_VELODROME_WETH_USDC).approve(address(cWETHUSDC), 1 ether);
        cWETHUSDC.deposit(1 ether, liquidityProvider);

        vm.stopPrank();
    }

    function setUp() public override {
        _fork("ETH_NODE_URI_OPTIMISM", 109095500);

        _deployCentralRegistry();
        _deployCVE();
        _deployRewardManager();
        _deployVeCVE();
        _deployGaugeManager();
        _deployMarketManager();
        _deployOracleRouter();
        _deployDynamicInterestRateModel();

        chainlinkAdaptor = new ChainlinkAdaptor(
            ICentralRegistry(address(centralRegistry))
        );
        oracleRouter.addApprovedAdaptor(address(chainlinkAdaptor));

        chainlinkDaiUsd = new MockV3Aggregator(8, 1e8, 1e50, 1e6);
        chainlinkAdaptor.addAsset(
            _DAI_ADDRESS,
            address(chainlinkDaiUsd),
            0,
            true
        );
        oracleRouter.addAssetPriceFeed(
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
        oracleRouter.addAssetPriceFeed(
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
        oracleRouter.addAssetPriceFeed(
            _ETH_ADDRESS,
            address(chainlinkAdaptor)
        );
        oracleRouter.addAssetPriceFeed(
            _WETH_ADDRESS,
            address(chainlinkAdaptor)
        );

        adaptor = new VelodromeVolatileLPAdaptor(
            ICentralRegistry(address(centralRegistry))
        );
        adaptor.addAsset(_VELODROME_WETH_USDC);
        oracleRouter.addApprovedAdaptor(address(adaptor));
        oracleRouter.addAssetPriceFeed(_VELODROME_WETH_USDC, address(adaptor));

        owner = address(this);
        user = user1;

        // setup dDAI
        {
            _deployDDAI();
            // add MToken support on price router
            oracleRouter.addMTokenSupport(address(dDAI));

            _prepareDAI(owner, 200000e18);
            dai.approve(address(dDAI), 200000e18);
            marketManager.listToken(address(dDAI));
        }

        // setup cWETHUSDC
        {
            cWETHUSDC = new VelodromeVolatileCToken(
                ICentralRegistry(address(centralRegistry)),
                IERC20(_VELODROME_WETH_USDC),
                address(marketManager),
                gauge,
                veloPairFactory,
                veloRouter
            );
            // add MToken support on price router
            oracleRouter.addMTokenSupport(address(cWETHUSDC));

            deal(_VELODROME_WETH_USDC, owner, 1 ether);
            IERC20(_VELODROME_WETH_USDC).approve(address(cWETHUSDC), 1 ether);
            marketManager.listToken(address(cWETHUSDC));

            marketManager.updateCollateralToken(
                IMToken(address(cWETHUSDC)),
                7000,
                4000,
                3000,
                200,
                400,
                10,
                1000
            );
            
            address[] memory tokens = new address[](1);
            tokens[0] = address(cWETHUSDC);
            uint256[] memory caps = new uint256[](1);
            caps[0] = 100_000e18;

            marketManager.setCTokenCollateralCaps(tokens, caps);
        }

        positionManagement = new PositionManagementVelodromeVolatile(
            ICentralRegistry(address(centralRegistry)),
            address(marketManager),
            address(veloRouter),
            address(veloPairFactory)
        );
        marketManager.setPositionManagement(address(positionManagement));

        _provideEnoughLiquidityForLeverage();

        centralRegistry.setExternalCallDataChecker(
            _UNISWAP_V2_ROUTER,
            address(new MockCallDataChecker(_UNISWAP_V2_ROUTER))
        );

        centralRegistry.setExternalCallDataChecker(
            address(veloRouter),
            address(new MockCallDataChecker(address(veloRouter)))
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

        deal(_VELODROME_WETH_USDC, user, 0.0001 ether);
        IERC20(_VELODROME_WETH_USDC).approve(address(cWETHUSDC), 0.0001 ether);

        // mint
        assertGt(cWETHUSDC.deposit(0.0001 ether, user), 0);
        marketManager.postCollateral(user, address(cWETHUSDC), 0.0001 ether);
        assertEq(cWETHUSDC.balanceOf(user), 0.0001 ether);

        uint256 balanceBeforeBorrow = dai.balanceOf(user);
        // borrow
        dDAI.borrow(100 ether);
        assertEq(balanceBeforeBorrow + 100 ether, dai.balanceOf(user));

        // try leverage with 50% of max
        uint256 amountForLeverage = (positionManagement
            .queryAmountToBorrowForLeverageMax(user, address(dDAI)) * 50) /
            100;

        PositionManagementVelodromeVolatile.LeverageStruct memory leverageData;
        leverageData.borrowToken = dDAI;
        leverageData.borrowAmount = amountForLeverage;
        leverageData.collateralToken = CTokenPrimitive(address(cWETHUSDC));
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
        leverageData.data = bytes("");

        positionManagement.leverage(leverageData, 500);

        (uint256 dDAIBalance, uint256 dDAIBorrowed, ) = dDAI.getSnapshot(user);
        assertEq(dDAIBalance, 0);
        assertEq(dDAIBorrowed, 100 ether + amountForLeverage);

        (uint256 cUSDCDAIBalance, uint256 cUSDCDAIBorrowed, ) = cWETHUSDC
            .getSnapshot(user);
        assertGt(cUSDCDAIBalance, 0.00013 ether);
        assertEq(cUSDCDAIBorrowed, 0 ether);

        vm.stopPrank();
    }

    function testDeLeverage() public {
        testLeverage();
        // Warp until collateral posting wait time ends
        vm.warp(block.timestamp + 20 minutes);
        dDAI.accrueInterest();

        vm.startPrank(user);

        PositionManagementVelodromeVolatile.DeleverageStruct memory deleverageData;

        (, uint256 dDAIBorrowedBefore, ) = dDAI.getSnapshot(user);
        (uint256 cUSDCDAIBalanceBefore, , ) = cWETHUSDC.getSnapshot(user);

        deleverageData.collateralToken = CTokenPrimitive(address(cWETHUSDC));
        deleverageData.collateralAmount = 0.00003 ether;
        deleverageData.borrowToken = dDAI;

        deleverageData.swapData = new SwapperLib.Swap[](2);
        deleverageData.swapData[0].inputToken = _WETH_ADDRESS;
        deleverageData.swapData[0].inputAmount = 0.7 ether;
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
            0.7 ether,
            0,
            routes,
            address(positionManagement),
            block.timestamp
        );
        deleverageData.swapData[1].inputToken = _USDC_ADDRESS;
        deleverageData.swapData[1].inputAmount = 2300e6;
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
            2300e6,
            0,
            routes,
            address(positionManagement),
            block.timestamp
        );
        deleverageData.repayAmount = 2300e18;

        cWETHUSDC.approve(address(positionManagement), type(uint256).max);
        positionManagement.deleverage(deleverageData, 5000);

        (uint256 dDAIBalance, uint256 dDAIBorrowed, ) = dDAI.getSnapshot(user);
        assertEq(dDAIBalance, 0);
        assertEq(
            dDAIBorrowed,
            dDAIBorrowedBefore - deleverageData.repayAmount
        );

        (uint256 cUSDCDAIBalance, uint256 cUSDCDAIBorrowed, ) = cWETHUSDC
            .getSnapshot(user);
        assertEq(
            cUSDCDAIBalance,
            cUSDCDAIBalanceBefore - deleverageData.collateralAmount
        );
        assertEq(cUSDCDAIBorrowed, 0);

        vm.stopPrank();
    }
}
