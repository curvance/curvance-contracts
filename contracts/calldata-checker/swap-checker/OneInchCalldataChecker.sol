// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { BaseSwapChecker } from "contracts/calldata-checker/swap-checker/BaseSwapChecker.sol";

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";

import { UniswapV3Pool } from "contracts/interfaces/external/uniswap/UniswapV3Pool.sol";
import { IAggregationRouterV5 } from "contracts/interfaces/external/1inch/IAggregationRouterV5.sol";

/// @notice Inspects the calldata for a 1inch related swap action.
/// @dev NOTE: Currently built for Aggregation Router V5.
contract OneInchCalldataChecker is BaseSwapChecker {
    /// CONSTANTS ///

    /// @notice The mask for the one for zero flag
    uint256 private constant _ONE_FOR_ZERO_MASK = 1 << 255;
    /// @notice The mask for the reverse flag
    uint256 private constant _REVERSE_MASK =
        0x8000000000000000000000000000000000000000000000000000000000000000;

    /// CONSTRUCTOR ///

    constructor(address _target) BaseSwapChecker(_target) {}

    /// EXTERNAL FUNCTIONS ///

    /// @notice Inspects calldata for compliance with other swap instruction
    ///         parameters.
    /// @dev Used on swap to inspect and validate calldata safety.
    /// @param swapAction Swap action instructions including both direct
    ///                   parameters and decodeable calldata.
    /// @param expectedRecipient Address who will receive proceeds of
    ///                          `swapAction`.
    function checkCalldata(
        SwapperLib.Swap memory swapAction,
        address expectedRecipient
    ) external view override {
        if (swapAction.target != target) {
            revert CalldataChecker__TargetError();
        }

        bytes4 funcSigHash = _getFuncSigHash(swapAction.call);
        address recipient;
        address inputToken;
        uint256 inputAmount;
        address outputToken;
        if (funcSigHash == IAggregationRouterV5.swap.selector) {
            (, IAggregationRouterV5.SwapDescription memory desc, , ) = abi
                .decode(
                    _getFuncParams(swapAction.call),
                    (
                        address,
                        IAggregationRouterV5.SwapDescription,
                        bytes,
                        bytes
                    )
                );
            recipient = desc.dstReceiver;
            inputToken = desc.srcToken;
            inputAmount = desc.amount;
            outputToken = desc.dstToken;
        } else if (
            funcSigHash ==
            IAggregationRouterV5.uniswapV3SwapToWithPermit.selector
        ) {
            (
                address payable recipientAddress,
                address srcToken,
                uint256 amount,
                ,
                uint256[] memory pools,

            ) = abi.decode(
                    _getFuncParams(swapAction.call),
                    (address, address, uint256, uint256, uint256[], bytes)
                );

            recipient = recipientAddress;
            inputToken = srcToken;
            inputAmount = amount;

            uint256 pool = pools[pools.length - 1];
            outputToken = (pool & _ONE_FOR_ZERO_MASK == 0)
                ? UniswapV3Pool(address(uint160(pool))).token1()
                : UniswapV3Pool(address(uint160(pool))).token0();
        } else if (
            funcSigHash == IAggregationRouterV5.uniswapV3SwapTo.selector
        ) {
            (
                address payable recipientAddress,
                uint256 amount,
                ,
                uint256[] memory pools
            ) = abi.decode(
                    _getFuncParams(swapAction.call),
                    (address, uint256, uint256, uint256[])
                );

            recipient = recipientAddress;
            inputAmount = amount;

            uint256 pool = pools[0];
            inputToken = (pool & _ONE_FOR_ZERO_MASK == 0)
                ? UniswapV3Pool(address(uint160(pool))).token0()
                : UniswapV3Pool(address(uint160(pool))).token1();

            pool = pools[pools.length - 1];
            outputToken = (pool & _ONE_FOR_ZERO_MASK == 0)
                ? UniswapV3Pool(address(uint160(pool))).token1()
                : UniswapV3Pool(address(uint160(pool))).token0();
        } else if (
            funcSigHash == IAggregationRouterV5.uniswapV3Swap.selector
        ) {
            (uint256 amount, , uint256[] memory pools) = abi.decode(
                _getFuncParams(swapAction.call),
                (uint256, uint256, uint256[])
            );

            recipient = expectedRecipient;
            inputAmount = amount;

            uint256 pool = pools[0];
            inputToken = (pool & _ONE_FOR_ZERO_MASK == 0)
                ? UniswapV3Pool(address(uint160(pool))).token0()
                : UniswapV3Pool(address(uint160(pool))).token1();

            pool = pools[pools.length - 1];
            outputToken = (pool & _ONE_FOR_ZERO_MASK == 0)
                ? UniswapV3Pool(address(uint160(pool))).token1()
                : UniswapV3Pool(address(uint160(pool))).token0();
        } else if (
            funcSigHash == IAggregationRouterV5.unoswapToWithPermit.selector
        ) {
            (
                address payable recipientAddress,
                address srcToken,
                uint256 amount,
                ,
                uint256[] memory pools,

            ) = abi.decode(
                    _getFuncParams(swapAction.call),
                    (address, address, uint256, uint256, uint256[], bytes)
                );

            recipient = recipientAddress;
            inputToken = srcToken;
            inputAmount = amount;

            uint256 pool = pools[pools.length - 1];
            outputToken = (pool & _REVERSE_MASK == 0)
                ? UniswapV3Pool(address(uint160(pool))).token1()
                : UniswapV3Pool(address(uint160(pool))).token0();
        } else if (funcSigHash == IAggregationRouterV5.unoswapTo.selector) {
            (
                address payable recipientAddress,
                address srcToken,
                uint256 amount,
                ,
                uint256[] memory pools
            ) = abi.decode(
                    _getFuncParams(swapAction.call),
                    (address, address, uint256, uint256, uint256[])
                );

            recipient = recipientAddress;
            inputToken = srcToken;
            inputAmount = amount;

            uint256 pool = pools[pools.length - 1];
            outputToken = (pool & _REVERSE_MASK == 0)
                ? UniswapV3Pool(address(uint160(pool))).token1()
                : UniswapV3Pool(address(uint160(pool))).token0();
        } else if (funcSigHash == IAggregationRouterV5.unoswap.selector) {
            (address srcToken, uint256 amount, , uint256[] memory pools) = abi
                .decode(
                    _getFuncParams(swapAction.call),
                    (address, uint256, uint256, uint256[])
                );

            recipient = expectedRecipient;
            inputToken = srcToken;
            inputAmount = amount;

            uint256 pool = pools[pools.length - 1];
            outputToken = (pool & _REVERSE_MASK == 0)
                ? UniswapV3Pool(address(uint160(pool))).token1()
                : UniswapV3Pool(address(uint160(pool))).token0();
        } else {
            revert CalldataChecker__InvalidFuncSig();
        }

        if (recipient != expectedRecipient) {
            revert CalldataChecker__RecipientError();
        }

        if (inputToken != swapAction.inputToken) {
            revert CalldataChecker__InputTokenError();
        }

        if (inputAmount != swapAction.inputAmount) {
            revert CalldataChecker__InputAmountError();
        }

        if (outputToken != swapAction.outputToken) {
            revert CalldataChecker__OutputTokenError();
        }
    }
}
