// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { PendleLib } from "contracts/libraries/PendleLib.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IPendleRouter } from "contracts/interfaces/external/pendle/IPendleRouter.sol";
import { IPendlePTOracle } from "contracts/interfaces/external/pendle/IPendlePtOracle.sol";
import { BaseZapper } from "contracts/plugins/BaseZapper.sol";
import { PendleLPTokenAdaptor } from "contracts/oracles/adaptors/pendle/PendleLPTokenAdaptor.sol";
import { PendleLPPToken } from "contracts/market/token/PendleLPPToken.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

contract TestComplexZapperPendle is TestBaseMarketIsolated {
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
    PendleLPPToken public pSTETH;

    receive() external payable {}

    fallback() external payable {}

    function setUp() public override {
        _fork(20287400);
        _init();

        chainlinkAdaptor.addAsset(_STETH, _CHAINLINK_STETH_USD, 0, true);
        oracleManager.addAssetPriceFeed(_STETH, address(chainlinkAdaptor));

        adaptor = new PendleLPTokenAdaptor(
            ICentralRegistry(address(centralRegistry)),
            IPendlePTOracle(_PT_ORACLE),
            .1e18,
            0,
            30 days,
            7 days
        );
        PendleLPTokenAdaptor.AssetConfig memory assetConfig;
        assetConfig.twapDuration = 12;
        assetConfig.quoteAsset = _STETH;
        assetConfig.pt = _PT_STETH;
        assetConfig.quoteAssetDecimals = 18;
        adaptor.addAsset(_LP_STETH, assetConfig);
        oracleManager.addApprovedAdaptor(address(adaptor));
        oracleManager.addAssetPriceFeed(_LP_STETH, address(adaptor));

        pSTETH = new PendleLPPToken(
            ICentralRegistry(address(centralRegistry)),
            IERC20(_LP_STETH),
            address(marketManager),
            IPendleRouter(_PENDLE_ROUTER)
        );
        oracleManager.addCTokenSupport(address(pSTETH));

        deal(_LP_STETH, address(this), 1 ether);
        IERC20(_LP_STETH).approve(address(pSTETH), 1 ether);
        marketManager.listToken(address(pSTETH));
        marketManager.updatePositionToken(
            address(pSTETH),
            7000,
            4000,
            3000,
            200,
            400,
            1000
        );

        address[] memory tokens = new address[](1);
        tokens[0] = address(pSTETH);
        uint256[] memory caps = new uint256[](1);
        caps[0] = 100_000e18;
        marketManager.setCollateralCaps(tokens, caps);
    }

    function testEnterPendle() public {
        uint256 ethAmount = 3 ether;
        vm.deal(user1, ethAmount);

        PendleLib.PendleAction memory action;

        action.approx.guessMin = 1e10;
        action.approx.guessMax = 1e18;
        action.approx.guessOffchain = 0;
        action.approx.maxIteration = 200;
        action.approx.eps = 1e18;

        vm.prank(user1);
        complexZapper.enterPendle{ value: ethAmount }(
            address(0),
            ComplexZapper.ZapAction(
                address(0),
                ethAmount,
                _PENDLE_LP_STETH,
                1,
                true
            ),
            new SwapperLib.Swap[](0),
            _PENDLE_ROUTER,
            _IS_PT,
            action,
            1.2 ether,
            false,
            user1
        );

        assertEq(user1.balance, 0);
        assertGt(IERC20(_PENDLE_LP_STETH).balanceOf(user1), 0);
    }

    function testExitPendle() public {
        testEnterPendle();

        uint256 withdrawAmount = IERC20(_PENDLE_LP_STETH).balanceOf(user1);

        PendleLib.PendleAction memory action;

        action.approx.guessMin = 1e10;
        action.approx.guessMax = 1e18;
        action.approx.guessOffchain = 0;
        action.approx.maxIteration = 200;
        action.approx.eps = 1e18;

        vm.startPrank(user1);
        IERC20(_PENDLE_LP_STETH).approve(
            address(complexZapper),
            withdrawAmount
        );
        complexZapper.exitPendle(
            _PENDLE_ROUTER,
            _IS_PT,
            _STETH,
            action,
            ComplexZapper.ZapAction(
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

    function testEnterPendleWithPToken() public {
        uint256 ethAmount = 3 ether;
        vm.deal(user1, ethAmount);

        PendleLib.PendleAction memory action;

        action.approx.guessMin = 1e10;
        action.approx.guessMax = 1e18;
        action.approx.guessOffchain = 0;
        action.approx.maxIteration = 200;
        action.approx.eps = 1e18;

        vm.prank(user1);
        complexZapper.enterPendle{ value: ethAmount }(
            address(pSTETH),
            ComplexZapper.ZapAction(
                address(0),
                ethAmount,
                _PENDLE_LP_STETH,
                1,
                true
            ),
            new SwapperLib.Swap[](0),
            _PENDLE_ROUTER,
            _IS_PT,
            action,
            1.2 ether,
            false,
            user1
        );

        assertEq(user1.balance, 0);

        (uint256 balance, uint256 borrowed, ) = pSTETH.getSnapshot(user1);
        assertApproxEqRel(balance, 1.24 ether, 0.01 ether);
        assertEq(borrowed, 0);
    }

    function testEnterPendleWithPTokenWithCollateralize() public {
        uint256 ethAmount = 3 ether;
        vm.deal(user1, ethAmount);

        PendleLib.PendleAction memory action;

        action.approx.guessMin = 1e10;
        action.approx.guessMax = 1e18;
        action.approx.guessOffchain = 0;
        action.approx.maxIteration = 200;
        action.approx.eps = 1e18;

        vm.prank(user1);
        complexZapper.enterPendle{ value: ethAmount }(
            address(pSTETH),
            ComplexZapper.ZapAction(
                address(0),
                ethAmount,
                _PENDLE_LP_STETH,
                1,
                true
            ),
            new SwapperLib.Swap[](0),
            _PENDLE_ROUTER,
            _IS_PT,
            action,
            1.2 ether,
            true,
            user1
        );

        assertEq(user1.balance, 0);

        (uint256 balance, uint256 borrowed, ) = pSTETH.getSnapshot(user1);
        assertApproxEqRel(balance, 1.24 ether, 0.01 ether);
        assertEq(borrowed, 0);
    }

    function testEnterPendleWithDelegation() public {
        uint256 ethAmount = 3 ether;
        vm.deal(user2, ethAmount);

        vm.prank(user1);
        pSTETH.setDelegateApproval(user2, true);
        vm.prank(user1);
        pSTETH.setDelegateApproval(address(complexZapper), true);

        PendleLib.PendleAction memory action;

        action.approx.guessMin = 1e10;
        action.approx.guessMax = 1e18;
        action.approx.guessOffchain = 0;
        action.approx.maxIteration = 200;
        action.approx.eps = 1e18;

        vm.prank(user2);
        complexZapper.enterPendle{ value: ethAmount }(
            address(pSTETH),
            ComplexZapper.ZapAction(
                address(0),
                ethAmount,
                _PENDLE_LP_STETH,
                1,
                true
            ),
            new SwapperLib.Swap[](0),
            _PENDLE_ROUTER,
            _IS_PT,
            action,
            1.2 ether,
            true,
            user1
        );

        assertEq(user2.balance, 0);

        (uint256 balance, uint256 borrowed, ) = pSTETH.getSnapshot(user1);
        assertApproxEqRel(balance, 1.24 ether, 0.01 ether);
        assertEq(borrowed, 0);
    }

    function testRedeemAndExitPendle() public {
        testEnterPendleWithPTokenWithCollateralize();

        vm.prank(user1);
        pSTETH.setDelegateApproval(address(complexZapper), true);

        BaseZapper.RedeemAction memory redeemAction;
        redeemAction.mToken = address(pSTETH);
        redeemAction.shares = 1.24 ether;
        redeemAction.forceRedeemCollateral = false;

        PendleLib.PendleAction memory action;

        action.approx.guessMin = 1e10;
        action.approx.guessMax = 1e18;
        action.approx.guessOffchain = 0;
        action.approx.maxIteration = 200;
        action.approx.eps = 1e18;

        vm.startPrank(user1);
        IERC20(_PENDLE_LP_STETH).approve(address(complexZapper), 3 ether);
        complexZapper.redeemAndExitPendle(
            redeemAction,
            _PENDLE_ROUTER,
            _IS_PT,
            _STETH,
            action,
            ComplexZapper.ZapAction(
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
