// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { AerodromeStablePToken, IVeloGauge, IVeloRouter, IVeloPairFactory, IERC20 } from "contracts/market/token/AerodromeStablePToken.sol";
import { VelodromeStableLPAdaptor } from "contracts/oracles/adaptors/velodrome/VelodromeStableLPAdaptor.sol";
import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { PositionManagementAerodromeStable } from "contracts/market/position-management/PositionManagementAerodromeStable.sol";
import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { IMToken } from "contracts/market/LiquidityManager.sol";
import { SimplePToken } from "contracts/market/token/SimplePToken.sol";
import { IUniswapV2Router } from "contracts/interfaces/external/uniswap/IUniswapV2Router.sol";

contract TestPositionManagementAerodromeStable is TestBaseMarket {
    address internal _AERODROME_DAI_USDC =
        0x67b00B46FA4f4F24c03855c5C8013C0B938B3eEc;
    IVeloGauge public gauge =
        IVeloGauge(0x640e9ef68e1353112fF18826c4eDa844E1dC5eD0);
    IVeloPairFactory public aeroPairFactory =
        IVeloPairFactory(0x420DD381b31aEf6683db6B902084cB0FFECe40Da);
    IVeloRouter public aeroRouter =
        IVeloRouter(0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43);

    AerodromeStablePToken public cUSDCDAI;
    VelodromeStableLPAdaptor public adaptor;
    PositionManagementAerodromeStable public positionManagement;

    address public owner;
    address public user;

    receive() external payable {}

    fallback() external payable {}

    function _provideEnoughLiquidityForLeverage() internal {
        address liquidityProvider = makeAddr("liquidityProvider");

        deal(_AERODROME_DAI_USDC, liquidityProvider, 1 ether);
        _prepareDAI(liquidityProvider, 20000000e18);

        vm.startPrank(liquidityProvider);

        // mint dDAI
        dai.approve(address(dDAI), 20000000 ether);
        dDAI.mint(20000000 ether);

        // mint cUSDCDAI
        IERC20(_AERODROME_DAI_USDC).approve(address(cUSDCDAI), 1 ether);
        cUSDCDAI.deposit(1 ether, liquidityProvider);

        vm.stopPrank();
    }

    function setUp() public override {
        _fork("ETH_NODE_URI_BASE", 19000000);

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
        adaptor.addAsset(_AERODROME_DAI_USDC);
        oracleManager.addApprovedAdaptor(address(adaptor));
        oracleManager.addAssetPriceFeed(_AERODROME_DAI_USDC, address(adaptor));

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
            cUSDCDAI = new AerodromeStablePToken(
                ICentralRegistry(address(centralRegistry)),
                IERC20(_AERODROME_DAI_USDC),
                address(marketManager),
                gauge,
                aeroPairFactory,
                aeroRouter
            );
            // add MToken support on price router
            oracleManager.addMTokenSupport(address(cUSDCDAI));

            deal(_AERODROME_DAI_USDC, owner, 1 ether);
            IERC20(_AERODROME_DAI_USDC).approve(address(cUSDCDAI), 1 ether);
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

        positionManagement = new PositionManagementAerodromeStable(
            ICentralRegistry(address(centralRegistry)),
            address(marketManager),
            address(aeroRouter),
            address(aeroPairFactory)
        );
        marketManager.setPositionManagement(address(positionManagement));

        _provideEnoughLiquidityForLeverage();

        centralRegistry.setExternalCallDataChecker(
            _UNISWAP_V2_ROUTER,
            address(new MockCalldataChecker(_UNISWAP_V2_ROUTER))
        );

        centralRegistry.setExternalCallDataChecker(
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

        deal(_AERODROME_DAI_USDC, user, 0.0001 ether);
        IERC20(_AERODROME_DAI_USDC).approve(address(cUSDCDAI), 0.0001 ether);

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

        PositionManagementAerodromeStable.LeverageStruct memory leverageData;
        leverageData.borrowToken = dDAI;
        leverageData.borrowAmount = amountForLeverage;
        leverageData.collateralToken = SimplePToken(address(cUSDCDAI));
        leverageData.swapData.inputToken = address(0x0);
        leverageData.swapData.inputAmount = 0;
        leverageData.swapData.outputToken = address(0x0);
        leverageData.swapData.target = address(0x0);
        leverageData.swapData.slippage = 0;
        leverageData.swapData.call = bytes("");
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

        PositionManagementAerodromeStable.DeleverageStruct memory deleverageData;

        (, uint256 dDAIBorrowedBefore, ) = dDAI.getSnapshot(user);
        (uint256 cUSDCDAIBalanceBefore, , ) = cUSDCDAI.getSnapshot(user);

        deleverageData.collateralToken = SimplePToken(address(cUSDCDAI));
        deleverageData.collateralAmount = 0.00003 ether;
        deleverageData.borrowToken = dDAI;

        uint256 usdcAmount = 28451980;
        deleverageData.swapData = new SwapperLib.Swap[](1);
        deleverageData.swapData[0].inputToken = _USDC_ADDRESS;
        deleverageData.swapData[0].inputAmount = usdcAmount;
        deleverageData.swapData[0].outputToken = _DAI_ADDRESS;
        deleverageData.swapData[0].target = _UNISWAP_V2_ROUTER;
        deleverageData.swapData[0].slippage = 1e18;
        address[] memory path = new address[](2);
        path[0] = _USDC_ADDRESS;
        path[1] = _DAI_ADDRESS;
        deleverageData.swapData[0].call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            usdcAmount,
            0,
            path,
            address(positionManagement),
            block.timestamp
        );
        IUniswapV2Router(_UNISWAP_V2_ROUTER)
            .getAmountsOut(usdcAmount, path);
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
