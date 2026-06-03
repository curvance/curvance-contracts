// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";

import { KyberSwapChecker } from "contracts/calldata-checker/swap-checker/KyberSwapChecker.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IMetaAggregationRouterV2 } from "contracts/interfaces/external/kyberswap/IMetaAggregationRouterV2.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";

contract KyberCheckerMiniRegistry {
    address public immutable daoAddress;

    constructor(address daoAddress_) {
        daoAddress = daoAddress_;
    }

    function hasDaoPermissions(address addressToCheck) external view returns (bool) {
        return addressToCheck == daoAddress;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0x01ffc9a7 ||
            interfaceId == type(ICentralRegistry).interfaceId;
    }
}

contract TestKyberSwapCheckerDeployment is Test {
    address internal constant KYBER_ROUTER =
        0x6131B5fae19EA4f9D964eAc0408E4408b66337b5;
    address internal constant KYBER_EXECUTOR =
        0x63242A4Ea82847b20E506b63B0e2e2eFF0CC6cB0;

    address internal dao = address(0xDA0);
    address internal inputToken = address(0x1001);
    address internal outputToken = address(0x2002);
    address internal recipient = address(0x3003);

    KyberCheckerMiniRegistry internal registry;
    KyberSwapChecker internal correctChecker;
    KyberSwapChecker internal scriptShapedChecker;

    function setUp() public {
        vm.chainId(143);

        registry = new KyberCheckerMiniRegistry(dao);

        address[] memory executors = new address[](1);
        executors[0] = KYBER_EXECUTOR;

        correctChecker = new KyberSwapChecker(
            KYBER_ROUTER,
            executors,
            address(registry)
        );

        // Matches the pre-fix DeployCalldataChecker.s.sol: the constructor
        // received cr.daoAddress() where KyberSwapChecker expects CentralRegistry.
        vm.expectRevert();
        scriptShapedChecker = new KyberSwapChecker(
            KYBER_ROUTER,
            executors,
            dao
        );
    }

    function test_kyberSwapChecker_rejectsDaoAddressAsRegistryForFeeValidation() public {
        SwapperLib.Swap memory swapAction = _swapAction();

        assertEq(
            correctChecker.checkCalldata(swapAction, recipient),
            1,
            "correct registry-backed checker accepts valid calldata"
        );

        vm.expectRevert();
        new KyberSwapChecker(KYBER_ROUTER, _executors(), dao);
    }

    function test_kyberSwapChecker_rejectsDaoAddressAsRegistryForExecutorAdmin() public {
        vm.prank(dao);
        correctChecker.setExecutorApproval(KYBER_EXECUTOR, false);
        assertFalse(correctChecker.isApprovedExecutor(KYBER_EXECUTOR));

        vm.expectRevert();
        new KyberSwapChecker(KYBER_ROUTER, _executors(), dao);
    }

    function test_kyberSwapChecker_rejectsZeroExecutorInConstructor() public {
        address[] memory executors = new address[](1);
        executors[0] = address(0);

        vm.expectRevert(
            KyberSwapChecker.KyberSwapChecker__InvalidExecutor.selector
        );
        new KyberSwapChecker(KYBER_ROUTER, executors, address(registry));
    }

    function test_kyberSwapChecker_rejectsZeroExecutorAdminUpdate() public {
        vm.prank(dao);
        vm.expectRevert(
            KyberSwapChecker.KyberSwapChecker__InvalidExecutor.selector
        );
        correctChecker.setExecutorApproval(address(0), true);

        vm.prank(dao);
        vm.expectRevert(
            KyberSwapChecker.KyberSwapChecker__InvalidExecutor.selector
        );
        correctChecker.setExecutorApproval(address(0), false);
    }

    function _swapAction() internal view returns (SwapperLib.Swap memory swapAction) {
        swapAction.target = KYBER_ROUTER;
        swapAction.inputToken = inputToken;
        swapAction.inputAmount = 1e18;
        swapAction.outputToken = outputToken;
        swapAction.call = _kyberCall();
    }

    function _executors() internal pure returns (address[] memory executors) {
        executors = new address[](1);
        executors[0] = KYBER_EXECUTOR;
    }

    function _kyberCall() internal view returns (bytes memory) {
        IMetaAggregationRouterV2.SwapDescriptionV2 memory desc;
        desc.srcToken = IERC20(inputToken);
        desc.dstToken = IERC20(outputToken);
        desc.dstReceiver = recipient;
        desc.amount = 1e18;
        desc.minReturnAmount = 1;
        desc.flags = 0x280;
        desc.feeReceivers = new address[](1);
        desc.feeReceivers[0] = dao;
        desc.feeAmounts = new uint256[](1);
        desc.feeAmounts[0] = 4;
        desc.srcReceivers = new address[](1);
        desc.srcReceivers[0] = KYBER_EXECUTOR;
        desc.srcAmounts = new uint256[](1);
        desc.srcAmounts[0] = 1e18 - ((1e18 * 4) / 10_000);

        IMetaAggregationRouterV2.SwapExecutionParams memory execution;
        execution.callTarget = KYBER_EXECUTOR;
        execution.approveTarget = address(0);
        execution.targetData = hex"01";
        execution.desc = desc;

        return abi.encodeWithSelector(IMetaAggregationRouterV2.swap.selector, execution);
    }
}
