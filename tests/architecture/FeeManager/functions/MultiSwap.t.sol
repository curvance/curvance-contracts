// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseFeeManager } from "../TestBaseFeeManager.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { FeeManager } from "contracts/architecture/FeeManager.sol";
import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";

contract MultiSwapTest is TestBaseFeeManager {
    SwapperLib.Swap[] public swapData;
    address[] public path;
    address[] public tokens;

    function setUp() public override {
        super.setUp();

        path.push(_WETH_ADDRESS);
        path.push(_USDC_ADDRESS);

        tokens.push(_WETH_ADDRESS);

        swapData.push(
            SwapperLib.Swap({
                inputToken: _WETH_ADDRESS,
                inputAmount: _ONE,
                outputToken: _USDC_ADDRESS,
                target: _UNISWAP_V2_ROUTER,
                call: abi.encodeWithSignature(
                    "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
                    _ONE,
                    0,
                    path,
                    address(feeManager),
                    block.timestamp
                ),
                slippage: 60e16
            })
        );

        address[] memory rewardTokens = new address[](2);
        rewardTokens[0] = _WETH_ADDRESS;
        rewardTokens[1] = _USDC_ADDRESS;

        feeManager.addRewardTokens(rewardTokens);

        centralRegistry.setExternalCallDataChecker(
            _UNISWAP_V2_ROUTER,
            address(new MockCalldataChecker(_UNISWAP_V2_ROUTER))
        );
    }

    function test_multiSwap_fail_whenCallerIsNotAuthorized() public {
        vm.expectRevert(FeeManager.FeeManager__Unauthorized.selector);
        feeManager.multiSwap(abi.encode(swapData), tokens);
    }

    function test_multiSwap_fail_whenTokensLengthIsNotMatch() public {
        tokens.push(_USDT_ADDRESS);

        vm.expectRevert(
            abi.encodeWithSelector(
                FeeManager.FeeManager__SwapDataAndTokenLengthMismatch.selector,
                1,
                2
            )
        );

        vm.prank(harvester);
        feeManager.multiSwap(abi.encode(swapData), tokens);
    }

    function test_multiSwap_fail_whenTokenIsNotRewardToken() public {
        tokens[0] = _USDT_ADDRESS;

        vm.expectRevert(
            abi.encodeWithSelector(
                FeeManager
                    .FeeManager__SwapDataCurrentTokenIsNotRewardToken
                    .selector,
                0,
                _USDT_ADDRESS
            )
        );

        vm.prank(harvester);
        feeManager.multiSwap(abi.encode(swapData), tokens);
    }

    function test_multiSwap_fail_whenTokenIsNotSwapInputToken() public {
        tokens[0] = _USDC_ADDRESS;

        vm.expectRevert(
            abi.encodeWithSelector(
                FeeManager
                    .FeeManager__SwapDataInputTokenIsNotCurrentToken
                    .selector,
                0,
                _WETH_ADDRESS,
                _USDC_ADDRESS
            )
        );

        vm.prank(harvester);
        feeManager.multiSwap(abi.encode(swapData), tokens);
    }

    function test_multiSwap_fail_whenSwapOutputTokenIsNotFeeToken() public {
        swapData[0] = SwapperLib.Swap({
            inputToken: _WETH_ADDRESS,
            inputAmount: _ONE,
            outputToken: _USDT_ADDRESS,
            target: _UNISWAP_V2_ROUTER,
            call: abi.encodeWithSignature(
                "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
                _ONE,
                0,
                path,
                address(feeManager),
                block.timestamp
            ),
            slippage: 10e16
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                FeeManager
                    .FeeManager__SwapDataOutputTokenIsNotFeeToken
                    .selector,
                0,
                _USDT_ADDRESS,
                _USDC_ADDRESS
            )
        );

        vm.prank(harvester);
        feeManager.multiSwap(abi.encode(swapData), tokens);
    }

    function test_multiSwap_fail_whenFeeManagerHasNoEnoughToken() public {
        vm.expectRevert();

        vm.prank(harvester);
        feeManager.multiSwap(abi.encode(swapData), tokens);
    }

    function test_multiSwap_success() public {
        deal(_WETH_ADDRESS, address(feeManager), _ONE);

        vm.prank(harvester);
        feeManager.multiSwap(abi.encode(swapData), tokens);

        assertEq(weth.balanceOf(address(centralRegistry)), 0);
    }
}
