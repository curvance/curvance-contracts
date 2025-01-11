// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

import "tests/market/TestBaseMarket.sol";

contract TestComplexZapperCurveStable is TestBaseMarket {
    address internal _CURVE_TRICRYPTO_LP =
        0xc4AD29ba4B3c580e6D59105FFf484999997675Ff;
    address internal _CURVE_TRICRYPTO_MINTER =
        0xD51a44d3FaE010294C616388b506AcdA1bfAAE46;

    receive() external payable {}

    fallback() external payable {}

    function testEnterCurveWithETH() public {
        uint256 ethAmount = 3 ether;
        vm.deal(user1, ethAmount);

        vm.startPrank(user1);
        address[] memory tokens = new address[](3);
        tokens[0] = _USDT_ADDRESS;
        tokens[1] = _WBTC_ADDRESS;
        tokens[2] = _WETH_ADDRESS;
        complexZapper.enterCurve{ value: ethAmount }(
            address(0),
            ComplexZapper.ZapperData(
                address(0),
                ethAmount,
                _CURVE_TRICRYPTO_LP,
                1,
                true
            ),
            new SwapperLib.Swap[](0),
            _CURVE_TRICRYPTO_MINTER,
            tokens,
            2.9 ether,
            false,
            user1
        );
        vm.stopPrank();

        assertEq(user1.balance, 0);
        assertGt(IERC20(_CURVE_TRICRYPTO_LP).balanceOf(user1), 0);
    }

    function testEnterCurveWithWETH() public {
        uint256 wethAmount = 3 ether;
        _prepareWETH(user1, wethAmount);

        vm.startPrank(user1);
        weth.approve(address(complexZapper), wethAmount);
        address[] memory tokens = new address[](3);
        tokens[0] = _USDT_ADDRESS;
        tokens[1] = _WBTC_ADDRESS;
        tokens[2] = _WETH_ADDRESS;
        complexZapper.enterCurve(
            address(0),
            ComplexZapper.ZapperData(
                _WETH_ADDRESS,
                wethAmount,
                _CURVE_TRICRYPTO_LP,
                1,
                false
            ),
            new SwapperLib.Swap[](0),
            _CURVE_TRICRYPTO_MINTER,
            tokens,
            2.9 ether,
            false,
            user1
        );
        vm.stopPrank();

        assertEq(user1.balance, 0);
        assertGt(IERC20(_CURVE_TRICRYPTO_LP).balanceOf(user1), 0);
    }

    function testExitCurve() public {
        testEnterCurveWithETH();

        uint256 withdrawAmount = IERC20(_CURVE_TRICRYPTO_LP).balanceOf(user1);

        vm.startPrank(user1);
        address[] memory tokens = new address[](3);
        tokens[0] = _USDT_ADDRESS;
        tokens[1] = _WBTC_ADDRESS;
        tokens[2] = _WETH_ADDRESS;
        IERC20(_CURVE_TRICRYPTO_LP).approve(
            address(complexZapper),
            withdrawAmount
        );
        complexZapper.exitCurve(
            _CURVE_TRICRYPTO_MINTER,
            ComplexZapper.ZapperData(
                _CURVE_TRICRYPTO_LP,
                withdrawAmount,
                _WETH_ADDRESS,
                0,
                false
            ),
            tokens,
            1,
            2,
            new SwapperLib.Swap[](0),
            user1
        );
        vm.stopPrank();

        assertApproxEqRel(weth.balanceOf(user1), 3 ether, 0.01 ether);
        assertEq(IERC20(_CURVE_TRICRYPTO_LP).balanceOf(user1), 0);
    }
}
