// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { PendleLib } from "contracts/libraries/PendleLib.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IPendleRouter } from "contracts/interfaces/external/pendle/IPendleRouter.sol";
import { IMToken } from "contracts/interfaces/market/IMToken.sol";
import { IPendlePTOracle } from "contracts/interfaces/external/pendle/IPendlePtOracle.sol";
import { ComplexZapper } from "contracts/plugins/market/ComplexZapper.sol";
import { PendleLPTokenAdaptor } from "contracts/oracles/adaptors/pendle/PendleLPTokenAdaptor.sol";
import { PendleLPPToken } from "contracts/market/token/PendleLPPToken.sol";

import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";

contract TestComplexZapperPendle is TestBaseMarket {
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
    PendleLPPToken public cSTETH;

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

        cSTETH = new PendleLPPToken(
            ICentralRegistry(address(centralRegistry)),
            IERC20(_LP_STETH),
            address(marketManager),
            IPendleRouter(_PENDLE_ROUTER)
        );
        oracleManager.addMTokenSupport(address(cSTETH));

        deal(_LP_STETH, address(this), 1 ether);
        IERC20(_LP_STETH).approve(address(cSTETH), 1 ether);
        marketManager.listToken(address(cSTETH));
        marketManager.updatePositionToken(
            IMToken(address(cSTETH)),
            7000,
            4000,
            3000,
            200,
            400,
            10,
            1000
        );

        address[] memory tokens = new address[](1);
        tokens[0] = address(cSTETH);
        uint256[] memory caps = new uint256[](1);
        caps[0] = 100_000e18;
        marketManager.setPTokenCollateralCaps(tokens, caps);
    }

    function testInitialize() public {
        assertEq(
            address(complexZapper.marketManager()),
            address(marketManager)
        );
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

        vm.prank(user1);
        complexZapper.enterPendle{ value: ethAmount }(
            address(0),
            ComplexZapper.ZapperData(
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
            false,
            user1
        );

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
            address(complexZapper),
            withdrawAmount
        );
        complexZapper.exitPendle(
            _PENDLE_ROUTER,
            _IS_PT,
            _STETH,
            data,
            ComplexZapper.ZapperData(
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

        PendleLib.PendleData memory data;

        data.approx.guessMin = 1e10;
        data.approx.guessMax = 1e18;
        data.approx.guessOffchain = 0;
        data.approx.maxIteration = 200;
        data.approx.eps = 1e18;

        vm.prank(user1);
        complexZapper.enterPendle{ value: ethAmount }(
            address(cSTETH),
            ComplexZapper.ZapperData(
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
            false,
            user1
        );

        assertEq(user1.balance, 0);

        (uint256 balance, uint256 borrowed, ) = cSTETH.getSnapshot(user1);
        assertApproxEqRel(balance, 1.24 ether, 0.01 ether);
        assertEq(borrowed, 0);
    }

    function testEnterPendleWithDelegation() public {
        uint256 ethAmount = 3 ether;
        vm.deal(user2, ethAmount);

        vm.prank(user1);
        cSTETH.setDelegateApproval(user2, true);

        PendleLib.PendleData memory data;

        data.approx.guessMin = 1e10;
        data.approx.guessMax = 1e18;
        data.approx.guessOffchain = 0;
        data.approx.maxIteration = 200;
        data.approx.eps = 1e18;

        vm.prank(user2);
        complexZapper.enterPendle{ value: ethAmount }(
            address(cSTETH),
            ComplexZapper.ZapperData(
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
            false,
            user1
        );

        assertEq(user2.balance, 0);

        (uint256 balance, uint256 borrowed, ) = cSTETH.getSnapshot(user1);
        assertApproxEqRel(balance, 1.24 ether, 0.01 ether);
        assertEq(borrowed, 0);
    }

    function testRedeemAndExitPendle() public {
        testEnterPendleWithPToken();

        vm.prank(user1);
        cSTETH.setDelegateApproval(address(complexZapper), true);

        ComplexZapper.RedemptionData memory redemptionData;
        redemptionData.pToken = address(cSTETH);
        redemptionData.shares = 1.24 ether;
        redemptionData.forceRedeemCollateral = false;

        PendleLib.PendleData memory data;

        data.approx.guessMin = 1e10;
        data.approx.guessMax = 1e18;
        data.approx.guessOffchain = 0;
        data.approx.maxIteration = 200;
        data.approx.eps = 1e18;

        vm.startPrank(user1);
        IERC20(_PENDLE_LP_STETH).approve(address(complexZapper), 3 ether);
        complexZapper.redeemAndExitPendle(
            redemptionData,
            _PENDLE_ROUTER,
            _IS_PT,
            _STETH,
            data,
            ComplexZapper.ZapperData(
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
