// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IPendlePTOracle } from "contracts/interfaces/external/pendle/IPendlePtOracle.sol";
import { IUniswapV3Router } from "contracts/interfaces/external/uniswap/IUniswapV3Router.sol";
import { IEToken } from "contracts/interfaces/IEToken.sol";
import { IPToken } from "contracts/interfaces/IPToken.sol";

import { EToken } from "contracts/market/token/EToken.sol";
import { NativeUniversalBalance } from "contracts/architecture/NativeUniversalBalance.sol";
import { Multicall } from "contracts/libraries/Multicall.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { SimplePToken } from "contracts/market/token/SimplePToken.sol";
import { MockPythAdaptor } from "contracts/mocks/MockPythAdaptor.sol";
import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";
import { PythAdaptor } from "contracts/oracles/adaptors/pyth/PythAdaptor.sol";
import { BaseMulticallChecker } from "contracts/calldata-checker/multicall-checker/BaseMulticallChecker.sol";
import { PythAdaptorMulticallChecker } from "contracts/calldata-checker/multicall-checker/PythAdaptorMulticallChecker.sol";
import { SimplePositionManager } from "contracts/market/position-management/SimplePositionManager.sol";
import "tests/market/TestBaseMarketIsolated.sol";

contract User {}

contract TestPythAdaptorMulticall is TestBaseMarketIsolated {
    address internal _UNISWAP_V3_SWAP_ROUTER =
        0xE592427A0AEce92De3Edee1F18E0157C05861564;

    address public owner;

    MockPythAdaptor public adapter;
    PythAdaptorMulticallChecker public multicallChecker;

    MockDataFeed public mockUsdcFeed;
    MockDataFeed public mockWethFeed;
    MockDataFeed public mockStethFeed;

    SimplePToken public pWBTC;
    NativeUniversalBalance public nativeUniversalBalance;

    address internal _PYTH_ADDRESS =
        0x4305FB66699C3B2702D4d05CF36551390A4c69C6;

    EToken public eWETH;
    SimplePositionManager public positionManagement;

    receive() external payable {}

    fallback() external payable {}

    function setUp() public override {
        super.setUp();

        owner = address(this);

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
            address(mockUsdcFeed),
            0,
            true
        );
        dualChainlinkAdaptor.addAsset(
            _WETH_ADDRESS,
            address(mockUsdcFeed),
            0,
            true
        );

        eWETH = _deployEToken(_WETH_ADDRESS);

        nativeUniversalBalance = new NativeUniversalBalance(
            ICentralRegistry(address(centralRegistry)),
            address(eWETH),
            _WETH_ADDRESS
        );

        adapter = new MockPythAdaptor(
            ICentralRegistry(address(centralRegistry)),
            address(nativeUniversalBalance),
            _PYTH_ADDRESS,
            _WETH_ADDRESS
        );

        PythAdaptor.AdaptorData memory data;
        data
            .priceId = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;
        data.isConfigured = true;
        data.heartbeat = 24 hours;
        data.max = 1000000 ether;
        data.min = 0 ether;
        adapter.addAsset(_WBTC_ADDRESS, true, data);
        vm.warp(1711335100);

        multicallChecker = new PythAdaptorMulticallChecker(
            address(centralRegistry)
        );
        centralRegistry.setMulticallChecker(
            address(adapter),
            address(multicallChecker)
        );

        oracleManager.addApprovedAdaptor(address(adapter));

        bytes[] memory priceUpdateData = new bytes[](1);
        priceUpdateData[
            0
        ] = hex"504e41550100000003b801000000030d020a7b7ffb72301af2e092a12e041ae6a78170dd07c24e217cbdb0a8039e7d18bb7c6ee9ef2ccda22577215495b143d8c4fc1176df69b764b40f158016a8cf36b60104757f964d92c47d33631cee4dfccc3f45f42bff015c2aa83acd9e74c67f9fbb511883c492b57008527dd56aa7e9c7ab6ad1eb4673893bbd009416bd61b7a4ceae010610d9d51d01e93ced4f599587306e2cbf14f471a1a1b1bc39acca921e151e900153ce57ccd5c4c19db9ec502e08c79efc685732f8ae5d3e0335dd089c01631ce1010755010fd2bc0912835c143b27631a1f09b6b86fa9f822a2662b86657a27a4167a2fa8edf27d95ecd61dbf58117708bfb53c066d3b3469557d1d00ed8f5c8834740108f4f2534dfe7b5e87281781e484a73d551c43a653e42eb9fd6a7ead250818127e5752b2ff21d506e2bdf282f285cf69c0524c1cf7e2af57a94873cb6960d324d9000ae6b90a7c36433981ece47bceaae676f9ccddf914d8946cfe96a8ebe8cb216a4c1771dcbd25185dfbf357b286d4184f05eb8aef1291cd63812adeb985335d03dc010b78e0948b52499efb548bb218faa4571a10262b8b0272a8ff49ba22c233f571f54089fe5c3ebcf288b26167fe5b8b9a228a9e6dff67f41891c4753bda84909776000c5d6372be8617082f53254f65208281699e8e596d7d1e88fb582972db79b175477322fcf6552372705607547505608d66d619dadac3a9c851df4e899b61d44466010de8d731d9ff0d060c26b12e4dc49cd9b34135747110f0ec2a2d5e86607cce8f2d228fb25235f29792f4af72b462765aadf5cb08cf697f8a2ba578ed49c2e1160f000ed1bb44ca27af02ea6f6779add5b9f7b0195785c09d245c1616e13d9db157dabe75c9ce4a3acf87042e8ef1c40bed721a87c1d96c828a52b5698583445bc691ea000f94ba9e599f54e41b51fd4c491d005c0d5af40f0f10000a59abac698a4cbc49880ebe0e82747521b39e5f569ad1cf97e502327247b09a171e0765a490629c4a370110f22d63f7e49ff0b3873f5cb6877f32e0cf380085edb6a0e66802b8a24a9ebdf6051cfea4cf5da6aad6458b1a1594884729d409b38edb984a7aced5ab821345e5011221e43e4720c590a639eb09094bcfed44c5785cda54eb50353291c6a746f4d1d15548b670b3c3a28135612df19df50d3dbbdeb6cc9566dd4a259b18b100d3543d016600e58e00000000001ae101faedac5851e32b9b23b5f9411a8c2bac4aae3ed4dd7b811dd1a72ea4aa710000000002c780310141555756000000000007d0d7e7000027101d0fab54a256ec0b3c3d1cfdf581e7e6247f470401005500e62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b4300000610b389158800000000b8380842fffffff8000000006600e58e000000006600e58e00000610a18e492000000000c09246340a941e1745f663bb2f0eea9f8e51a7036d28a429632fe998b4d09fa9eb8a81c4cc48e6ed6417f53e8f49671b3ebceff073d9aea4752c8a8cc7fd70d0e3204f5d77edd037f1be9594667373c44c2cc78f64be672d431343901f8cbd68b2aad00861c1a6a962d6c58076ebfd33b19e54a97917a8c27987ce112e71b572ade229c085913ca65a283db13d8d936027d9e7ff1e3c18ce00f076d7f4503ed097bf8f36a55d815057287f9662e45a90bc4475fcc14514eca3077251162e95954ca370843e8d4e5c1a49299797";
        adapter.updateFeedsWithNative{ value: 1 ether }(priceUpdateData);
        oracleManager.addAssetPriceFeed(_WBTC_ADDRESS, address(adapter));

        // start epoch
        vm.warp(gaugeManager.gaugeStartTime());
        vm.roll(block.number + 1000);

        mockUsdcFeed.setMockUpdatedAt(block.timestamp);

        // // deploy eUSDC
        // {
        //     _deployEUSDC();
        //     // support market
        //     _prepareUSDC(owner, 200000e6);
        //     usdc.approve(address(eUSDC), 200000e6);
        //     marketManagerIsolated.listToken(address(eUSDC));
        //     // add MToken support on oracle manager
        //     oracleManager.addMTokenSupport(address(eUSDC));
        //     address[] memory markets = new address[](1);
        //     markets[0] = address(eUSDC);
        //     // vm.prank(user1);
        //     // marketManager.enterMarkets(markets);
        //     // vm.prank(user2);
        //     // marketManager.enterMarkets(markets);
        // }

        // deploy eWETH
        {
            // support market
            _prepareWETH(owner, 200000 ether);
            weth.approve(address(eWETH), 200000e6);
            // add MToken support on oracle manager
            oracleManager.addMTokenSupport(address(eWETH));
            address[] memory markets = new address[](1);
            markets[0] = address(eWETH);
            // vm.prank(user1);
            // marketManager.enterMarkets(markets);
            // vm.prank(user2);
            // marketManager.enterMarkets(markets);
        }

        // deploy pWBTC
        {
            // deploy aura position vault
            pWBTC = new SimplePToken(
                ICentralRegistry(address(centralRegistry)),
                wbtc,
                address(marketManagerIsolated)
            );

            // support market
            _prepareWBTC(owner, 1e8);
            wbtc.approve(address(pWBTC), 1e8);
            // add MToken support on oracle manager
            oracleManager.addMTokenSupport(address(pWBTC));
            // set position token configuration
        }

        marketManagerIsolated.listTokens(address(pWBTC), address(eWETH));

        marketManagerIsolated.updatePositionToken(
            7000,    // collRatio 70%
            4000,    // collReqSoft 40%
            3000,    // collReqHard 25%
            1000,    // liqIncBase 10%
            1500,    // liqIncHard 15%
            500,     // liqIncMin 5%
            2000,    // liqIncMax 20%
            2000,    // minEffectiveCFactor 20%
            3000,    // maxEffectiveCFactor 30%
            1000     // baseCFactor 10%
        );


        address[] memory mTokens = new address[](1);
        mTokens[0] = address(pWBTC);
        uint256[] memory caps = new uint256[](1);
        caps[0] = 100e8;
        marketManagerIsolated.setCollateralCaps(mTokens, caps);

        // provide enough liquidity
        provideEnoughLiquidityForLeverage();

        // setup position management
        {
            positionManagement = new SimplePositionManager(
                ICentralRegistry(address(centralRegistry)),
                address(marketManagerIsolated),
                _WETH_ADDRESS
            );
            marketManagerIsolated.addPositionManager(address(positionManagement));
        }

        address[] memory multicallProviders = new address[](2);
        multicallProviders[0] = address(pWBTC);
        multicallProviders[1] = address(positionManagement);
        centralRegistry.setMulticallProviders(multicallProviders, true);

        centralRegistry.setExternalCalldataChecker(
            _UNISWAP_V3_SWAP_ROUTER,
            address(new MockCalldataChecker(_UNISWAP_V3_SWAP_ROUTER))
        );
    }

    function provideEnoughLiquidityForLeverage() internal {
        address liquidityProvider = address(new User());
        // _prepareUSDC(liquidityProvider, 200000e6);
        _prepareWBTC(liquidityProvider, 10 ether);
        _prepareWETH(liquidityProvider, 200000 ether);
        // mint eUSDC
        vm.startPrank(liquidityProvider);
        // usdc.approve(address(eUSDC), 200000e6);
        // eUSDC.mint(200000e6);
        // mint eWETH
        weth.approve(address(eWETH), 200000e6);
        eWETH.mint(200000e6);
        // mint pWBTC
        wbtc.approve(address(pWBTC), 10 ether);
        pWBTC.mint(10 ether, liquidityProvider);
        vm.stopPrank();
    }

    function testInitialize() public {
        assertTrue(pWBTC.isPToken());
        // assertFalse(eUSDC.isPToken());
    }

    function testPTokenMintMulticall() public {
        // provide fee to universal balance
        vm.deal(user1, 1 ether);
        vm.prank(user1);
        nativeUniversalBalance.depositNative{ value: 1 ether }(false);

        _prepareWBTC(user1, 2 ether);

        vm.prank(user1);
        wbtc.approve(address(pWBTC), 1e8);

        Multicall.MulticallData[] memory calls = new Multicall.MulticallData[](
            2
        );
        calls[0].target = address(adapter);
        bytes[] memory priceUpdateData = new bytes[](1);
        priceUpdateData[
            0
        ] = hex"504e41550100000003b801000000030d020a7b7ffb72301af2e092a12e041ae6a78170dd07c24e217cbdb0a8039e7d18bb7c6ee9ef2ccda22577215495b143d8c4fc1176df69b764b40f158016a8cf36b60104757f964d92c47d33631cee4dfccc3f45f42bff015c2aa83acd9e74c67f9fbb511883c492b57008527dd56aa7e9c7ab6ad1eb4673893bbd009416bd61b7a4ceae010610d9d51d01e93ced4f599587306e2cbf14f471a1a1b1bc39acca921e151e900153ce57ccd5c4c19db9ec502e08c79efc685732f8ae5d3e0335dd089c01631ce1010755010fd2bc0912835c143b27631a1f09b6b86fa9f822a2662b86657a27a4167a2fa8edf27d95ecd61dbf58117708bfb53c066d3b3469557d1d00ed8f5c8834740108f4f2534dfe7b5e87281781e484a73d551c43a653e42eb9fd6a7ead250818127e5752b2ff21d506e2bdf282f285cf69c0524c1cf7e2af57a94873cb6960d324d9000ae6b90a7c36433981ece47bceaae676f9ccddf914d8946cfe96a8ebe8cb216a4c1771dcbd25185dfbf357b286d4184f05eb8aef1291cd63812adeb985335d03dc010b78e0948b52499efb548bb218faa4571a10262b8b0272a8ff49ba22c233f571f54089fe5c3ebcf288b26167fe5b8b9a228a9e6dff67f41891c4753bda84909776000c5d6372be8617082f53254f65208281699e8e596d7d1e88fb582972db79b175477322fcf6552372705607547505608d66d619dadac3a9c851df4e899b61d44466010de8d731d9ff0d060c26b12e4dc49cd9b34135747110f0ec2a2d5e86607cce8f2d228fb25235f29792f4af72b462765aadf5cb08cf697f8a2ba578ed49c2e1160f000ed1bb44ca27af02ea6f6779add5b9f7b0195785c09d245c1616e13d9db157dabe75c9ce4a3acf87042e8ef1c40bed721a87c1d96c828a52b5698583445bc691ea000f94ba9e599f54e41b51fd4c491d005c0d5af40f0f10000a59abac698a4cbc49880ebe0e82747521b39e5f569ad1cf97e502327247b09a171e0765a490629c4a370110f22d63f7e49ff0b3873f5cb6877f32e0cf380085edb6a0e66802b8a24a9ebdf6051cfea4cf5da6aad6458b1a1594884729d409b38edb984a7aced5ab821345e5011221e43e4720c590a639eb09094bcfed44c5785cda54eb50353291c6a746f4d1d15548b670b3c3a28135612df19df50d3dbbdeb6cc9566dd4a259b18b100d3543d016600e58e00000000001ae101faedac5851e32b9b23b5f9411a8c2bac4aae3ed4dd7b811dd1a72ea4aa710000000002c780310141555756000000000007d0d7e7000027101d0fab54a256ec0b3c3d1cfdf581e7e6247f470401005500e62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b4300000610b389158800000000b8380842fffffff8000000006600e58e000000006600e58e00000610a18e492000000000c09246340a941e1745f663bb2f0eea9f8e51a7036d28a429632fe998b4d09fa9eb8a81c4cc48e6ed6417f53e8f49671b3ebceff073d9aea4752c8a8cc7fd70d0e3204f5d77edd037f1be9594667373c44c2cc78f64be672d431343901f8cbd68b2aad00861c1a6a962d6c58076ebfd33b19e54a97917a8c27987ce112e71b572ade229c085913ca65a283db13d8d936027d9e7ff1e3c18ce00f076d7f4503ed097bf8f36a55d815057287f9662e45a90bc4475fcc14514eca3077251162e95954ca370843e8d4e5c1a49299797";
        calls[0].data = abi.encodeWithSelector(
            PythAdaptor.updateFeedsFromUniversalBalance.selector,
            priceUpdateData,
            user1
        );
        calls[0].isPriceUpdate = true;

        calls[1].target = address(pWBTC);
        calls[1].data = abi.encodeWithSelector(
            pWBTC.mint.selector,
            1e8,
            user1
        );

        // try mint()
        vm.prank(user1);
        pWBTC.multicall(calls);

        assertEq(pWBTC.balanceOf(user1), 1e8);
    }

    function testETokenMintWithMulticall() public {
        // provide fee to universal balance
        vm.deal(user1, 1 ether);
        vm.prank(user1);
        nativeUniversalBalance.depositNative{ value: 1 ether }(false);

        _prepareWETH(user1, 2 ether);

        vm.prank(user1);
        weth.approve(address(eWETH), 1 ether);

        Multicall.MulticallData[] memory calls = new Multicall.MulticallData[](2);
        calls[0].target = address(adapter);
        bytes[] memory priceUpdateData = new bytes[](1);
        priceUpdateData[0] = hex"504e41550100000003b801000000030d020a7b7ffb72301af2e092a12e041ae6a78170dd07c24e217cbdb0a8039e7d18bb7c6ee9ef2ccda22577215495b143d8c4fc1176df69b764b40f158016a8cf36b60104757f964d92c47d33631cee4dfccc3f45f42bff015c2aa83acd9e74c67f9fbb511883c492b57008527dd56aa7e9c7ab6ad1eb4673893bbd009416bd61b7a4ceae010610d9d51d01e93ced4f599587306e2cbf14f471a1a1b1bc39acca921e151e900153ce57ccd5c4c19db9ec502e08c79efc685732f8ae5d3e0335dd089c01631ce1010755010fd2bc0912835c143b27631a1f09b6b86fa9f822a2662b86657a27a4167a2fa8edf27d95ecd61dbf58117708bfb53c066d3b3469557d1d00ed8f5c8834740108f4f2534dfe7b5e87281781e484a73d551c43a653e42eb9fd6a7ead250818127e5752b2ff21d506e2bdf282f285cf69c0524c1cf7e2af57a94873cb6960d324d9000ae6b90a7c36433981ece47bceaae676f9ccddf914d8946cfe96a8ebe8cb216a4c1771dcbd25185dfbf357b286d4184f05eb8aef1291cd63812adeb985335d03dc010b78e0948b52499efb548bb218faa4571a10262b8b0272a8ff49ba22c233f571f54089fe5c3ebcf288b26167fe5b8b9a228a9e6dff67f41891c4753bda84909776000c5d6372be8617082f53254f65208281699e8e596d7d1e88fb582972db79b175477322fcf6552372705607547505608d66d619dadac3a9c851df4e899b61d44466010de8d731d9ff0d060c26b12e4dc49cd9b34135747110f0ec2a2d5e86607cce8f2d228fb25235f29792f4af72b462765aadf5cb08cf697f8a2ba578ed49c2e1160f000ed1bb44ca27af02ea6f6779add5b9f7b0195785c09d245c1616e13d9db157dabe75c9ce4a3acf87042e8ef1c40bed721a87c1d96c828a52b5698583445bc691ea000f94ba9e599f54e41b51fd4c491d005c0d5af40f0f10000a59abac698a4cbc49880ebe0e82747521b39e5f569ad1cf97e502327247b09a171e0765a490629c4a370110f22d63f7e49ff0b3873f5cb6877f32e0cf380085edb6a0e66802b8a24a9ebdf6051cfea4cf5da6aad6458b1a1594884729d409b38edb984a7aced5ab821345e5011221e43e4720c590a639eb09094bcfed44c5785cda54eb50353291c6a746f4d1d15548b670b3c3a28135612df19df50d3dbbdeb6cc9566dd4a259b18b100d3543d016600e58e00000000001ae101faedac5851e32b9b23b5f9411a8c2bac4aae3ed4dd7b811dd1a72ea4aa710000000002c780310141555756000000000007d0d7e7000027101d0fab54a256ec0b3c3d1cfdf581e7e6247f470401005500e62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b4300000610b389158800000000b8380842fffffff8000000006600e58e000000006600e58e00000610a18e492000000000c09246340a941e1745f663bb2f0eea9f8e51a7036d28a429632fe998b4d09fa9eb8a81c4cc48e6ed6417f53e8f49671b3ebceff073d9aea4752c8a8cc7fd70d0e3204f5d77edd037f1be9594667373c44c2cc78f64be672d431343901f8cbd68b2aad00861c1a6a962d6c58076ebfd33b19e54a97917a8c27987ce112e71b572ade229c085913ca65a283db13d8d936027d9e7ff1e3c18ce00f076d7f4503ed097bf8f36a55d815057287f9662e45a90bc4475fcc14514eca3077251162e95954ca370843e8d4e5c1a49299797"; // placeholder for hex data

        calls[0].data = abi.encodeWithSelector(
            PythAdaptor.updateFeedsFromUniversalBalance.selector,
            priceUpdateData,
            user1
        );
        calls[0].isPriceUpdate = true;

        calls[1].target = address(eWETH);
        calls[1].data = abi.encodeWithSelector(eWETH.mint.selector, 1 ether);

        // try mint()
        vm.prank(user1);
        eWETH.multicall(calls);

        assertEq(eWETH.balanceOf(user1), 1 ether);
    }

    function testPositionLeverage() public {
        centralRegistry.setSlippageLimit(6000);

        // provide fee to universal balance
        vm.deal(user1, 1 ether);
        vm.prank(user1);
        nativeUniversalBalance.depositNative{ value: 1 ether }(false);

        _prepareWBTC(user1, 0.1e8);
        vm.prank(user1);
        wbtc.approve(address(pWBTC), 0.1e8);

        vm.prank(user1);
        assertGt(pWBTC.deposit(0.1e8, user1), 0);
        vm.prank(user1);
        pWBTC.postCollateral(0.1e8);
        assertEq(pWBTC.balanceOf(user1), 0.1e8);

        uint256 amountForLeverage = (positionManagement.maxRemainingLeverageOf(
            user1,
            address(eWETH)
        ) * 50) / 100;

        SimplePositionManager.LeverageStruct memory leverageData;
        leverageData.borrowToken = IEToken(address(eWETH));
        leverageData.borrowAmount = amountForLeverage;
        leverageData.positionToken = IPToken(address(pWBTC));
        leverageData.swapData.inputToken = _WETH_ADDRESS;
        leverageData.swapData.inputAmount = amountForLeverage;
        leverageData.swapData.outputToken = _WBTC_ADDRESS;
        leverageData.swapData.target = address(_UNISWAP_V3_SWAP_ROUTER);
        leverageData.swapData.slippage = 2e18;
        IUniswapV3Router.ExactInputSingleParams memory params;
        params.tokenIn = _WETH_ADDRESS;
        params.tokenOut = _WBTC_ADDRESS;
        params.fee = 3000;
        params.recipient = address(positionManagement);
        params.deadline = block.timestamp;
        params.amountIn = amountForLeverage;
        params.amountOutMinimum = 0;
        params.sqrtPriceLimitX96 = 0;
        leverageData.swapData.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector,
            params
        );
        leverageData.auxData = bytes("");

        Multicall.MulticallData[] memory calls = new Multicall.MulticallData[](2);
        calls[0].target = address(adapter);
        bytes[] memory priceUpdateData = new bytes[](1);
        priceUpdateData[0] = "504e41550100000003b801000000030d020a7b7ffb72301af2e092a12e041ae6a78170dd07c24e217cbdb0a8039e7d18bb7c6ee9ef2ccda22577215495b143d8c4fc1176df69b764b40f158016a8cf36b60104757f964d92c47d33631cee4dfccc3f45f42bff015c2aa83acd9e74c67f9fbb511883c492b57008527dd56aa7e9c7ab6ad1eb4673893bbd009416bd61b7a4ceae010610d9d51d01e93ced4f599587306e2cbf14f471a1a1b1bc39acca921e151e900153ce57ccd5c4c19db9ec502e08c79efc685732f8ae5d3e0335dd089c01631ce1010755010fd2bc0912835c143b27631a1f09b6b86fa9f822a2662b86657a27a4167a2fa8edf27d95ecd61dbf58117708bfb53c066d3b3469557d1d00ed8f5c8834740108f4f2534dfe7b5e87281781e484a73d551c43a653e42eb9fd6a7ead250818127e5752b2ff21d506e2bdf282f285cf69c0524c1cf7e2af57a94873cb6960d324d9000ae6b90a7c36433981ece47bceaae676f9ccddf914d8946cfe96a8ebe8cb216a4c1771dcbd25185dfbf357b286d4184f05eb8aef1291cd63812adeb985335d03dc010b78e0948b52499efb548bb218faa4571a10262b8b0272a8ff49ba22c233f571f54089fe5c3ebcf288b26167fe5b8b9a228a9e6dff67f41891c4753bda84909776000c5d6372be8617082f53254f65208281699e8e596d7d1e88fb582972db79b175477322fcf6552372705607547505608d66d619dadac3a9c851df4e899b61d44466010de8d731d9ff0d060c26b12e4dc49cd9b34135747110f0ec2a2d5e86607cce8f2d228fb25235f29792f4af72b462765aadf5cb08cf697f8a2ba578ed49c2e1160f000ed1bb44ca27af02ea6f6779add5b9f7b0195785c09d245c1616e13d9db157dabe75c9ce4a3acf87042e8ef1c40bed721a87c1d96c828a52b5698583445bc691ea000f94ba9e599f54e41b51fd4c491d005c0d5af40f0f10000a59abac698a4cbc49880ebe0e82747521b39e5f569ad1cf97e502327247b09a171e0765a490629c4a370110f22d63f7e49ff0b3873f5cb6877f32e0cf380085edb6a0e66802b8a24a9ebdf6051cfea4cf5da6aad6458b1a1594884729d409b38edb984a7aced5ab821345e5011221e43e4720c590a639eb09094bcfed44c5785cda54eb50353291c6a746f4d1d15548b670b3c3a28135612df19df50d3dbbdeb6cc9566dd4a259b18b100d3543d016600e58e00000000001ae101faedac5851e32b9b23b5f9411a8c2bac4aae3ed4dd7b811dd1a72ea4aa710000000002c780310141555756000000000007d0d7e7000027101d0fab54a256ec0b3c3d1cfdf581e7e6247f470401005500e62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b4300000610b389158800000000b8380842fffffff8000000006600e58e000000006600e58e00000610a18e492000000000c09246340a941e1745f663bb2f0eea9f8e51a7036d28a429632fe998b4d09fa9eb8a81c4cc48e6ed6417f53e8f49671b3ebceff073d9aea4752c8a8cc7fd70d0e3204f5d77edd037f1be9594667373c44c2cc78f64be672d431343901f8cbd68b2aad00861c1a6a962d6c58076ebfd33b19e54a97917a8c27987ce112e71b572ade229c085913ca65a283db13d8d936027d9e7ff1e3c18ce00f076d7f4503ed097bf8f36a55d815057287f9662e45a90bc4475fcc14514eca3077251162e95954ca370843e8d4e5c1a49299797";
        
        calls[0].data = abi.encodeWithSelector(
            PythAdaptor.updateFeedsFromUniversalBalance.selector,
            priceUpdateData,
            user1
        );
        calls[0].isPriceUpdate = true;

        calls[1].target = address(positionManagement);
        calls[1].data = abi.encodeWithSelector(
            positionManagement.leverage.selector,
            leverageData
        );

        // try leverage()
        vm.prank(user1);
        positionManagement.multicall(calls);
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
            address(adapter),
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
            address(adapter),
            abi.encodeWithSelector(
                PythAdaptor.updateFeedsWithNative.selector,
                priceUpdateData
            )
        );
    }
}
