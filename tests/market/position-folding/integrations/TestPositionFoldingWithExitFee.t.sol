// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { IMToken } from "contracts/interfaces/market/IMToken.sol";
import { IUniswapV2Router } from "contracts/interfaces/external/uniswap/IUniswapV2Router.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { CTokenPrimitive } from "contracts/market/collateral/CTokenPrimitive.sol";
import { MockCallDataChecker } from "contracts/mocks/MockCallDataChecker.sol";
import { FixedPointMathLib } from "contracts/libraries/FixedPointMathLib.sol";
import { WAD } from "contracts/libraries/Constants.sol";
import "tests/market/TestBaseMarket.sol";

contract User {}

contract TestPositionFoldingWithExitFee is TestBaseMarket {
    address public owner;
    address public user;
    MockDataFeed public mockUsdcFeed;
    MockDataFeed public mockDaiFeed;
    MockDataFeed public mockWethFeed;
    MockDataFeed public mockRethFeed;

    receive() external payable {}

    fallback() external payable {}

    function setUp() public override {
        super.setUp();

        owner = address(this);
        user = user1;

        // use mock pricing for testing
        mockUsdcFeed = new MockDataFeed(_CHAINLINK_USDC_USD);
        chainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            address(mockUsdcFeed),
            0,
            true
        );
        dualChainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            address(mockUsdcFeed),
            0,
            true
        );
        mockDaiFeed = new MockDataFeed(_CHAINLINK_DAI_USD);
        chainlinkAdaptor.addAsset(_DAI_ADDRESS, address(mockDaiFeed), 0, true);
        dualChainlinkAdaptor.addAsset(
            _DAI_ADDRESS,
            address(mockDaiFeed),
            0,
            true
        );
        mockWethFeed = new MockDataFeed(_CHAINLINK_ETH_USD);
        chainlinkAdaptor.addAsset(
            _WETH_ADDRESS,
            address(mockWethFeed),
            0,
            true
        );
        dualChainlinkAdaptor.addAsset(
            _WETH_ADDRESS,
            address(mockWethFeed),
            0,
            true
        );
        mockRethFeed = new MockDataFeed(_CHAINLINK_RETH_ETH);
        chainlinkAdaptor.addAsset(
            _RETH_ADDRESS,
            address(mockRethFeed),
            0,
            false
        );
        dualChainlinkAdaptor.addAsset(
            _RETH_ADDRESS,
            address(mockRethFeed),
            0,
            false
        );

        _prepareUSDC(user, 200000e6);
        _prepareDAI(user, 200000e18);
        _prepareBALRETH(user, 1 ether);

        // start epoch
        gaugePool.start(address(marketManager));
        vm.warp(gaugePool.startTime());
        vm.roll(block.number + 1000);

        mockUsdcFeed.setMockUpdatedAt(block.timestamp);
        mockDaiFeed.setMockUpdatedAt(block.timestamp);
        mockWethFeed.setMockUpdatedAt(block.timestamp);
        mockRethFeed.setMockUpdatedAt(block.timestamp);

        (, int256 ethPrice, , , ) = mockWethFeed.latestRoundData();
        chainlinkEthUsd.updateAnswer(ethPrice);

        // setup dDAI
        {
            _prepareDAI(owner, 200000e18);
            dai.approve(address(dDAI), 200000e18);
            marketManager.listToken(address(dDAI));
            // add MToken support on price router
            oracleRouter.addMTokenSupport(address(dDAI));
        }

        // setup cBALRETHWithExitFee
        {
            // support market
            _prepareBALRETH(owner, 1 ether);
            balRETH.approve(address(cBALRETHWithExitFee), 1 ether);
            marketManager.listToken(address(cBALRETHWithExitFee));
            // set collateral factor
            marketManager.updateCollateralToken(
                IMToken(address(cBALRETHWithExitFee)),
                7000,
                4000,
                3000,
                200,
                400,
                10,
                1000
            );
            address[] memory tokens = new address[](1);
            tokens[0] = address(cBALRETHWithExitFee);
            uint256[] memory caps = new uint256[](1);
            caps[0] = 100_000e18;
            marketManager.setCTokenCollateralCaps(tokens, caps);
        }

        // set position folding
        MarketManager(marketManager).setPositionFolding(
            address(positionFolding)
        );

        // vm.warp(gaugePool.startTime());
        // vm.roll(block.number + 1000);

        // // set gauge settings of next epoch
        // address[] memory tokensParam = new address[](2);
        // tokensParam[0] = address(dDAI);
        // tokensParam[1] = address(cBALRETHWithExitFee);
        // uint256[] memory poolWeights = new uint256[](2);
        // poolWeights[0] = 100;
        // poolWeights[1] = 100;
        // vm.prank(protocolMessagingHub);
        // gaugePool.setEmissionRates(1, tokensParam, poolWeights);
        // vm.prank(protocolMessagingHub);
        // cve.mintGaugeEmissions(300 * 2 weeks, address(gaugePool));
        // vm.warp(gaugePool.startTime() + 1 * 2 weeks);

        // provide enough liquidity for leverage
        provideEnoughLiquidityForLeverage();

        centralRegistry.setExternalCallDataChecker(
            _UNISWAP_V2_ROUTER,
            address(new MockCallDataChecker(_UNISWAP_V2_ROUTER))
        );
    }

    function provideEnoughLiquidityForLeverage() internal {
        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareDAI(liquidityProvider, 200000e18);
        _prepareBALRETH(liquidityProvider, 10 ether);
        // mint dDAI
        vm.startPrank(liquidityProvider);
        dai.approve(address(dDAI), 200000 ether);
        dDAI.mint(200000 ether);
        // mint cBALETH
        balRETH.approve(address(cBALRETHWithExitFee), 10 ether);
        cBALRETHWithExitFee.deposit(10 ether, liquidityProvider);
        vm.stopPrank();
    }

    function testInitialize() public {
        assertEq(
            address(positionFolding.centralRegistry()),
            address(centralRegistry)
        );
        assertEq(
            address(positionFolding.marketManager()),
            address(marketManager)
        );
    }

    function testLeverageWithExitFee() public {
        vm.startPrank(user);

        // approve
        balRETH.approve(address(cBALRETHWithExitFee), 1 ether);

        // mint
        assertGt(cBALRETHWithExitFee.deposit(1 ether, user1), 0);
        marketManager.postCollateral(
            user,
            address(cBALRETHWithExitFee),
            1 ether
        );
        assertEq(cBALRETHWithExitFee.balanceOf(user), 1 ether);

        uint256 balanceBeforeBorrow = dai.balanceOf(user);
        // borrow
        dDAI.borrow(100 ether);
        assertEq(balanceBeforeBorrow + 100 ether, dai.balanceOf(user));

        // try leverage with 50% of max
        uint256 amountForLeverage = (positionFolding
            .queryAmountToBorrowForLeverageMax(user, address(dDAI)) * 50) /
            100;

        PositionFolding.LeverageStruct memory leverageData;
        leverageData.borrowToken = dDAI;
        leverageData.borrowAmount = amountForLeverage;
        leverageData.collateralToken = CTokenPrimitive(
            address(cBALRETHWithExitFee)
        );
        leverageData.swapData.slippage = 0.003e18;
        leverageData.swapData.inputToken = address(dai);
        leverageData.swapData.inputAmount = amountForLeverage;
        leverageData.swapData.outputToken = _WETH_ADDRESS;
        leverageData.swapData.target = _UNISWAP_V2_ROUTER;
        address[] memory path = new address[](2);
        path[0] = address(dai);
        path[1] = _WETH_ADDRESS;
        leverageData.swapData.call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            amountForLeverage,
            0,
            path,
            address(positionFolding),
            block.timestamp
        );
        leverageData.swapZap.slippage = 0.001e18;
        leverageData.swapZap.inputToken = _WETH_ADDRESS;
        leverageData.swapZap.outputToken = _BAL_WETH_RETH_ADDRESS;
        uint256[] memory amountsOut = IUniswapV2Router(_UNISWAP_V2_ROUTER)
            .getAmountsOut(amountForLeverage, path);
        leverageData.swapZap.inputAmount = amountsOut[1];

        address[] memory tokens = new address[](2);
        tokens[0] = _RETH_ADDRESS;
        tokens[1] = _WETH_ADDRESS;
        leverageData.swapZap.target = address(complexZapper);
        leverageData.swapZap.call = abi.encodeWithSelector(
            ComplexZapper.enterBalancer.selector,
            address(0),
            ComplexZapper.ZapperData(
                _WETH_ADDRESS,
                leverageData.swapZap.inputAmount,
                address(balRETH),
                0,
                false
            ),
            new SwapperLib.Swap[](0),
            _BAL_VAULT_ADDRESS,
            _BAL_WETH_RETH_POOLID,
            tokens,
            address(positionFolding)
        );

        positionFolding.leverage(leverageData, 500);

        (uint256 dDAIBalance, uint256 dDAIBorrowed, ) = dDAI.getSnapshot(user);
        assertEq(dDAIBalance, 0);
        assertEq(dDAIBorrowed, 100 ether + amountForLeverage);

        (
            uint256 cBALRETHWithExitFeeBalance,
            uint256 cBALRETHWithExitFeeBorrowed,

        ) = cBALRETHWithExitFee.getSnapshot(user);
        assertGt(cBALRETHWithExitFeeBalance, 1.5 ether);
        assertEq(cBALRETHWithExitFeeBorrowed, 0 ether);

        vm.stopPrank();
    }

    function testDeLeverageWithExitFee() public {
        testLeverageWithExitFee();
        // Warp until collateral posting wait time ends
        vm.warp(block.timestamp + 20 minutes);
        dDAI.accrueInterest();

        vm.startPrank(user);

        PositionFolding.DeleverageStruct memory deleverageData;

        (, uint256 dDAIBorrowedBefore, ) = dDAI.getSnapshot(user);
        (uint256 cBALRETHWithExitFeeBalanceBefore, , ) = cBALRETHWithExitFee
            .getSnapshot(user);

        deleverageData.collateralToken = CTokenPrimitive(
            address(cBALRETHWithExitFee)
        );
        deleverageData.collateralAmount = 0.3 ether;
        deleverageData.borrowToken = dDAI;

        deleverageData.swapZap.slippage = 0.0003e18;
        deleverageData.swapZap.inputToken = address(balRETH);
        deleverageData.swapZap.outputToken = _WETH_ADDRESS;
        deleverageData.swapZap.inputAmount =
            deleverageData.collateralAmount -
            FixedPointMathLib.mulDivUp(
                cBALRETHWithExitFee.exitFee(),
                deleverageData.collateralAmount,
                WAD
            );

        address[] memory tokens = new address[](2);
        tokens[0] = _RETH_ADDRESS;
        tokens[1] = _WETH_ADDRESS;
        deleverageData.swapZap.target = address(complexZapper);
        deleverageData.swapZap.call = abi.encodeWithSelector(
            ComplexZapper.exitBalancer.selector,
            ComplexZapper.BPTRedemption(
                _BAL_VAULT_ADDRESS,
                _BAL_WETH_RETH_POOLID,
                true,
                1
            ),
            ComplexZapper.ZapperData(
                address(balRETH),
                deleverageData.swapZap.inputAmount,
                _WETH_ADDRESS,
                0,
                false
            ),
            tokens,
            new SwapperLib.Swap[](0),
            address(positionFolding)
        );

        uint256 amountForDeleverage = 0.3 ether;
        deleverageData.swapData = new SwapperLib.Swap[](1);
        deleverageData.swapData[0].slippage = 0.003e18;
        deleverageData.swapData[0].inputToken = _WETH_ADDRESS;
        deleverageData.swapData[0].inputAmount = amountForDeleverage;
        deleverageData.swapData[0].outputToken = address(dai);
        deleverageData.swapData[0].target = _UNISWAP_V2_ROUTER;
        address[] memory path = new address[](2);
        path[0] = _WETH_ADDRESS;
        path[1] = address(dai);
        deleverageData.swapData[0].call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            amountForDeleverage,
            0,
            path,
            address(positionFolding),
            block.timestamp
        );
        uint256[] memory amountsOut = IUniswapV2Router(_UNISWAP_V2_ROUTER)
            .getAmountsOut(amountForDeleverage, path);
        deleverageData.repayAmount = amountsOut[1];

        cBALRETHWithExitFee.approve(
            address(positionFolding),
            type(uint256).max
        );
        positionFolding.deleverage(deleverageData, 500);

        (uint256 dDAIBalance, uint256 dDAIBorrowed, ) = dDAI.getSnapshot(user);
        assertEq(dDAIBalance, 0);
        assertEq(
            dDAIBorrowed,
            dDAIBorrowedBefore - deleverageData.repayAmount
        );

        (
            uint256 cBALRETHWithExitFeeBalance,
            uint256 cBALRETHWithExitFeeBorrowed,

        ) = cBALRETHWithExitFee.getSnapshot(user);
        assertEq(
            cBALRETHWithExitFeeBalance,
            cBALRETHWithExitFeeBalanceBefore - deleverageData.collateralAmount
        );
        assertEq(cBALRETHWithExitFeeBorrowed, 0);

        vm.stopPrank();
    }
}
