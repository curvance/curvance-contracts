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
        _fork(22063248);

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

    function testLeverageWithPreSwap() public {

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
        ) * 50) / 100;

        address[] memory path = new address[](2);
        path[0] = _DAI_ADDRESS;
        path[1] = _USDC_ADDRESS;

        address uniswapV2Router = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;

        uint256 estimatedUniswapOutputAmount = 9983287;

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
                        1742138915,
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
            .extCalldata = hex"e21fd0e900000000000000000000000000000000000000000000000000000000000000200000000000000000000000000f4a1d7fdf4890be35e71f3e0bbc4a0ec377eca3000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000005a000000000000000000000000000000000000000000000000000000000000007e000000000000000000000000000000000000000000000000000000000000004e0000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000c0000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48000000000000000000000000ae7ab96520de3a18e5e111b5eaab095312d7fe84000000000000000000000000888888888889758f76e7103c6cbf23abbf58f946000000000000000000000000000000000000000000000000000000007fffffff00000000000000000000000000000000000000000000000000000000000004800000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000030000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000014000000000000000000000000000000000000000000000000000000000000002a0000000000000000000000000000000000000000000000000000000000000004094f1a6820000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000985537000000000000000000000000f6e72db5454dd049d0788e411b06cfaf16853042000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb480000000000000000000000000f4a1d7fdf4890be35e71f3e0bbc4a0ec377eca3000000000000000000000000000000000000000000000000000000000000004059361199000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000100000000000000000000000000c5578194d457dcce3f272538d1ad52c68d1ce8490000000000000000000000006b175474e89094c44da98b954eedeac495271d0f0000000000000000000000007f39c581f595b53c5cb19bd0b3f8da6c935e2ca00000000000000000000000000f4a1d7fdf4890be35e71f3e0bbc4a0ec377eca30000000000000000000000000000000000000000000000008a8bc2a1fdc67000000000000000000000000000000000000000000000000000000000000000000300000000000000000000000000000000000000000000000000000000000003e8000000000000000000000000000000000000000000000000000000000000003200000000000000000000000000000000000000000000000000000000000000400ca8ebf10000000000000000000000000000000000000000000000000000000300000000000000000000000000000000000000000000000000000000000000600000000000000000000000007f39c581f595b53c5cb19bd0b3f8da6c935e2ca0000000000000000000000000000000000000000000000000000fa3b0c74f64c2000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000200000000000000000000000013a116eb300000000000000000012b84c7f6b36a7000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48000000000000000000000000ae7ab96520de3a18e5e111b5eaab095312d7fe84000000000000000000000000000000000000000000000000000000000000016000000000000000000000000000000000000000000000000000000000000001a000000000000000000000000000000000000000000000000000000000000001e00000000000000000000000000000000000000000000000000000000000000200000000000000000000000000888888888889758f76e7103c6cbf23abbf58f94600000000000000000000000000000000000000000000000000000000009855370000000000000000000000000000000000000000000000000010d911a5e07dfc0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000022000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000f4a1d7fdf4890be35e71f3e0bbc4a0ec377eca300000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000985537000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000025d7b22536f75726365223a2250656e646c65222c22416d6f756e74496e555344223a22392e393832323633363433333735383034222c22416d6f756e744f7574555344223a2231302e303337333735303830373036313431222c22526566657272616c223a22222c22466c616773223a302c22416d6f756e744f7574223a2235323639313838323735353439383633222c2254696d657374616d70223a313734323137343030342c22526f7574654944223a2266363566643033662d373666382d346338362d623633372d616631326465316530613931222c22496e74656772697479496e666f223a7b224b65794944223a2231222c225369676e6174757265223a22475a4634542f46696563412f4e4d56703774614d42546b2b4e4f68656e53587a344d2f696b4e414e6b44524e4d6c39414c44666a6a352f4a576454637443365732316f774f6f346236787434383479384e756f38564c542f73772b7a4130473536356143567a75464f6d756f434b4d3976595a415334744764345a6a5272634e6f79534e36654f37374d6f4c4f48374e665132524666376a68785a2f56624469366d514a43624c794e6374726b4272556c50737a483669374c4c54563849753163557132426455766e31343175306a4e51436666384a37726b487a32384f646f646d4645474a373972534c6a34676f6447366f3263476a4e383151415669534a5836593273624e5535725139456647543772635133363448454e2f6c65426473744c3850447a33566944624b33596b435836786568553934667238455151744b435a382b5a6a3531766657536e4d75475343794145673d3d227d7d000000";

        data.input.swapData.needScale = false;
        leverageData.auxData = abi.encode(_LP_STETH, 1, data);

        leverageData.swapData = swapData;

        vm.expectRevert();
        // FIX LATER

        positionManagement.leverage(leverageData, 0.10e18); // 10% slippage

        // (uint256 eDAIBalance, uint256 eDAIBorrowed, ) = eDAI.getSnapshot(user);
        // assertEq(eDAIBalance, 0);
        // assertEq(eDAIBorrowed, 100 ether + amountForLeverage);

        // (uint256 pPendlePTBalance, uint256 pPendlePTBorrowed, ) = pPendlePT
        //     .getSnapshot(user);
        // assertGt(pPendlePTBalance, 2 ether);
        // assertEq(pPendlePTBorrowed, 0 ether);

        vm.stopPrank();
    }

    


}
