// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IPendlePTOracle } from "contracts/interfaces/external/pendle/IPendlePtOracle.sol";
import { IUniswapV3Router } from "contracts/interfaces/external/uniswap/IUniswapV3Router.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { ICToken } from "contracts/interfaces/ICToken.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { NativeUniversalBalance } from "contracts/architecture/NativeUniversalBalance.sol";
import { Multicall } from "contracts/libraries/Multicall.sol";
import { SimpleCToken } from "contracts/market/token/SimpleCToken.sol";

import { PythAdaptor } from "contracts/oracles/adaptors/pyth/PythAdaptor.sol";
import { BaseMulticallChecker } from "contracts/calldata-checker/multicall-checker/BaseMulticallChecker.sol";
import { PythAdaptorMulticallChecker } from "contracts/calldata-checker/multicall-checker/PythAdaptorMulticallChecker.sol";
import { SimplePositionManager } from "contracts/market/position-management/SimplePositionManager.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { MockPythAdaptor } from "contracts/mocks/MockPythAdaptor.sol";
import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";

contract TestPythAdaptorMulticall is TestBaseMarketIsolated {
    address internal _UNISWAP_V3_SWAP_ROUTER =
        0xE592427A0AEce92De3Edee1F18E0157C05861564;

    address public owner;

    MockPythAdaptor public pythAdaptor;
    PythAdaptorMulticallChecker public multicallChecker;

    SimpleCToken public cWBTC;
    NativeUniversalBalance public nativeUniversalBalance;

    address internal _PYTH_ADDRESS =
        0x4305FB66699C3B2702D4d05CF36551390A4c69C6;

    BorrowableCToken public borrowableCWETH;
    SimplePositionManager public positionManager;

    receive() external payable {}

    fallback() external payable {}

    function setUp() public override {
        super.setUp();

        owner = address(this);

        borrowableCWETH = _deployBorrowableCToken(_WETH_ADDRESS);

        nativeUniversalBalance = new NativeUniversalBalance(
            ICentralRegistry(address(centralRegistry)),
            address(borrowableCWETH),
            _WETH_ADDRESS
        );

        pythAdaptor = new MockPythAdaptor(
            ICentralRegistry(address(centralRegistry)),
            address(nativeUniversalBalance),
            _PYTH_ADDRESS,
            _WETH_ADDRESS
        );

        pythAdaptor.addAsset(
            _WBTC_ADDRESS,
            true,
            1 days,
            0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43
        );
        vm.roll(23293262);

        multicallChecker = new PythAdaptorMulticallChecker(ICentralRegistry(address(centralRegistry)));
        centralRegistry.setMulticallChecker(
            address(pythAdaptor),
            address(multicallChecker)
        );

        oracleManager.addApprovedAdaptor(address(pythAdaptor));

        bytes[] memory priceUpdateData = new bytes[](1);
        priceUpdateData[
            0
        ] = hex"504e41550100000003b801000000040d00e2e37a06095835540c9d2c497b1cd04f41edb5692ea2d72c2ab5d0ea46ffc0033b068424f6fc5e0a8fad5c981020d8821e9c27913cea0818b241187b0053ce0c0002351c706803e32b16496f0d8e3f629bf1b8b65c08d573408dd278eca2175ec0993cc6f91c6244004e1a73e484106f91fa008c3b1560f9d4f7a891723b9631cac2010368add62a17ed655b90e27f6fce90793a63ac35a872dbd9c0bc5be9e4633a84d070ea7da70732516307fe617119b6d930362e8d83265968b98dbd879533af2e2301043bca9b8eeda235e131498bd6e833a050be27c5fc942c690a5950af95020a4e3462cfd2e2b06c1472fe5de8bf9f34819feab775749482744cf561dec57eda21d600064e3320e9980dc91ea21e3ae94ea595e8013be8b4ba007d0ad5d88944a6e3d65f53b4e716e1f1d19db945f7972448f9a60323d50769615d6ca6bbe2bf55d0aaf50008933cd880fa3f9c16ccd2b00b646372bf74e2b0815ecd629a27bc741f17e21c6326056db33b2979632eb3293a7f63b54d44989ffd7fc1ad8cc036254733d7ed4c000a2c41eb3991fe3df870bc83d321998e325bcfb6869eee439fa8872f9e1f70305d5c0f61e575d528e68dc2971aa9411b19db96fde8b9b9461d64514c25fc468182000bd2807c7eb44685b8bb52828b2897d34f7c387e85978ea2d102b6e161fb16753d1821a057ba53c12e3bdad8680428d0409c0d74740badefdb365ba0ff96955897000ccf19a53d005f3064b5342e18edaf9c8412cfdf2a210f744140878cf2d0b2f7100ce12587d1b13ae2964705bb33760777c8ce2fe703728cffc09964ff0c8637aa010d9a81a187dc1f5d6b543aec4055e9db7d1c873f884c39e14f13e04b2693e221831b54be1e8168c75eda551f21032d7df8c9361b7479f6aaee987d6fb88773e256000e700e6921eaab26171a20520164f5f4ceab6537e7215d6cec7daabc32198ed2b2404bc8772b8b3259b46a074312dc8bbe04cc363c382930bb65b58fb4bcfcb7ac01102a405b93b434c5fc377f34b37756d0361bc549c37db80627927ef3a5eba9b49272904a9640c84fb1f62d6fbe95a54aea8d7b192ed270db113d29c861378e208a001184dfb3642d013d9ec3233257b8b25b0598fd7a0d8dd93f89e7df9fc19a437d6e339d164ed2e81e865abf4d8a124688d185032c78174669fce74fd4171b894f370168ba2adc00000000001ae101faedac5851e32b9b23b5f9411a8c2bac4aae3ed4dd7b811dd1a72ea4aa7100000000094a5bd4014155575600000000000e57f0a0000027101efe27efe3de4e5f6bc14a76209e1eea7549c37501005500e62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b4300000a0ebde0ceab00000000c2bb02f3fffffff80000000068ba2adc0000000068ba2adb00000a13f1dc410000000000cf1b27840de1bfe3a773c7994d01bf6f7adf9efe5dbe3999ead1b8c70063cfb7825801b67291cb0c4c588c8ff8e99c09de2caede93ddbac6290dbddbbe01bb4b9c83aa6069da6a733142fb87209d61a8a335f45ce9cedbcf82f11182b771cecb8b58a040d98bfa0b1c7fd24ba0cf49148cc11f59a7d6b81af84577541c986f71f1016f2fe63b199b2d1a53930bb02d3712e03a69c4f58fcb816e7376ecf1732aa5653d6537d6d3795a6e011f17d9e094794b774c7674e0ed3cfe366a130542a84c092227585c32033b0f85d5e1d25d568b9b1679f01eadb7ed1c91207e52e1cf768476e5999de18e01c2b8fff0197833c95b59c5e8a7962ed733c6ee6d014c7593df70b6ab26bd5e73";
        pythAdaptor.updateFeedsWithNative{ value: 1 ether }(priceUpdateData);
        
        // remove WBTC pricefeeds made in base market setup
        oracleManager.removeAssetPriceFeed(
            _WBTC_ADDRESS,
            address(chainlinkAdaptor)
        );
        oracleManager.removeAssetPriceFeed(
            _WBTC_ADDRESS,
            address(dualChainlinkAdaptor)
        );
        // Add the Pyth pythAdaptor as the price feed for WBTC.
        oracleManager.addAssetPriceFeed(_WBTC_ADDRESS, address(pythAdaptor));

        // start epoch
        vm.warp(gaugeManager.gaugeStartTime());
        vm.roll(block.number + 1000);

        mockUsdcFeed.setMockUpdatedAt(block.timestamp);

        // Setup borrowableCWETH.
        {
            _prepareWETH(owner, 200000 ether);
            weth.approve(address(borrowableCWETH), 200000e6);
            // add CToken support on oracle manager
            oracleManager.addCTokenSupport(address(borrowableCWETH));
            address[] memory markets = new address[](1);
            markets[0] = address(borrowableCWETH);
        }

        // Setup cWBTC.
        {
            cWBTC = new SimpleCToken(
                ICentralRegistry(address(centralRegistry)),
                wbtc,
                address(marketManagerIsolated)
            );

            _prepareWBTC(owner, 1e8);
            wbtc.approve(address(cWBTC), 1e8);
            // add CToken support on oracle manager
            oracleManager.addCTokenSupport(address(cWBTC));
        }

        marketManagerIsolated.listTokens(address(cWBTC), address(borrowableCWETH));

        _refreshMockFeeds();

        _setCTokenConfigBasic(address(cWBTC), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCWETH), 100_000e18, 1_000_000e18);

        // Provide enough liquidity for leveraging.
        _provideEnoughLiquidityForLeverage();

        // Setup position manager.
        {
            positionManager = new SimplePositionManager(
                ICentralRegistry(address(centralRegistry)),
                address(marketManagerIsolated),
                _WETH_ADDRESS
            );
            marketManagerIsolated.addPositionManager(address(positionManager));
        }

        nativeUniversalBalance.setDelegateApproval(address(cWBTC), true);
        nativeUniversalBalance.setDelegateApproval(address(positionManager), true);
        nativeUniversalBalance.setDelegateApproval(address(borrowableCWETH), true);

        centralRegistry.setExternalCalldataChecker(
            _UNISWAP_V3_SWAP_ROUTER,
            address(new MockCalldataChecker(_UNISWAP_V3_SWAP_ROUTER))
        );
    }

    function testCTokenMintMulticall() public {
        // provide fee to universal balance
        vm.deal(user1, 1 ether);
        vm.prank(user1);
        nativeUniversalBalance.depositNative{ value: 1 ether }(false);

        _prepareWBTC(user1, 2 ether);

        vm.prank(user1);
        wbtc.approve(address(cWBTC), 1e8);

        Multicall.MulticallAction[] memory calls = new Multicall.MulticallAction[](
            2
        );
        calls[0].target = address(pythAdaptor);
        bytes[] memory priceUpdateData = new bytes[](1);
        priceUpdateData[
            0
        ] = hex"504e41550100000003b801000000040d00e2e37a06095835540c9d2c497b1cd04f41edb5692ea2d72c2ab5d0ea46ffc0033b068424f6fc5e0a8fad5c981020d8821e9c27913cea0818b241187b0053ce0c0002351c706803e32b16496f0d8e3f629bf1b8b65c08d573408dd278eca2175ec0993cc6f91c6244004e1a73e484106f91fa008c3b1560f9d4f7a891723b9631cac2010368add62a17ed655b90e27f6fce90793a63ac35a872dbd9c0bc5be9e4633a84d070ea7da70732516307fe617119b6d930362e8d83265968b98dbd879533af2e2301043bca9b8eeda235e131498bd6e833a050be27c5fc942c690a5950af95020a4e3462cfd2e2b06c1472fe5de8bf9f34819feab775749482744cf561dec57eda21d600064e3320e9980dc91ea21e3ae94ea595e8013be8b4ba007d0ad5d88944a6e3d65f53b4e716e1f1d19db945f7972448f9a60323d50769615d6ca6bbe2bf55d0aaf50008933cd880fa3f9c16ccd2b00b646372bf74e2b0815ecd629a27bc741f17e21c6326056db33b2979632eb3293a7f63b54d44989ffd7fc1ad8cc036254733d7ed4c000a2c41eb3991fe3df870bc83d321998e325bcfb6869eee439fa8872f9e1f70305d5c0f61e575d528e68dc2971aa9411b19db96fde8b9b9461d64514c25fc468182000bd2807c7eb44685b8bb52828b2897d34f7c387e85978ea2d102b6e161fb16753d1821a057ba53c12e3bdad8680428d0409c0d74740badefdb365ba0ff96955897000ccf19a53d005f3064b5342e18edaf9c8412cfdf2a210f744140878cf2d0b2f7100ce12587d1b13ae2964705bb33760777c8ce2fe703728cffc09964ff0c8637aa010d9a81a187dc1f5d6b543aec4055e9db7d1c873f884c39e14f13e04b2693e221831b54be1e8168c75eda551f21032d7df8c9361b7479f6aaee987d6fb88773e256000e700e6921eaab26171a20520164f5f4ceab6537e7215d6cec7daabc32198ed2b2404bc8772b8b3259b46a074312dc8bbe04cc363c382930bb65b58fb4bcfcb7ac01102a405b93b434c5fc377f34b37756d0361bc549c37db80627927ef3a5eba9b49272904a9640c84fb1f62d6fbe95a54aea8d7b192ed270db113d29c861378e208a001184dfb3642d013d9ec3233257b8b25b0598fd7a0d8dd93f89e7df9fc19a437d6e339d164ed2e81e865abf4d8a124688d185032c78174669fce74fd4171b894f370168ba2adc00000000001ae101faedac5851e32b9b23b5f9411a8c2bac4aae3ed4dd7b811dd1a72ea4aa7100000000094a5bd4014155575600000000000e57f0a0000027101efe27efe3de4e5f6bc14a76209e1eea7549c37501005500e62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b4300000a0ebde0ceab00000000c2bb02f3fffffff80000000068ba2adc0000000068ba2adb00000a13f1dc410000000000cf1b27840de1bfe3a773c7994d01bf6f7adf9efe5dbe3999ead1b8c70063cfb7825801b67291cb0c4c588c8ff8e99c09de2caede93ddbac6290dbddbbe01bb4b9c83aa6069da6a733142fb87209d61a8a335f45ce9cedbcf82f11182b771cecb8b58a040d98bfa0b1c7fd24ba0cf49148cc11f59a7d6b81af84577541c986f71f1016f2fe63b199b2d1a53930bb02d3712e03a69c4f58fcb816e7376ecf1732aa5653d6537d6d3795a6e011f17d9e094794b774c7674e0ed3cfe366a130542a84c092227585c32033b0f85d5e1d25d568b9b1679f01eadb7ed1c91207e52e1cf768476e5999de18e01c2b8fff0197833c95b59c5e8a7962ed733c6ee6d014c7593df70b6ab26bd5e73";
        calls[0].data = abi.encodeWithSelector(
            PythAdaptor.updateFeedsFromUniversalBalance.selector,
            priceUpdateData,
            user1
        );
        calls[0].isPriceUpdate = true;

        calls[1].target = address(cWBTC);
        calls[1].data = abi.encodeWithSelector(
            cWBTC.mint.selector,
            1e8,
            user1
        );

        // try mint()
        vm.prank(user1);
        cWBTC.multicall(calls);

        assertEq(cWBTC.balanceOf(user1), 1e8);
    }

    function testBorrowableCTokenMintWithMulticall() public {
        // provide fee to universal balance
        vm.deal(user1, 1 ether);
        vm.prank(user1);
        nativeUniversalBalance.depositNative{ value: 1 ether }(false);

        _prepareWETH(user1, 2 ether);

        vm.prank(user1);
        weth.approve(address(borrowableCWETH), 1 ether);

        Multicall.MulticallAction[] memory calls = new Multicall.MulticallAction[](2);
        calls[0].target = address(pythAdaptor);
        bytes[] memory priceUpdateData = new bytes[](1);
        priceUpdateData[0] = hex"504e41550100000003b801000000040d00e2e37a06095835540c9d2c497b1cd04f41edb5692ea2d72c2ab5d0ea46ffc0033b068424f6fc5e0a8fad5c981020d8821e9c27913cea0818b241187b0053ce0c0002351c706803e32b16496f0d8e3f629bf1b8b65c08d573408dd278eca2175ec0993cc6f91c6244004e1a73e484106f91fa008c3b1560f9d4f7a891723b9631cac2010368add62a17ed655b90e27f6fce90793a63ac35a872dbd9c0bc5be9e4633a84d070ea7da70732516307fe617119b6d930362e8d83265968b98dbd879533af2e2301043bca9b8eeda235e131498bd6e833a050be27c5fc942c690a5950af95020a4e3462cfd2e2b06c1472fe5de8bf9f34819feab775749482744cf561dec57eda21d600064e3320e9980dc91ea21e3ae94ea595e8013be8b4ba007d0ad5d88944a6e3d65f53b4e716e1f1d19db945f7972448f9a60323d50769615d6ca6bbe2bf55d0aaf50008933cd880fa3f9c16ccd2b00b646372bf74e2b0815ecd629a27bc741f17e21c6326056db33b2979632eb3293a7f63b54d44989ffd7fc1ad8cc036254733d7ed4c000a2c41eb3991fe3df870bc83d321998e325bcfb6869eee439fa8872f9e1f70305d5c0f61e575d528e68dc2971aa9411b19db96fde8b9b9461d64514c25fc468182000bd2807c7eb44685b8bb52828b2897d34f7c387e85978ea2d102b6e161fb16753d1821a057ba53c12e3bdad8680428d0409c0d74740badefdb365ba0ff96955897000ccf19a53d005f3064b5342e18edaf9c8412cfdf2a210f744140878cf2d0b2f7100ce12587d1b13ae2964705bb33760777c8ce2fe703728cffc09964ff0c8637aa010d9a81a187dc1f5d6b543aec4055e9db7d1c873f884c39e14f13e04b2693e221831b54be1e8168c75eda551f21032d7df8c9361b7479f6aaee987d6fb88773e256000e700e6921eaab26171a20520164f5f4ceab6537e7215d6cec7daabc32198ed2b2404bc8772b8b3259b46a074312dc8bbe04cc363c382930bb65b58fb4bcfcb7ac01102a405b93b434c5fc377f34b37756d0361bc549c37db80627927ef3a5eba9b49272904a9640c84fb1f62d6fbe95a54aea8d7b192ed270db113d29c861378e208a001184dfb3642d013d9ec3233257b8b25b0598fd7a0d8dd93f89e7df9fc19a437d6e339d164ed2e81e865abf4d8a124688d185032c78174669fce74fd4171b894f370168ba2adc00000000001ae101faedac5851e32b9b23b5f9411a8c2bac4aae3ed4dd7b811dd1a72ea4aa7100000000094a5bd4014155575600000000000e57f0a0000027101efe27efe3de4e5f6bc14a76209e1eea7549c37501005500e62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b4300000a0ebde0ceab00000000c2bb02f3fffffff80000000068ba2adc0000000068ba2adb00000a13f1dc410000000000cf1b27840de1bfe3a773c7994d01bf6f7adf9efe5dbe3999ead1b8c70063cfb7825801b67291cb0c4c588c8ff8e99c09de2caede93ddbac6290dbddbbe01bb4b9c83aa6069da6a733142fb87209d61a8a335f45ce9cedbcf82f11182b771cecb8b58a040d98bfa0b1c7fd24ba0cf49148cc11f59a7d6b81af84577541c986f71f1016f2fe63b199b2d1a53930bb02d3712e03a69c4f58fcb816e7376ecf1732aa5653d6537d6d3795a6e011f17d9e094794b774c7674e0ed3cfe366a130542a84c092227585c32033b0f85d5e1d25d568b9b1679f01eadb7ed1c91207e52e1cf768476e5999de18e01c2b8fff0197833c95b59c5e8a7962ed733c6ee6d014c7593df70b6ab26bd5e73";

        calls[0].data = abi.encodeWithSelector(
            PythAdaptor.updateFeedsFromUniversalBalance.selector,
            priceUpdateData,
            user1
        );
        calls[0].isPriceUpdate = true;

        calls[1].target = address(borrowableCWETH);
        calls[1].data = abi.encodeWithSelector(borrowableCWETH.deposit.selector, 1 ether, user1);

        // try mint()
        vm.prank(user1);
        borrowableCWETH.multicall(calls);

        assertEq(borrowableCWETH.balanceOf(user1), 1 ether);
    }

    function testPositionLeverage() public {
        centralRegistry.setSlippageLimit(6000);

        // provide fee to universal balance
        vm.deal(user1, 1 ether);
        vm.prank(user1);
        nativeUniversalBalance.depositNative{ value: 1 ether }(false);

        _prepareWBTC(user1, 0.1e8);
        vm.prank(user1);
        wbtc.approve(address(cWBTC), 0.1e8);

        vm.prank(user1);
        assertGt(cWBTC.deposit(0.1e8, user1), 0);
        vm.prank(user1);
        cWBTC.postCollateral(0.1e8);
        assertEq(cWBTC.balanceOf(user1), 0.1e8);

        // Try leveraging with 50% of limit.
        uint256 amountForLeverage = _maxRemainingLeverageOfHelper(
            user1,
            address(borrowableCWETH)
        ) / 2;

        SimplePositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCWETH));
        leverageAction.borrowAssets = amountForLeverage;
        leverageAction.cToken = ICToken(address(cWBTC));
        leverageAction.swapAction.inputToken = _WETH_ADDRESS;
        leverageAction.swapAction.inputAmount = amountForLeverage;
        leverageAction.swapAction.outputToken = _WBTC_ADDRESS;
        leverageAction.swapAction.target = address(_UNISWAP_V3_SWAP_ROUTER);
        leverageAction.swapAction.slippage = 2e18;
        IUniswapV3Router.ExactInputSingleParams memory params;
        params.tokenIn = _WETH_ADDRESS;
        params.tokenOut = _WBTC_ADDRESS;
        params.fee = 3000;
        params.recipient = address(positionManager);
        params.deadline = block.timestamp;
        params.amountIn = amountForLeverage;
        params.amountOutMinimum = 0;
        params.sqrtPriceLimitX96 = 0;
        leverageAction.swapAction.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector,
            params
        );
        leverageAction.auxData = bytes("");

        Multicall.MulticallAction[] memory calls = new Multicall.MulticallAction[](2);
        calls[0].target = address(pythAdaptor);
        bytes[] memory priceUpdateData = new bytes[](1);
        priceUpdateData[0] = hex"504e41550100000003b801000000040d00e2e37a06095835540c9d2c497b1cd04f41edb5692ea2d72c2ab5d0ea46ffc0033b068424f6fc5e0a8fad5c981020d8821e9c27913cea0818b241187b0053ce0c0002351c706803e32b16496f0d8e3f629bf1b8b65c08d573408dd278eca2175ec0993cc6f91c6244004e1a73e484106f91fa008c3b1560f9d4f7a891723b9631cac2010368add62a17ed655b90e27f6fce90793a63ac35a872dbd9c0bc5be9e4633a84d070ea7da70732516307fe617119b6d930362e8d83265968b98dbd879533af2e2301043bca9b8eeda235e131498bd6e833a050be27c5fc942c690a5950af95020a4e3462cfd2e2b06c1472fe5de8bf9f34819feab775749482744cf561dec57eda21d600064e3320e9980dc91ea21e3ae94ea595e8013be8b4ba007d0ad5d88944a6e3d65f53b4e716e1f1d19db945f7972448f9a60323d50769615d6ca6bbe2bf55d0aaf50008933cd880fa3f9c16ccd2b00b646372bf74e2b0815ecd629a27bc741f17e21c6326056db33b2979632eb3293a7f63b54d44989ffd7fc1ad8cc036254733d7ed4c000a2c41eb3991fe3df870bc83d321998e325bcfb6869eee439fa8872f9e1f70305d5c0f61e575d528e68dc2971aa9411b19db96fde8b9b9461d64514c25fc468182000bd2807c7eb44685b8bb52828b2897d34f7c387e85978ea2d102b6e161fb16753d1821a057ba53c12e3bdad8680428d0409c0d74740badefdb365ba0ff96955897000ccf19a53d005f3064b5342e18edaf9c8412cfdf2a210f744140878cf2d0b2f7100ce12587d1b13ae2964705bb33760777c8ce2fe703728cffc09964ff0c8637aa010d9a81a187dc1f5d6b543aec4055e9db7d1c873f884c39e14f13e04b2693e221831b54be1e8168c75eda551f21032d7df8c9361b7479f6aaee987d6fb88773e256000e700e6921eaab26171a20520164f5f4ceab6537e7215d6cec7daabc32198ed2b2404bc8772b8b3259b46a074312dc8bbe04cc363c382930bb65b58fb4bcfcb7ac01102a405b93b434c5fc377f34b37756d0361bc549c37db80627927ef3a5eba9b49272904a9640c84fb1f62d6fbe95a54aea8d7b192ed270db113d29c861378e208a001184dfb3642d013d9ec3233257b8b25b0598fd7a0d8dd93f89e7df9fc19a437d6e339d164ed2e81e865abf4d8a124688d185032c78174669fce74fd4171b894f370168ba2adc00000000001ae101faedac5851e32b9b23b5f9411a8c2bac4aae3ed4dd7b811dd1a72ea4aa7100000000094a5bd4014155575600000000000e57f0a0000027101efe27efe3de4e5f6bc14a76209e1eea7549c37501005500e62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b4300000a0ebde0ceab00000000c2bb02f3fffffff80000000068ba2adc0000000068ba2adb00000a13f1dc410000000000cf1b27840de1bfe3a773c7994d01bf6f7adf9efe5dbe3999ead1b8c70063cfb7825801b67291cb0c4c588c8ff8e99c09de2caede93ddbac6290dbddbbe01bb4b9c83aa6069da6a733142fb87209d61a8a335f45ce9cedbcf82f11182b771cecb8b58a040d98bfa0b1c7fd24ba0cf49148cc11f59a7d6b81af84577541c986f71f1016f2fe63b199b2d1a53930bb02d3712e03a69c4f58fcb816e7376ecf1732aa5653d6537d6d3795a6e011f17d9e094794b774c7674e0ed3cfe366a130542a84c092227585c32033b0f85d5e1d25d568b9b1679f01eadb7ed1c91207e52e1cf768476e5999de18e01c2b8fff0197833c95b59c5e8a7962ed733c6ee6d014c7593df70b6ab26bd5e73";
        
        calls[0].data = abi.encodeWithSelector(
            PythAdaptor.updateFeedsFromUniversalBalance.selector,
            priceUpdateData,
            user1
        );
        calls[0].isPriceUpdate = true;

        calls[1].target = address(positionManager);
        calls[1].data = abi.encodeWithSelector(
            positionManager.leverage.selector,
            leverageAction,
            2e18
        );

        // try leverage()
        vm.prank(user1);
        positionManager.multicall(calls);
    }

    function testCheckCalldata() public {
        bytes[] memory priceUpdateData = new bytes[](1);
        priceUpdateData[
            0
        ] = hex"504e41550100000003b801000000030d020a7b7ffb72301af2e092a12e041ae6a78170dd07c24e217cbdb0a8039e7d18bb7c6ee9ef2ccda22577215495b143d8c4fc1176df69b764b40f158016a8cf36b60104757f964d92c47d33631cee4dfccc3f45f42bff015c2aa83acd9e74c67f9fbb511883c492b57008527dd56aa7e9c7ab6ad1eb4673893bbd009416bd61b7a4ceae010610d9d51d01e93ced4f599587306e2cbf14f471a1a1b1bc39acca921e151e900153ce57ccd5c4c19db9ec502e08c79efc685732f8ae5d3e0335dd089c01631ce1010755010fd2bc0912835c143b27631a1f09b6b86fa9f822a2662b86657a27a4167a2fa8edf27d95ecd61dbf58117708bfb53c066d3b3469557d1d00ed8f5c8834740108f4f2534dfe7b5e87281781e484a73d551c43a653e42eb9fd6a7ead250818127e5752b2ff21d506e2bdf282f285cf69c0524c1cf7e2af57a94873cb6960d324d9000ae6b90a7c36433981ece47bceaae676f9ccddf914d8946cfe96a8ebe8cb216a4c1771dcbd25185dfbf357b286d4184f05eb8aef1291cd63812adeb985335d03dc010b78e0948b52499efb548bb218faa4571a10262b8b0272a8ff49ba22c233f571f54089fe5c3ebcf288b26167fe5b8b9a228a9e6dff67f41891c4753bda84909776000c5d6372be8617082f53254f65208281699e8e596d7d1e88fb582972db79b175477322fcf6552372705607547505608d66d619dadac3a9c851df4e899b61d44466010de8d731d9ff0d060c26b12e4dc49cd9b34135747110f0ec2a2d5e86607cce8f2d228fb25235f29792f4af72b462765aadf5cb08cf697f8a2ba578ed49c2e1160f000ed1bb44ca27af02ea6f6779add5b9f7b0195785c09d245c1616e13d9db157dabe75c9ce4a3acf87042e8ef1c40bed721a87c1d96c828a52b5698583445bc691ea000f94ba9e599f54e41b51fd4c491d005c0d5af40f0f10000a59abac698a4cbc49880ebe0e82747521b39e5f569ad1cf97e502327247b09a171e0765a490629c4a370110f22d63f7e49ff0b3873f5cb6877f32e0cf380085edb6a0e66802b8a24a9ebdf6051cfea4cf5da6aad6458b1a1594884729d409b38edb984a7aced5ab821345e5011221e43e4720c590a639eb09094bcfed44c5785cda54eb50353291c6a746f4d1d15548b670b3c3a28135612df19df50d3dbbdeb6cc9566dd4a259b18b100d3543d016600e58e00000000001ae101faedac5851e32b9b23b5f9411a8c2bac4aae3ed4dd7b811dd1a72ea4aa710000000002c780310141555756000000000007d0d7e7000027101d0fab54a256ec0b3c3d1cfdf581e7e6247f470401005500e62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b4300000610b389158800000000b8380842fffffff8000000006600e58e000000006600e58e00000610a18e492000000000c09246340a941e1745f663bb2f0eea9f8e51a7036d28a429632fe998b4d09fa9eb8a81c4cc48e6ed6417f53e8f49671b3ebceff073d9aea4752c8a8cc7fd70d0e3204f5d77edd037f1be9594667373c44c2cc78f64be672d431343901f8cbd68b2aad00861c1a6a962d6c58076ebfd33b19e54a97917a8c27987ce112e71b572ade229c085913ca65a283db13d8d936027d9e7ff1e3c18ce00f076d7f4503ed097bf8f36a55d815057287f9662e45a90bc4475fcc14514eca3077251162e95954ca370843e8d4e5c1a49299797";

        vm.expectRevert(
            BaseMulticallChecker.MulticallChecker__TargetError.selector
        );
        multicallChecker.checkCalldata(
            address(this),
            address(this),
            abi.encodeWithSelector(
                PythAdaptor.updateFeedsFromUniversalBalance.selector,
                priceUpdateData,
                user1
            )
        );
        vm.expectRevert(
            BaseMulticallChecker.MulticallChecker__InvalidCalldata.selector
        );
        multicallChecker.checkCalldata(
            address(this),
            address(pythAdaptor),
            abi.encodeWithSelector(
                PythAdaptor.updateFeedsFromUniversalBalance.selector,
                priceUpdateData,
                user1
            )
        );
        vm.expectRevert(
            BaseMulticallChecker.MulticallChecker__InvalidFuncSig.selector
        );
        multicallChecker.checkCalldata(
            address(this),
            address(pythAdaptor),
            abi.encodeWithSelector(
                PythAdaptor.updateFeedsWithNative.selector,
                priceUpdateData
            )
        );
    }

    function _provideEnoughLiquidityForLeverage() internal {
        address liquidityProvider = user2;
        _prepareWBTC(liquidityProvider, 10 ether);
        _prepareWETH(liquidityProvider, 200000 ether);

        // Mint borrowable cWETH.
        vm.startPrank(liquidityProvider);
        weth.approve(address(borrowableCWETH), 200000e18);
        borrowableCWETH.deposit(200000e18, liquidityProvider);

        // Mint cWBTC.
        wbtc.approve(address(cWBTC), 10 ether);
        cWBTC.deposit(10 ether, liquidityProvider);
        vm.stopPrank();
    }
}
