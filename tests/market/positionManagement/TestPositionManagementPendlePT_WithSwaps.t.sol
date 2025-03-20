// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { PendleLib } from "contracts/libraries/PendleLib.sol";
import { SwapType } from "contracts/interfaces/external/pendle/IPSwapAggregator.sol";
import { PositionManagementPendlePT } from "contracts/market/position-management/PositionManagementPendlePT.sol";
import { PendlePrincipalTokenAdaptor } from "contracts/oracles/adaptors/pendle/PendlePrincipalTokenAdaptor.sol";
import { SimplePToken } from "contracts/market/token/SimplePToken.sol";
import { IEToken } from "contracts/interfaces/IEToken.sol";
import { IPToken } from "contracts/interfaces/IPToken.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IPendleRouter } from "contracts/interfaces/external/pendle/IPendleRouter.sol";
import { IPendlePTOracle } from "contracts/interfaces/external/pendle/IPendlePtOracle.sol";
import { IERC20 } from "contracts/market/token/PendleLPPToken.sol";
import { IPMarket } from "contracts/interfaces/external/pendle/IPMarket.sol";
import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";

contract Test_SwapPositionManagementPendlePT is TestBaseMarket {
    address internal _CHAINLINK_STETH_USD =
        0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8;
    IPendleRouter internal _ROUTER =
        IPendleRouter(0x888888888889758F76e7103c6CbF23ABbF58F946);
    address internal _STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address internal _WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address internal _PT_STETH = 0xb253Eff1104802b97aC7E3aC9FdD73AecE295a2c; // PT-stETH-24DEC25
    address internal _LP_STETH = 0x34280882267ffa6383B363E278B027Be083bBe3b; // YT-stETH-24DEC25/SY-stETH Market
    address internal _PT_ORACLE = 0x14030836AEc15B2ad48bB097bd57032559339c92;
    address internal _PENDLE_SWAP = 0x1e8b6Ac39f8A33f46a6Eb2D1aCD1047B99180AD1;

    PositionManagementPendlePT public positionManagement;
    PendlePrincipalTokenAdaptor public adaptor;
    SimplePToken public pPendlePT;
    IERC20 public pendlePT = IERC20(_PT_STETH);

    address public owner;
    address public user;

    address positionManagementAddress = 0x27cc01A4676C73fe8b6d0933Ac991BfF1D77C4da;

    receive() external payable {}

    fallback() external payable {}

    // this is to use address(this) as mock cToken address
    function tokenType() external pure returns (uint256) {
        return 1;
    }

    function setUp() public override {
        // unused
    }

    function _setUpMarket(uint256 _preOrPost) internal {
        if (_preOrPost == 0) {
            // set up pre-swap market
            _fork(22084188);
        } else {
            // set up post-swap market
            _fork(22085259);
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

        centralRegistry.addHarvester(address(this));
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

        // setup eDAI
        {
            _deployEDAI();
            // add MToken support on price router
            oracleManager.addMTokenSupport(address(eDAI));

            _prepareDAI(owner, 200000e18);
            dai.approve(address(eDAI), 200000e18);
            marketManager.listToken(address(eDAI));
        }

        // deploy pPendlePT
        {
            pPendlePT = new SimplePToken(
                ICentralRegistry(address(centralRegistry)),
                pendlePT,
                address(marketManager)
            );

            // support market
            _preparePT(owner, 1 ether);
            pendlePT.approve(address(pPendlePT), 1 ether);
            marketManager.listToken(address(pPendlePT));
            // add MToken support on oracle manager
            oracleManager.addMTokenSupport(address(pPendlePT));
            // set position token configuration
            marketManager.updatePositionToken(
                address(pPendlePT),
                7000,
                4000, // liquidate at 71%
                3000,
                200, // 2% liq incentive
                400,
                1000
            );

            address[] memory mTokens = new address[](1);
            mTokens[0] = address(pPendlePT);
            uint256[] memory caps = new uint256[](1);
            caps[0] = 100 ether;
            marketManager.setPTokenCollateralCaps(mTokens, caps);
        }

        positionManagement = new PositionManagementPendlePT(
            ICentralRegistry(address(centralRegistry)),
            address(marketManager),
            _WETH_ADDRESS,
            _ROUTER
        );

        marketManager.setPositionManagement(address(positionManagement));

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
        pendlePT.approve(address(pPendlePT), 1 ether);

        // mint
        assertGt(pPendlePT.deposit(1 ether, user), 0);
        marketManager.postCollateral(user, address(pPendlePT), 1 ether);
        assertEq(pPendlePT.balanceOf(user), 1 ether);

        uint256 balanceBeforeBorrow = dai.balanceOf(user);
        // borrow
        eDAI.borrow(100 ether);
        assertEq(balanceBeforeBorrow + 100 ether, dai.balanceOf(user));

        // try leverage with 50% of max
        uint256 amountForLeverage = (positionManagement.maxRemainingLeverageOf(
            user,
            address(eDAI)
        ) * 20) / 100;

        emit debugUint("amountForLeverage", amountForLeverage);

        PositionManagementPendlePT.LeverageStruct memory leverageData;
        leverageData.borrowToken = IEToken(address(eDAI));
        leverageData.borrowAmount = amountForLeverage;
        leverageData.positionToken = IPToken(address(pPendlePT));
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
        data.input.swapData.swapType = SwapType.KYBERSWAP;
        data
            .input
            .swapData
            .extRouter = 0x6131B5fae19EA4f9D964eAc0408E4408b66337b5;
        data
            .input
            .swapData
            .extCalldata = hex"e21fd0e900000000000000000000000000000000000000000000000000000000000000200000000000000000000000000f4a1d7fdf4890be35e71f3e0bbc4a0ec377eca3000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000004c000000000000000000000000000000000000000000000000000000000000007000000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000c00000000000000000000000006b175474e89094c44da98b954eedeac495271d0f0000000000000000000000007f39c581f595b53c5cb19bd0b3f8da6c935e2ca0000000000000000000000000888888888889758f76e7103c6cbf23abbf58f946000000000000000000000000000000000000000000000000000000007fffffff00000000000000000000000000000000000000000000000000000000000003a000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000180000000000000000000000000000000000000000000000000000000000000004063407a490000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000e00000000000000000000000000f4a1d7fdf4890be35e71f3e0bbc4a0ec377eca300000000000000000000000060594a405d53811d3bc4766596efd80fd545a2700000000000000000000000006b175474e89094c44da98b954eedeac495271d0f000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc20000000000000000000000000000000000000000000000056bc75e2d63100000000000000000000000000000000000000000000000000000000000010009046c000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000408cc7a56b0000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000ba12222222228d8ba445958a75a0704d566bf2c893d199263632a4ef4bb438f1feb99e57b4b5f0bd0000000000000000000005c2000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc20000000000000000000000007f39c581f595b53c5cb19bd0b3f8da6c935e2ca000000000000000000000000000000000000000000000000000af3d45ef7fa85f000000000000000000000000000000000000000000000000000000000000002000000000000000000000000997c0dcb2000000000000000000925fd29796894f0000000000000000000000006b175474e89094c44da98b954eedeac495271d0f0000000000000000000000007f39c581f595b53c5cb19bd0b3f8da6c935e2ca0000000000000000000000000000000000000000000000000000000000000016000000000000000000000000000000000000000000000000000000000000001a000000000000000000000000000000000000000000000000000000000000001e00000000000000000000000000000000000000000000000000000000000000200000000000000000000000000888888888889758f76e7103c6cbf23abbf58f9460000000000000000000000000000000000000000000000056bc75e2d63100000000000000000000000000000000000000000000000000000008b0e3b433568d70000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000022000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000f4a1d7fdf4890be35e71f3e0bbc4a0ec377eca300000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000056bc75e2d63100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000025d7b22536f75726365223a2250656e646c65222c22416d6f756e74496e555344223a2239392e3936333939353635303332393538222c22416d6f756e744f7574555344223a2239392e3838353137333531303739323333222c22526566657272616c223a22222c22466c616773223a302c22416d6f756e744f7574223a223431323030373034363930373531383233222c2254696d657374616d70223a313734323433353438322c22526f7574654944223a2239393033353766322d323639382d343030302d616136662d336236643831313262353837222c22496e74656772697479496e666f223a7b224b65794944223a2231222c225369676e6174757265223a2261494f306c72664869366e61314d656a566533663337564f614250792b45743865442b6475325139476957627a5a76396e6d4f5254564e4b794a503157664b6142647762465245734d414e2f30735451686a6f4f475a4e4f784c4a6f444848646a6d366567437249514d314c346b787262736a77334b6567726b71326c6f2b6259716171462f57757244536975316a65794679666f6d66653973474c32467932423235582f62447657524a7752366d6966635a5977394e6d705551663469664e424f7633623835374d31686c47757a434f7257696547383849594e716d555a707034585571615a6a2f6a4c3575666952706536762f3752437a573878696d4935632f764e6568374736667651753761536635634272385046636e685a62502f62644a696a5a68666679304562613574793343654255574f4953504576752f48417956745774466978447534454c324e466578776d55513d3d227d7d000000";

        data.input.swapData.needScale = false;
        leverageData.auxData = abi.encode(_LP_STETH, 1, data);

        positionManagement.leverage(leverageData, 0.05e18); // 5% slippage

        (uint256 eDAIBalance, uint256 eDAIBorrowed, ) = eDAI.getSnapshot(user);
        assertEq(eDAIBalance, 0);
        assertEq(eDAIBorrowed, 100 ether + amountForLeverage);

        (uint256 pPendlePTBalance, uint256 pPendlePTBorrowed, ) = pPendlePT
            .getSnapshot(user);
        assertGt(pPendlePTBalance, 2 ether);
        assertEq(pPendlePTBorrowed, 0 ether);

        vm.stopPrank();
    }

    function _provideEnoughLiquidityForLeverage() internal {
        address liquidityProvider = makeAddr("liquidityProvider");

        _preparePT(liquidityProvider, 10 ether);
        _prepareDAI(liquidityProvider, 20000000e18);

        vm.startPrank(liquidityProvider);

        // mint eDAI
        dai.approve(address(eDAI), 20000000 ether);
        eDAI.mint(20000000 ether);

        // mint pSTETH
        pendlePT.approve(address(pPendlePT), 10 ether);
        pPendlePT.mint(10 ether, liquidityProvider);

        vm.stopPrank();
    }

    function testLeverageWithPreSwap_Success() public {
        _setUpMarket(0);

        vm.startPrank(user);

        uint256 initialPositionSize = 1 ether;

        _preparePT(user, initialPositionSize);
        pendlePT.approve(address(pPendlePT), initialPositionSize);

        // mint
        assertGt(pPendlePT.deposit(initialPositionSize, user), 0);
        marketManager.postCollateral(user, address(pPendlePT), initialPositionSize);
        assertEq(pPendlePT.balanceOf(user), initialPositionSize);

        uint256 balanceBeforeBorrow = dai.balanceOf(user);
        // borrow
        eDAI.borrow(100 ether);
        assertEq(balanceBeforeBorrow + 100 ether, dai.balanceOf(user));

        // try leverage with 20% of max
        uint256 amountForLeverage = (positionManagement.maxRemainingLeverageOf(
            user,
            address(eDAI)
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

        // create SwapData
        SwapperLib.Swap memory swapData;
        swapData.inputToken = _DAI_ADDRESS;
        swapData.inputAmount = amountForLeverage;
        swapData.outputToken = _USDC_ADDRESS;
        swapData.target = address(_UNISWAP_V2_ROUTER);
        swapData.slippage = 1000 * 1e14;
        swapData.call = abi.encodeWithSignature(
                        "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
                        amountForLeverage,
                        ((amountForLeverage * 98) / 100) / 10**12, // scale from 18 decimals to 6 decimals and apply 2% slippage
                        path,
                        address(positionManagement),
                        block.timestamp + 30
        );

        PositionManagementPendlePT.LeverageStruct memory leverageData;
        leverageData.borrowToken = IEToken(address(eDAI));
        leverageData.borrowAmount = amountForLeverage;
        leverageData.positionToken = IPToken(address(pPendlePT));
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
        data.input.swapData.swapType = SwapType.KYBERSWAP;
        data
            .input
            .swapData
            .extRouter = 0x6131B5fae19EA4f9D964eAc0408E4408b66337b5;
        data
            .input
            .swapData
            .extCalldata = hex"e21fd0e900000000000000000000000000000000000000000000000000000000000000200000000000000000000000000f4a1d7fdf4890be35e71f3e0bbc4a0ec377eca3000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000000058000000000000000000000000000000000000000000000000000000000000007c000000000000000000000000000000000000000000000000000000000000004c0000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000c0000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48000000000000000000000000ae7ab96520de3a18e5e111b5eaab095312d7fe84000000000000000000000000888888888889758f76e7103c6cbf23abbf58f946000000000000000000000000000000000000000000000000000000007fffffff00000000000000000000000000000000000000000000000000000000000004600000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000030000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000016000000000000000000000000000000000000000000000000000000000000002c00000000000000000000000000000000000000000000000000000000000000040301a40330000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000a000000000000000000000000031373595f40ea48a7aab6cbcb0d377c6066e2dca000000000000000000000000000000000000000000000000000000002e6651b9000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48000000000000000000000000dac17f958d2ee523a2206206994597c13d831ec70000000000000000000000000f4a1d7fdf4890be35e71f3e0bbc4a0ec377eca30000000000000000000000000000000000000000000000000000000000000040593611990000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000001000000000000000000000000000d4a11d5eeaac28ec3f61d100daf4d40471f1852000000000000000000000000dac17f958d2ee523a2206206994597c13d831ec7000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc20000000000000000000000000f4a1d7fdf4890be35e71f3e0bbc4a0ec377eca3000000000000000000000000000000000000000000000000000000002e63dcb5000000000000000000000000000000000000000000000000000000000000000300000000000000000000000000000000000000000000000000000000000003e800000000000000000000000000000000000000000000000000000000000000320000000000000000000000000000000000000000000000000000000000000040eeb543140000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000544582e91f1369e00000000000000000000000000000000000000000000000000000000000000200000000000000000000000585db145e2000000000000000005445ba2389ad56b000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48000000000000000000000000ae7ab96520de3a18e5e111b5eaab095312d7fe84000000000000000000000000000000000000000000000000000000000000016000000000000000000000000000000000000000000000000000000000000001a000000000000000000000000000000000000000000000000000000000000001e00000000000000000000000000000000000000000000000000000000000000200000000000000000000000000888888888889758f76e7103c6cbf23abbf58f946000000000000000000000000000000000000000000000000000000002e6651b90000000000000000000000000000000000000000000000000500f0a6e8f97df20000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000022000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000f4a1d7fdf4890be35e71f3e0bbc4a0ec377eca30000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000002e6651b9000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000025e7b22536f75726365223a2250656e646c65222c22416d6f756e74496e555344223a223737382e37383635383134313631383937222c22416d6f756e744f7574555344223a223737362e39333030323837343632363337222c22526566657272616c223a22222c22466c616773223a302c22416d6f756e744f7574223a22333739353239303230383938343635313331222c2254696d657374616d70223a313734323432363838342c22526f7574654944223a2231316138636336392d623266322d346133302d396466302d333536653464393931373866222c22496e74656772697479496e666f223a7b224b65794944223a2231222c225369676e6174757265223a224772784c363976487966766251526b435632736e73585656713258545668705873732b764173355079647358366c4a6944424f4736475333524d37486a79687a3147765552486939634f4a7838324230383066724c3471626c747446484d7758354e544947794e686a424b38784d4a374b7a676c633658332f4d3378483257502f52656d4d6e59317854745534394e5830437042516b686d6e413955586b7a486b6649467462463936556a64747731752b636b73423461366a7349486b6b37354f33765649695941366d4a7552512f333737336c515643517738655343795a776e574a3053454b4768734749665a64545846376f4b453579325477395a554f4a3364743143537842694c6579494938682f35436f6959736b7241514b51632b423537716670314e45545546753452392b763042775655613031484b4b6a765634625a396c6f694e464632514e536a53436548303172513d3d227d7d0000";

        data.input.swapData.needScale = false;
        leverageData.auxData = abi.encode(_LP_STETH, 1, data);

        leverageData.swapData = swapData;

        positionManagement.leverage(leverageData, 0.10e18); // 10% slippage


        // Verify having more than initial position
        (uint256 pPendlePTBalance, uint256 pPendlePTBorrowed, ) = pPendlePT
            .getSnapshot(user);
        assertGt(pPendlePTBalance, initialPositionSize); 

        vm.stopPrank();
    }

    // function testDeLeverageWithPostSwap_Success() public {
    //     _setUpMarket(1);
    //     _createLeverage();

    //     // Warp until collateral posting wait time ends
    //     vm.warp(block.timestamp + 20 minutes);
    //     eDAI.accrueInterest();

    //     vm.startPrank(user);
    //     PositionManagementPendlePT.DeleverageStruct memory deleverageData;
    //     (, uint256 eDAIBorrowedBefore, ) = eDAI.getSnapshot(user);
    //     (uint256 PTBalanceBefore, , ) = pPendlePT.getSnapshot(user);

    //     deleverageData.positionToken = IPToken(address(pendlePT));
    //     deleverageData.collateralAmount = 1 ether;
    //     deleverageData.borrowToken = IEToken(address(eDAI));

    //     deleverageData.swapData = new SwapperLib.Swap[](1);
    //     deleverageData.swapData[0].inputToken = _STETH;
    //     deleverageData.swapData[0].inputAmount = 2.149 ether;
    //     deleverageData.swapData[0].outputToken = _DAI_ADDRESS;
    //     deleverageData.swapData[0].target = address(_UNISWAP_V2_ROUTER);
    //     address[] memory path = new address[](2);
    //     path[0] = _STETH;
    //     path[1] = _DAI_ADDRESS;

    //     deleverageData.swapData[0].call = abi.encodeWithSignature(
    //         "swapExactTokensForTokensSupportingFeeOnTransferTokens(uint256,uint256,address[],address,uint256)",
    //         2.149 ether,
    //         0,
    //         path,
    //         address(positionManagement),
    //         block.timestamp
    //     );
    //     deleverageData.swapData[0].slippage = 0.6e18;
    //     deleverageData.repayAmount = 6500e18;
    //     PendleLib.PendleData memory data;
    //     data.approx.guessMin = 1e10;
    //     data.approx.guessMax = 1e18;
    //     data.approx.guessOffchain = 0;
    //     data.approx.maxIteration = 200;
    //     data.approx.eps = 1e18;
    //     deleverageData.auxData = abi.encode(0, data);

    //     pendlePT.approve(address(positionManagement), type(uint256).max);
    //     positionManagement.setDelegateApproval(address(user2), true);
    //     vm.stopPrank();

    //     vm.prank(user2);
    //     positionManagement.deleverageFor(deleverageData, user, 0.05e18); // 5% slippage

    //     (uint256 eDAIBalance, uint256 eDAIBorrowed, ) = eDAI.getSnapshot(user);
    //     assertEq(eDAIBalance, 0);
    //     assertEq(
    //         eDAIBorrowed,
    //         eDAIBorrowedBefore - deleverageData.repayAmount
    //     );

    //     (uint256 pPendlePTBalance, uint256 pPendlePTBorrowed, ) = pPendlePT.getSnapshot(
    //         user
    //     );
    //     assertEq(
    //         pPendlePTBalance,
    //         PTBalanceBefore - deleverageData.collateralAmount
    //     );
    //     assertEq(pPendlePTBorrowed, 0);

    //     vm.stopPrank();
    // }






}
