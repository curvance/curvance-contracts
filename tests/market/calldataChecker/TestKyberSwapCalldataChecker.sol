// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { KyberSwapChecker } from "contracts/calldata-checker/swap-checker/KyberSwapChecker.sol";
import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { BaseSwapChecker } from "contracts/calldata-checker/swap-checker/BaseSwapChecker.sol";
import { SimpleZapper } from "contracts/plugins/market/SimpleZapper.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IMetaAggregationRouterV2 } from "contracts/interfaces/external/kyberswap/IMetaAggregationRouterV2.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

contract TestKyberSwapCalldataChecker is TestBaseMarketIsolated {
    uint256 constant FORK_BLOCK = 67860000;

    address public kyberSwapRouter =
        0x6131B5fae19EA4f9D964eAc0408E4408b66337b5;
    address public kyberSwapExecutor =
        0x63242A4Ea82847b20E506b63B0e2e2eFF0CC6cB0;
    address public constant WMON_ADDRESS =
        0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;

    BorrowableCToken public borrowableCUSDC_MONAD;
    BorrowableCToken public borrowableCWMON;

    KyberSwapChecker public checker;

    SwapperLib.Swap public swapAction;
    address public recipient;

    SimpleZapper public simpleZapper;

    receive() external payable {}

    fallback() external payable {}

    function setUp() public override {
        _fork("MON_NODE_URI_MONAD_ARCHIVE", FORK_BLOCK);

        _initMainConstantVariables();

        _deployCentralRegistry();
        _deployCVE();
        _deployRewardManager();
        _deployVeCVE();
        _deployGaugeManager();
        _deployMarketManager();
        _deployOracleManager();

        address[] memory kyberSwapExecutors = new address[](1);
        kyberSwapExecutors[0] = kyberSwapExecutor;

        checker = new KyberSwapChecker(
            kyberSwapRouter,
            kyberSwapExecutors,
            address(centralRegistry)
        );
        centralRegistry.setExternalCalldataChecker(
            kyberSwapRouter,
            address(checker)
        );

        simpleZapper = new SimpleZapper(
            ICentralRegistry(address(centralRegistry)),
            WMON_ADDRESS
        );

        borrowableCUSDC_MONAD = _deployBorrowableCToken(_USDC_ADDRESS);
        borrowableCWMON = _deployBorrowableCToken(WMON_ADDRESS);

        MockV3Aggregator chainlinkUSDC_USD = new MockV3Aggregator(8, 1e8);
        // real Chainlink feed on Monad mainnet
        address chainlinkWMON_USD = 0x54a1020D118B9BeF3F3A4ec8E24AeEc9DFdBe4c3;

        ChainlinkAdaptor chainlinkAdaptor = new ChainlinkAdaptor(
            ICentralRegistry(address(centralRegistry))
        );

        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));

        chainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            true,
            address(chainlinkUSDC_USD),
            0
        );
        chainlinkAdaptor.addAsset(WMON_ADDRESS, true, chainlinkWMON_USD, 0);

        oracleManager.addAssetPricingAdaptor(
            _USDC_ADDRESS,
            address(chainlinkAdaptor),
            100,
            50,
            100,
            50
        );
        oracleManager.addAssetPricingAdaptor(
            WMON_ADDRESS,
            address(chainlinkAdaptor),
            100,
            50,
            100,
            50
        );

        oracleManager.addCTokenSupport(address(borrowableCUSDC_MONAD));
        oracleManager.addCTokenSupport(address(borrowableCWMON));

        deal(_USDC_ADDRESS, address(this), 77777);
        IERC20(_USDC_ADDRESS).approve(
            address(borrowableCUSDC_MONAD),
            type(uint256).max
        );

        deal(WMON_ADDRESS, address(this), 77777);
        IERC20(WMON_ADDRESS).approve(
            address(borrowableCWMON),
            type(uint256).max
        );

        marketManagerIsolated.listTokens(
            address(borrowableCUSDC_MONAD),
            address(borrowableCWMON)
        );

        _setCTokenConfigBasic(
            address(borrowableCUSDC_MONAD),
            1_000_000e6,
            1_000_000e6
        );
        _setCTokenConfigBasic(
            address(borrowableCWMON),
            1_000_000e18,
            1_000_000e18
        );
    }

    function test_revert_constructor_unsupportedChain() public {
        address[] memory executors = new address[](1);
        executors[0] = kyberSwapExecutor;

        vm.chainId(1); // Ethereum mainnet, not Monad (143)
        vm.expectRevert(
            KyberSwapChecker.KyberSwapChecker__UnsupportedChain.selector
        );
        new KyberSwapChecker(
            kyberSwapRouter,
            executors,
            address(centralRegistry)
        );
    }

    function test_revert_wrongTarget() public {
        swapAction.target = address(0);

        vm.expectRevert(BaseSwapChecker.CalldataChecker__TargetError.selector);
        checker.checkCalldata(swapAction, recipient);
    }

    function test_revert_wrongSelector() public {
        recipient = address(this);
        bytes
            memory invalidCallData = hex"d7ada2f3000000000000000000000000760afe86e5de5fa0ee542fc7b7b713e1c542570100000000000000000000000000000000000000000000000014b292ba662a6b6d000000000000000000000000f817257fed379853cde0fa4f97ab987181b1e5ea00000000000000000000000000000000000000000000000000000000004c4b40000000000000000000000000c45f0add4981076928537490f8c0e24944288947000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000f39fd6e51aad88f6f4ce6ab8827279cfffb92266000000000000000000000000000000000000000000000000000000000000006400000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000140000000000000000000000000000000000000000000000000000000000000004e02f817257fed379853cde0fa4f97ab987181b1e5ea01ffff04cd5455b24f3622a1cfece944615ae5bc8f36ee18010000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000";
        recipient = address(simpleZapper);
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kyberSwapRouter;
        swapAction.call = invalidCallData;

        vm.expectRevert(
            BaseSwapChecker.CalldataChecker__InvalidFuncSig.selector
        );
        checker.checkCalldata(swapAction, address(simpleZapper));
    }

    function test_revert_inputTokenMismatch() public {
        recipient = address(this);
        swapAction.inputToken = address(0);
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kyberSwapRouter;
        swapAction.call = _buildKyberCalldata(
            _USDC_ADDRESS,
            WMON_ADDRESS,
            5e6,
            recipient
        );

        vm.expectRevert(
            BaseSwapChecker.CalldataChecker__InputTokenError.selector
        );
        checker.checkCalldata(swapAction, recipient);
    }

    function test_revert_inputAmountMismatch() public {
        recipient = address(this);
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 0;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kyberSwapRouter;
        swapAction.call = _buildKyberCalldata(
            _USDC_ADDRESS,
            WMON_ADDRESS,
            5e6,
            recipient
        );

        vm.expectRevert(
            BaseSwapChecker.CalldataChecker__InputAmountError.selector
        );
        checker.checkCalldata(swapAction, recipient);
    }

    function test_revert_outputTokenMismatch() public {
        recipient = address(this);
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = address(0);
        swapAction.target = kyberSwapRouter;
        swapAction.call = _buildKyberCalldata(
            _USDC_ADDRESS,
            WMON_ADDRESS,
            5e6,
            recipient
        );

        vm.expectRevert(
            BaseSwapChecker.CalldataChecker__OutputTokenError.selector
        );
        checker.checkCalldata(swapAction, recipient);
    }

    function test_basicSuccess() public {
        recipient = address(this);
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kyberSwapRouter;
        swapAction.call = _buildKyberCalldata(
            _USDC_ADDRESS,
            WMON_ADDRESS,
            5e6,
            address(this)
        );

        checker.checkCalldata(swapAction, recipient);
    }

    // --- Fee validation ---

    function test_feeConfig_exactBps() public {
        recipient = address(this);
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kyberSwapRouter;

        address daoAddress = centralRegistry.daoAddress();
        swapAction.call = _buildKyberCalldataWithFee(
            _USDC_ADDRESS,
            WMON_ADDRESS,
            5e6,
            recipient,
            daoAddress,
            4, // exactly FEE_BPS
            0x280 // REQUIRED_FLAGS
        );

        // Should not revert — DAO receiver with exact fee match.
        checker.checkCalldata(swapAction, recipient);
    }

    function test_revert_fee_noReceivers() public {
        recipient = address(this);
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kyberSwapRouter;
        swapAction.call = _buildKyberCalldataNoFee(
            _USDC_ADDRESS,
            WMON_ADDRESS,
            5e6,
            recipient
        );

        vm.expectRevert(
            KyberSwapChecker.KyberSwapChecker__InvalidFeeConfig.selector
        );
        checker.checkCalldata(swapAction, recipient);
    }

    function test_revert_fee_wrongReceiver() public {
        recipient = address(this);
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kyberSwapRouter;

        address nonDao = makeAddr("attacker");
        swapAction.call = _buildKyberCalldataWithFee(
            _USDC_ADDRESS,
            WMON_ADDRESS,
            5e6,
            recipient,
            nonDao,
            4,
            0x280 // REQUIRED_FLAGS
        );

        vm.expectRevert(
            KyberSwapChecker.KyberSwapChecker__InvalidFeeConfig.selector
        );
        checker.checkCalldata(swapAction, recipient);
    }

    function test_revert_fee_bpsTooHigh() public {
        recipient = address(this);
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kyberSwapRouter;

        address daoAddress = centralRegistry.daoAddress();
        swapAction.call = _buildKyberCalldataWithFee(
            _USDC_ADDRESS,
            WMON_ADDRESS,
            5e6,
            recipient,
            daoAddress,
            5, // 5 != FEE_BPS (4)
            0x280 // REQUIRED_FLAGS
        );

        vm.expectRevert(
            KyberSwapChecker.KyberSwapChecker__InvalidFeeConfig.selector
        );
        checker.checkCalldata(swapAction, recipient);
    }

    function test_revert_fee_bpsTooLow() public {
        recipient = address(this);
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kyberSwapRouter;

        address daoAddress = centralRegistry.daoAddress();
        swapAction.call = _buildKyberCalldataWithFee(
            _USDC_ADDRESS,
            WMON_ADDRESS,
            5e6,
            recipient,
            daoAddress,
            3, // 3 != FEE_BPS (4)
            0x280 // REQUIRED_FLAGS
        );

        vm.expectRevert(
            KyberSwapChecker.KyberSwapChecker__InvalidFeeConfig.selector
        );
        checker.checkCalldata(swapAction, recipient);
    }

    function test_revert_fee_zeroBps() public {
        recipient = address(this);
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kyberSwapRouter;

        address daoAddress = centralRegistry.daoAddress();
        swapAction.call = _buildKyberCalldataWithFee(
            _USDC_ADDRESS,
            WMON_ADDRESS,
            5e6,
            recipient,
            daoAddress,
            0,
            0x280 // REQUIRED_FLAGS
        );

        vm.expectRevert(
            KyberSwapChecker.KyberSwapChecker__InvalidFeeConfig.selector
        );
        checker.checkCalldata(swapAction, recipient);
    }

    function test_revert_fee_multipleReceivers() public {
        recipient = address(this);
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kyberSwapRouter;

        address daoAddress = centralRegistry.daoAddress();

        IMetaAggregationRouterV2.SwapDescriptionV2 memory desc;
        desc.srcToken = IERC20(_USDC_ADDRESS);
        desc.dstToken = IERC20(WMON_ADDRESS);
        desc.dstReceiver = recipient;
        desc.amount = 5e6;
        desc.minReturnAmount = 1;
        desc.feeReceivers = new address[](2);
        desc.feeReceivers[0] = daoAddress;
        desc.feeReceivers[1] = daoAddress;
        desc.feeAmounts = new uint256[](2);
        desc.feeAmounts[0] = 2;
        desc.feeAmounts[1] = 2;

        IMetaAggregationRouterV2.SwapExecutionParams memory exec;
        exec.callTarget = kyberSwapExecutor;
        exec.approveTarget = address(0);
        exec.targetData = hex"01";
        exec.desc = desc;

        swapAction.call = abi.encodeWithSelector(
            IMetaAggregationRouterV2.swap.selector,
            exec
        );

        vm.expectRevert(
            KyberSwapChecker.KyberSwapChecker__InvalidFeeConfig.selector
        );
        checker.checkCalldata(swapAction, recipient);
    }

    function test_revert_fee_amountsLengthMismatch() public {
        recipient = address(this);
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kyberSwapRouter;

        address daoAddress = centralRegistry.daoAddress();

        IMetaAggregationRouterV2.SwapDescriptionV2 memory desc;
        desc.srcToken = IERC20(_USDC_ADDRESS);
        desc.dstToken = IERC20(WMON_ADDRESS);
        desc.dstReceiver = recipient;
        desc.amount = 5e6;
        desc.minReturnAmount = 1;
        desc.feeReceivers = new address[](1);
        desc.feeReceivers[0] = daoAddress;
        // feeAmounts intentionally left empty (length 0, mismatched)

        IMetaAggregationRouterV2.SwapExecutionParams memory exec;
        exec.callTarget = kyberSwapExecutor;
        exec.approveTarget = address(0);
        exec.targetData = hex"01";
        exec.desc = desc;

        swapAction.call = abi.encodeWithSelector(
            IMetaAggregationRouterV2.swap.selector,
            exec
        );

        vm.expectRevert(
            KyberSwapChecker.KyberSwapChecker__InvalidFeeConfig.selector
        );
        checker.checkCalldata(swapAction, recipient);
    }

    function test_revert_fee_receiversZero_amountsOne() public {
        recipient = address(this);
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kyberSwapRouter;

        IMetaAggregationRouterV2.SwapDescriptionV2 memory desc;
        desc.srcToken = IERC20(_USDC_ADDRESS);
        desc.dstToken = IERC20(WMON_ADDRESS);
        desc.dstReceiver = recipient;
        desc.amount = 5e6;
        desc.minReturnAmount = 1;
        // feeReceivers intentionally left empty (length 0)
        desc.feeAmounts = new uint256[](1);
        desc.feeAmounts[0] = 4;

        IMetaAggregationRouterV2.SwapExecutionParams memory exec;
        exec.callTarget = kyberSwapExecutor;
        exec.approveTarget = address(0);
        exec.targetData = hex"01";
        exec.desc = desc;

        swapAction.call = abi.encodeWithSelector(
            IMetaAggregationRouterV2.swap.selector,
            exec
        );

        vm.expectRevert(
            KyberSwapChecker.KyberSwapChecker__InvalidFeeConfig.selector
        );
        checker.checkCalldata(swapAction, recipient);
    }

    function test_revert_fee_receiversOne_amountsTwo() public {
        recipient = address(this);
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kyberSwapRouter;

        address daoAddress = centralRegistry.daoAddress();

        IMetaAggregationRouterV2.SwapDescriptionV2 memory desc;
        desc.srcToken = IERC20(_USDC_ADDRESS);
        desc.dstToken = IERC20(WMON_ADDRESS);
        desc.dstReceiver = recipient;
        desc.amount = 5e6;
        desc.minReturnAmount = 1;
        desc.feeReceivers = new address[](1);
        desc.feeReceivers[0] = daoAddress;
        desc.feeAmounts = new uint256[](2); // mismatched: 1 receiver, 2 amounts
        desc.feeAmounts[0] = 2;
        desc.feeAmounts[1] = 2;

        IMetaAggregationRouterV2.SwapExecutionParams memory exec;
        exec.callTarget = kyberSwapExecutor;
        exec.approveTarget = address(0);
        exec.targetData = hex"01";
        exec.desc = desc;

        swapAction.call = abi.encodeWithSelector(
            IMetaAggregationRouterV2.swap.selector,
            exec
        );

        vm.expectRevert(
            KyberSwapChecker.KyberSwapChecker__InvalidFeeConfig.selector
        );
        checker.checkCalldata(swapAction, recipient);
    }

    // --- Recipient & executor ---

    function test_recipientZero_resolvesToMsgSender() public {
        // Kyber interprets dstReceiver == address(0) as msg.sender.
        recipient = address(this);
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kyberSwapRouter;

        IMetaAggregationRouterV2.SwapDescriptionV2 memory desc;
        desc.srcToken = IERC20(_USDC_ADDRESS);
        desc.dstToken = IERC20(WMON_ADDRESS);
        desc.dstReceiver = address(0);
        desc.amount = 5e6;
        desc.minReturnAmount = 1;
        desc.feeReceivers = new address[](1);
        desc.feeReceivers[0] = centralRegistry.daoAddress();
        desc.feeAmounts = new uint256[](1);
        desc.feeAmounts[0] = 4;
        desc.flags = 0x280; // REQUIRED_FLAGS
        desc.srcReceivers = new address[](1);
        desc.srcReceivers[0] = kyberSwapExecutor;
        desc.srcAmounts = new uint256[](1);
        desc.srcAmounts[0] = 5e6;

        IMetaAggregationRouterV2.SwapExecutionParams memory exec;
        exec.callTarget = kyberSwapExecutor;
        exec.approveTarget = address(0);
        exec.targetData = hex"01";
        exec.desc = desc;

        swapAction.call = abi.encodeWithSelector(
            IMetaAggregationRouterV2.swap.selector,
            exec
        );

        // checker should normalize dstReceiver==0 to msg.sender
        checker.checkCalldata(swapAction, recipient);
    }

    function test_revert_recipientZero_mismatch() public {
        address expectedRecipient = makeAddr("expectedRecipient");

        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kyberSwapRouter;

        IMetaAggregationRouterV2.SwapDescriptionV2 memory desc;
        desc.srcToken = IERC20(_USDC_ADDRESS);
        desc.dstToken = IERC20(WMON_ADDRESS);
        desc.dstReceiver = address(0);
        desc.amount = 5e6;
        desc.minReturnAmount = 1;

        IMetaAggregationRouterV2.SwapExecutionParams memory exec;
        exec.callTarget = kyberSwapExecutor;
        exec.approveTarget = address(0);
        exec.targetData = hex"01";
        exec.desc = desc;

        swapAction.call = abi.encodeWithSelector(
            IMetaAggregationRouterV2.swap.selector,
            exec
        );

        vm.expectRevert(
            BaseSwapChecker.CalldataChecker__RecipientError.selector
        );
        checker.checkCalldata(swapAction, expectedRecipient);
    }

    function test_recipientZero_matchesMsgSender() public {
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kyberSwapRouter;

        IMetaAggregationRouterV2.SwapDescriptionV2 memory desc;
        desc.srcToken = IERC20(_USDC_ADDRESS);
        desc.dstToken = IERC20(WMON_ADDRESS);
        desc.dstReceiver = address(0); // zero address defaults to msg.sender
        desc.amount = 5e6;
        desc.minReturnAmount = 1;
        desc.feeReceivers = new address[](1);
        desc.feeReceivers[0] = centralRegistry.daoAddress();
        desc.feeAmounts = new uint256[](1);
        desc.feeAmounts[0] = 4;
        desc.flags = 0x280; // REQUIRED_FLAGS
        desc.srcReceivers = new address[](1);
        desc.srcReceivers[0] = kyberSwapExecutor;
        desc.srcAmounts = new uint256[](1);
        desc.srcAmounts[0] = 5e6;

        IMetaAggregationRouterV2.SwapExecutionParams memory exec;
        exec.callTarget = kyberSwapExecutor;
        exec.approveTarget = address(0);
        exec.targetData = hex"01";
        exec.desc = desc;

        // Will not revert, dstReceiver is 0 so it will default to msg.sender
        swapAction.call = abi.encodeWithSelector(
            IMetaAggregationRouterV2.swap.selector,
            exec
        );

        // Use address(this) who is the msg.sender
        checker.checkCalldata(swapAction, address(this));
    }

    function test_executorApproval_addRemove() public {
        address newExecutor = makeAddr("newExecutor");

        recipient = address(this);
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kyberSwapRouter;

        IMetaAggregationRouterV2.SwapDescriptionV2 memory desc;
        desc.srcToken = IERC20(_USDC_ADDRESS);
        desc.dstToken = IERC20(WMON_ADDRESS);
        desc.dstReceiver = recipient;
        desc.amount = 5e6;
        desc.minReturnAmount = 1;
        desc.feeReceivers = new address[](1);
        desc.feeReceivers[0] = centralRegistry.daoAddress();
        desc.feeAmounts = new uint256[](1);
        desc.feeAmounts[0] = 4;
        desc.flags = 0x280; // REQUIRED_FLAGS
        desc.srcReceivers = new address[](1);
        desc.srcReceivers[0] = newExecutor;
        desc.srcAmounts = new uint256[](1);
        desc.srcAmounts[0] = 5e6;

        IMetaAggregationRouterV2.SwapExecutionParams memory exec;
        exec.callTarget = newExecutor;
        exec.approveTarget = address(0);
        exec.targetData = hex"01";
        exec.desc = desc;

        swapAction.call = abi.encodeWithSelector(
            IMetaAggregationRouterV2.swap.selector,
            exec
        );

        vm.expectRevert(BaseSwapChecker.CalldataChecker__TargetError.selector);
        checker.checkCalldata(swapAction, recipient);

        address nonDao = makeAddr("nonDao");
        vm.prank(nonDao);
        vm.expectRevert(
            KyberSwapChecker.KyberSwapChecker__Unauthorized.selector
        );
        checker.setExecutorApproval(newExecutor, true);

        checker.setExecutorApproval(newExecutor, true);
        checker.checkCalldata(swapAction, recipient);

        checker.setExecutorApproval(newExecutor, false);
        vm.expectRevert(BaseSwapChecker.CalldataChecker__TargetError.selector);
        checker.checkCalldata(swapAction, recipient);
    }

    function test_executorApproval_multipleExecutors() public {
        address otherExecutor = makeAddr("otherExecutor"); // second executor
        address[] memory multipleExecutors = new address[](2);
        multipleExecutors[0] = kyberSwapExecutor;
        multipleExecutors[1] = otherExecutor;
        KyberSwapChecker multiChecker = new KyberSwapChecker(
            kyberSwapRouter,
            multipleExecutors,
            address(centralRegistry)
        );

        assertEq(multiChecker.isApprovedExecutor(kyberSwapExecutor), true);
        assertEq(multiChecker.isApprovedExecutor(otherExecutor), true);

        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kyberSwapRouter;

        IMetaAggregationRouterV2.SwapDescriptionV2 memory desc;
        desc.srcToken = IERC20(_USDC_ADDRESS);
        desc.dstToken = IERC20(WMON_ADDRESS);
        desc.dstReceiver = address(0);
        desc.amount = 5e6;
        desc.minReturnAmount = 1;
        desc.feeReceivers = new address[](1);
        desc.feeReceivers[0] = centralRegistry.daoAddress();
        desc.feeAmounts = new uint256[](1);
        desc.feeAmounts[0] = 4;
        desc.flags = 0x280; // REQUIRED_FLAGS
        desc.srcReceivers = new address[](1);
        desc.srcReceivers[0] = kyberSwapExecutor;
        desc.srcAmounts = new uint256[](1);
        desc.srcAmounts[0] = 5e6;

        IMetaAggregationRouterV2.SwapExecutionParams memory exec;
        exec.callTarget = kyberSwapExecutor;
        exec.approveTarget = address(0);
        exec.targetData = hex"01";
        exec.desc = desc;

        swapAction.call = abi.encodeWithSelector(
            IMetaAggregationRouterV2.swap.selector,
            exec
        );

        multiChecker.checkCalldata(swapAction, address(this));

        multiChecker.setExecutorApproval(otherExecutor, false);
        assertEq(multiChecker.isApprovedExecutor(otherExecutor), false);

        exec.callTarget = otherExecutor;
        swapAction.call = abi.encodeWithSelector(
            IMetaAggregationRouterV2.swap.selector,
            exec
        );

        vm.expectRevert(BaseSwapChecker.CalldataChecker__TargetError.selector);
        multiChecker.checkCalldata(swapAction, address(this));
    }

    function test_revert_emptyTargetData() public {
        recipient = address(this);
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kyberSwapRouter;

        IMetaAggregationRouterV2.SwapDescriptionV2 memory desc;
        desc.srcToken = IERC20(_USDC_ADDRESS);
        desc.dstToken = IERC20(WMON_ADDRESS);
        desc.dstReceiver = recipient;
        desc.amount = 5e6;
        desc.minReturnAmount = 1;

        IMetaAggregationRouterV2.SwapExecutionParams memory exec;
        exec.callTarget = kyberSwapExecutor;
        exec.approveTarget = address(0);
        exec.targetData = ""; // empty path
        exec.desc = desc;

        swapAction.call = abi.encodeWithSelector(
            IMetaAggregationRouterV2.swap.selector,
            exec
        );

        vm.expectRevert(
            KyberSwapChecker.KyberSwapChecker__InvalidTargetData.selector
        );
        checker.checkCalldata(swapAction, recipient);
    }

    function test_revert_flags_requiresExtraEth() public {
        recipient = address(this);
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kyberSwapRouter;

        IMetaAggregationRouterV2.SwapDescriptionV2 memory desc;
        desc.srcToken = IERC20(_USDC_ADDRESS);
        desc.dstToken = IERC20(WMON_ADDRESS);
        desc.dstReceiver = recipient;
        desc.amount = 5e6;
        desc.minReturnAmount = 1;
        desc.feeReceivers = new address[](1);
        desc.feeReceivers[0] = centralRegistry.daoAddress();
        desc.feeAmounts = new uint256[](1);
        desc.feeAmounts[0] = 4;

        IMetaAggregationRouterV2.SwapExecutionParams memory exec;
        exec.callTarget = kyberSwapExecutor;
        exec.approveTarget = address(0);
        exec.targetData = hex"01"; // non-empty dummy
        exec.desc = desc;
        exec.desc.flags = 0x02; // _REQUIRES_EXTRA_ETH

        swapAction.call = abi.encodeWithSelector(
            IMetaAggregationRouterV2.swap.selector,
            exec
        );

        vm.expectRevert(
            KyberSwapChecker.KyberSwapChecker__InvalidFlags.selector
        );
        checker.checkCalldata(swapAction, recipient);
    }

    // --- Flag validation (exact match: REQUIRED_FLAGS = 0x280) ---

    /// flags=0: router treats feeAmounts[0]=4 as 4 wei, not 4 BPS.
    function test_revert_flags_noFeeInBps() public {
        recipient = address(this);
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kyberSwapRouter;
        swapAction.call = _buildKyberCalldataWithFee(
            _USDC_ADDRESS,
            WMON_ADDRESS,
            5e6,
            recipient,
            centralRegistry.daoAddress(),
            4,
            0 // no _FEE_IN_BPS — the attack
        );

        vm.expectRevert(
            KyberSwapChecker.KyberSwapChecker__InvalidFlags.selector
        );
        checker.checkCalldata(swapAction, recipient);
    }

    function test_revert_flags_feeOnDst() public {
        recipient = address(this);
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kyberSwapRouter;
        swapAction.call = _buildKyberCalldataWithFee(
            _USDC_ADDRESS,
            WMON_ADDRESS,
            5e6,
            recipient,
            centralRegistry.daoAddress(),
            4,
            0x280 | 0x40 // REQUIRED_FLAGS | _FEE_ON_DST
        );

        vm.expectRevert(
            KyberSwapChecker.KyberSwapChecker__InvalidFlags.selector
        );
        checker.checkCalldata(swapAction, recipient);
    }

    function test_revert_flags_simpleSwap() public {
        recipient = address(this);
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kyberSwapRouter;
        swapAction.call = _buildKyberCalldataWithFee(
            _USDC_ADDRESS,
            WMON_ADDRESS,
            5e6,
            recipient,
            centralRegistry.daoAddress(),
            4,
            0x280 | 0x20 // REQUIRED_FLAGS | _SIMPLE_SWAP
        );

        vm.expectRevert(
            KyberSwapChecker.KyberSwapChecker__InvalidFlags.selector
        );
        checker.checkCalldata(swapAction, recipient);
    }

    function test_revert_flags_burnMsgSender() public {
        recipient = address(this);
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kyberSwapRouter;
        swapAction.call = _buildKyberCalldataWithFee(
            _USDC_ADDRESS,
            WMON_ADDRESS,
            5e6,
            recipient,
            centralRegistry.daoAddress(),
            4,
            0x280 | 0x08 // REQUIRED_FLAGS | _BURN_FROM_MSG_SENDER
        );

        vm.expectRevert(
            KyberSwapChecker.KyberSwapChecker__InvalidFlags.selector
        );
        checker.checkCalldata(swapAction, recipient);
    }

    function test_revert_flags_burnTxOrigin() public {
        recipient = address(this);
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kyberSwapRouter;
        swapAction.call = _buildKyberCalldataWithFee(
            _USDC_ADDRESS,
            WMON_ADDRESS,
            5e6,
            recipient,
            centralRegistry.daoAddress(),
            4,
            0x280 | 0x10 // REQUIRED_FLAGS | _BURN_FROM_TX_ORIGIN
        );

        vm.expectRevert(
            KyberSwapChecker.KyberSwapChecker__InvalidFlags.selector
        );
        checker.checkCalldata(swapAction, recipient);
    }

    function test_revert_flags_unknownBit() public {
        recipient = address(this);
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kyberSwapRouter;
        swapAction.call = _buildKyberCalldataWithFee(
            _USDC_ADDRESS,
            WMON_ADDRESS,
            5e6,
            recipient,
            centralRegistry.daoAddress(),
            4,
            0x280 | 0x100 // REQUIRED_FLAGS | unknown flag
        );

        vm.expectRevert(
            KyberSwapChecker.KyberSwapChecker__InvalidFlags.selector
        );
        checker.checkCalldata(swapAction, recipient);
    }

    function test_flags_exactMatch() public {
        recipient = address(this);
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kyberSwapRouter;
        swapAction.call = _buildKyberCalldataWithFee(
            _USDC_ADDRESS,
            WMON_ADDRESS,
            5e6,
            recipient,
            centralRegistry.daoAddress(),
            4,
            0x280 // exactly REQUIRED_FLAGS
        );

        checker.checkCalldata(swapAction, recipient);
    }

    function test_revert_nonEmptyPermit() public {
        recipient = address(this);
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kyberSwapRouter;

        IMetaAggregationRouterV2.SwapDescriptionV2 memory desc;
        desc.srcToken = IERC20(_USDC_ADDRESS);
        desc.dstToken = IERC20(WMON_ADDRESS);
        desc.dstReceiver = recipient;
        desc.amount = 5e6;
        desc.minReturnAmount = 1;
        desc.feeReceivers = new address[](1);
        desc.feeReceivers[0] = centralRegistry.daoAddress();
        desc.feeAmounts = new uint256[](1);
        desc.feeAmounts[0] = 4;
        desc.flags = 0x280; // REQUIRED_FLAGS — must pass flags to reach permit check
        desc.permit = hex"01";

        IMetaAggregationRouterV2.SwapExecutionParams memory exec;
        exec.callTarget = kyberSwapExecutor;
        exec.approveTarget = address(0);
        exec.targetData = hex"01";
        exec.desc = desc;

        swapAction.call = abi.encodeWithSelector(
            IMetaAggregationRouterV2.swap.selector,
            exec
        );

        vm.expectRevert(
            KyberSwapChecker.KyberSwapChecker__InvalidPermit.selector
        );
        checker.checkCalldata(swapAction, recipient);
    }

    function test_revert_unapprovedExecutor() public {
        address wrongExecutor = makeAddr("wrongExecutor");
        address[] memory wrongExecutors = new address[](1);
        wrongExecutors[0] = wrongExecutor;
        KyberSwapChecker badChecker = new KyberSwapChecker(
            kyberSwapRouter,
            wrongExecutors,
            address(centralRegistry)
        ); // wrong executor

        recipient = address(this);
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kyberSwapRouter;
        swapAction.call = _buildKyberCalldata(
            _USDC_ADDRESS,
            WMON_ADDRESS,
            5e6,
            recipient
        );

        vm.expectRevert(BaseSwapChecker.CalldataChecker__TargetError.selector);
        badChecker.checkCalldata(swapAction, recipient);
    }

    // --- Native address guards, recipient mismatch, srcReceiver loop ---

    function test_revert_recipientMismatch() public {
        recipient = address(this);
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kyberSwapRouter;

        address wrongRecipient = makeAddr("wrongRecipient");

        IMetaAggregationRouterV2.SwapDescriptionV2 memory desc;
        desc.srcToken = IERC20(_USDC_ADDRESS);
        desc.dstToken = IERC20(WMON_ADDRESS);
        desc.dstReceiver = wrongRecipient; // non-zero, doesn't match recipient
        desc.amount = 5e6;
        desc.minReturnAmount = 1;
        desc.flags = 0x280;
        desc.feeReceivers = new address[](1);
        desc.feeReceivers[0] = centralRegistry.daoAddress();
        desc.feeAmounts = new uint256[](1);
        desc.feeAmounts[0] = 4;
        desc.srcReceivers = new address[](1);
        desc.srcReceivers[0] = kyberSwapExecutor;
        desc.srcAmounts = new uint256[](1);
        desc.srcAmounts[0] = 5e6;

        IMetaAggregationRouterV2.SwapExecutionParams memory exec;
        exec.callTarget = kyberSwapExecutor;
        exec.approveTarget = address(0);
        exec.targetData = hex"01";
        exec.desc = desc;

        swapAction.call = abi.encodeWithSelector(
            IMetaAggregationRouterV2.swap.selector,
            exec
        );

        vm.expectRevert(
            BaseSwapChecker.CalldataChecker__RecipientError.selector
        );
        checker.checkCalldata(swapAction, recipient);
    }

    function test_revert_inputTokenNativeZero() public {
        recipient = address(this);
        swapAction.inputToken = address(0);
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kyberSwapRouter;
        swapAction.call = _buildKyberCalldataWithFee(
            address(0),
            WMON_ADDRESS,
            5e6,
            recipient,
            centralRegistry.daoAddress(),
            4,
            0x280
        );

        vm.expectRevert(
            KyberSwapChecker
                .KyberSwapChecker__InvalidNativeTokenAddress
                .selector
        );
        checker.checkCalldata(swapAction, recipient);
    }

    function test_revert_outputTokenNativeZero() public {
        recipient = address(this);
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = address(0);
        swapAction.target = kyberSwapRouter;
        swapAction.call = _buildKyberCalldataWithFee(
            _USDC_ADDRESS,
            address(0),
            5e6,
            recipient,
            centralRegistry.daoAddress(),
            4,
            0x280
        );

        vm.expectRevert(
            KyberSwapChecker
                .KyberSwapChecker__InvalidNativeTokenAddress
                .selector
        );
        checker.checkCalldata(swapAction, recipient);
    }

    function test_revert_src_zeroAtIndex0_multiElement() public {
        recipient = address(this);
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kyberSwapRouter;

        IMetaAggregationRouterV2.SwapDescriptionV2 memory desc;
        desc.srcToken = IERC20(_USDC_ADDRESS);
        desc.dstToken = IERC20(WMON_ADDRESS);
        desc.dstReceiver = recipient;
        desc.amount = 5e6;
        desc.minReturnAmount = 1;
        desc.flags = 0x280;
        desc.feeReceivers = new address[](1);
        desc.feeReceivers[0] = centralRegistry.daoAddress();
        desc.feeAmounts = new uint256[](1);
        desc.feeAmounts[0] = 4;
        desc.srcReceivers = new address[](2);
        desc.srcReceivers[0] = address(0); // burn address at index 0
        desc.srcReceivers[1] = kyberSwapExecutor; // valid
        desc.srcAmounts = new uint256[](2);
        desc.srcAmounts[0] = 3e6;
        desc.srcAmounts[1] = 2e6;

        IMetaAggregationRouterV2.SwapExecutionParams memory exec;
        exec.callTarget = kyberSwapExecutor;
        exec.approveTarget = address(0);
        exec.targetData = hex"01";
        exec.desc = desc;

        swapAction.call = abi.encodeWithSelector(
            IMetaAggregationRouterV2.swap.selector,
            exec
        );

        vm.expectRevert(
            KyberSwapChecker.KyberSwapChecker__InvalidSrcConfig.selector
        );
        checker.checkCalldata(swapAction, recipient);
    }

    function test_revert_src_zeroAtIndex1() public {
        recipient = address(this);
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kyberSwapRouter;

        IMetaAggregationRouterV2.SwapDescriptionV2 memory desc;
        desc.srcToken = IERC20(_USDC_ADDRESS);
        desc.dstToken = IERC20(WMON_ADDRESS);
        desc.dstReceiver = recipient;
        desc.amount = 5e6;
        desc.minReturnAmount = 1;
        desc.flags = 0x280;
        desc.feeReceivers = new address[](1);
        desc.feeReceivers[0] = centralRegistry.daoAddress();
        desc.feeAmounts = new uint256[](1);
        desc.feeAmounts[0] = 4;
        desc.srcReceivers = new address[](2);
        desc.srcReceivers[0] = kyberSwapExecutor; // valid
        desc.srcReceivers[1] = address(0); // burn address — loop must catch
        desc.srcAmounts = new uint256[](2);
        desc.srcAmounts[0] = 3e6;
        desc.srcAmounts[1] = 2e6;

        IMetaAggregationRouterV2.SwapExecutionParams memory exec;
        exec.callTarget = kyberSwapExecutor;
        exec.approveTarget = address(0);
        exec.targetData = hex"01";
        exec.desc = desc;

        swapAction.call = abi.encodeWithSelector(
            IMetaAggregationRouterV2.swap.selector,
            exec
        );

        vm.expectRevert(
            KyberSwapChecker.KyberSwapChecker__InvalidSrcConfig.selector
        );
        checker.checkCalldata(swapAction, recipient);
    }

    function test_src_multipleValid() public {
        recipient = address(this);
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kyberSwapRouter;

        address pool1 = makeAddr("pool1");
        address pool2 = makeAddr("pool2");

        IMetaAggregationRouterV2.SwapDescriptionV2 memory desc;
        desc.srcToken = IERC20(_USDC_ADDRESS);
        desc.dstToken = IERC20(WMON_ADDRESS);
        desc.dstReceiver = recipient;
        desc.amount = 5e6;
        desc.minReturnAmount = 1;
        desc.flags = 0x280;
        desc.feeReceivers = new address[](1);
        desc.feeReceivers[0] = centralRegistry.daoAddress();
        desc.feeAmounts = new uint256[](1);
        desc.feeAmounts[0] = 4;
        desc.srcReceivers = new address[](2);
        desc.srcReceivers[0] = pool1;
        desc.srcReceivers[1] = pool2;
        desc.srcAmounts = new uint256[](2);
        desc.srcAmounts[0] = 3e6;
        desc.srcAmounts[1] = 2e6;

        IMetaAggregationRouterV2.SwapExecutionParams memory exec;
        exec.callTarget = kyberSwapExecutor;
        exec.approveTarget = address(0);
        exec.targetData = hex"01";
        exec.desc = desc;

        swapAction.call = abi.encodeWithSelector(
            IMetaAggregationRouterV2.swap.selector,
            exec
        );

        checker.checkCalldata(swapAction, recipient);
    }

    function test_returnsMinOutAmount() public {
        recipient = address(this);
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kyberSwapRouter;

        IMetaAggregationRouterV2.SwapDescriptionV2 memory desc;
        desc.srcToken = IERC20(_USDC_ADDRESS);
        desc.dstToken = IERC20(WMON_ADDRESS);
        desc.dstReceiver = recipient;
        desc.amount = 5e6;
        desc.minReturnAmount = 123456789;
        desc.flags = 0x280;
        desc.feeReceivers = new address[](1);
        desc.feeReceivers[0] = centralRegistry.daoAddress();
        desc.feeAmounts = new uint256[](1);
        desc.feeAmounts[0] = 4;
        desc.srcReceivers = new address[](1);
        desc.srcReceivers[0] = kyberSwapExecutor;
        desc.srcAmounts = new uint256[](1);
        desc.srcAmounts[0] = 5e6;

        IMetaAggregationRouterV2.SwapExecutionParams memory exec;
        exec.callTarget = kyberSwapExecutor;
        exec.approveTarget = address(0);
        exec.targetData = hex"01";
        exec.desc = desc;

        swapAction.call = abi.encodeWithSelector(
            IMetaAggregationRouterV2.swap.selector,
            exec
        );

        uint256 minOut = checker.checkCalldata(swapAction, recipient);
        assertEq(minOut, 123456789);
    }

    // --- API-sourced fail cases (real KyberSwap API calldata, hardcoded) ---

    /// @dev Calldata from KyberSwap API at block ~67926499 with
    ///      feeReceiver=0x...dEaD instead of the DAO address.
    function test_revert_api_wrongFeeReceiver() public {
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kyberSwapRouter;
        swapAction
            .call = hex"e21fd0e9000000000000000000000000000000000000000000000000000000000000002000000000000000000000000063242a4ea82847b20e506b63b0e2e2eff0cc6cb0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000005c000000000000000000000000000000000000000000000000000000000000008400000000000000000000000000000000000000000000000000000000000000500000000000000000000000000004c4370000000000000000000000000004c4370000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000e000000000000000000000000000000000000000000000000000000000000000416265f5d9d1398ddeb5d0071f62991ee44920958a4074fc9423f843835a3f2e30264f33e87d9a2c4b5e060743e4ee7a4551bf7924f50a45448eeac0671b85e84a1b0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000004000000000000000000000000007fa9385be102ac3eac297483dd6233d62b3e149600000000000000000000000000000000000000000000000000000000000001400000000000000000000000000000000000000000000000000000000000000180000000000000000000000000004873440000000000000000000000000050139c000000000000000000000000004c43700000000000000007d741458ad63c40000000000000000000000000000000000000838c26708c210000000f42400000000000000000000000000000004f82e73edb06d29ff62c91ec8f5ff06571bdeb2900000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000069dd652d00000000000000000000000000000000000000000000000000000000000003e0000000000000000000000000000000000000000000000000000000000000000161f598cd000000000000000029443467522688c0d201d27e37a32f56c83d107b0000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000001c0000000000000000000000000754704bc059f8c67012fed69bc8a327a5aafb60380000000000000000000000000000004000000000000000000000000004c437000000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000004c43706efd106f0000000000000001c28883c9da855e34a75d002bddb4c823dfda2807000000000000000000000000000000000000000000000000000000000000008000000000000000000000000063242a4ea82847b20e506b63b0e2e2eff0cc6cb000000000000000000000000000000000000000000000000000000000000000400000000000000000000000004538053fc57d72eb70c6f822a3275531760bc7fd000000000000000000000000ff53611968f1e5ca45cfca7918447e7f5776f6d40000000000000000000000003bd359c1119da7da1d913d1c4d2b7c461115433a8000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000754704bc059f8c67012fed69bc8a327a5aafb6030000000000000000000000003bd359c1119da7da1d913d1c4d2b7c461115433a000000000000000000000000000000000000000000000000000000000000016000000000000000000000000000000000000000000000000000000000000001a000000000000000000000000000000000000000000000000000000000000001e000000000000000000000000000000000000000000000000000000000000002200000000000000000000000007fa9385be102ac3eac297483dd6233d62b3e149600000000000000000000000000000000000000000000000000000000004c4b40000000000000000000000000000000000000000000000007c32eb2ed49da5e1400000000000000000000000000000000000000000000000000000000000002800000000000000000000000000000000000000000000000000000000000000260000000000000000000000000000000000000000000000000000000000000000100000000000000000000000063242a4ea82847b20e506b63b0e2e2eff0cc6cb0000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000004c43700000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000dead00000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000b97b22536f75726365223a2243757276616e636550726f746f636f6c222c22416d6f756e74496e555344223a22342e393934343131222c22416d6f756e744f7574555344223a22342e393932303239222c22416d6f756e744f7574223a22313434363337393633353730323039363336333532222c22526f7574654944223a22646237376436643975686c46767053483a3930323066376132673346506e4a5a57222c2254696d657374616d70223a313737363131353833377d00000000000000";

        vm.expectRevert(
            KyberSwapChecker.KyberSwapChecker__InvalidFeeConfig.selector
        );
        checker.checkCalldata(swapAction, address(this));
    }

    /// @dev Calldata from KyberSwap API at block ~67926499 with
    ///      feeBps=10 instead of the required 4.
    function test_revert_api_feeBpsTooHigh() public {
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kyberSwapRouter;
        swapAction
            .call = hex"e21fd0e9000000000000000000000000000000000000000000000000000000000000002000000000000000000000000063242a4ea82847b20e506b63b0e2e2eff0cc6cb0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000008800000000000000000000000000000000000000000000000000000000000000540000000000000000000000000004c37b8000000000000000000000000004c37b8000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000e00000000000000000000000000000000000000000000000000000000000000041ed3bc26fd2eba8abf4ca19deecbdccfe220c7f4f2f04c56c98585e4df65834fa50278c421172ba938f745e32081283dba43dca2983059e945090ad1544b5eb761c0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000004400000000000000000000000007fa9385be102ac3eac297483dd6233d62b3e1496000000000000000000000000000000000000000000000000000000000000014000000000000000000000000000000000000000000000000000000000000001a0000000000000000000000000004868220000000000000000000000000050074e000000000000000000000000004c37b80000000000000007d129b10e9681800000000000000000000000000000000000008325f1075cb70000000f42400000000000000000000000000000004f82e73edb06d29ff62c91ec8f5ff06571bdeb2900000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000069dd67600000000000000000000000000000000000000000000000000000000000000420000000000000000000000000000000000000000000000000000000000000000261f598cd000000000000000029443467522688c0d201d27e37a32f56c83d107b2164c94f000000000000000029443467522688c0d201d27e37a32f56c83d107b0000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000001e0000000000000000000000000754704bc059f8c67012fed69bc8a327a5aafb60380000000000000000000000000000004000000000000000000000000004c37b800000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000004c37b8a357fd2d0000000000000001fe25d210dfe5cdff81917aa7067bac446ecac27c000000000000000000000000000000000000000000000000000000000000008000000000000000000000000063242a4ea82847b20e506b63b0e2e2eff0cc6cb00000000000000000000000000000000000000000000000000000000000000060000000000000000000000000fa32f9ec28787d1f9c5ba5c39e54e59984fef3f000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000147efb7defd39b49af7dacf914c0000000000000000000000003bd359c1119da7da1d913d1c4d2b7c461115433a8000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000754704bc059f8c67012fed69bc8a327a5aafb6030000000000000000000000003bd359c1119da7da1d913d1c4d2b7c461115433a000000000000000000000000000000000000000000000000000000000000016000000000000000000000000000000000000000000000000000000000000001a000000000000000000000000000000000000000000000000000000000000001e000000000000000000000000000000000000000000000000000000000000002200000000000000000000000007fa9385be102ac3eac297483dd6233d62b3e149600000000000000000000000000000000000000000000000000000000004c4b40000000000000000000000000000000000000000000000007bd26b6f766ebb99900000000000000000000000000000000000000000000000000000000000002800000000000000000000000000000000000000000000000000000000000000260000000000000000000000000000000000000000000000000000000000000000100000000000000000000000063242a4ea82847b20e506b63b0e2e2eff0cc6cb0000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000004c37b800000000000000000000000000000000000000000000000000000000000000010000000000000000000000007fa9385be102ac3eac297483dd6233d62b3e14960000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000b97b22536f75726365223a2243757276616e636550726f746f636f6c222c22416d6f756e74496e555344223a22342e393833393239222c22416d6f756e744f7574555344223a22342e393932303333222c22416d6f756e744f7574223a22313434313938393830383230313531363634363430222c22526f7574654944223a226239633730616631714c354b4b4a4d483a39313064373565336e6b31444c4b596c222c2254696d657374616d70223a313737363131363430317d00000000000000";

        vm.expectRevert(
            KyberSwapChecker.KyberSwapChecker__InvalidFeeConfig.selector
        );
        checker.checkCalldata(swapAction, address(this));
    }

    /// @dev Calldata from KyberSwap API at block ~67926499 with
    ///      no fee params at all (feeReceiver omitted).
    function test_revert_api_noFee() public {
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kyberSwapRouter;
        swapAction
            .call = hex"e21fd0e9000000000000000000000000000000000000000000000000000000000000002000000000000000000000000063242a4ea82847b20e506b63b0e2e2eff0cc6cb0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000009200000000000000000000000000000000000000000000000000000000000000b600000000000000000000000000000000000000000000000000000000000000860000000000000000000000000004c4b40000000000000000000000000004c4b40000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000e00000000000000000000000000000000000000000000000000000000000000041492df14071f60b8a576b7d4b66f65df332a78188477d8ed2794efa400b558d225bbacad19ac80a71b36c6f0e54e420dfde044838aa4171adf26114ea6fa655d71b0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000007600000000000000000000000007fa9385be102ac3eac297483dd6233d62b3e1496000000000000000000000000000000000000000000000000000000000000014000000000000000000000000000000000000000000000000000000000000001a000000000000000000000000000487ab000000000000000000000000000501bd0000000000000000000000000004c4b400000000000000007cf789518309f4000000000000000000000000000000000000083098ea963e60000000f42400000000000000000000000000000004f82e73edb06d29ff62c91ec8f5ff06571bdeb2900000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000069dd67be0000000000000000000000000000000000000000000000000000000000000740000000000000000000000000000000000000000000000000000000000000000261f598cd000000000000000029443467522688c0d201d27e37a32f56c83d107b91dd7346000000000000000029443467522688c0d201d27e37a32f56c83d107b0000000000000000000000000000000000000000000000000000000000000003000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000003c00000000000000000000000000000000000000000000000000000000000000500000000000000000000000000754704bc059f8c67012fed69bc8a327a5aafb60380000000000000000000000000000005000000000000000000000000004c4b4000000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000004c4b40736e774d0000000000000001d1877a31a73c7cb31c02b9e7d7c336531562b21e000000000000000000000000000000000000000000000000000000000000008000000000000000000000000063242a4ea82847b20e506b63b0e2e2eff0cc6cb00000000000000000000000000000000000000000000000000000000000000220000000000000000000000000188d586ddcf52439676ca21a244753fa19f9ea8e0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000020000000000000000000000000754704bc059f8c67012fed69bc8a327a5aafb60300000000000000000000000000000000000000000000000000000000004c4b40000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001f3000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000c00000000000000000000000000000000000000000000003429ffc2104685d16c70000000000000000000000000000000000000000000000000000000000000000000000000000000000000000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee8000000000000000000083098ea963e60000000000000007cf789518309f4000000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000007cf789518309f400000000000000000000000000200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003bd359c1119da7da1d913d1c4d2b7c461115433a8000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000754704bc059f8c67012fed69bc8a327a5aafb6030000000000000000000000003bd359c1119da7da1d913d1c4d2b7c461115433a000000000000000000000000000000000000000000000000000000000000016000000000000000000000000000000000000000000000000000000000000001a000000000000000000000000000000000000000000000000000000000000001e000000000000000000000000000000000000000000000000000000000000002000000000000000000000000007fa9385be102ac3eac297483dd6233d62b3e149600000000000000000000000000000000000000000000000000000000004c4b40000000000000000000000000000000000000000000000007bb79efc377d0db8500000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000220000000000000000000000000000000000000000000000000000000000000000100000000000000000000000063242a4ea82847b20e506b63b0e2e2eff0cc6cb0000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000004c4b4000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000b97b22536f75726365223a2243757276616e636550726f746f636f6c222c22416d6f756e74496e555344223a22342e393838333632222c22416d6f756e744f7574555344223a22342e393838313531222c22416d6f756e744f7574223a22313434303737303731343130313530373139343838222c22526f7574654944223a2239333465316137304e4146433834516f3a6662663363396139475a5643425a6c74222c2254696d657374616d70223a313737363131363439357d00000000000000";

        vm.expectRevert(
            KyberSwapChecker.KyberSwapChecker__InvalidFeeConfig.selector
        );
        checker.checkCalldata(swapAction, address(this));
    }

    /// @dev Calldata from KyberSwap API at block ~67926499 with
    ///      chargeFeeBy=currency_out. Sets _FEE_ON_DST flag (0x40),
    ///      making flags 0x2C0 instead of required 0x280.
    function test_revert_api_feeOnOutput() public {
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kyberSwapRouter;
        swapAction
            .call = hex"e21fd0e9000000000000000000000000000000000000000000000000000000000000002000000000000000000000000063242a4ea82847b20e506b63b0e2e2eff0cc6cb0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000009200000000000000000000000000000000000000000000000000000000000000ba00000000000000000000000000000000000000000000000000000000000000860000000000000000000000000004c4b40000000000000000000000000004c4b40000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000e0000000000000000000000000000000000000000000000000000000000000004173a9bf0f614739651f79621b38b48b481347e4d3fc9980eb134d6d01dbddab56002ed16249424a06f6193f06090360e8a797ed3889eb114a3edf6fb5284813c71b0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000007600000000000000000000000006131b5fae19ea4f9d964eac0408e4408b66337b5000000000000000000000000000000000000000000000000000000000000014000000000000000000000000000000000000000000000000000000000000001a000000000000000000000000000487ab000000000000000000000000000501bd0000000000000000000000000004c4b400000000000000007cd3dee6f152c4000000000000000000000000000000000000082e428b9ee590000000f42400000000000000000000000000000004f82e73edb06d29ff62c91ec8f5ff06571bdeb2900000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000069dd68150000000000000000000000000000000000000000000000000000000000000740000000000000000000000000000000000000000000000000000000000000000261f598cd000000000000000029443467522688c0d201d27e37a32f56c83d107b91dd7346000000000000000029443467522688c0d201d27e37a32f56c83d107b0000000000000000000000000000000000000000000000000000000000000003000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000003c00000000000000000000000000000000000000000000000000000000000000500000000000000000000000000754704bc059f8c67012fed69bc8a327a5aafb60380000000000000000000000000000005000000000000000000000000004c4b4000000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000004c4b40736e774d0000000000000001d1877a31a73c7cb31c02b9e7d7c336531562b21e000000000000000000000000000000000000000000000000000000000000008000000000000000000000000063242a4ea82847b20e506b63b0e2e2eff0cc6cb00000000000000000000000000000000000000000000000000000000000000220000000000000000000000000188d586ddcf52439676ca21a244753fa19f9ea8e0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000020000000000000000000000000754704bc059f8c67012fed69bc8a327a5aafb60300000000000000000000000000000000000000000000000000000000004c4b40000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001f3000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000c00000000000000000000000000000000000000000000003429ffc2104685d16c70000000000000000000000000000000000000000000000000000000000000000000000000000000000000000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee8000000000000000000082e428b9ee590000000000000007cd3dee6f152c4000000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000007cd3dee6f152c400000000000000000000000000200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003bd359c1119da7da1d913d1c4d2b7c461115433a8000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000754704bc059f8c67012fed69bc8a327a5aafb6030000000000000000000000003bd359c1119da7da1d913d1c4d2b7c461115433a000000000000000000000000000000000000000000000000000000000000016000000000000000000000000000000000000000000000000000000000000001a000000000000000000000000000000000000000000000000000000000000001e000000000000000000000000000000000000000000000000000000000000002200000000000000000000000007fa9385be102ac3eac297483dd6233d62b3e149600000000000000000000000000000000000000000000000000000000004c4b40000000000000000000000000000000000000000000000007b87a850936a107e300000000000000000000000000000000000000000000000000000000000002c00000000000000000000000000000000000000000000000000000000000000260000000000000000000000000000000000000000000000000000000000000000100000000000000000000000063242a4ea82847b20e506b63b0e2e2eff0cc6cb0000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000004c4b4000000000000000000000000000000000000000000000000000000000000000010000000000000000000000007fa9385be102ac3eac297483dd6233d62b3e149600000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000b97b22536f75726365223a2243757276616e636550726f746f636f6c222c22416d6f756e74496e555344223a22342e393831393135222c22416d6f756e744f7574555344223a22342e393832353036222c22416d6f756e744f7574223a22313433383538383830383439323134313636303830222c22526f7574654944223a22636464323836303359785244727063463a343636656338353043486c4274356f6d222c2254696d657374616d70223a313737363131363538317d00000000000000";

        vm.expectRevert(
            KyberSwapChecker.KyberSwapChecker__InvalidFlags.selector
        );
        checker.checkCalldata(swapAction, address(this));
    }

    /// @dev Calldata from KyberSwap API at block ~67926499 with
    ///      isInBps=false. The _FEE_IN_BPS flag (0x80) is missing,
    ///      making flags 0x200 instead of required 0x280.
    ///      NOTE: With isInBps=false the API treats feeAmount=4 as 4 wei
    ///      (not 4 BPS). The fee deduction appears in srcAmounts, not
    ///      desc.amount, so desc.amount remains 5e6.
    function test_revert_api_isInBpsFalse() public {
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kyberSwapRouter;
        swapAction
            .call = hex"e21fd0e9000000000000000000000000000000000000000000000000000000000000002000000000000000000000000063242a4ea82847b20e506b63b0e2e2eff0cc6cb0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a00000000000000000000000000000000000000000000000000000000000000b000000000000000000000000000000000000000000000000000000000000000d800000000000000000000000000000000000000000000000000000000000000a40000000000000000000000000004c4b3c000000000000000000000000004c4b3c000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000e00000000000000000000000000000000000000000000000000000000000000041515588c3e162e5c7ff54ff5b65cda0b9a9608969cb7d97b4abb153c631f6d96041b0d26ac25fdf256bb4b97a13a8965868f943ac080c19843a39e5dede5a038a1b0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000009400000000000000000000000007fa9385be102ac3eac297483dd6233d62b3e1496000000000000000000000000000000000000000000000000000000000000014000000000000000000000000000000000000000000000000000000000000001c000000000000000000000000000487aac00000000000000000000000000501bcb000000000000000000000000004c4b3c0000000000000007c8cad164c59d8000000000000000000000000000000000000082998192f7460000000f42400000000000000000000000000000004f82e73edb06d29ff62c91ec8f5ff06571bdeb2900000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000069dd687d0000000000000000000000000000000000000000000000000000000000000920000000000000000000000000000000000000000000000000000000000000000361f598cd000000000000000029443467522688c0d201d27e37a32f56c83d107b2164c94f000000000000000029443467522688c0d201d27e37a32f56c83d107b91dd7346000000000000000029443467522688c0d201d27e37a32f56c83d107b000000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000220000000000000000000000000000000000000000000000000000000000000058000000000000000000000000000000000000000000000000000000000000006c0000000000000000000000000754704bc059f8c67012fed69bc8a327a5aafb60380000000000000000000000000000004000000000000000000000000004c4b3c00000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000004c4b3ca357fd2d0000000000000001fe25d210dfe5cdff81917aa7067bac446ecac27c000000000000000000000000000000000000000000000000000000000000008000000000000000000000000063242a4ea82847b20e506b63b0e2e2eff0cc6cb000000000000000000000000000000000000000000000000000000000000000600000000000000000000000002d82ac42334b394a9a8d8f097d61dc1c6b065fd8000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000045f4796d25f930000000000000000000000000555e30da8f98308edb960aa94c0db47230d2b9c8000000000000000000000000000000100000000000000000000000000001ab50000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000001ab5736e774d0000000000000002d1877a31a73c7cb31c02b9e7d7c336531562b21e000000000000000000000000000000000000000000000000000000000000008000000000000000000000000063242a4ea82847b20e506b63b0e2e2eff0cc6cb00000000000000000000000000000000000000000000000000000000000000220000000000000000000000000188d586ddcf52439676ca21a244753fa19f9ea8e00000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000200000000000000000000000000555e30da8f98308edb960aa94c0db47230d2b9c0000000000000000000000000000000000000000000000000000000000001ab5000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001f40000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000c0000000000000000000000000fffd8963efd1fc6a506488495d951d5263988d250000000000000000000000000000000000000000000000000000000000000000000000000000000000000000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee8000000000000000000082998192f7460000000000000007c8cad164c59d8000000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000007c8cad164c59d800000000000000000000000000300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003bd359c1119da7da1d913d1c4d2b7c461115433a8000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000754704bc059f8c67012fed69bc8a327a5aafb6030000000000000000000000003bd359c1119da7da1d913d1c4d2b7c461115433a000000000000000000000000000000000000000000000000000000000000016000000000000000000000000000000000000000000000000000000000000001a000000000000000000000000000000000000000000000000000000000000001e000000000000000000000000000000000000000000000000000000000000002200000000000000000000000007fa9385be102ac3eac297483dd6233d62b3e149600000000000000000000000000000000000000000000000000000000004c4b40000000000000000000000000000000000000000000000007b4dd450f48c2533300000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000260000000000000000000000000000000000000000000000000000000000000000100000000000000000000000063242a4ea82847b20e506b63b0e2e2eff0cc6cb0000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000004c4b3c00000000000000000000000000000000000000000000000000000000000000010000000000000000000000007fa9385be102ac3eac297483dd6233d62b3e149600000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000b97b22536f75726365223a2243757276616e636550726f746f636f6c222c22416d6f756e74496e555344223a22342e393833383334222c22416d6f756e744f7574555344223a22342e393733333934222c22416d6f756e744f7574223a22313433353935383135343939353930333639323830222c22526f7574654944223a223761376463626135356b6c435636587a3a3063653461616363686e70484a49354f222c2254696d657374616d70223a313737363131363638357d00000000000000";

        vm.expectRevert(
            KyberSwapChecker.KyberSwapChecker__InvalidFlags.selector
        );
        checker.checkCalldata(swapAction, address(this));
    }

    // --- Integration (calldata captured with feeAmount=4, isInBps=true,
    // chargeFeeBy=currency_in, feeReceiver=DAO at block ~67860000) ---

    function test_integration_zapperSwap() public {
        recipient = address(simpleZapper);
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kyberSwapRouter;
        swapAction
            .call = hex"e21fd0e9000000000000000000000000000000000000000000000000000000000000002000000000000000000000000063242a4ea82847b20e506b63b0e2e2eff0cc6cb0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000009200000000000000000000000000000000000000000000000000000000000000ba00000000000000000000000000000000000000000000000000000000000000860000000000000000000000000004c4370000000000000000000000000004c4370000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000e000000000000000000000000000000000000000000000000000000000000000410080ccb9fa6feca12636a0c079bb58d752ceaf11d6bb9aa377458eabd77136270711b54142b60aca95e0aeba258f09a42f68e603bb28d0dbe844977276d84a761b00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000076000000000000000000000000015cf58144ef33af1e14b5208015d11f9143e27b9000000000000000000000000000000000000000000000000000000000000014000000000000000000000000000000000000000000000000000000000000001a0000000000000000000000000004873440000000000000000000000000050139c000000000000000000000000004c43700000000000000007fcb8f952799a800000000000000000000000000000000000008600c08016a60000000f42400000000000000000000000000000004f82e73edb06d29ff62c91ec8f5ff06571bdeb29000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000000000740000000000000000000000000000000000000000000000000000000000000000261f598cd000000000000000029443467522688c0d201d27e37a32f56c83d107b91dd7346000000000000000029443467522688c0d201d27e37a32f56c83d107b0000000000000000000000000000000000000000000000000000000000000003000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000003c00000000000000000000000000000000000000000000000000000000000000500000000000000000000000000754704bc059f8c67012fed69bc8a327a5aafb60380000000000000000000000000000004000000000000000000000000004c437000000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000004c4370736e774d0000000000000001d1877a31a73c7cb31c02b9e7d7c336531562b21e000000000000000000000000000000000000000000000000000000000000008000000000000000000000000063242a4ea82847b20e506b63b0e2e2eff0cc6cb00000000000000000000000000000000000000000000000000000000000000220000000000000000000000000188d586ddcf52439676ca21a244753fa19f9ea8e0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000020000000000000000000000000754704bc059f8c67012fed69bc8a327a5aafb60300000000000000000000000000000000000000000000000000000000004c4370000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001f3000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000c000000000000000000000000000000000000000000000033560bba8611b4a6c4f0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee800000000000000000008600c08016a60000000000000007fcb8f952799a8000000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000007fcb8f952799a800000000000000000000000000200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003bd359c1119da7da1d913d1c4d2b7c461115433a8000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000754704bc059f8c67012fed69bc8a327a5aafb6030000000000000000000000003bd359c1119da7da1d913d1c4d2b7c461115433a000000000000000000000000000000000000000000000000000000000000016000000000000000000000000000000000000000000000000000000000000001a000000000000000000000000000000000000000000000000000000000000001e0000000000000000000000000000000000000000000000000000000000000022000000000000000000000000015cf58144ef33af1e14b5208015d11f9143e27b900000000000000000000000000000000000000000000000000000000004c4b40000000000000000000000000000000000000000000000007d3d3fe9362b1028f00000000000000000000000000000000000000000000000000000000000002800000000000000000000000000000000000000000000000000000000000000260000000000000000000000000000000000000000000000000000000000000000100000000000000000000000063242a4ea82847b20e506b63b0e2e2eff0cc6cb0000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000004c437000000000000000000000000000000000000000000000000000000000000000010000000000000000000000007fa9385be102ac3eac297483dd6233d62b3e149600000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000b87b22536f75726365223a2243757276616e636550726f746f636f6c222c22416d6f756e74496e555344223a22342e393838313733222c22416d6f756e744f7574555344223a22342e3938373439222c22416d6f756e744f7574223a22313437333337373837373431383632323634383332222c22526f7574654944223a22343164316432353669695644324a66343a3432356561376166714d6c4a306f6d52222c2254696d657374616d70223a313737363038393630387d0000000000000000";

        deal(_USDC_ADDRESS, address(this), 5e6);
        IERC20(_USDC_ADDRESS).approve(address(simpleZapper), 5e6);

        borrowableCWMON.setDelegateApproval(address(simpleZapper), true);

        uint256 cWMONBalanceBefore = borrowableCWMON.balanceOf(address(this));

        simpleZapper.swapAndDeposit(
            address(borrowableCWMON),
            true,
            swapAction,
            0,
            true,
            address(this)
        );

        assertGt(borrowableCWMON.balanceOf(address(this)), cWMONBalanceBefore);
    }

    // --- Defense-in-depth: approveTarget, srcReceivers, minReturn ---

    function test_revert_nonZeroApproveTarget() public {
        recipient = address(this);
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kyberSwapRouter;

        IMetaAggregationRouterV2.SwapDescriptionV2 memory desc;
        desc.srcToken = IERC20(_USDC_ADDRESS);
        desc.dstToken = IERC20(WMON_ADDRESS);
        desc.dstReceiver = recipient;
        desc.amount = 5e6;
        desc.minReturnAmount = 1;
        desc.flags = 0x280;
        desc.feeReceivers = new address[](1);
        desc.feeReceivers[0] = centralRegistry.daoAddress();
        desc.feeAmounts = new uint256[](1);
        desc.feeAmounts[0] = 4;
        desc.srcReceivers = new address[](1);
        desc.srcReceivers[0] = kyberSwapExecutor;
        desc.srcAmounts = new uint256[](1);
        desc.srcAmounts[0] = 5e6;

        IMetaAggregationRouterV2.SwapExecutionParams memory exec;
        exec.callTarget = kyberSwapExecutor;
        exec.approveTarget = makeAddr("nonZeroApproveTarget");
        exec.targetData = hex"01";
        exec.desc = desc;

        swapAction.call = abi.encodeWithSelector(
            IMetaAggregationRouterV2.swap.selector,
            exec
        );

        vm.expectRevert(
            KyberSwapChecker.KyberSwapChecker__InvalidApproveTarget.selector
        );
        checker.checkCalldata(swapAction, recipient);
    }

    function test_revert_src_noReceivers() public {
        recipient = address(this);
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kyberSwapRouter;

        IMetaAggregationRouterV2.SwapDescriptionV2 memory desc;
        desc.srcToken = IERC20(_USDC_ADDRESS);
        desc.dstToken = IERC20(WMON_ADDRESS);
        desc.dstReceiver = recipient;
        desc.amount = 5e6;
        desc.minReturnAmount = 1;
        desc.flags = 0x280;
        desc.feeReceivers = new address[](1);
        desc.feeReceivers[0] = centralRegistry.daoAddress();
        desc.feeAmounts = new uint256[](1);
        desc.feeAmounts[0] = 4;
        // srcReceivers intentionally left empty

        IMetaAggregationRouterV2.SwapExecutionParams memory exec;
        exec.callTarget = kyberSwapExecutor;
        exec.approveTarget = address(0);
        exec.targetData = hex"01";
        exec.desc = desc;

        swapAction.call = abi.encodeWithSelector(
            IMetaAggregationRouterV2.swap.selector,
            exec
        );

        vm.expectRevert(
            KyberSwapChecker.KyberSwapChecker__InvalidSrcConfig.selector
        );
        checker.checkCalldata(swapAction, recipient);
    }

    function test_revert_src_lengthMismatch() public {
        recipient = address(this);
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kyberSwapRouter;

        IMetaAggregationRouterV2.SwapDescriptionV2 memory desc;
        desc.srcToken = IERC20(_USDC_ADDRESS);
        desc.dstToken = IERC20(WMON_ADDRESS);
        desc.dstReceiver = recipient;
        desc.amount = 5e6;
        desc.minReturnAmount = 1;
        desc.flags = 0x280;
        desc.feeReceivers = new address[](1);
        desc.feeReceivers[0] = centralRegistry.daoAddress();
        desc.feeAmounts = new uint256[](1);
        desc.feeAmounts[0] = 4;
        desc.srcReceivers = new address[](2);
        desc.srcReceivers[0] = kyberSwapExecutor;
        desc.srcReceivers[1] = kyberSwapExecutor;
        desc.srcAmounts = new uint256[](1); // mismatch: 2 receivers, 1 amount
        desc.srcAmounts[0] = 5e6;

        IMetaAggregationRouterV2.SwapExecutionParams memory exec;
        exec.callTarget = kyberSwapExecutor;
        exec.approveTarget = address(0);
        exec.targetData = hex"01";
        exec.desc = desc;

        swapAction.call = abi.encodeWithSelector(
            IMetaAggregationRouterV2.swap.selector,
            exec
        );

        vm.expectRevert(
            KyberSwapChecker.KyberSwapChecker__InvalidSrcConfig.selector
        );
        checker.checkCalldata(swapAction, recipient);
    }

    function test_revert_src_zeroAddress() public {
        recipient = address(this);
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kyberSwapRouter;

        IMetaAggregationRouterV2.SwapDescriptionV2 memory desc;
        desc.srcToken = IERC20(_USDC_ADDRESS);
        desc.dstToken = IERC20(WMON_ADDRESS);
        desc.dstReceiver = recipient;
        desc.amount = 5e6;
        desc.minReturnAmount = 1;
        desc.flags = 0x280;
        desc.feeReceivers = new address[](1);
        desc.feeReceivers[0] = centralRegistry.daoAddress();
        desc.feeAmounts = new uint256[](1);
        desc.feeAmounts[0] = 4;
        desc.srcReceivers = new address[](1);
        desc.srcReceivers[0] = address(0); // burn address
        desc.srcAmounts = new uint256[](1);
        desc.srcAmounts[0] = 5e6;

        IMetaAggregationRouterV2.SwapExecutionParams memory exec;
        exec.callTarget = kyberSwapExecutor;
        exec.approveTarget = address(0);
        exec.targetData = hex"01";
        exec.desc = desc;

        swapAction.call = abi.encodeWithSelector(
            IMetaAggregationRouterV2.swap.selector,
            exec
        );

        vm.expectRevert(
            KyberSwapChecker.KyberSwapChecker__InvalidSrcConfig.selector
        );
        checker.checkCalldata(swapAction, recipient);
    }

    function test_revert_zeroMinReturn() public {
        recipient = address(this);
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kyberSwapRouter;

        IMetaAggregationRouterV2.SwapDescriptionV2 memory desc;
        desc.srcToken = IERC20(_USDC_ADDRESS);
        desc.dstToken = IERC20(WMON_ADDRESS);
        desc.dstReceiver = recipient;
        desc.amount = 5e6;
        desc.minReturnAmount = 0; // zero — invalid
        desc.flags = 0x280;
        desc.feeReceivers = new address[](1);
        desc.feeReceivers[0] = centralRegistry.daoAddress();
        desc.feeAmounts = new uint256[](1);
        desc.feeAmounts[0] = 4;
        desc.srcReceivers = new address[](1);
        desc.srcReceivers[0] = kyberSwapExecutor;
        desc.srcAmounts = new uint256[](1);
        desc.srcAmounts[0] = 5e6;

        IMetaAggregationRouterV2.SwapExecutionParams memory exec;
        exec.callTarget = kyberSwapExecutor;
        exec.approveTarget = address(0);
        exec.targetData = hex"01";
        exec.desc = desc;

        swapAction.call = abi.encodeWithSelector(
            IMetaAggregationRouterV2.swap.selector,
            exec
        );

        vm.expectRevert(
            BaseSwapChecker.CalldataChecker__InvalidMinOut.selector
        );
        checker.checkCalldata(swapAction, recipient);
    }

    // --- Helpers ---

    /// @dev Default calldata: DAO fee + correct flags.
    function _buildKyberCalldata(
        address tokenIn,
        address tokenOut,
        uint256 amount,
        address dstReceiver
    ) internal view returns (bytes memory) {
        return
            _buildKyberCalldataWithFee(
                tokenIn,
                tokenOut,
                amount,
                dstReceiver,
                centralRegistry.daoAddress(),
                4, // FEE_BPS
                0x280 // REQUIRED_FLAGS (_FEE_IN_BPS | executor v3)
            );
    }

    /// @dev No fee receivers. Flags still valid so fee-rejection tests don't trip the flags check.
    function _buildKyberCalldataNoFee(
        address tokenIn,
        address tokenOut,
        uint256 amount,
        address dstReceiver
    ) internal view returns (bytes memory) {
        IMetaAggregationRouterV2.SwapDescriptionV2 memory desc;
        desc.srcToken = IERC20(tokenIn);
        desc.dstToken = IERC20(tokenOut);
        desc.dstReceiver = dstReceiver;
        desc.amount = amount;
        desc.minReturnAmount = 1;
        desc.flags = 0x280; // REQUIRED_FLAGS

        IMetaAggregationRouterV2.SwapExecutionParams memory exec;
        exec.callTarget = kyberSwapExecutor;
        exec.approveTarget = address(0);
        exec.targetData = hex"01";
        exec.desc = desc;

        return
            abi.encodeWithSelector(
                IMetaAggregationRouterV2.swap.selector,
                exec
            );
    }

    /// @dev Configurable fee + flags. Includes valid srcReceivers.
    function _buildKyberCalldataWithFee(
        address tokenIn,
        address tokenOut,
        uint256 amount,
        address dstReceiver,
        address feeReceiver,
        uint256 feeAmount,
        uint256 flags
    ) internal view returns (bytes memory) {
        IMetaAggregationRouterV2.SwapDescriptionV2 memory desc;
        desc.srcToken = IERC20(tokenIn);
        desc.dstToken = IERC20(tokenOut);
        desc.dstReceiver = dstReceiver;
        desc.amount = amount;
        desc.minReturnAmount = 1;
        desc.flags = flags;
        desc.feeReceivers = new address[](1);
        desc.feeReceivers[0] = feeReceiver;
        desc.feeAmounts = new uint256[](1);
        desc.feeAmounts[0] = feeAmount;
        desc.srcReceivers = new address[](1);
        desc.srcReceivers[0] = kyberSwapExecutor;
        desc.srcAmounts = new uint256[](1);
        desc.srcAmounts[0] = amount;

        IMetaAggregationRouterV2.SwapExecutionParams memory exec;
        exec.callTarget = kyberSwapExecutor;
        exec.approveTarget = address(0);
        exec.targetData = hex"01";
        exec.desc = desc;

        return
            abi.encodeWithSelector(
                IMetaAggregationRouterV2.swap.selector,
                exec
            );
    }
}
