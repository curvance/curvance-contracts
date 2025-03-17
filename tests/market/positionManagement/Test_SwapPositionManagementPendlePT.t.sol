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
        _fork(22062345);

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

    // function testInitialize() public {
    //     assertEq(
    //         address(positionManagement.centralRegistry()),
    //         address(centralRegistry)
    //     );
    //     assertEq(
    //         address(positionManagement.marketManager()),
    //         address(marketManager)
    //     );
    // }

    // function testLeverage() public {
    //     vm.startPrank(user);

    //     _preparePT(user, 1 ether);
    //     pendlePT.approve(address(pPendlePT), 1 ether);

    //     // mint
    //     assertGt(pPendlePT.deposit(1 ether, user), 0);
    //     marketManager.postCollateral(user, address(pPendlePT), 1 ether);
    //     assertEq(pPendlePT.balanceOf(user), 1 ether);

    //     uint256 balanceBeforeBorrow = dai.balanceOf(user);
    //     // borrow
    //     eDAI.borrow(100 ether);
    //     assertEq(balanceBeforeBorrow + 100 ether, dai.balanceOf(user));

    //     // try leverage with 50% of max
    //     uint256 amountForLeverage = (positionManagement.maxRemainingLeverageOf(
    //         user,
    //         address(eDAI)
    //     ) * 50) / 100;

    //     PositionManagementPendlePT.LeverageStruct memory leverageData;
    //     leverageData.borrowToken = IEToken(address(eDAI));
    //     leverageData.borrowAmount = amountForLeverage;
    //     leverageData.positionToken = IPToken(address(pPendlePT));
    //     PendleLib.PendleData memory data;
    //     data.approx.guessMin = 0;
    //     data.approx.guessMax = type(uint256).max;
    //     data.approx.guessOffchain = 0;
    //     data.approx.maxIteration = 30;
    //     data.approx.eps = 1e15;
    //     data.input.tokenIn = _DAI_ADDRESS;
    //     data.input.netTokenIn = amountForLeverage;
    //     data.input.tokenMintSy = _WSTETH;
    //     data.input.pendleSwap = _PENDLE_SWAP;
    //     data.input.swapData.swapType = SwapType.KYBERSWAP;
    //     data
    //         .input
    //         .swapData
    //         .extRouter = 0x6131B5fae19EA4f9D964eAc0408E4408b66337b5;
    //     data
    //         .input
    //         .swapData
    //         .extCalldata = hex"8af033fb000000000000000000000000f081470f5c6fbccf48cc4e5b82dd926409dcdd670000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000028000000000000000000000000000000000000000000000000000000000000007600000000000000000000000006b175474e89094c44da98b954eedeac495271d0f0000000000000000000000007f39c581f595b53c5cb19bd0b3f8da6c935e2ca00000000000000000000000000000000000000000000000000000000000000160000000000000000000000000000000000000000000000000000000000000018000000000000000000000000000000000000000000000000000000000000001a000000000000000000000000000000000000000000000000000000000000001c0000000000000000000000000888888888889758f76e7103c6cbf23abbf58f9460000000000000000000000000000000000000000000000bd4f3762c29d0b80560000000000000000000000000000000000000000000000000cd21ab41da73736000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000001e00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000004c0000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000e00000000000000000000000000000000000000000000000000000000000000120000000000000000000000000000000000000000000000000000000007fffffff00000000000000000000000000000000000000000000000000000000000004600000000000000000000000000000000000000000000000000000000000000001000000000000000000000000a478c2975ab1ea89e8196811f51a7b7ade33eb1100000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000bd4f3762c29d0b80560000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000002e000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000001a0000000000000000000000000000000000000000000000000000000000000004059361199000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000100000000000000000000000000a478c2975ab1ea89e8196811f51a7b7ade33eb110000000000000000000000006b175474e89094c44da98b954eedeac495271d0f000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc2000000000000000000000000f081470f5c6fbccf48cc4e5b82dd926409dcdd670000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000300000000000000000000000000000000000000000000000000000000000003e8000000000000000000000000000000000000000000000000000000000000003200000000000000000000000000000000000000000000000000000000000000408cc7a56b0000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000ba12222222228d8ba445958a75a0704d566bf2c893d199263632a4ef4bb438f1feb99e57b4b5f0bd0000000000000000000005c2000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc20000000000000000000000007f39c581f595b53c5cb19bd0b3f8da6c935e2ca00000000000000000000000000000000000000000000000000f35a0e408a8273700000000000000000000000000000000000000000000000000000000000000200000000000000000000000d786ec3cd500000000000000000cd8ae8233427c12000000000000000000000000000000000000000000000000000000000000022d7b22536f75726365223a2250656e646c65222c22416d6f756e74496e555344223a22333438382e363935393534363937383535222c22416d6f756e744f7574555344223a22333438372e323339383532373931363538222c22526566657272616c223a22222c22466c616773223a302c22416d6f756e744f7574223a22393235363831353937363533363133353836222c2254696d657374616d70223a313733313331393638302c22496e74656772697479496e666f223a7b224b65794944223a2231222c225369676e6174757265223a224a716d6f69783866726a704a6a5246725364634f5a4d546a576150365563533144335732754f63384a58444c4d5453384c5230354e554639574b7837434f495a616b58756f7847747545474c57324430565a742b576476672f30796742692f777a4349332b5756496e4e7254654b4c61574e614b764a56592b6c65426252756f51564d63763671724e45394836346f6e4d383933646876726f5876485535437649706e46483175746f424a6a3931536c2f4d4e464c517a57393138316a78327965486e4862573738312b7a683841747a4373324556496e615230316d736739384733497851342b4d5879303378744843707a7577663052706b4f4738386f313757416e2b666573444d36394e546b34546a4b62746756336a427664644f42566a4670757a545570455247657354715972694b524d5032583745614964505547584c4a76586a2b6a5055486f416c534c75706b387a36513d3d227d7d00000000000000000000000000000000000000";

    //     data.input.swapData.needScale = false;
    //     leverageData.auxData = abi.encode(_LP_STETH, 1, data);

    //     positionManagement.leverage(leverageData, 0.05e18); // 5% slippage

    //     (uint256 eDAIBalance, uint256 eDAIBorrowed, ) = eDAI.getSnapshot(user);
    //     assertEq(eDAIBalance, 0);
    //     assertEq(eDAIBorrowed, 100 ether + amountForLeverage);

    //     (uint256 pPendlePTBalance, uint256 pPendlePTBorrowed, ) = pPendlePT
    //         .getSnapshot(user);
    //     assertGt(pPendlePTBalance, 2 ether);
    //     assertEq(pPendlePTBorrowed, 0 ether);

    //     vm.stopPrank();
    // }


    // This test is to improve coverage when doing the first swap leg to leverage the position
    // The first swap leg successfully completes, but the second swap fails because of the transaction calldata 
    // for Pendle needed to swap USDC -> WSTETH is difficult to generate:
    // 1. If I try to warp to the latest block, then get a valid swap calldata from the Pendle API
    //       the acheived PT will have a different expiration date than the one currently used in this test file.
    // 2. I cannot retrieve a valid swap calldata for old blocks because the API does not permit it.
    // 
    // Note: In order to generate the first swap, I have to comment out the slippage check in the Swapper Lib.
    //       I can come back to this test and try to use a PT from the latest block
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
        data.approx.guessMin = 5e17;
        data.approx.guessMax = 1.2e18;
        data.approx.guessOffchain = 1.2e18;
        data.approx.maxIteration = 30;
        data.approx.eps = 1e15;
        data.input.tokenIn = _USDC_ADDRESS;
        data.input.netTokenIn = estimatedUniswapOutputAmount;
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
            .extCalldata = hex"0d5f0e3b00000000000000000001a663888888888889758f76e7103c6cbf23abbf58f94600000000000000000000000000000000000000000000000000000000009855370000000000000000000000000000000000000000000000000010f44e377f987800000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000001200000000000000000000000e0554a476a092703abdb3ef35c80e0d76d32939f";

        data.input.swapData.needScale = false;
        leverageData.auxData = abi.encode(_LP_STETH, 1, data);

        leverageData.swapData = swapData;

        vm.expectRevert();

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
