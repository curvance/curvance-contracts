// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { ComplexZapper } from "contracts/market/zapper/ComplexZapper.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract TestComplexZapperVelodrome is TestBaseMarket {
    address internal _VELODROME_FACTORY =
        0xF1046053aa5682b4F9a81b5481394DA16BE5FF5a;
    address internal _VELODROME_ROUTER =
        0xa062aE8A9c5e11aaA026fc2670B0D65cCc8B2858;
    address internal _VELODROME_WETH_USDC =
        0x0493Bf8b6DBB159Ce2Db2E0E8403E753Abd1235b;
    address internal _WETH = 0x4200000000000000000000000000000000000006;
    address internal _USDC = 0x7F5c764cBc14f9669B88837ca1490cCa17c31607;
    bool internal _IS_STABLE = false;

    receive() external payable {}

    fallback() external payable {}

    function setUp() public override {
        _fork("ETH_NODE_URI_OPTIMISM", 109095500);

        _deployCentralRegistry();
        _deployCVE();
        _deployRewardManager();
        _deployVeCVE();
        _deployGaugeManager();
        _deployMarketManager();

        complexZapper = new ComplexZapper(
            ICentralRegistry(address(centralRegistry)),
            address(marketManager),
            _WETH
        );
    }

    function testInitialize() public {
        assertEq(
            address(complexZapper.marketManager()),
            address(marketManager)
        );
    }

    function testEnterVelodrome() public {
        uint256 ethAmount = 3 ether;
        vm.deal(user1, ethAmount);

        vm.prank(user1);
        complexZapper.enterVelodrome{ value: ethAmount }(
            address(0),
            ComplexZapper.ZapperData(
                address(0),
                ethAmount,
                _VELODROME_WETH_USDC,
                1,
                true
            ),
            new SwapperLib.Swap[](0),
            _VELODROME_ROUTER,
            _VELODROME_FACTORY,
            false,
            user1
        );

        assertEq(user1.balance, 0);
        assertGt(IERC20(_VELODROME_WETH_USDC).balanceOf(user1), 0);
    }

    function testExitVelodrome() public {
        testEnterVelodrome();

        uint256 withdrawAmount = IERC20(_VELODROME_WETH_USDC).balanceOf(user1);

        vm.startPrank(user1);
        IERC20(_VELODROME_WETH_USDC).approve(
            address(complexZapper),
            withdrawAmount
        );
        complexZapper.exitVelodrome(
            _VELODROME_ROUTER,
            ComplexZapper.ZapperData(
                _VELODROME_WETH_USDC,
                withdrawAmount,
                _WETH,
                0,
                false
            ),
            new SwapperLib.Swap[](0),
            user1
        );
        vm.stopPrank();

        assertGt(IERC20(_WETH).balanceOf(user1), 0);
        // assertGt(IERC20(_USDC).balanceOf(user1), 0);
        assertEq(IERC20(_VELODROME_WETH_USDC).balanceOf(user1), 0);
    }
}
