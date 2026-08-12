// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {
    OdosV3CalldataChecker
} from "contracts/calldata-checker/swap-checker/OdosV3CalldataChecker.sol";
import {
    BaseSwapChecker
} from "contracts/calldata-checker/swap-checker/BaseSwapChecker.sol";
import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";
import {IERC20} from "contracts/interfaces/IERC20.sol";
import {
    IOdosRouterV3
} from "contracts/interfaces/external/odos/IOdosRouterV3.sol";
import {SwapperLib} from "contracts/libraries/SwapperLib.sol";
import {
    SafeTransferLib
} from "contracts/libraries/external/SafeTransferLib.sol";
import {MockERC20Token} from "contracts/mocks/MockERC20Token.sol";

contract OdosV3RegistryStub {
    mapping(address target => address checker) public externalCalldataChecker;
    address public oracleManager;

    constructor(address oracleManager_) {
        oracleManager = oracleManager_;
    }

    function setExternalCalldataChecker(address target, address checker)
        external
    {
        externalCalldataChecker[target] = checker;
    }
}

contract OdosV3OracleManagerStub {
    function getPrice(address, bool, bool)
        external
        pure
        returns (uint256 price, uint256 errorCode)
    {
        return (1e18, 0);
    }
}

contract OdosV3ReferralFeeRouterMock {
    using SafeTransferLib for address;

    uint256 internal constant FEE_DENOM = 1e18;

    function swap(
        IOdosRouterV3.swapTokenInfo memory tokenInfo,
        bytes calldata,
        address,
        IOdosRouterV3.swapReferralInfo memory referralInfo
    ) external payable returns (uint256 amountOut) {
        tokenInfo.inputToken
            .safeTransferFrom(msg.sender, address(this), tokenInfo.inputAmount);

        amountOut = tokenInfo.outputQuote;
        if (referralInfo.fee > 0) {
            uint256 splitBps = (referralInfo.code >> 32) & 65_535;
            if (splitBps == 0) splitBps = 8_000;

            tokenInfo.outputToken
                .safeTransfer(
                    referralInfo.feeRecipient,
                    amountOut * referralInfo.fee * splitBps
                        / (FEE_DENOM * 10_000)
                );
            amountOut = amountOut * (FEE_DENOM - referralInfo.fee) / FEE_DENOM;
        }

        require(amountOut >= tokenInfo.outputMin, "Slippage Limit Exceeded");
        tokenInfo.outputToken.safeTransfer(tokenInfo.outputReceiver, amountOut);
    }
}

contract OdosV3SwapperHarness {
    function execute(ICentralRegistry registry, SwapperLib.Swap memory action)
        external
        returns (uint256)
    {
        return SwapperLib._swapSafe(registry, action);
    }
}

contract OdosV3ReferralFeePoC is Test {
    uint256 internal constant INPUT_AMOUNT = 100e18;
    uint256 internal constant OUTPUT_QUOTE = 100e18;
    uint256 internal constant OUTPUT_MIN = 98e18;
    uint64 internal constant MAX_REFERRAL_FEE = 2e16;

    address internal attacker = makeAddr("referralFeeRecipient");
    address internal odosExecutor = makeAddr("odosExecutor");

    MockERC20Token internal inputToken;
    MockERC20Token internal outputToken;
    OdosV3OracleManagerStub internal oracleManager;
    OdosV3RegistryStub internal registry;
    OdosV3ReferralFeeRouterMock internal router;
    OdosV3CalldataChecker internal checker;
    OdosV3SwapperHarness internal swapper;

    function setUp() public {
        inputToken = new MockERC20Token();
        outputToken = new MockERC20Token();
        oracleManager = new OdosV3OracleManagerStub();
        registry = new OdosV3RegistryStub(address(oracleManager));
        router = new OdosV3ReferralFeeRouterMock();
        checker = new OdosV3CalldataChecker(
            address(router),
            odosExecutor,
            0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE
        );
        swapper = new OdosV3SwapperHarness();

        registry.setExternalCalldataChecker(address(router), address(checker));
        inputToken.mint(address(swapper), INPUT_AMOUNT);
        outputToken.mint(address(router), OUTPUT_QUOTE);
    }

    function test_PoC_codeZeroReferralFeeIsRejectedBeforeSwap() public {
        IOdosRouterV3.swapTokenInfo memory tokenInfo =
            IOdosRouterV3.swapTokenInfo({
                inputToken: address(inputToken),
                inputAmount: INPUT_AMOUNT,
                inputReceiver: odosExecutor,
                outputToken: address(outputToken),
                outputQuote: OUTPUT_QUOTE,
                outputMin: OUTPUT_MIN,
                outputReceiver: address(swapper)
            });
        IOdosRouterV3.swapReferralInfo memory referralInfo =
            IOdosRouterV3.swapReferralInfo({
                code: 0, fee: MAX_REFERRAL_FEE, feeRecipient: attacker
            });

        SwapperLib.Swap memory action = SwapperLib.Swap({
            inputToken: address(inputToken),
            inputAmount: INPUT_AMOUNT,
            outputToken: address(outputToken),
            target: address(router),
            slippage: MAX_REFERRAL_FEE,
            call: abi.encodeCall(
                IOdosRouterV3.swap,
                (tokenInfo, hex"01", odosExecutor, referralInfo)
            )
        });

        vm.expectRevert(
            BaseSwapChecker.CalldataChecker__ReferralError.selector
        );
        checker.checkCalldata(action, address(swapper));

        vm.expectRevert(
            BaseSwapChecker.CalldataChecker__ReferralError.selector
        );
        swapper.execute(ICentralRegistry(address(registry)), action);

        assertEq(
            inputToken.balanceOf(address(swapper)),
            INPUT_AMOUNT,
            "swapper input must remain untouched"
        );
        assertEq(
            outputToken.balanceOf(attacker),
            0,
            "referral recipient must receive nothing"
        );
        assertEq(
            outputToken.balanceOf(address(router)),
            OUTPUT_QUOTE,
            "router output balance must remain untouched"
        );
    }
}
