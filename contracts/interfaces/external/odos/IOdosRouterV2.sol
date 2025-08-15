// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

interface IOdosRouterV2 {
    struct swapTokenInfo {
        address inputToken;
        uint256 inputAmount;
        address inputReceiver;
        address outputToken;
        uint256 outputQuote;
        uint256 outputMin;
        address outputReceiver;
    }

    struct permit2Info {
        address contractAddress;
        uint256 nonce;
        uint256 deadline;
        bytes signature;
    }

    struct inputTokenInfo {
        address tokenAddress;
        uint256 amountIn;
        address receiver;
    }

    struct outputTokenInfo {
        address tokenAddress;
        uint256 relativeValue;
        address receiver;
    }

    function swapCompact() external payable returns (uint256);

    function swap(
        swapTokenInfo memory tokenInfo,
        bytes calldata pathDefinition,
        address executor,
        uint32 referralCode
    ) external payable returns (uint256 amountOut);

    function swapPermit2(
        permit2Info memory permit2,
        swapTokenInfo memory tokenInfo,
        bytes calldata pathDefinition,
        address executor,
        uint32 referralCode
    ) external returns (uint256 amountOut);

    function swapMultiCompact() external payable returns (uint256[] memory amountsOut);

    function swapMulti(
        inputTokenInfo[] memory inputs,
        outputTokenInfo[] memory outputs,
        uint256 valueOutMin,
        bytes calldata pathDefinition,
        address executor,
        uint32 referralCode
    ) external payable returns (uint256[] memory amountsOut);

    function swapMultiPermit2(
        permit2Info memory permit2,
        inputTokenInfo[] memory inputs,
        outputTokenInfo[] memory outputs,
        uint256 valueOutMin,
        bytes calldata pathDefinition,
        address executor,
        uint32 referralCode
    ) external payable returns (uint256[] memory amountsOut);

    
}