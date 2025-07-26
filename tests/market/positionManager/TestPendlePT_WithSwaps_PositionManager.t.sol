// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { PendleLib } from "contracts/libraries/PendleLib.sol";
import { SwapType } from "contracts/interfaces/external/pendle/IPSwapAggregator.sol";
import { PendlePTPositionManager } from "contracts/market/position-management/PendlePTPositionManager.sol";
import { PendlePrincipalTokenAdaptor } from "contracts/oracles/adaptors/pendle/PendlePrincipalTokenAdaptor.sol";
import { SimpleCToken } from "contracts/market/token/SimpleCToken.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { ICToken, AccountSnapshot } from "contracts/interfaces/ICToken.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IPendleRouter } from "contracts/interfaces/external/pendle/IPendleRouter.sol";
import { IPendlePTOracle } from "contracts/interfaces/external/pendle/IPendlePtOracle.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IPMarket } from "contracts/interfaces/external/pendle/IPMarket.sol";
import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";

contract TestPendlePT_WithSwaps_PositionManager is TestBaseMarketIsolated {
    address internal _CHAINLINK_STETH_USD =
        0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8;
    IPendleRouter internal _ROUTER =
        IPendleRouter(0x888888888889758F76e7103c6CbF23ABbF58F946);
    address internal _WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address internal _PT_STETH = 0xb253Eff1104802b97aC7E3aC9FdD73AecE295a2c; // PT-stETH-24DEC25
    address internal _LP_STETH = 0x34280882267ffa6383B363E278B027Be083bBe3b; // YT-stETH-24DEC25/SY-stETH Market
    address internal _PT_ORACLE = 0x14030836AEc15B2ad48bB097bd57032559339c92;
    address internal _PENDLE_SWAP = 0x1e8b6Ac39f8A33f46a6Eb2D1aCD1047B99180AD1;

    PendlePTPositionManager public positionManager;
    PendlePrincipalTokenAdaptor public adaptor;
    SimpleCToken public cPendlePTSTETH;
    IERC20 public pendlePT = IERC20(_PT_STETH);

    address public owner;
    address public user;

    address positionManagerAddress = 0x27cc01A4676C73fe8b6d0933Ac991BfF1D77C4da;

    receive() external payable {}

    fallback() external payable {}

    function setUp() public override {
        // unused
    }

    function _setUpMarket(uint256 _preOrPost) internal {
        if (_preOrPost == 0) {
            // set up pre-swap market
            _fork(22084188);
        } else {
            // set up post-swap market
            _fork(22088673);
        }

        _deployCentralRegistry();
        _deployCVE();
        _deployRewardManager();
        _deployVeCVE();
        _deployGaugeManager();
        _deployOracleManager();
        _deployChainlinkAdaptors();
        _deployMarketManager();

        chainlinkAdaptor.addAsset(_STETH, _CHAINLINK_STETH_USD, 0, true);
        oracleManager.addAssetPriceFeed(_STETH, address(chainlinkAdaptor));

        centralRegistry.addHarvestPermissions(address(this));
        centralRegistry.setFeeManager(address(this));

        centralRegistry.setExternalCalldataChecker(
            _UNISWAP_V2_ROUTER,
            address(new MockCalldataChecker(_UNISWAP_V2_ROUTER))
        );

        adaptor = new PendlePrincipalTokenAdaptor(
            ICentralRegistry(address(centralRegistry)),
            IPendlePTOracle(_PT_ORACLE)
        );
        PendlePrincipalTokenAdaptor.AdaptorData memory adapterData;
        adapterData.market = IPMarket(_LP_STETH);
        adapterData.twapDuration = 12;
        adapterData.quoteAsset = _STETH;
        adapterData.quoteAssetDecimals = 18;
        adaptor.addAsset(_PT_STETH, adapterData);

        oracleManager.addApprovedAdaptor(address(adaptor));
        oracleManager.addAssetPriceFeed(_PT_STETH, address(adaptor));

        owner = address(this);
        user = user1;

        // Setup borrowable cDAI.
        {
            _deployBorrowableCDAI();
            // Add cToken support on Oracle Manager.
            oracleManager.addCTokenSupport(address(borrowableCDAI));

            _prepareDAI(owner, 200000e18);
            dai.approve(address(borrowableCDAI), 200000e18);
        }

        // Setup cPendlePTSTETH.
        {
            cPendlePTSTETH = new SimpleCToken(
                ICentralRegistry(address(centralRegistry)),
                pendlePT,
                address(marketManagerIsolated)
            );

            _preparePT(owner, 1 ether);
            pendlePT.approve(address(cPendlePTSTETH), 1 ether);
            
            // Add cToken support on Oracle Manager.
            oracleManager.addCTokenSupport(address(cPendlePTSTETH));

        }

        marketManagerIsolated.listTokens(address(cPendlePTSTETH), address(borrowableCDAI));

         _setCTokenConfigBasic(address(cPendlePTSTETH), 100_000e18, 0);
         _setCTokenConfigBasic(address(borrowableCDAI), 100_000e18, 100_000e18);

        positionManager = new PendlePTPositionManager(
            ICentralRegistry(address(centralRegistry)),
            address(marketManagerIsolated),
            _WETH_ADDRESS,
            _ROUTER
        );

        marketManagerIsolated.addPositionManager(address(positionManager));

        _provideEnoughLiquidityForLeverage();
        
        
    }

    function _preparePT(address _user, uint256 _amount) internal {
        deal(_PT_STETH, _user, _amount);
    }

    event debugUint(string, uint256);

    function _createLeverage() public {
        _setUpMarket(1);

        vm.startPrank(user);

        _preparePT(user, 1 ether);
        pendlePT.approve(address(cPendlePTSTETH), 1 ether);

        // Mint cPendlePTSTETH.
        assertGt(cPendlePTSTETH.deposit(1 ether, user), 0);
        cPendlePTSTETH.postCollateral(1 ether);
        assertEq(cPendlePTSTETH.balanceOf(user), 1 ether);

        uint256 balanceBeforeBorrow = dai.balanceOf(user);
        
        // Borrow borrowable cDAI.
        borrowableCDAI.borrow(100 ether, user);
        assertEq(balanceBeforeBorrow + 100 ether, dai.balanceOf(user));

        // Try leverage with 20% of max.
        uint256 amountForLeverage = (positionManager.maxRemainingLeverageOf(
            user,
            address(borrowableCDAI)
        ) * 20) / 100;

        PendlePTPositionManager.LeverageAction memory leverageAction;
        leverageAction.debtToken = IBorrowableCToken(address(borrowableCDAI));
        leverageAction.borrowAssets = amountForLeverage;
        leverageAction.collateralToken = ICToken(address(cPendlePTSTETH));
        PendleLib.PendleData memory data;
        data.approx.guessMin = 0.001e18;
        data.approx.guessMax = 10.0e18;
        data.approx.guessOffchain = 1.0e18;
        data.approx.maxIteration = 30;
        data.approx.eps = 1e15;
        data.input.tokenIn = _DAI_ADDRESS;
        data.input.netTokenIn = amountForLeverage;
        data.input.tokenMintSy = _WSTETH;
        data.input.pendleSwap = _PENDLE_SWAP;
        data.input.swapAction.swapType = SwapType.KYBERSWAP;
        data
            .input
            .swapAction
            .extRouter = 0x6131B5fae19EA4f9D964eAc0408E4408b66337b5;
        data
            .input
            .swapAction
            .extCalldata = hex"e21fd0e900000000000000000000000000000000000000000000000000000000000000200000000000000000000000000f4a1d7fdf4890be35e71f3e0bbc4a0ec377eca3000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000008400000000000000000000000000000000000000000000000000000000000000540000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000c00000000000000000000000006b175474e89094c44da98b954eedeac495271d0f0000000000000000000000007f39c581f595b53c5cb19bd0b3f8da6c935e2ca0000000000000000000000000888888888889758f76e7103c6cbf23abbf58f946000000000000000000000000000000000000000000000000000000007fffffff00000000000000000000000000000000000000000000000000000000000004e0000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000003000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000001400000000000000000000000000000000000000000000000000000000000000280000000000000000000000000000000000000000000000000000000000000004094f1a68200000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000002958191adc67739c9f000000000000000000000000f6e72db5454dd049d0788e411b06cfaf168530420000000000000000000000006b175474e89094c44da98b954eedeac495271d0f0000000000000000000000000f4a1d7fdf4890be35e71f3e0bbc4a0ec377eca3000000000000000000000000000000000000000000000000000000000000004063407a490000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000e00000000000000000000000000f4a1d7fdf4890be35e71f3e0bbc4a0ec377eca3000000000000000000000000e0554a476a092703abdb3ef35c80e0d76d32939f000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc2000000000000000000000000000000000000000000000000000000002d7556c100000000000000000000000000000000000000000000000000000001000276a40000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000004063407a490000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000e00000000000000000000000000f4a1d7fdf4890be35e71f3e0bbc4a0ec377eca3000000000000000000000000109830a1aaad605bbf02a9dfa7b0b92ec2fb7daa000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc20000000000000000000000007f39c581f595b53c5cb19bd0b3f8da6c935e2ca0000000000000000000000000000000000000000000000000054a08ea7d31485c00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000002000000000000000000000004a1e2982540000000000000000046af2bce0ec44180000000000000000000000006b175474e89094c44da98b954eedeac495271d0f0000000000000000000000007f39c581f595b53c5cb19bd0b3f8da6c935e2ca0000000000000000000000000000000000000000000000000000000000000016000000000000000000000000000000000000000000000000000000000000001a000000000000000000000000000000000000000000000000000000000000001e00000000000000000000000000000000000000000000000000000000000000200000000000000000000000000888888888889758f76e7103c6cbf23abbf58f94600000000000000000000000000000000000000000000002958191adc67739c9f00000000000000000000000000000000000000000000000004326699d5ad40b00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000022000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000f4a1d7fdf4890be35e71f3e0bbc4a0ec377eca3000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000002958191adc67739c9f000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000025e7b22536f75726365223a2250656e646c65222c22416d6f756e74496e555344223a223736332e34343136393232373437303335222c22416d6f756e744f7574555344223a223736342e37383531343439353030323235222c22526566657272616c223a22222c22466c616773223a302c22416d6f756e744f7574223a22333138333333363136373234333935303332222c2254696d657374616d70223a313734323438313039312c22526f7574654944223a2265666635633962322d653236652d343736622d613462312d613736393734303533633365222c22496e74656772697479496e666f223a7b224b65794944223a2231222c225369676e6174757265223a2243636454575675597566724a584e394257716c51665046566439565632543535457039336d366b556c566d2f5978535777542b6a2b796730384170424a2b35697654475670306768336e306e415366303233736769774850555169617958633351586d6e694d63315a5665566758524b2b4b344b6a5971504c46655a2f62654c56443046334353317467556c6855376d7a64546e446b6433536975473149456341716b4645726b53446f6234556934775a68664977715557706f6a6e79386631506d48704f4855694a4b6e77327a4873456d41553339646e6b4a3236443338566a6745626945736174617569776a633833674a6e694a75414d7748736e464a386942686834684849692b5938514647314e49757366666b58624936577a71716738686163394a2f586f736858596b43576f75326c6e2f4968684d6a5a7a5834624c4b71496c79417564434b716f4561473167767074513d3d227d7d0000";

        data.input.swapAction.needScale = false;
        leverageAction.auxData = abi.encode(_LP_STETH, 1, data);

        positionManager.leverage(leverageAction, 0.05e18); // 5% slippage

        AccountSnapshot memory borrowableCDAISnapshot = borrowableCDAI.getSnapshot(user);
        assertEq(borrowableCDAI.balanceOf(user), 0);
        assertEq(borrowableCDAISnapshot.debtBalance, 100 ether + amountForLeverage);

        AccountSnapshot memory cPendlePTSTETHSnapshot = cPendlePTSTETH
            .getSnapshot(user);
        assertGt(cPendlePTSTETHSnapshot.collateralPosted, 1 ether);
        assertEq(cPendlePTSTETHSnapshot.debtBalance, 0 ether);

        vm.stopPrank();
    }

    function _provideEnoughLiquidityForLeverage() internal {
        address liquidityProvider = makeAddr("liquidityProvider");

        _preparePT(liquidityProvider, 10 ether);
        _prepareDAI(liquidityProvider, 20000000e18);

        vm.startPrank(liquidityProvider);

        // Deposit borrowableCDAI.
        dai.approve(address(borrowableCDAI), 20000000 ether);
        borrowableCDAI.deposit(20000000 ether, liquidityProvider);

        // Deposit Pendle PT stETH.
        pendlePT.approve(address(cPendlePTSTETH), 10 ether);
        cPendlePTSTETH.deposit(10 ether, liquidityProvider);

        vm.stopPrank();
    }

    function testLeverageWithPreSwap_Success() public {
        _setUpMarket(0);

        vm.startPrank(user);

        uint256 initialPositionSize = 1 ether;

        _preparePT(user, initialPositionSize);
        pendlePT.approve(address(cPendlePTSTETH), initialPositionSize);

        // Mint cPendlePTSTETH.
        assertGt(cPendlePTSTETH.deposit(initialPositionSize, user), 0);
        cPendlePTSTETH.postCollateral(initialPositionSize);
        assertEq(cPendlePTSTETH.balanceOf(user), initialPositionSize);

        uint256 balanceBeforeBorrow = dai.balanceOf(user);
        
        // Borrow borrowable cDAI.
        borrowableCDAI.borrow(100 ether, user);
        assertEq(balanceBeforeBorrow + 100 ether, dai.balanceOf(user));

        // Try leverage with 20% of max.
        uint256 amountForLeverage = (positionManager.maxRemainingLeverageOf(
            user,
            address(borrowableCDAI)
        ) * 20) / 100;

        address[] memory path = new address[](2);
        path[0] = _DAI_ADDRESS;
        path[1] = _USDC_ADDRESS;

        address uniswapV2Router = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;

        uint256 estimatedUniswapOutputAmount = 778457529;

        vm.stopPrank();

        vm.prank(centralRegistry.emergencyCouncil());
        centralRegistry.transferEmergencyCouncil(address(this));

        centralRegistry.setSlippageLimit(1000);

        vm.stopPrank(); 

        vm.startPrank(user);

        // Create swapAction.
        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _DAI_ADDRESS;
        swapAction.inputAmount = amountForLeverage;
        swapAction.outputToken = _USDC_ADDRESS;
        swapAction.target = address(_UNISWAP_V2_ROUTER);
        swapAction.slippage = 1000 * 1e14;
        swapAction.call = abi.encodeWithSignature(
                        "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
                        amountForLeverage,
                        ((amountForLeverage * 98) / 100) / 10**12, // scale from 18 decimals to 6 decimals and apply 2% slippage
                        path,
                        address(positionManager),
                        block.timestamp + 30
        );

        PendlePTPositionManager.LeverageAction memory leverageAction;
        leverageAction.debtToken = IBorrowableCToken(address(borrowableCDAI));
        leverageAction.borrowAssets = amountForLeverage;
        leverageAction.collateralToken = ICToken(address(cPendlePTSTETH));
        PendleLib.PendleData memory data;
        data.approx.guessMin = 0.001e18;
        data.approx.guessMax = 10.0e18;
        data.approx.guessOffchain = 1.0e18;
        data.approx.maxIteration = 30;
        data.approx.eps = 1e15;
        data.input.tokenIn = _USDC_ADDRESS;
        data.input.netTokenIn = estimatedUniswapOutputAmount;
        data.input.tokenMintSy = _STETH;
        data.input.pendleSwap = _PENDLE_SWAP;
        data.input.swapAction.swapType = SwapType.KYBERSWAP;
        data
            .input
            .swapAction
            .extRouter = 0x6131B5fae19EA4f9D964eAc0408E4408b66337b5;
        data
            .input
            .swapAction
            .extCalldata = hex"e21fd0e900000000000000000000000000000000000000000000000000000000000000200000000000000000000000000f4a1d7fdf4890be35e71f3e0bbc4a0ec377eca3000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000000058000000000000000000000000000000000000000000000000000000000000007c000000000000000000000000000000000000000000000000000000000000004c0000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000c0000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48000000000000000000000000ae7ab96520de3a18e5e111b5eaab095312d7fe84000000000000000000000000888888888889758f76e7103c6cbf23abbf58f946000000000000000000000000000000000000000000000000000000007fffffff00000000000000000000000000000000000000000000000000000000000004600000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000030000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000016000000000000000000000000000000000000000000000000000000000000002c00000000000000000000000000000000000000000000000000000000000000040301a40330000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000a000000000000000000000000031373595f40ea48a7aab6cbcb0d377c6066e2dca000000000000000000000000000000000000000000000000000000002e6651b9000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48000000000000000000000000dac17f958d2ee523a2206206994597c13d831ec70000000000000000000000000f4a1d7fdf4890be35e71f3e0bbc4a0ec377eca30000000000000000000000000000000000000000000000000000000000000040593611990000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000001000000000000000000000000000d4a11d5eeaac28ec3f61d100daf4d40471f1852000000000000000000000000dac17f958d2ee523a2206206994597c13d831ec7000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc20000000000000000000000000f4a1d7fdf4890be35e71f3e0bbc4a0ec377eca3000000000000000000000000000000000000000000000000000000002e63dcb5000000000000000000000000000000000000000000000000000000000000000300000000000000000000000000000000000000000000000000000000000003e800000000000000000000000000000000000000000000000000000000000000320000000000000000000000000000000000000000000000000000000000000040eeb543140000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000544582e91f1369e00000000000000000000000000000000000000000000000000000000000000200000000000000000000000585db145e2000000000000000005445ba2389ad56b000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48000000000000000000000000ae7ab96520de3a18e5e111b5eaab095312d7fe84000000000000000000000000000000000000000000000000000000000000016000000000000000000000000000000000000000000000000000000000000001a000000000000000000000000000000000000000000000000000000000000001e00000000000000000000000000000000000000000000000000000000000000200000000000000000000000000888888888889758f76e7103c6cbf23abbf58f946000000000000000000000000000000000000000000000000000000002e6651b90000000000000000000000000000000000000000000000000500f0a6e8f97df20000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000022000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000f4a1d7fdf4890be35e71f3e0bbc4a0ec377eca30000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000002e6651b9000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000025e7b22536f75726365223a2250656e646c65222c22416d6f756e74496e555344223a223737382e37383635383134313631383937222c22416d6f756e744f7574555344223a223737362e39333030323837343632363337222c22526566657272616c223a22222c22466c616773223a302c22416d6f756e744f7574223a22333739353239303230383938343635313331222c2254696d657374616d70223a313734323432363838342c22526f7574654944223a2231316138636336392d623266322d346133302d396466302d333536653464393931373866222c22496e74656772697479496e666f223a7b224b65794944223a2231222c225369676e6174757265223a224772784c363976487966766251526b435632736e73585656713258545668705873732b764173355079647358366c4a6944424f4736475333524d37486a79687a3147765552486939634f4a7838324230383066724c3471626c747446484d7758354e544947794e686a424b38784d4a374b7a676c633658332f4d3378483257502f52656d4d6e59317854745534394e5830437042516b686d6e413955586b7a486b6649467462463936556a64747731752b636b73423461366a7349486b6b37354f33765649695941366d4a7552512f333737336c515643517738655343795a776e574a3053454b4768734749665a64545846376f4b453579325477395a554f4a3364743143537842694c6579494938682f35436f6959736b7241514b51632b423537716670314e45545546753452392b763042775655613031484b4b6a765634625a396c6f694e464632514e536a53436548303172513d3d227d7d0000";

        data.input.swapAction.needScale = false;
        leverageAction.auxData = abi.encode(_LP_STETH, 1, data);

        leverageAction.swapAction = swapAction;

        positionManager.leverage(leverageAction, 0.10e18); // 10% slippage


        // Verify having more than initial position
        AccountSnapshot memory cPendlePTSTETHSnapshot = cPendlePTSTETH
            .getSnapshot(user);
        assertGt(cPendlePTSTETHSnapshot.collateralPosted, initialPositionSize); 

        vm.stopPrank();
    }

    function testDeLeverageWithPostSwap_Success() public {
        _setUpMarket(1);
        _createLeverage();

        // Warp until collateralization cooldown period ends.
        vm.warp(block.timestamp + 20 minutes);
        borrowableCDAI.accrueIfNeeded();

        vm.startPrank(user);
        PendlePTPositionManager.DeleverageAction memory deleverageAction;
        AccountSnapshot memory borrowableCDAIBeforeSnapshot = borrowableCDAI.getSnapshot(user);
        AccountSnapshot memory cPendlePTSTETHBeforeSnapshot = cPendlePTSTETH.getSnapshot(user);

        deleverageAction.collateralToken = ICToken(address(cPendlePTSTETH));
        deleverageAction.collateralAssets = 1 ether;
        deleverageAction.debtToken = IBorrowableCToken(address(borrowableCDAI));

        deleverageAction.swapActions = new SwapperLib.Swap[](1);
        deleverageAction.swapActions[0].inputToken = _STETH;
        deleverageAction.swapActions[0].inputAmount = 0.85 ether;
        deleverageAction.swapActions[0].outputToken = _DAI_ADDRESS;
        deleverageAction.swapActions[0].target = address(_UNISWAP_V2_ROUTER);
        address[] memory path = new address[](3);
        path[0] = _STETH;
        path[1] = _WETH_ADDRESS;
        path[2] = _DAI_ADDRESS;

        deleverageAction.swapActions[0].call = abi.encodeWithSignature(
            "swapExactTokensForTokensSupportingFeeOnTransferTokens(uint256,uint256,address[],address,uint256)",
            0.85 ether,
            0,
            path,
            address(positionManager),
            block.timestamp
        );

        deleverageAction.swapActions[0].slippage = 0.6e18; // 60% slippage

        deleverageAction.repayAssets = (borrowableCDAIBeforeSnapshot.debtBalance * 95) / 100;
        deleverageAction.swapActions[0].slippage = 0.6e18;
        deleverageAction.repayAssets = (borrowableCDAIBeforeSnapshot.debtBalance * 95) / 100;
        PendleLib.PendleData memory data;
        data.approx.guessMin = 1e10;
        data.approx.guessMax = 1e18;
        data.approx.guessOffchain = 0;
        data.approx.maxIteration = 200;
        data.approx.eps = 1e18;

        data.output.tokenOut = _STETH;  
        data.output.tokenRedeemSy = _STETH;

        data.output.pendleSwap = _PENDLE_SWAP;

        deleverageAction.auxData = abi.encode(_LP_STETH, data);

        pendlePT.approve(address(positionManager), type(uint256).max);

        positionManager.deleverage(deleverageAction, 0.6e18); // 60% slippage

        AccountSnapshot memory borrowableCDAISnapshot = borrowableCDAI.getSnapshot(user);
        assertEq(borrowableCDAI.balanceOf(user), 0);
        assertEq(
            borrowableCDAISnapshot.debtBalance,
            borrowableCDAIBeforeSnapshot.debtBalance - deleverageAction.repayAssets
        );

        AccountSnapshot memory cPendlePTSTETHSnapshot = cPendlePTSTETH.getSnapshot(
            user
        );
        assertEq(
            cPendlePTSTETHSnapshot.collateralPosted,
            cPendlePTSTETHBeforeSnapshot.collateralPosted - deleverageAction.collateralAssets
        );
        assertEq(cPendlePTSTETHSnapshot.debtBalance, 0);

        vm.stopPrank();
    }

}
