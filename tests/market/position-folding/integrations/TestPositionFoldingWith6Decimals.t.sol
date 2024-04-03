// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { IMToken } from "contracts/interfaces/market/IMToken.sol";
import { IUniswapV2Router } from "contracts/interfaces/external/uniswap/IUniswapV2Router.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { CTokenPrimitive } from "contracts/market/collateral/CTokenPrimitive.sol";
import { MockCallDataChecker } from "contracts/mocks/MockCallDataChecker.sol";

import "tests/market/TestBaseMarket.sol";

contract User {}

contract TestPositionFoldingWith6Decimals is TestBaseMarket {
    address internal constant _UNISWAP_V2_ROUTER =
        0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;

    address public owner;
    address public user;
    MockDataFeed public mockUsdcFeed;
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
        _prepareBALRETH(user, 1 ether);

        // start epoch
        gaugePool.start(address(marketManager));
        vm.warp(gaugePool.startTime());
        vm.roll(block.number + 1000);

        mockUsdcFeed.setMockUpdatedAt(block.timestamp);
        mockWethFeed.setMockUpdatedAt(block.timestamp);
        mockRethFeed.setMockUpdatedAt(block.timestamp);

        (, int256 ethPrice, , , ) = mockWethFeed.latestRoundData();
        chainlinkEthUsd.updateAnswer(ethPrice);

        // setup dUSDC
        {
            _prepareUSDC(owner, 200000e6);
            usdc.approve(address(dUSDC), 200000e6);
            marketManager.listToken(address(dUSDC));
            // // add MToken support on price router
            // oracleRouter.addMTokenSupport(address(dUSDC));
        }

        // setup CBALRETH
        {
            // support market
            _prepareBALRETH(owner, 1 ether);
            balRETH.approve(address(cBALRETH), 1 ether);
            marketManager.listToken(address(cBALRETH));
            // set collateral factor
            marketManager.updateCollateralToken(
                IMToken(address(cBALRETH)),
                7000,
                4000,
                3000,
                200,
                400,
                10,
                1000
            );
            address[] memory tokens = new address[](1);
            tokens[0] = address(cBALRETH);
            uint256[] memory caps = new uint256[](1);
            caps[0] = 100_000e18;
            marketManager.setCTokenCollateralCaps(tokens, caps);
        }

        // set position folding
        MarketManager(marketManager).setPositionFolding(
            address(positionFolding)
        );

        // provide enough liquidity for leverage
        provideEnoughLiquidityForLeverage();

        centralRegistry.setExternalCallDataChecker(
            _UNISWAP_V2_ROUTER,
            address(new MockCallDataChecker(_UNISWAP_V2_ROUTER))
        );
    }

    function provideEnoughLiquidityForLeverage() internal {
        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareUSDC(liquidityProvider, 200000e6);
        _prepareBALRETH(liquidityProvider, 10 ether);
        // mint dUSDC
        vm.startPrank(liquidityProvider);
        usdc.approve(address(dUSDC), 200000e6);
        dUSDC.mint(200000e6);
        // mint cBALETH
        balRETH.approve(address(cBALRETH), 10 ether);
        cBALRETH.deposit(10 ether, liquidityProvider);
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

    function testLeverage() public {
        vm.startPrank(user);

        // approve
        balRETH.approve(address(cBALRETH), 1 ether);

        // mint
        assertGt(cBALRETH.deposit(1 ether, user1), 0);
        marketManager.postCollateral(user, address(cBALRETH), 1 ether);
        assertEq(cBALRETH.balanceOf(user), 1 ether);

        uint256 balanceBeforeBorrow = usdc.balanceOf(user);
        // borrow
        dUSDC.borrow(100e6);
        assertEq(balanceBeforeBorrow + 100e6, usdc.balanceOf(user));

        // try leverage with 50% of max
        uint256 amountForLeverage = (positionFolding
            .queryAmountToBorrowForLeverageMax(user, address(dUSDC)) * 50) /
            100;

        PositionFolding.LeverageStruct memory leverageData;
        leverageData.borrowToken = dUSDC;
        leverageData.borrowAmount = amountForLeverage;
        leverageData.collateralToken = CTokenPrimitive(address(cBALRETH));
        leverageData.swapData.inputToken = address(usdc);
        leverageData.swapData.inputAmount = amountForLeverage;
        leverageData.swapData.outputToken = _WETH_ADDRESS;
        leverageData.swapData.target = _UNISWAP_V2_ROUTER;
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = _WETH_ADDRESS;
        leverageData.swapData.call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            amountForLeverage,
            0,
            path,
            address(positionFolding),
            block.timestamp
        );
        leverageData.swapZap.inputToken = _WETH_ADDRESS;
        uint256[] memory amountsOut = IUniswapV2Router(_UNISWAP_V2_ROUTER)
            .getAmountsOut(amountForLeverage, path);
        leverageData.swapZap.inputAmount = amountsOut[1];
        leverageData.swapZap.outputToken = address(balRETH);

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
            _BALANCER_VAULT,
            _BAL_WETH_RETH_POOLID,
            tokens,
            address(positionFolding)
        );

        positionFolding.leverage(leverageData, 500);

        (uint256 dUSDCBalance, uint256 dUSDCBorrowed, ) = dUSDC.getSnapshot(
            user
        );
        assertEq(dUSDCBalance, 0);
        assertEq(dUSDCBorrowed, 100e6 + amountForLeverage);

        (uint256 cBALRETHBalance, uint256 cBALRETHBorrowed, ) = cBALRETH
            .getSnapshot(user);
        assertGt(cBALRETHBalance, 1.5 ether);
        assertEq(cBALRETHBorrowed, 0 ether);

        vm.stopPrank();
    }

    function testDeLeverage() public {
        testLeverage();
        // Warp until collateral posting wait time ends
        vm.warp(block.timestamp + 20 minutes);
        dUSDC.accrueInterest();

        vm.startPrank(user);

        PositionFolding.DeleverageStruct memory deleverageData;

        (, uint256 dUSDCBorrowedBefore, ) = dUSDC.getSnapshot(user);
        (uint256 cBALRETHBalanceBefore, , ) = cBALRETH.getSnapshot(user);

        deleverageData.collateralToken = CTokenPrimitive(address(cBALRETH));
        deleverageData.collateralAmount = 0.3 ether;
        deleverageData.borrowToken = dUSDC;

        deleverageData.swapZap.inputToken = address(balRETH);
        deleverageData.swapZap.inputAmount = deleverageData.collateralAmount;
        deleverageData.swapZap.outputToken = _WETH_ADDRESS;

        address[] memory tokens = new address[](2);
        tokens[0] = _RETH_ADDRESS;
        tokens[1] = _WETH_ADDRESS;
        deleverageData.swapZap.target = address(complexZapper);
        deleverageData.swapZap.call = abi.encodeWithSelector(
            ComplexZapper.exitBalancer.selector,
            ComplexZapper.BPTRedemption(
                _BALANCER_VAULT,
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
        deleverageData.swapData.inputToken = _WETH_ADDRESS;
        deleverageData.swapData.inputAmount = amountForDeleverage;
        deleverageData.swapData.outputToken = address(usdc);
        deleverageData.swapData.target = _UNISWAP_V2_ROUTER;
        address[] memory path = new address[](2);
        path[0] = _WETH_ADDRESS;
        path[1] = address(usdc);
        deleverageData.swapData.call = abi.encodeWithSignature(
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

        cBALRETH.approve(address(positionFolding), type(uint256).max);
        positionFolding.deleverage(deleverageData, 500);

        (uint256 dUSDCBalance, uint256 dUSDCBorrowed, ) = dUSDC.getSnapshot(
            user
        );
        assertEq(dUSDCBalance, 0);
        assertEq(
            dUSDCBorrowed,
            dUSDCBorrowedBefore - deleverageData.repayAmount
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
