// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { AerodromeStableCToken, IVeloGauge, IVeloRouter, IVeloPairFactory, IERC20 } from "contracts/market/collateral/AerodromeStableCToken.sol";
import { VelodromeStableLPAdaptor } from "contracts/oracles/adaptors/velodrome/VelodromeStableLPAdaptor.sol";
import { MockCallDataChecker } from "contracts/mocks/MockCallDataChecker.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { PositionManagementAerodromeStable } from "contracts/market/position-management/PositionManagementAerodromeStable.sol";
import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";

contract TestPositionManagementAerodromeStable is TestBaseMarket {
    address internal _AERO_ADDRESS =
        0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    address internal _AERODROME_DAI_USDC =
        0x67b00B46FA4f4F24c03855c5C8013C0B938B3eEc;
    IVeloGauge public gauge =
        IVeloGauge(0x640e9ef68e1353112fF18826c4eDa844E1dC5eD0);
    IVeloPairFactory public aeroPairFactory =
        IVeloPairFactory(0x420DD381b31aEf6683db6B902084cB0FFECe40Da);
    IVeloRouter public aeroRouter =
        IVeloRouter(0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43);

    AerodromeStableCToken public cUSDCDAI;
    VelodromeStableLPAdaptor public adaptor;
    PositionManagementAerodromeStable public positionManagement;
    MockV3Aggregator public chainlinkAERO;
    MockV3Aggregator public chainlinkDAI;
    MockV3Aggregator public chainlinkUSDC;

    receive() external payable {}

    fallback() external payable {}

    // this is to use address(this) as mock cToken address
    function tokenType() external pure returns (uint256) {
        return 1;
    }

    function _deployPositionManagement() internal {
        positionManagement = new PositionManagementAerodromeStable(
            ICentralRegistry(address(centralRegistry)),
            address(marketManager),
            address(_AERODROME_DAI_USDC),
            IVeloRouter(address(aeroRouter))
        );
    }

    function _provideEnoughLiquidityForLeverage() internal {
        address liquidityProvider = makeAddr("liquidityProvider");
        uint256 amount0 = 10000e18;
        deal(_DAI_ADDRESS, liquidityProvider, amount0 * 2);

        IVeloRouter.Route[] memory routes = new IVeloRouter.Route[](1);
        routes[0].from = _DAI_ADDRESS;
        routes[0].to = _USDC_ADDRESS;
        routes[0].stable = true;
        routes[0].factory = address(aeroPairFactory);

        vm.startPrank(liquidityProvider);

        SwapperLib._approveTokenIfNeeded(
            _DAI_ADDRESS,
            address(aeroRouter),
            amount0
        );
        aeroRouter.swapExactTokensForTokens(
            amount0,
            0,
            routes,
            liquidityProvider,
            type(uint256).max
        );

        uint256 amount1 = usdc.balanceOf(liquidityProvider);

        SwapperLib._approveTokenIfNeeded(
            _DAI_ADDRESS,
            address(aeroRouter),
            amount0
        );
        SwapperLib._approveTokenIfNeeded(
            _USDC_ADDRESS,
            address(aeroRouter),
            amount1
        );
        (, , uint256 assets) = aeroRouter.addLiquidity(
            _DAI_ADDRESS,
            _USDC_ADDRESS,
            true,
            amount0,
            amount1,
            0,
            0,
            liquidityProvider,
            block.timestamp
        );

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

        centralRegistry.addHarvester(address(this));
        centralRegistry.setFeeAccumulator(address(this));
        centralRegistry.setExternalCallDataChecker(
            address(aeroRouter),
            address(new MockCallDataChecker(address(aeroRouter)))
        );

        cUSDCDAI = new AerodromeStableCToken(
            ICentralRegistry(address(centralRegistry)),
            IERC20(_AERODROME_DAI_USDC),
            address(marketManager),
            gauge,
            aeroPairFactory,
            aeroRouter
        );

        vm.warp(veCVE.nextEpochStartTime());

        _deployOracleRouter();

        chainlinkAdaptor = new ChainlinkAdaptor(
            ICentralRegistry(address(centralRegistry))
        );
        oracleRouter.addApprovedAdaptor(address(chainlinkAdaptor));

        chainlinkAERO = new MockV3Aggregator(8, 0.65e8, 1e50, 1e6);
        chainlinkAdaptor.addAsset(
            _AERO_ADDRESS,
            address(chainlinkAERO),
            0,
            true
        );
        oracleRouter.addAssetPriceFeed(
            _AERO_ADDRESS,
            address(chainlinkAdaptor)
        );

        chainlinkDAI = new MockV3Aggregator(8, 1e8, 1e50, 1e6);
        chainlinkAdaptor.addAsset(
            _DAI_ADDRESS,
            address(chainlinkDAI),
            0,
            true
        );
        oracleRouter.addAssetPriceFeed(
            _DAI_ADDRESS,
            address(chainlinkAdaptor)
        );

        chainlinkUSDC = new MockV3Aggregator(8, 1e8, 1e50, 1e6);
        chainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            address(chainlinkUSDC),
            0,
            true
        );
        oracleRouter.addAssetPriceFeed(
            _USDC_ADDRESS,
            address(chainlinkAdaptor)
        );

        adaptor = new VelodromeStableLPAdaptor(
            ICentralRegistry(address(centralRegistry))
        );
        adaptor.addAsset(_AERODROME_DAI_USDC);
        oracleRouter.addApprovedAdaptor(address(adaptor));
        oracleRouter.addAssetPriceFeed(_AERODROME_DAI_USDC, address(adaptor));

        centralRegistry.setSlippageLimit(6000);

        _deployPositionManagement();
        marketManager.setPositionManagement(address(positionManagement));
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
        (uint256 price, uint256 errorCode) = oracleRouter.getPrice(
            _AERODROME_DAI_USDC,
            true,
            false
        );
        assertEq(errorCode, 0);
        assertGt(price, 0);

        uint256 amount0 = 100e18;

        (uint256 updatedPrice, ) = oracleRouter.getPrice(
            _AERODROME_DAI_USDC,
            true,
            false
        );
        assertApproxEqRel(updatedPrice, price, 0.0001e18);

        deal(_AERODROME_DAI_USDC, address(this), 42069);

        IERC20(_AERODROME_DAI_USDC).approve(address(cUSDCDAI), 42069);
        marketManager.listToken(address(cUSDCDAI));

        vm.prank(user1);
        IERC20(_AERODROME_DAI_USDC).approve(address(cUSDCDAI), assets);

        vm.prank(user1);
        cUSDCDAI.deposit(assets, user1);

        assertEq(
            cUSDCDAI.totalAssets(),
            assets + 42069,
            "Total Assets should equal user deposit plus initial mint."
        );

        vm.startPrank(gauge.voter());
        deal(_AERO_ADDRESS, gauge.voter(), 10e18);
        IERC20(_AERO_ADDRESS).approve(address(gauge), 10e18);
        gauge.notifyRewardAmount(10e18);
        vm.stopPrank();

        // Advance time to earn CRV and CVX rewards
        vm.warp(block.timestamp + 1 days);
        chainlinkAERO.updateAnswer(chainlinkAERO.latestAnswer());
        chainlinkDAI.updateAnswer(chainlinkDAI.latestAnswer());

        // Mint some extra rewards for Vault.
        uint256 earned = gauge.earned(address(cUSDCDAI));
        uint256 amount = (earned * 84) / 100;
        SwapperLib.Swap memory swapData;
        swapData.inputToken = _AERO_ADDRESS;
        swapData.inputAmount = amount;
        swapData.outputToken = _DAI_ADDRESS;
        swapData.target = address(aeroRouter);
        routes = new IVeloRouter.Route[](1);
        routes[0].from = _AERO_ADDRESS;
        routes[0].to = _DAI_ADDRESS;
        routes[0].stable = false;
        routes[0].factory = address(aeroPairFactory);
        swapData.call = abi.encodeWithSelector(
            IVeloRouter.swapExactTokensForTokens.selector,
            amount,
            0,
            routes,
            address(cUSDCDAI),
            type(uint256).max
        );
        swapData.slippage = 50e16;

        cUSDCDAI.harvest(abi.encode(swapData));

        assertEq(
            cUSDCDAI.totalAssets(),
            assets + 42069,
            "Total Assets should equal user deposit plus initial mint."
        );

        vm.warp(block.timestamp + 8 days);
        chainlinkAERO.updateAnswer(chainlinkAERO.latestAnswer());
        chainlinkDAI.updateAnswer(chainlinkDAI.latestAnswer());

        // Mint some extra rewards for Vault.
        earned = gauge.earned(address(cUSDCDAI));
        amount = (earned * 84) / 100;
        swapData.inputAmount = amount;
        swapData.call = abi.encodeWithSelector(
            IVeloRouter.swapExactTokensForTokens.selector,
            amount,
            0,
            routes,
            address(cUSDCDAI),
            type(uint256).max
        );
        cUSDCDAI.harvest(abi.encode(swapData));

        vm.warp(block.timestamp + 7 days);
        chainlinkAERO.updateAnswer(chainlinkAERO.latestAnswer());
        chainlinkDAI.updateAnswer(chainlinkDAI.latestAnswer());

        assertGt(
            cUSDCDAI.totalAssets(),
            assets + 42069,
            "Total Assets should greater than original deposit plus initial mint."
        );

        vm.prank(user1);
        cUSDCDAI.withdraw(assets, user1, user1);
    }

    function testDeLeverage() public {
        testLeverage();
        // Warp until collateral posting wait time ends
        vm.warp(block.timestamp + 20 minutes);
        dDAI.accrueInterest();

        vm.startPrank(user);

        PositionManagementAerodromeStable.DeleverageStruct memory deleverageData;

        (, uint256 dDAIBorrowedBefore, ) = dDAI.getSnapshot(user);
        (uint256 cBALRETHBalanceBefore, , ) = cBALRETH.getSnapshot(user);

        deleverageData.collateralToken = CTokenPrimitive(address(cBALRETH));
        deleverageData.collateralAmount = 0.3 ether;
        deleverageData.borrowToken = dDAI;

        deleverageData.swapZap.inputToken = address(balRETH);
        deleverageData.swapZap.inputAmount = deleverageData.collateralAmount;
        deleverageData.swapZap.outputToken = _WETH_ADDRESS;

        uint256 amountForDeleverage = 0.3 ether;
        deleverageData.swapData = new SwapperLib.Swap[](1);
        deleverageData.swapData[0].inputToken = _WETH_ADDRESS;
        deleverageData.swapData[0].inputAmount = amountForDeleverage;
        deleverageData.swapData[0].outputToken = address(dai);
        deleverageData.swapData[0].target = _UNISWAP_V2_ROUTER;
        deleverageData.swapData[0].slippage = 50e16;
        address[] memory path = new address[](2);
        path[0] = _WETH_ADDRESS;
        path[1] = address(dai);
        deleverageData.swapData[0].call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            amountForDeleverage,
            0,
            path,
            address(positionManagement),
            block.timestamp
        );
        uint256[] memory amountsOut = IUniswapV2Router(_UNISWAP_V2_ROUTER)
            .getAmountsOut(amountForDeleverage, path);
        deleverageData.repayAmount = amountsOut[1];

        cBALRETH.approve(address(positionManagement), type(uint256).max);
        positionManagement.deleverage(deleverageData, 500);

        (uint256 dDAIBalance, uint256 dDAIBorrowed, ) = dDAI.getSnapshot(user);
        assertEq(dDAIBalance, 0);
        assertEq(
            dDAIBorrowed,
            dDAIBorrowedBefore - deleverageData.repayAmount
        );

        (uint256 cBALRETHBalance, uint256 cBALRETHBorrowed, ) = cBALRETH
            .getSnapshot(user);
        assertEq(
            cBALRETHBalance,
            cBALRETHBalanceBefore - deleverageData.collateralAmount
        );
        assertEq(cBALRETHBorrowed, 0);

        vm.stopPrank();
    }
}
