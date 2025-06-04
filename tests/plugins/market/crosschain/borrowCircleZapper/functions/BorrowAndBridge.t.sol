// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";

import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { BorrowCircleZapper } from "contracts/plugins/market/crosschain/BorrowCircleZapper.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IUniswapV3Router } from "contracts/interfaces/external/uniswap/IUniswapV3Router.sol";

contract BorrowAndBridgeTest is TestBaseMarket {
    address internal _UNISWAP_V3_SWAP_ROUTER =
        0xE592427A0AEce92De3Edee1F18E0157C05861564;

    MockDataFeed public mockDaiFeed;
    MockDataFeed public mockWethFeed;
    MockDataFeed public mockRethFeed;
    BorrowCircleZapper public circleZapper;

    SwapperLib.Swap public swapData;
    IUniswapV3Router.ExactInputSingleParams public params;

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
            marketManager.listToken(address(eDAI));
            // add MToken support on oracle manager
            oracleManager.addMTokenSupport(address(eDAI));
        }

        // setup pBALRETH
        {
            // support market
            _prepareBALRETH(address(this), _ONE);
            balRETH.approve(address(pBALRETH), _ONE);
            marketManager.listToken(address(pBALRETH));
            // set collateral factor
            marketManager.updatePositionToken(
                address(pBALRETH),
                7000,
                4000,
                3000,
                200,
                400,
                1000
            );
            address[] memory tokens = new address[](1);
            tokens[0] = address(pBALRETH);
            uint256[] memory caps = new uint256[](1);
            caps[0] = 100_000e18;
            marketManager.setCollateralCaps(tokens, caps);
        }

        // provide enough liquidity
        _provideEnoughLiquidityForLeverage();

        deal(user1, _ONE);

        circleZapper = new BorrowCircleZapper(
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

        _prepareBALRETH(user1, _ONE);

        // try mint()
        vm.startPrank(user1);
        balRETH.approve(address(pBALRETH), _ONE);
        pBALRETH.deposit(_ONE, user1);
        marketManager.postCollateral(user1, address(pBALRETH), _ONE);
        vm.stopPrank();

        assertEq(pBALRETH.balanceOf(user1), _ONE);
        assertEq(pBALRETH.exchangeRateCached(), _ONE);

        centralRegistry.setExternalCalldataChecker(
            _UNISWAP_V3_SWAP_ROUTER,
            address(new MockCalldataChecker(_UNISWAP_V3_SWAP_ROUTER))
        );

        swapData.inputToken = _DAI_ADDRESS;
        swapData.inputAmount = 500e18;
        swapData.outputToken = _USDC_ADDRESS;
        swapData.target = _UNISWAP_V3_SWAP_ROUTER;
        params.tokenIn = _DAI_ADDRESS;
        params.tokenOut = _USDC_ADDRESS;
        params.fee = 3000;
        params.recipient = address(circleZapper);
        params.deadline = block.timestamp;
        params.amountIn = 500e18;
        params.amountOutMinimum = 0;
        params.sqrtPriceLimitX96 = 0;
        swapData.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector,
            params
        );
    }

    function test_borrowAndBridge_fail_whenSwapDataIsInvalid() public {
        swapData.inputToken = _USDC_ADDRESS;

        vm.startPrank(user1);

        eDAI.setDelegateApproval(address(circleZapper), true);

        vm.expectRevert(
            BorrowCircleZapper.BorrowCircleZapper__InvalidSwapData.selector
        );
        circleZapper.borrowAndBridge{ value: _ONE }(
            address(eDAI),
            500e18,
            swapData,
            42161,
            0
        );

        vm.stopPrank();
    }

    function test_borrowAndBridge_fail_whenCCTPIsNotConfigured() public {
        centralRegistry.setCircleTokenMessenger(address(0));

        vm.startPrank(user1);

        eDAI.setDelegateApproval(address(circleZapper), true);

        vm.expectRevert(
            BorrowCircleZapper.BorrowCircleZapper__CCTPIsNotConfigured.selector
        );
        circleZapper.borrowAndBridge{ value: _ONE }(
            address(eDAI),
            500e18,
            swapData,
            42161,
            0
        );

        vm.stopPrank();
    }

    function test_borrowAndBridge_fail_whenGasTokenIsNotEnough() public {
        uint256 messageFee = circleZapper.quoteMessageFee(42161, 0);

        vm.startPrank(user1);

        eDAI.setDelegateApproval(address(circleZapper), true);

        vm.expectRevert(
            BorrowCircleZapper
                .BorrowCircleZapper__InsufficientGasToken
                .selector
        );
        circleZapper.borrowAndBridge{ value: messageFee - 1 }(
            address(eDAI),
            500e18,
            swapData,
            42161,
            0
        );

        vm.stopPrank();
    }

    function test_borrowAndBridge_success() public {
        uint256 messageFee = circleZapper.quoteMessageFee(42161, 0);
        uint256 balance = user1.balance;

        vm.startPrank(user1);

        eDAI.setDelegateApproval(address(circleZapper), true);
        circleZapper.borrowAndBridge{ value: _ONE }(
            address(eDAI),
            500e18,
            swapData,
            42161,
            0
        );
        eDAI.borrow(500e18);

        vm.stopPrank();

        assertEq(user1.balance, balance - messageFee);
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
