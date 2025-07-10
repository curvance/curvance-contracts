// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBasePredeposit } from "../TestBasePredeposit.sol";
import { Predeposit } from "contracts/misc/Predeposit.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract TestPredeposit is TestBasePredeposit {
    SwapperLib.Swap public swapData;

    function setUp() public override {
        super.setUp();

        _prepareUSDC(address(this), 1000e6);
        _prepareBALRETH(address(this), 1000e18);
        _prepareWETH(user1, _ONE);
        _prepareWETH(user2, 100e18);
        _prepareBALRETH(user2, 100e18);

        address[] memory newPredepositTokens = new address[](1);
        newPredepositTokens[0] = _BAL_WETH_RETH_ADDRESS;

        vm.startPrank(manager);
        predeposit.addPredepositTokens(newPredepositTokens);
        vm.stopPrank();

        usdc.approve(address(borrowableCUSDC), 1000e6);
        balRETH.approve(address(strategyCBALRETH), 1000e18);

        marketManagerIsolated.listTokens(address(strategyCBALRETH),address(borrowableCUSDC));

        vm.startPrank(manager);

        predeposit.setMigrationConfig(_USDC_ADDRESS, address(borrowableCUSDC));
        predeposit.setMigrationConfig(
            _BAL_WETH_RETH_ADDRESS,
            address(strategyCBALRETH)
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
            address(predeposit),
            block.timestamp
        );

        centralRegistry.setExternalCalldataChecker(
            _UNISWAP_V2_ROUTER,
            address(new MockCalldataChecker(_UNISWAP_V2_ROUTER))
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

        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = address(strategyCBALRETH);
        tokenConfig.collRatio = 7000;
        tokenConfig.collReqSoft = 4000;
        tokenConfig.collReqHard = 3000;
        tokenConfig.liqIncBase = 1000;
        tokenConfig.liqIncHard = 1500;
        tokenConfig.liqIncMin = 500;
        tokenConfig.liqIncMax = 2000;
        tokenConfig.minEffectiveCloseFactor = 2000;
        tokenConfig.maxEffectiveCloseFactor = 5000;
        tokenConfig.baseCFactor = 1000;
        tokenConfig.collateralCap = 100_000e18;
        tokenConfig.debtCap = 0;

        marketManagerIsolated.updateTokenConfig(tokenConfig);

        tokenConfig.cToken = address(borrowableCUSDC);
        tokenConfig.debtCap = 100_000e6;
        marketManagerIsolated.updateTokenConfig(tokenConfig);
    }

    function test_swapAndDeposit_migrate_withPToken_withCollateralize_success()
        public
    {
        vm.startPrank(user1);

        weth.approve(address(predeposit), _ONE);

        swapData.outputToken = _BAL_WETH_RETH_ADDRESS;

        address[] memory path = new address[](2);
        path[0] = _WETH_ADDRESS;
        path[1] = _BAL_WETH_RETH_ADDRESS;

        swapData.call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            _ONE,
            0,
            path,
            address(predeposit),
            block.timestamp
        );

        strategyCBALRETH.setDelegateApproval(address(predeposit), true);
        predeposit.swapAndDeposit(swapData, 0.1e18);

        skip(1 weeks);

        uint256 underlyingBalance = balRETH.balanceOf(address(strategyCBALRETH));

        assertEq(
            predeposit.balanceOf(user1, _BAL_WETH_RETH_ADDRESS),
            0.1e18
        );
        assertEq(balRETH.balanceOf(address(predeposit)), 0.1e18);

        predeposit.migrate(_BAL_WETH_RETH_ADDRESS, 0.1e18, true);

        vm.stopPrank();

        assertEq(predeposit.balanceOf(user1, _BAL_WETH_RETH_ADDRESS), 0);
        assertEq(balRETH.balanceOf(address(predeposit)), 0);
        assertEq(balRETH.balanceOf(address(strategyCBALRETH)), underlyingBalance);
        assertEq(strategyCBALRETH.balanceOf(user1), 0.1e18);
    }

    function test_swapAndDeposit_migrate_withPToken_withoutCollateralize_success()
        public
    {
        vm.startPrank(user1);

        weth.approve(address(predeposit), _ONE);

        swapData.outputToken = _BAL_WETH_RETH_ADDRESS;

        address[] memory path = new address[](2);
        path[0] = _WETH_ADDRESS;
        path[1] = _BAL_WETH_RETH_ADDRESS;

        swapData.call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            _ONE,
            0,
            path,
            address(predeposit),
            block.timestamp
        );

        predeposit.swapAndDeposit(swapData, 0.1e18);

        vm.stopPrank();

        skip(1 weeks);

        uint256 underlyingBalance = balRETH.balanceOf(address(strategyCBALRETH));

        assertEq(
            predeposit.balanceOf(user1, _BAL_WETH_RETH_ADDRESS),
            0.1e18
        );
        assertEq(balRETH.balanceOf(address(predeposit)), 0.1e18);

        vm.prank(user1);
        predeposit.migrate(_BAL_WETH_RETH_ADDRESS, 0.1e18, false);

        assertEq(predeposit.balanceOf(user1, _BAL_WETH_RETH_ADDRESS), 0);
        assertEq(balRETH.balanceOf(address(predeposit)), 0);
        assertEq(balRETH.balanceOf(address(strategyCBALRETH)), underlyingBalance);
        assertEq(strategyCBALRETH.balanceOf(user1), 0.1e18);
    }

    function test_swapAndDeposit_migrate_withEToken_success() public {
        vm.startPrank(user1);

        weth.approve(address(predeposit), _ONE);

        swapData.outputToken = _USDC_ADDRESS;
        predeposit.swapAndDeposit(swapData, 100e6);

        vm.stopPrank();

        skip(1 weeks);

        uint256 marketUnderlyingHeld = borrowableCUSDC.assetsHeld();

        assertEq(predeposit.balanceOf(user1, _USDC_ADDRESS), 100e6);
        assertEq(usdc.balanceOf(address(predeposit)), 100e6);

        vm.prank(user1);

        predeposit.migrate(_USDC_ADDRESS, 100e6, true);

        assertEq(predeposit.balanceOf(user1, _USDC_ADDRESS), 0);
        assertEq(usdc.balanceOf(address(predeposit)), 0);
        assertEq(borrowableCUSDC.assetsHeld(), marketUnderlyingHeld + 100e6);
        assertEq(borrowableCUSDC.balanceOf(user1), 100e6);
    }
}
