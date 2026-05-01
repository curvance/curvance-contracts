// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";

import { BaseSwapChecker } from "contracts/calldata-checker/swap-checker/BaseSwapChecker.sol";
import { OogaBoogaCalldataChecker } from "contracts/calldata-checker/swap-checker/OogaBoogaCalldataChecker.sol";
import { IOBRouter } from "contracts/interfaces/external/ooga/IOBRouter.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";

contract TestOogaBoogaCalldataChecker is Test {
    address internal router = address(0x1111111254EEB25477B68fb85Ed929f73A960582);
    address internal inputToken = address(0x1001);
    address internal outputToken = address(0x2002);
    address internal recipient = address(0x3003);
    address internal executor = address(0x4004);

    OogaBoogaCalldataChecker internal checker;

    function setUp() public {
        checker = new OogaBoogaCalldataChecker(router);
    }

    function test_oogaBoogaChecker_rejectsPermit2Swaps() public {
        SwapperLib.Swap memory swapAction = _baseSwap();
        IOBRouter.permit2Info memory permit2 = IOBRouter.permit2Info({
            contractAddress: address(0x5005),
            nonce: 1,
            deadline: 0,
            signature: hex"01"
        });
        IOBRouter.swapTokenInfo memory tokenInfo = _tokenInfo();

        swapAction.call = abi.encodeWithSelector(
            IOBRouter.swapPermit2.selector,
            permit2,
            tokenInfo,
            bytes("path"),
            executor,
            uint32(0)
        );

        vm.expectRevert(BaseSwapChecker.CalldataChecker__InvalidFuncSig.selector);
        checker.checkCalldata(swapAction, recipient);
    }

    function test_oogaBoogaChecker_rejectsErc20PermitSwaps() public {
        SwapperLib.Swap memory swapAction = _baseSwap();
        IOBRouter.erc20PermitInfo memory permit = IOBRouter.erc20PermitInfo({
            value: 1e18,
            deadline: 0,
            v: 27,
            r: bytes32(uint256(1)),
            s: bytes32(uint256(2))
        });
        IOBRouter.swapTokenInfo memory tokenInfo = _tokenInfo();

        swapAction.call = abi.encodeWithSelector(
            IOBRouter.swapERC20Permit.selector,
            permit,
            tokenInfo,
            bytes("path"),
            executor,
            uint32(0)
        );

        vm.expectRevert(BaseSwapChecker.CalldataChecker__InvalidFuncSig.selector);
        checker.checkCalldata(swapAction, recipient);
    }

    function test_oogaBoogaChecker_acceptsPlainSwap() public {
        SwapperLib.Swap memory swapAction = _baseSwap();
        IOBRouter.swapTokenInfo memory tokenInfo = _tokenInfo();

        swapAction.call = abi.encodeWithSelector(
            IOBRouter.swap.selector,
            tokenInfo,
            bytes("path"),
            executor,
            uint32(0)
        );

        assertEq(
            checker.checkCalldata(swapAction, recipient),
            tokenInfo.outputMin,
            "checker preserves plain Ooga swap support"
        );
    }

    function _baseSwap() internal view returns (SwapperLib.Swap memory swapAction) {
        swapAction.target = router;
        swapAction.inputToken = inputToken;
        swapAction.inputAmount = 1e18;
        swapAction.outputToken = outputToken;
    }

    function _tokenInfo() internal view returns (IOBRouter.swapTokenInfo memory tokenInfo) {
        tokenInfo = IOBRouter.swapTokenInfo({
            inputToken: inputToken,
            inputAmount: 1e18,
            outputToken: outputToken,
            outputQuote: 2e18,
            outputMin: 19e17,
            outputReceiver: recipient
        });
    }
}
