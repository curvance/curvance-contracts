// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

import "tests/market/TestBaseMarket.sol";

contract TestComplexZapperCurveETH is TestBaseMarket {
    address internal _CURVE_STETH_LP =
        0x21E27a5E5513D6e65C4f830167390997aA84843a;
    address internal _CURVE_STETH_MINTER =
        0x21E27a5E5513D6e65C4f830167390997aA84843a;
    address internal _STETH_ADDRESS =
        0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

    receive() external payable {}

    fallback() external payable {}

    function testInitialize() public {
        assertEq(
            address(complexZapper.marketManager()),
            address(marketManager)
        );
    }

    function testEnterCurveWithETH() public {
        uint256 ethAmount = 3 ether;
        vm.deal(user1, ethAmount);

        address[] memory tokens = new address[](2);
        tokens[0] = _ETH_ADDRESS;
        tokens[1] = _STETH_ADDRESS;

        vm.prank(user1);
        complexZapper.enterCurve{ value: ethAmount }(
            address(0),
            ComplexZapper.ZapperData(
                _ETH_ADDRESS,
                ethAmount,
                _CURVE_STETH_LP,
                1,
                false
            ),
            new SwapperLib.Swap[](0),
            _CURVE_STETH_MINTER,
            tokens,
            false,
            user1
        );

        assertEq(user1.balance, 0);
        assertGt(IERC20(_CURVE_STETH_LP).balanceOf(user1), 0);
    }

    function testExitCurve() public {
        testEnterCurveWithETH();

        uint256 withdrawAmount = IERC20(_CURVE_STETH_LP).balanceOf(user1);

        vm.startPrank(user1);
        address[] memory tokens = new address[](2);
        tokens[0] = _ETH_ADDRESS;
        tokens[1] = _STETH_ADDRESS;
        IERC20(_CURVE_STETH_LP).approve(
            address(complexZapper),
            withdrawAmount
        );
        complexZapper.exitCurve(
            _CURVE_STETH_MINTER,
            ComplexZapper.ZapperData(
                _CURVE_STETH_LP,
                withdrawAmount,
                _ETH_ADDRESS,
                0,
                false
            ),
            tokens,
            2,
            0,
            new SwapperLib.Swap[](0),
            user1
        );
        vm.stopPrank();

        assertApproxEqRel(user1.balance, 3 ether, 0.01 ether);
        assertEq(IERC20(_CURVE_STETH_LP).balanceOf(user1), 0);
    }
}
