// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { VelodromeStablePToken, IVeloGauge, IVeloRouter, IVeloPairFactory, IERC20 } from "contracts/market/token/VelodromeStablePToken.sol";
import { VelodromeStableLPAdaptor } from "contracts/oracles/adaptors/velodrome/VelodromeStableLPAdaptor.sol";
import { MockCallDataChecker } from "contracts/mocks/MockCallDataChecker.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { PositionManagementVelodromeStable } from "contracts/market/position-management/PositionManagementVelodromeStable.sol";
import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { IMToken } from "contracts/market/LiquidityManager.sol";
import { SimplePToken } from "contracts/market/token/SimplePToken.sol";

contract TestPositionManagementVelodromeStable is TestBaseMarket {
    address internal _VELODROME_DAI_USDC =
        0x19715771E30c93915A5bbDa134d782b81A820076;
    IVeloGauge public gauge =
        IVeloGauge(0x6998089F6bDd9c74C7D8d01b99d7e379ccCcb02D);
    IVeloPairFactory public veloPairFactory =
        IVeloPairFactory(0xF1046053aa5682b4F9a81b5481394DA16BE5FF5a);
    IVeloRouter public veloRouter =
        IVeloRouter(0xa062aE8A9c5e11aaA026fc2670B0D65cCc8B2858);

    VelodromeStablePToken public cUSDCDAI;
    VelodromeStableLPAdaptor public adaptor;
    PositionManagementVelodromeStable public positionManagement;

    address public owner;
    address public user;

    receive() external payable {}

    fallback() external payable {}

    function _provideEnoughLiquidityForLeverage() internal {
        address liquidityProvider = makeAddr("liquidityProvider");

        deal(_VELODROME_DAI_USDC, liquidityProvider, 1 ether);
        _prepareDAI(liquidityProvider, 20000000e18);

        vm.startPrank(liquidityProvider);

        // mint dDAI
        dai.approve(address(dDAI), 20000000 ether);
        dDAI.mint(20000000 ether);

        // mint cUSDCDAI
        IERC20(_VELODROME_DAI_USDC).approve(address(cUSDCDAI), 1 ether);
        cUSDCDAI.deposit(1 ether, liquidityProvider);

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
        _deployOracleManager();
        _deployDynamicInterestRateModel();

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

        // setup dDAI
        {
            _deployDDAI();
            // add MToken support on price router
            oracleManager.addMTokenSupport(address(dDAI));

            _prepareDAI(owner, 200000e18);
            dai.approve(address(dDAI), 200000e18);
            marketManager.listToken(address(dDAI));
        }

        // setup cUSDCDAI
        {
            cUSDCDAI = new VelodromeStablePToken(
                ICentralRegistry(address(centralRegistry)),
                IERC20(_VELODROME_DAI_USDC),
                address(marketManager),
                gauge,
                veloPairFactory,
                veloRouter
            );
            // add MToken support on price router
            oracleManager.addMTokenSupport(address(cUSDCDAI));

            deal(_VELODROME_DAI_USDC, owner, 1 ether);
            IERC20(_VELODROME_DAI_USDC).approve(address(cUSDCDAI), 1 ether);
            marketManager.listToken(address(cUSDCDAI));

            marketManager.updateCollateralToken(
                IMToken(address(cUSDCDAI)),
                7000,
                4000,
                3000,
                200,
                400,
                10,
                1000
            );
            
            address[] memory tokens = new address[](1);
            tokens[0] = address(cUSDCDAI);
            uint256[] memory caps = new uint256[](1);
            caps[0] = 100_000e18;

            marketManager.setPTokenCollateralCaps(tokens, caps);
        }

        positionManagement = new PositionManagementVelodromeStable(
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

        deal(_VELODROME_DAI_USDC, user, 0.0001 ether);
        IERC20(_VELODROME_DAI_USDC).approve(address(cUSDCDAI), 0.0001 ether);

        // mint
        assertGt(cUSDCDAI.deposit(0.0001 ether, user), 0);
        marketManager.postCollateral(user, address(cUSDCDAI), 0.0001 ether);
        assertEq(cUSDCDAI.balanceOf(user), 0.0001 ether);

        uint256 balanceBeforeBorrow = dai.balanceOf(user);
        // borrow
        dDAI.borrow(100 ether);
        assertEq(balanceBeforeBorrow + 100 ether, dai.balanceOf(user));

        // try leverage with 50% of max
        uint256 amountForLeverage = (positionManagement
            .queryAmountToBorrowForLeverageMax(user, address(dDAI)) * 50) /
            100;

        PositionManagementVelodromeStable.LeverageStruct memory leverageData;
        leverageData.borrowToken = dDAI;
        leverageData.borrowAmount = amountForLeverage;
        leverageData.collateralToken = SimplePToken(address(cUSDCDAI));
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
        leverageData.data = bytes("");

        positionManagement.leverage(leverageData, 500);

        (uint256 dDAIBalance, uint256 dDAIBorrowed, ) = dDAI.getSnapshot(user);
        assertEq(dDAIBalance, 0);
        assertEq(dDAIBorrowed, 100 ether + amountForLeverage);

        (uint256 cUSDCDAIBalance, uint256 cUSDCDAIBorrowed, ) = cUSDCDAI
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

        PositionManagementVelodromeStable.DeleverageStruct memory deleverageData;

        (, uint256 dDAIBorrowedBefore, ) = dDAI.getSnapshot(user);
        (uint256 cUSDCDAIBalanceBefore, , ) = cUSDCDAI.getSnapshot(user);

        deleverageData.collateralToken = SimplePToken(address(cUSDCDAI));
        deleverageData.collateralAmount = 0.00003 ether;
        deleverageData.borrowToken = dDAI;

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
        deleverageData.repayAmount = 30e18;

        cUSDCDAI.approve(address(positionManagement), type(uint256).max);
        positionManagement.deleverage(deleverageData, 5000);

        (uint256 dDAIBalance, uint256 dDAIBorrowed, ) = dDAI.getSnapshot(user);
        assertEq(dDAIBalance, 0);
        assertEq(
            dDAIBorrowed,
            dDAIBorrowedBefore - deleverageData.repayAmount
        );

        (uint256 cUSDCDAIBalance, uint256 cUSDCDAIBorrowed, ) = cUSDCDAI
            .getSnapshot(user);
        assertEq(
            cUSDCDAIBalance,
            cUSDCDAIBalanceBefore - deleverageData.collateralAmount
        );
        assertEq(cUSDCDAIBorrowed, 0);

        vm.stopPrank();
    }
}
