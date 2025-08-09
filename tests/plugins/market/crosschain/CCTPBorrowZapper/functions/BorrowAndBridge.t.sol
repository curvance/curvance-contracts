// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { CCTPBorrowZapper } from "contracts/plugins/market/crosschain/CCTPBorrowZapper.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { ChainConfig } from "contracts/interfaces/ICentralRegistry.sol";

import { IUniswapV3Router } from "contracts/interfaces/external/uniswap/IUniswapV3Router.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";

contract BorrowAndBridgeTest is TestBaseMarketIsolated {
    address internal _UNISWAP_V3_SWAP_ROUTER =
        0xE592427A0AEce92De3Edee1F18E0157C05861564;

    CCTPBorrowZapper public CCTPZapper;

    SwapperLib.Swap public swapAction;
    IUniswapV3Router.ExactInputSingleParams public params;

    function setUp() public override {
        _fork(19140000);

        _init();

        // use mock pricing for testing
        mockDaiFeed = new MockDataFeed(_CHAINLINK_DAI_USD);
        chainlinkAdaptor.addAsset(
            _DAI_ADDRESS,
            true,
            address(mockDaiFeed),
            0
        );
        dualChainlinkAdaptor.addAsset(
            _DAI_ADDRESS,
            true,
            address(mockDaiFeed),
            0
        );
        mockWethFeed = new MockDataFeed(_CHAINLINK_ETH_USD);
        chainlinkAdaptor.addAsset(
            _WETH_ADDRESS,
            true,
            address(mockWethFeed),
            0
        );
        dualChainlinkAdaptor.addAsset(
            _WETH_ADDRESS,
            true,
            address(mockWethFeed),
            0
        );
        mockRethFeed = new MockDataFeed(_CHAINLINK_RETH_ETH);
        chainlinkAdaptor.addAsset(
            _RETH_ADDRESS,
            false,
            address(mockRethFeed),
            0
        );
        dualChainlinkAdaptor.addAsset(
            _RETH_ADDRESS,
            false,
            address(mockRethFeed),
            0
        );

        // start epoch
        vm.warp(gaugeManager.gaugeStartTime());
        vm.roll(block.number + 1000);

        mockDaiFeed.setMockUpdatedAt(block.timestamp);
        mockWethFeed.setMockUpdatedAt(block.timestamp);
        mockRethFeed.setMockUpdatedAt(block.timestamp);

        (, int256 ethPrice, , , ) = mockWethFeed.latestRoundData();
        chainlinkEthUsd.updateAnswer(ethPrice);

        // Setup borrowable CDAI.
        {
            _prepareDAI(address(this), 200000e18);
            dai.approve(address(borrowableCDAI), 200000e18);

        }

        // Setup strategyCBALRETH.
        {
            _prepareBALRETH(address(this), _ONE);
            balRETH.approve(address(strategyCBALRETH), _ONE);
        }

        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCDAI));
        
        _setCTokenConfigBasic(address(strategyCBALRETH), 100_000e18, 0);
        _setCTokenConfigLowValues(address(borrowableCDAI), 100_000e18, 100_000e18);

        // provide enough liquidity
        _provideEnoughLiquidityForLeverage();

        deal(user1, _ONE);

        CCTPZapper = new CCTPBorrowZapper(
            ICentralRegistry(address(centralRegistry))
        );

        ChainConfig memory config;
        config.isSupported = 2;
        config.messagingChainId = 23;
        config.domain = 3;
        config.messagingHub = address(messagingHub);
        config.votingHub = address(votingHub);
        config.cveAddress = address(cve);
        config.feeTokenAddress = _USDC_ADDRESS;
        config.crosschainRelayer = makeAddr("Wormhole Relayer");

        // Support chainId 42161.
        centralRegistry.addChain(42161, config);

        _prepareBALRETH(user1, _ONE);

        // try mint()
        vm.startPrank(user1);
        balRETH.approve(address(strategyCBALRETH), _ONE);
        strategyCBALRETH.deposit(_ONE, user1);
        strategyCBALRETH.postCollateral(_ONE);
        vm.stopPrank();

        assertEq(strategyCBALRETH.balanceOf(user1), _ONE);
        assertEq(strategyCBALRETH.exchangeRate(), _ONE);

        centralRegistry.setExternalCalldataChecker(
            _UNISWAP_V3_SWAP_ROUTER,
            address(new MockCalldataChecker(_UNISWAP_V3_SWAP_ROUTER))
        );

        swapAction.inputToken = _DAI_ADDRESS;
        swapAction.inputAmount = 500e18;
        swapAction.outputToken = _USDC_ADDRESS;
        swapAction.target = _UNISWAP_V3_SWAP_ROUTER;
        params.tokenIn = _DAI_ADDRESS;
        params.tokenOut = _USDC_ADDRESS;
        params.fee = 3000;
        params.recipient = address(CCTPZapper);
        params.deadline = block.timestamp;
        params.amountIn = 500e18;
        params.amountOutMinimum = 0;
        params.sqrtPriceLimitX96 = 0;
        swapAction.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector,
            params
        );
    }

    function test_borrowAndBridge_fail_whenSwapActionIsInvalid() public {
        swapAction.inputToken = _USDC_ADDRESS;

        vm.startPrank(user1);

        borrowableCDAI.setDelegateApproval(address(CCTPZapper), true);

        vm.expectRevert(
            CCTPBorrowZapper.CCTPBorrowZapper__InvalidSwapAction.selector
        );
        CCTPZapper.borrowAndBridge{ value: _ONE }(
            address(borrowableCDAI),
            500e18,
            swapAction,
            42161,
            0
        );

        vm.stopPrank();
    }

    function test_borrowAndBridge_fail_whenCCTPIsNotConfigured() public {
        centralRegistry.setTokenMessager(address(0));

        vm.startPrank(user1);

        borrowableCDAI.setDelegateApproval(address(CCTPZapper), true);

        vm.expectRevert(
            CCTPBorrowZapper.CCTPBorrowZapper__CCTPIsNotConfigured.selector
        );
        CCTPZapper.borrowAndBridge{ value: _ONE }(
            address(borrowableCDAI),
            500e18,
            swapAction,
            42161,
            0
        );

        vm.stopPrank();
    }

    function test_borrowAndBridge_fail_whenGasTokenIsNotEnough() public {
        uint256 messageFee = CCTPZapper.quoteMessageFee(42161, 0);

        vm.startPrank(user1);

        borrowableCDAI.setDelegateApproval(address(CCTPZapper), true);

        vm.expectRevert(
            CCTPBorrowZapper
                .CCTPBorrowZapper__InsufficientGasToken
                .selector
        );
        CCTPZapper.borrowAndBridge{ value: messageFee - 1 }(
            address(borrowableCDAI),
            500e18,
            swapAction,
            42161,
            0
        );

        vm.stopPrank();
    }

    function test_borrowAndBridge_success() public {
        uint256 messageFee = CCTPZapper.quoteMessageFee(42161, 0);
        uint256 balance = user1.balance;

        vm.startPrank(user1);

        borrowableCDAI.setDelegateApproval(address(CCTPZapper), true);
        CCTPZapper.borrowAndBridge{ value: _ONE }(
            address(borrowableCDAI),
            500e18,
            swapAction,
            42161,
            0
        );
        borrowableCDAI.borrow(500e18, user1);

        vm.stopPrank();

        assertEq(user1.balance, balance - messageFee);
    }

    function _provideEnoughLiquidityForLeverage() internal {
        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareDAI(liquidityProvider, 200000e18);
        _prepareBALRETH(liquidityProvider, 10e18);
        // Mint borrowable cDAI.
        vm.startPrank(liquidityProvider);
        dai.approve(address(borrowableCDAI), 200000e18);
        borrowableCDAI.deposit(200000e18, liquidityProvider);
        // Mint cBALETH.
        balRETH.approve(address(strategyCBALRETH), 10e18);
        strategyCBALRETH.deposit(10e18, liquidityProvider);
        vm.stopPrank();
    }
}
