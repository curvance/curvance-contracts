// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseCurvancePrefarm } from "../TestBaseCurvancePrefarm.sol";
import { CurvancePrefarm } from "contracts/misc/CurvancePrefarm.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { MockCallDataChecker } from "contracts/mocks/MockCallDataChecker.sol";

contract TestCurvancePrefarm is TestBaseCurvancePrefarm {
    SwapperLib.Swap public swapData;

    function setUp() public override {
        super.setUp();

        deal(_USDC_ADDRESS, address(this), 1000e6);
        deal(_BAL_WETH_RETH_ADDRESS, address(this), 1000e18);
        deal(_WETH_ADDRESS, user1, _ONE);
        deal(_WETH_ADDRESS, user2, 100e18);
        deal(_BAL_WETH_RETH_ADDRESS, user2, 100e18);

        address[] memory newPrefarmTokens = new address[](1);
        newPrefarmTokens[0] = _BAL_WETH_RETH_ADDRESS;

        vm.startPrank(manager);
        curvancePrefarm.addPrefarmTokens(newPrefarmTokens);
        vm.stopPrank();

        usdc.approve(address(dUSDC), 1000e6);
        balRETH.approve(address(cBALRETH), 1000e18);

        marketManager.listToken(address(dUSDC));
        marketManager.listToken(address(cBALRETH));

        vm.startPrank(manager);

        curvancePrefarm.setMigrationConfig(_USDC_ADDRESS, address(dUSDC));
        curvancePrefarm.setMigrationConfig(
            _BAL_WETH_RETH_ADDRESS,
            address(cBALRETH)
        );

        vm.stopPrank();

        swapData.inputToken = _WETH_ADDRESS;
        swapData.inputAmount = _ONE;
        swapData.outputToken = _USDC_ADDRESS;
        swapData.target = _UNISWAP_V2_ROUTER;
        swapData.slippage = 50e16;

        address[] memory path = new address[](2);
        path[0] = _WETH_ADDRESS;
        path[1] = _USDC_ADDRESS;

        swapData.call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            _ONE,
            0,
            path,
            address(curvancePrefarm),
            block.timestamp
        );

        centralRegistry.setExternalCallDataChecker(
            _UNISWAP_V2_ROUTER,
            address(new MockCallDataChecker(_UNISWAP_V2_ROUTER))
        );

        vm.startPrank(user2);

        weth.approve(_UNISWAP_V2_ROUTER, 100e18);
        balRETH.approve(_UNISWAP_V2_ROUTER, 100e18);

        _UNISWAP_V2_ROUTER.call(
            abi.encodeWithSignature(
                "addLiquidity(address,address,uint256,uint256,uint256,uint256,address,uint256)",
                _WETH_ADDRESS,
                _BAL_WETH_RETH_ADDRESS,
                100e18,
                100e18,
                100e18,
                100e18,
                address(this),
                block.timestamp
            )
        );

        vm.stopPrank();
    }

    function test_zapAndDeposit_migrate_withCToken_withCollateralize_success()
        public
    {
        vm.startPrank(user1);

        weth.approve(address(curvancePrefarm), _ONE);

        swapData.outputToken = _BAL_WETH_RETH_ADDRESS;

        address[] memory path = new address[](2);
        path[0] = _WETH_ADDRESS;
        path[1] = _BAL_WETH_RETH_ADDRESS;

        swapData.call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            _ONE,
            0,
            path,
            address(curvancePrefarm),
            block.timestamp
        );

        curvancePrefarm.zapAndDeposit(swapData, 0.1e18);

        vm.stopPrank();

        skip(1 weeks);

        uint256 underlyingBalance = balRETH.balanceOf(address(cBALRETH));

        assertEq(
            curvancePrefarm.balanceOf(user1, _BAL_WETH_RETH_ADDRESS),
            0.1e18
        );
        assertEq(balRETH.balanceOf(address(curvancePrefarm)), 0.1e18);

        vm.prank(user1);
        curvancePrefarm.migrate(_BAL_WETH_RETH_ADDRESS, 0.1e18, true);

        assertEq(curvancePrefarm.balanceOf(user1, _BAL_WETH_RETH_ADDRESS), 0);
        assertEq(balRETH.balanceOf(address(curvancePrefarm)), 0);
        assertEq(balRETH.balanceOf(address(cBALRETH)), underlyingBalance);
        assertEq(cBALRETH.balanceOf(user1), 0.1e18);
    }

    function test_zapAndDeposit_migrate_withCToken_withoutCollateralize_success()
        public
    {
        vm.startPrank(user1);

        weth.approve(address(curvancePrefarm), _ONE);

        swapData.outputToken = _BAL_WETH_RETH_ADDRESS;

        address[] memory path = new address[](2);
        path[0] = _WETH_ADDRESS;
        path[1] = _BAL_WETH_RETH_ADDRESS;

        swapData.call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            _ONE,
            0,
            path,
            address(curvancePrefarm),
            block.timestamp
        );

        curvancePrefarm.zapAndDeposit(swapData, 0.1e18);

        vm.stopPrank();

        skip(1 weeks);

        uint256 underlyingBalance = balRETH.balanceOf(address(cBALRETH));

        assertEq(
            curvancePrefarm.balanceOf(user1, _BAL_WETH_RETH_ADDRESS),
            0.1e18
        );
        assertEq(balRETH.balanceOf(address(curvancePrefarm)), 0.1e18);

        vm.prank(user1);
        curvancePrefarm.migrate(_BAL_WETH_RETH_ADDRESS, 0.1e18, false);

        assertEq(curvancePrefarm.balanceOf(user1, _BAL_WETH_RETH_ADDRESS), 0);
        assertEq(balRETH.balanceOf(address(curvancePrefarm)), 0);
        assertEq(balRETH.balanceOf(address(cBALRETH)), underlyingBalance);
        assertEq(cBALRETH.balanceOf(user1), 0.1e18);
    }

    function test_zapAndDeposit_migrate_withDToken_success() public {
        vm.startPrank(user1);

        weth.approve(address(curvancePrefarm), _ONE);

        swapData.outputToken = _USDC_ADDRESS;
        curvancePrefarm.zapAndDeposit(swapData, 100e6);

        vm.stopPrank();

        skip(1 weeks);

        uint256 marketUnderlyingHeld = dUSDC.marketUnderlyingHeld();

        assertEq(curvancePrefarm.balanceOf(user1, _USDC_ADDRESS), 100e6);
        assertEq(usdc.balanceOf(address(curvancePrefarm)), 100e6);

        vm.prank(user1);

        curvancePrefarm.migrate(_USDC_ADDRESS, 100e6, true);

        assertEq(curvancePrefarm.balanceOf(user1, _USDC_ADDRESS), 0);
        assertEq(usdc.balanceOf(address(curvancePrefarm)), 0);
        assertEq(dUSDC.marketUnderlyingHeld(), marketUnderlyingHeld + 100e6);
        assertEq(dUSDC.balanceOf(user1), 100e6);
    }
}
