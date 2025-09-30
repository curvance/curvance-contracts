// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

interface IKuruFlowRouter {
    struct SwapIntent {
        address tokenUserBuys;
        uint256 minAmountUserBuys;
        address tokenUserSells;
        uint256 amountUserSells;
    }

    struct FeeCollection {
        address feeCollectorAddress; // Address to receive the main fee (API)
        uint256 feeBps; // Fee in basis points for the main collector
        address referrerAddress; // Address to receive the referrer fee (external apps)
        uint256 referrerFeeBps; // Referrer fee in basis points
        bool isInTokenFee; // true = take fee in input token (tokenUserSells), false = take fee in output token
            // (tokenUserBuys)
    }
    function executeRoute(
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 minAmountOut,
        bytes memory program
    ) external payable returns (uint256 amountOut);
}
