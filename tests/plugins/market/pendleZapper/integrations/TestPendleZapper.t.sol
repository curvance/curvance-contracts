// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { PendleLib } from "contracts/libraries/PendleLib.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IPendleRouter } from "contracts/interfaces/external/pendle/IPendleRouter.sol";
import { IPendlePTOracle } from "contracts/interfaces/external/pendle/IPendlePtOracle.sol";
import { PendleZapper } from "contracts/plugins/market/PendleZapper.sol";
import { ZapperBase } from "contracts/plugins/ZapperBase.sol";
import { PendleLPTokenAdaptor } from "contracts/oracles/adaptors/pendle/PendleLPTokenAdaptor.sol";
import { PendleLPCToken } from "contracts/market/token/PendleLPCToken.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

contract TestPendleZapper is TestBaseMarketIsolated {
    address internal _PENDLE_ROUTER =
        0x888888888889758F76e7103c6CbF23ABbF58F946;
    address internal _PENDLE_LP_STETH =
        0xD0354D4e7bCf345fB117cabe41aCaDb724eccCa2;
    address internal _STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address internal _CHAINLINK_STETH_USD =
        0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8;
    address internal _PT_ORACLE = 0x14030836AEc15B2ad48bB097bd57032559339c92;
    address internal _PT_STETH = 0x7758896b6AC966BbABcf143eFA963030f17D3EdF;
    address internal _LP_STETH = 0xD0354D4e7bCf345fB117cabe41aCaDb724eccCa2;

    bool internal _IS_PT = false;

    PendleLPTokenAdaptor public adaptor;
    PendleLPCToken public pendleCTokenSTETH;

    receive() external payable {}

    fallback() external payable {}

    function setUp() public override {
        _fork(20287400);
        _init();

        chainlinkAdaptor.addAsset(_STETH, _CHAINLINK_STETH_USD, 0, true);
        oracleManager.addAssetPriceFeed(_STETH, address(chainlinkAdaptor));

        adaptor = new PendleLPTokenAdaptor(
            ICentralRegistry(address(centralRegistry)),
            IPendlePTOracle(_PT_ORACLE)
        );
        PendleLPTokenAdaptor.AdaptorData memory adapterData;
        adapterData.twapDuration = 12;
        adapterData.quoteAsset = _STETH;
        adapterData.pt = _PT_STETH;
        adapterData.quoteAssetDecimals = 18;
        adaptor.addAsset(_LP_STETH, adapterData);
        oracleManager.addApprovedAdaptor(address(adaptor));
        oracleManager.addAssetPriceFeed(_LP_STETH, address(adaptor));

        pendleCTokenSTETH = new PendleLPCToken(
            ICentralRegistry(address(centralRegistry)),
            IERC20(_LP_STETH),
            address(marketManagerIsolated),
            IPendleRouter(_PENDLE_ROUTER),
            1 days
        );
        oracleManager.addCTokenSupport(address(pendleCTokenSTETH));

        _prepareUSDC(address(this), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);

        deal(_LP_STETH, address(this), 1 ether);
        IERC20(_LP_STETH).approve(address(pendleCTokenSTETH), 1 ether);

        marketManagerIsolated.listTokens(address(pendleCTokenSTETH), address(borrowableCUSDC));
        
        _setCTokenConfigBasic(address(pendleCTokenSTETH), 100_000e18, 0);
        _setCTokenConfigLowValues(address(borrowableCUSDC), 100_000e18, 100_000e18);
    }

    function testEnterPendle() public {
        uint256 ethAmount = 3 ether;
        vm.deal(user1, ethAmount);

        PendleLib.PendleData memory data;

        data.approx.guessMin = 1e10;
        data.approx.guessMax = 1e18;
        data.approx.guessOffchain = 0;
        data.approx.maxIteration = 200;
        data.approx.eps = 1e18;

        vm.startPrank(user1);
        pendleZapper.enterPendle{ value: ethAmount }(
            address(0),
            PendleZapper.ZapperData(
                address(0),
                ethAmount,
                _PENDLE_LP_STETH,
                1,
                true
            ),
            new SwapperLib.Swap[](0),
            _PENDLE_ROUTER,
            _IS_PT,
            data,
            1.2 ether,
            false,
            user1
        );

        vm.stopPrank();

        assertEq(user1.balance, 0);
        assertGt(IERC20(_PENDLE_LP_STETH).balanceOf(user1), 0);
    }

    function testExitPendle() public {
        testEnterPendle();

        uint256 withdrawAmount = IERC20(_PENDLE_LP_STETH).balanceOf(user1);

        PendleLib.PendleData memory data;

        data.approx.guessMin = 1e10;
        data.approx.guessMax = 1e18;
        data.approx.guessOffchain = 0;
        data.approx.maxIteration = 200;
        data.approx.eps = 1e18;

        vm.startPrank(user1);
        IERC20(_PENDLE_LP_STETH).approve(
            address(pendleZapper),
            withdrawAmount
        );
        pendleZapper.exitPendle(
            _PENDLE_ROUTER,
            _IS_PT,
            _STETH,
            data,
            PendleZapper.ZapperData(
                _PENDLE_LP_STETH,
                withdrawAmount,
                _STETH,
                0,
                false
            ),
            new SwapperLib.Swap[](0),
            user1
        );
        vm.stopPrank();

        assertGt(IERC20(_STETH).balanceOf(user1), 0);
        // assertGt(IERC20(_USDC).balanceOf(user1), 0);
        assertEq(IERC20(_PENDLE_LP_STETH).balanceOf(user1), 0);
    }

    function testEnterPendleWithCToken() public {
        uint256 ethAmount = 3 ether;
        vm.deal(user1, ethAmount);

        PendleLib.PendleData memory data;

        data.approx.guessMin = 1e10;
        data.approx.guessMax = 1e18;
        data.approx.guessOffchain = 0;
        data.approx.maxIteration = 200;
        data.approx.eps = 1e18;

        vm.startPrank(user1);
        pendleZapper.enterPendle{ value: ethAmount }(
            address(pendleCTokenSTETH),
            PendleZapper.ZapperData(
                address(0),
                ethAmount,
                _PENDLE_LP_STETH,
                1,
                true
            ),
            new SwapperLib.Swap[](0),
            _PENDLE_ROUTER,
            _IS_PT,
            data,
            1.2 ether,
            false,
            user1
        );

        vm.stopPrank();

        assertEq(user1.balance, 0);

        (,,,, uint256 pendleCTokenSTETHBorrowed, ) = pendleCTokenSTETH.getSnapshot(user1);
        assertApproxEqRel(pendleCTokenSTETH.balanceOf(user1), 1.24 ether, 0.01 ether);
        assertEq(pendleCTokenSTETHBorrowed, 0);
    }

    function testEnterPendleWithCTokenWithCollateralize() public {
        uint256 ethAmount = 3 ether;
        vm.deal(user1, ethAmount);

        PendleLib.PendleData memory data;

        data.approx.guessMin = 1e10;
        data.approx.guessMax = 1e18;
        data.approx.guessOffchain = 0;
        data.approx.maxIteration = 200;
        data.approx.eps = 1e18;

        vm.startPrank(user1);
        pendleCTokenSTETH.setDelegateApproval(address(pendleZapper), true);

        pendleZapper.enterPendle{ value: ethAmount }(
            address(pendleCTokenSTETH),
            PendleZapper.ZapperData(
                address(0),
                ethAmount,
                _PENDLE_LP_STETH,
                1,
                true
            ),
            new SwapperLib.Swap[](0),
            _PENDLE_ROUTER,
            _IS_PT,
            data,
            1.2 ether,
            true,
            user1
        );

        vm.stopPrank();

        assertEq(user1.balance, 0);

        (,,,, uint256 pendleCTokenSTETHBorrowed, ) = pendleCTokenSTETH.getSnapshot(user1);
        assertApproxEqRel(pendleCTokenSTETH.balanceOf(user1), 1.24 ether, 0.01 ether);
        assertEq(pendleCTokenSTETHBorrowed, 0);
    }

    function testEnterPendleWithDelegation() public {
        uint256 ethAmount = 3 ether;
        vm.deal(user2, ethAmount);

        vm.startPrank(user1);
        pendleCTokenSTETH.setDelegateApproval(user2, true);
        pendleCTokenSTETH.setDelegateApproval(address(pendleZapper), true);
        vm.stopPrank(user1);

        PendleLib.PendleData memory data;

        data.approx.guessMin = 1e10;
        data.approx.guessMax = 1e18;
        data.approx.guessOffchain = 0;
        data.approx.maxIteration = 200;
        data.approx.eps = 1e18;

        vm.startPrank(user2);
        pendleZapper.enterPendle{ value: ethAmount }(
            address(pendleCTokenSTETH),
            PendleZapper.ZapperData(
                address(0),
                ethAmount,
                _PENDLE_LP_STETH,
                1,
                true
            ),
            new SwapperLib.Swap[](0),
            _PENDLE_ROUTER,
            _IS_PT,
            data,
            1.2 ether,
            true,
            user1
        );

        vm.stopPrank();

        assertEq(user2.balance, 0);

        (,,,, uint256 pendleCTokenSTETHBorrowed, ) = pendleCTokenSTETH.getSnapshot(user1);
        assertApproxEqRel(pendleCTokenSTETH.balanceOf(user1), 1.24 ether, 0.01 ether);
        assertEq(pendleCTokenSTETHBorrowed, 0);
    }

    function testRedeemAndExitPendle() public {
        testEnterPendleWithCTokenWithCollateralize();

        ZapperBase.RedemptionData memory redemptionData;
        redemptionData.mToken = address(pendleCTokenSTETH);
        redemptionData.shares = 1.24 ether;
        redemptionData.forceRedeemCollateral = false;

        PendleLib.PendleData memory data;

        data.approx.guessMin = 1e10;
        data.approx.guessMax = 1e18;
        data.approx.guessOffchain = 0;
        data.approx.maxIteration = 200;
        data.approx.eps = 1e18;

        vm.warp(
            marketManagerIsolated.accountAssets(user1) +
                marketManagerIsolated.MIN_HOLD_PERIOD()
        );

        vm.startPrank(user1);
        pendleCTokenSTETH.setDelegateApproval(address(pendleZapper), true);

        IERC20(_PENDLE_LP_STETH).approve(address(pendleZapper), 3 ether);
        pendleZapper.redeemAndExitPendle(
            redemptionData,
            _PENDLE_ROUTER,
            _IS_PT,
            _STETH,
            data,
            PendleZapper.ZapperData(
                _PENDLE_LP_STETH,
                1.24 ether,
                _STETH,
                0,
                false
            ),
            new SwapperLib.Swap[](0),
            user1
        );
        vm.stopPrank();

        assertApproxEqRel(
            IERC20(_STETH).balanceOf(user1),
            2.6 ether,
            0.1 ether
        );
    }
}
