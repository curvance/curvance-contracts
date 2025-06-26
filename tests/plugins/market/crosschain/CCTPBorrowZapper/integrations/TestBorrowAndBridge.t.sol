// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { CCTPBorrowZapper } from "contracts/plugins/market/crosschain/CCTPBorrowZapper.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IUniswapV3Router } from "contracts/interfaces/external/uniswap/IUniswapV3Router.sol";

contract TestBorrowAndBridge is TestBaseMarketIsolated {
    address internal _UNISWAP_V3_SWAP_ROUTER =
        0xE592427A0AEce92De3Edee1F18E0157C05861564;

    MockDataFeed public mockDaiFeed;
    MockDataFeed public mockWethFeed;
    MockDataFeed public mockRethFeed;

    CCTPBorrowZapper public CCTPZapper;

    function setUp() public override {
        _fork(19140000);

        _init();

        // use mock pricing for testing
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

        // start epoch
        vm.warp(gaugeManager.gaugeStartTime());
        vm.roll(block.number + 1000);

        mockDaiFeed.setMockUpdatedAt(block.timestamp);
        mockWethFeed.setMockUpdatedAt(block.timestamp);
        mockRethFeed.setMockUpdatedAt(block.timestamp);

        (, int256 ethPrice, , , ) = mockWethFeed.latestRoundData();
        chainlinkEthUsd.updateAnswer(ethPrice);

        // setup eDAI
        {
            _prepareDAI(address(this), 200000e18);
            dai.approve(address(eDAI), 200000e18);
            // add MToken support on oracle manager
            oracleManager.addCTokenSupport(address(eDAI));
        }

        // setup pBALRETH
        {
            // support market
            _prepareBALRETH(address(this), _ONE);
            balRETH.approve(address(pBALRETH), _ONE);

        }

        marketManagerIsolated.listTokens(address(pBALRETH), address(eDAI));

        // set collateral factor
        marketManagerIsolated.updatePositionToken(
            7000,    // collRatio 70%
            4000,    // collReqSoft 40%
            3000,    // collReqHard 25%
            1000,    // liqIncBase 10%
            1500,    // liqIncHard 15%
            500,     // liqIncMin 5%
            2000,    // liqIncMax 20%
            2000,    // minEffectiveCFactor 20%
            5000,    // maxEffectiveCFactor 50%
            1000     // baseCFactor 20%
        );
        
        address[] memory tokens = new address[](1);
        tokens[0] = address(pBALRETH);
        uint256[] memory caps = new uint256[](1);
        caps[0] = 100_000e18;
        marketManagerIsolated.setCollateralCaps(tokens, caps);

        caps[0] = 100_000e18;
        tokens[0] = address(eDAI);
        marketManagerIsolated.setDebtCaps(tokens, caps);

        // provide enough liquidity
        _provideEnoughLiquidityForLeverage();

        deal(user1, _ONE);

        CCTPZapper = new CCTPBorrowZapper(
            ICentralRegistry(address(centralRegistry))
        );

        centralRegistry.addChainSupport(
            address(messagingHub),
            address(votingHub),
            address(cve),
            _USDC_ADDRESS,
            42161,
            23,
            makeAddr("Wormhole Relayer"),
            3
        );
    }

    function testETokenBorrowAndBridge() public {
        _prepareBALRETH(user1, _ONE);

        // try mint()
        vm.startPrank(user1);
        balRETH.approve(address(pBALRETH), _ONE);
        pBALRETH.deposit(_ONE, user1);
        pBALRETH.postCollateral(_ONE);
        vm.stopPrank();

        assertEq(pBALRETH.balanceOf(user1), _ONE);
        assertEq(pBALRETH.exchangeRate(), _ONE);

        centralRegistry.setExternalCalldataChecker(
            _UNISWAP_V3_SWAP_ROUTER,
            address(new MockCalldataChecker(_UNISWAP_V3_SWAP_ROUTER))
        );

        SwapperLib.Swap memory swapData;
        swapData.inputToken = _DAI_ADDRESS;
        swapData.inputAmount = 500e18;
        swapData.outputToken = _USDC_ADDRESS;
        swapData.target = _UNISWAP_V3_SWAP_ROUTER;
        IUniswapV3Router.ExactInputSingleParams memory params;
        params.tokenIn = _DAI_ADDRESS;
        params.tokenOut = _USDC_ADDRESS;
        params.fee = 3000;
        params.recipient = address(CCTPZapper);
        params.deadline = block.timestamp;
        params.amountIn = 500e18;
        params.amountOutMinimum = 0;
        params.sqrtPriceLimitX96 = 0;
        swapData.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector,
            params
        );

        uint256 messageFee = CCTPZapper.quoteMessageFee(42161, 0);

        // try borrow()
        vm.startPrank(user1);

        eDAI.setDelegateApproval(address(CCTPZapper), true);
        CCTPZapper.borrowAndBridge{ value: messageFee }(
            address(eDAI),
            500e18,
            swapData,
            42161,
            0
        );
        eDAI.borrow(500e18);

        vm.stopPrank();
    }

    function _provideEnoughLiquidityForLeverage() internal {
        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareDAI(liquidityProvider, 200000e18);
        _prepareBALRETH(liquidityProvider, 10e18);
        // mint eDAI
        vm.startPrank(liquidityProvider);
        dai.approve(address(eDAI), 200000e18);
        eDAI.mint(200000e18);
        // mint cBALETH
        balRETH.approve(address(pBALRETH), 10e18);
        pBALRETH.deposit(10e18, liquidityProvider);
        vm.stopPrank();
    }
}
