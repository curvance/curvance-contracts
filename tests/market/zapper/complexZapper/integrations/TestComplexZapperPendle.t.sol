// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { PendleLib } from "contracts/libraries/PendleLib.sol";
import { ComplexZapper } from "contracts/market/utils/ComplexZapper.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

contract TestComplexZapperPendle is TestBaseMarket {
    address internal _PENDLE_ROUTER =
        0x888888888889758F76e7103c6CbF23ABbF58F946;
    address internal _PENDLE_LP_STETH =
        0xD0354D4e7bCf345fB117cabe41aCaDb724eccCa2;
    address internal _STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

    bool internal _IS_PT = false;

    address public user;

    receive() external payable {}

    fallback() external payable {}

    function setUp() public override {
        _fork(20287400);
        _init();
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
}
