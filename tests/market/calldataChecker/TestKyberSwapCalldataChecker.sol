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
    uint256 constant FORK_BLOCK = 59224721;

    address public kyberSwapRouter   = 0x6131B5fae19EA4f9D964eAc0408E4408b66337b5;
    address public kyberSwapExecutor = 0x63242A4Ea82847b20E506b63B0e2e2eFF0CC6cB0;
    address public constant WMON_ADDRESS = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;

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

        checker = new KyberSwapChecker(kyberSwapRouter, kyberSwapExecutors, address(centralRegistry));
        centralRegistry.setExternalCalldataChecker(kyberSwapRouter, address(checker));

        simpleZapper = new SimpleZapper(ICentralRegistry(address(centralRegistry)), WMON_ADDRESS);

        borrowableCUSDC_MONAD = _deployBorrowableCToken(_USDC_ADDRESS);
        borrowableCWMON = _deployBorrowableCToken(WMON_ADDRESS);

        MockV3Aggregator chainlinkUSDC_USD = new MockV3Aggregator(8, 1e8);
        // real Chainlink feed on Monad mainnet
        address chainlinkWMON_USD = 0x54a1020D118B9BeF3F3A4ec8E24AeEc9DFdBe4c3;

        ChainlinkAdaptor chainlinkAdaptor = new ChainlinkAdaptor(ICentralRegistry(address(centralRegistry)));

        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));

        chainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            true,
            address(chainlinkUSDC_USD),
            0
        );
        chainlinkAdaptor.addAsset(
            WMON_ADDRESS,
            true,
            chainlinkWMON_USD,
            0
        );

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
        IERC20(_USDC_ADDRESS).approve(address(borrowableCUSDC_MONAD), type(uint256).max);

        deal(WMON_ADDRESS, address(this), 77777);
        IERC20(WMON_ADDRESS).approve(address(borrowableCWMON), type(uint256).max);

        marketManagerIsolated.listTokens(address(borrowableCUSDC_MONAD), address(borrowableCWMON));

        _setCTokenConfigBasic(address(borrowableCUSDC_MONAD), 1_000_000e6, 1_000_000e6);
        _setCTokenConfigBasic(address(borrowableCWMON), 1_000_000e18, 1_000_000e18);
    }

    function test_revert_wrongTarget() public {
        swapAction.target = address(0);

        vm.expectRevert(BaseSwapChecker.CalldataChecker__TargetError.selector);
        checker.checkCalldata(swapAction, recipient);
    }

    function test_revert_wrongSelector() public {
        recipient = address(this);
        bytes memory invalidCallData = hex"d7ada2f3000000000000000000000000760afe86e5de5fa0ee542fc7b7b713e1c542570100000000000000000000000000000000000000000000000014b292ba662a6b6d000000000000000000000000f817257fed379853cde0fa4f97ab987181b1e5ea00000000000000000000000000000000000000000000000000000000004c4b40000000000000000000000000c45f0add4981076928537490f8c0e24944288947000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000f39fd6e51aad88f6f4ce6ab8827279cfffb92266000000000000000000000000000000000000000000000000000000000000006400000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000140000000000000000000000000000000000000000000000000000000000000004e02f817257fed379853cde0fa4f97ab987181b1e5ea01ffff04cd5455b24f3622a1cfece944615ae5bc8f36ee18010000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000";
        recipient = address(simpleZapper);
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kyberSwapRouter;
        swapAction.call = invalidCallData;

        vm.expectRevert(BaseSwapChecker.CalldataChecker__InvalidFuncSig.selector);
        checker.checkCalldata(swapAction, address(simpleZapper));
    }

    function test_revert_inputTokenMismatch() public {
        recipient = address(this);
        swapAction.inputToken = address(0);
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kyberSwapRouter;
        swapAction.call = _buildKyberCalldata(_USDC_ADDRESS, WMON_ADDRESS, 5e6, recipient);

        vm.expectRevert(BaseSwapChecker.CalldataChecker__InputTokenError.selector);
        checker.checkCalldata(swapAction, recipient);
    }

    function test_revert_inputAmountMismatch() public {
        recipient = address(this);
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 0;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kyberSwapRouter;
        swapAction.call = _buildKyberCalldata(_USDC_ADDRESS, WMON_ADDRESS, 5e6, recipient);

        vm.expectRevert(BaseSwapChecker.CalldataChecker__InputAmountError.selector);
        checker.checkCalldata(swapAction, recipient);
    }

    function test_revert_outputTokenMismatch() public {
        recipient = address(this);
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = address(0);
        swapAction.target = kyberSwapRouter;
        swapAction.call = _buildKyberCalldata(_USDC_ADDRESS, WMON_ADDRESS, 5e6, recipient);

        vm.expectRevert(BaseSwapChecker.CalldataChecker__OutputTokenError.selector);
        checker.checkCalldata(swapAction, recipient);
    }

    function test_basicSuccess() public {
        recipient = address(this);
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kyberSwapRouter;
        swapAction.call = _buildKyberCalldata(_USDC_ADDRESS, WMON_ADDRESS, 5e6, address(this));

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
            _USDC_ADDRESS, WMON_ADDRESS, 5e6, recipient,
            daoAddress, 4 // exactly FEE_BPS
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
        swapAction.call = _buildKyberCalldataNoFee(_USDC_ADDRESS, WMON_ADDRESS, 5e6, recipient);

        vm.expectRevert(KyberSwapChecker.KyberSwapChecker__InvalidFeeConfig.selector);
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
            _USDC_ADDRESS, WMON_ADDRESS, 5e6, recipient,
            nonDao, 4
        );

        vm.expectRevert(KyberSwapChecker.KyberSwapChecker__InvalidFeeConfig.selector);
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
            _USDC_ADDRESS, WMON_ADDRESS, 5e6, recipient,
            daoAddress, 5 // 5 != FEE_BPS (4)
        );

        vm.expectRevert(KyberSwapChecker.KyberSwapChecker__InvalidFeeConfig.selector);
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
            _USDC_ADDRESS, WMON_ADDRESS, 5e6, recipient,
            daoAddress, 3 // 3 != FEE_BPS (4)
        );

        vm.expectRevert(KyberSwapChecker.KyberSwapChecker__InvalidFeeConfig.selector);
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
            _USDC_ADDRESS, WMON_ADDRESS, 5e6, recipient,
            daoAddress, 0
        );

        vm.expectRevert(KyberSwapChecker.KyberSwapChecker__InvalidFeeConfig.selector);
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

        vm.expectRevert(KyberSwapChecker.KyberSwapChecker__InvalidFeeConfig.selector);
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

        vm.expectRevert(KyberSwapChecker.KyberSwapChecker__InvalidFeeConfig.selector);
        checker.checkCalldata(swapAction, recipient);
    }

    // --- Recipient & executor ---

    function test_recipientZero_resolvesToMsgSender()
        public
    {
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
        desc.flags = 0x80; // REQUIRED_FLAGS
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

    function test_revert_recipientZero_mismatch()
        public
    {
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

        vm.expectRevert(BaseSwapChecker.CalldataChecker__RecipientError.selector);
        checker.checkCalldata(swapAction, expectedRecipient);
    }

    function test_recipientZero_matchesMsgSender()
        public
    {
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
        desc.flags = 0x80; // REQUIRED_FLAGS
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

    function test_executorApproval_addRemove()
        public
    {
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
        desc.flags = 0x80; // REQUIRED_FLAGS
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
        vm.expectRevert(KyberSwapChecker.KyberSwapChecker__Unauthorized.selector);
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
        KyberSwapChecker multiChecker =
            new KyberSwapChecker(kyberSwapRouter, multipleExecutors, address(centralRegistry));

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
        desc.flags = 0x80; // REQUIRED_FLAGS
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

        vm.expectRevert(KyberSwapChecker.KyberSwapChecker__InvalidTargetData.selector);
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

        vm.expectRevert(KyberSwapChecker.KyberSwapChecker__InvalidFlags.selector);
        checker.checkCalldata(swapAction, recipient);
    }

    // --- Flag validation (exact match: REQUIRED_FLAGS = 0x80) ---

    /// flags=0: router treats feeAmounts[0]=4 as 4 wei, not 4 BPS.
    function test_revert_flags_noFeeInBps() public {
        recipient = address(this);
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kyberSwapRouter;
        swapAction.call = _buildKyberCalldataWithFee(
            _USDC_ADDRESS, WMON_ADDRESS, 5e6, recipient,
            centralRegistry.daoAddress(), 4,
            0 // no _FEE_IN_BPS — the attack
        );

        vm.expectRevert(KyberSwapChecker.KyberSwapChecker__InvalidFlags.selector);
        checker.checkCalldata(swapAction, recipient);
    }

    function test_revert_flags_feeOnDst() public {
        recipient = address(this);
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kyberSwapRouter;
        swapAction.call = _buildKyberCalldataWithFee(
            _USDC_ADDRESS, WMON_ADDRESS, 5e6, recipient,
            centralRegistry.daoAddress(), 4,
            0x80 | 0x40 // _FEE_IN_BPS | _FEE_ON_DST
        );

        vm.expectRevert(KyberSwapChecker.KyberSwapChecker__InvalidFlags.selector);
        checker.checkCalldata(swapAction, recipient);
    }

    function test_revert_flags_simpleSwap() public {
        recipient = address(this);
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kyberSwapRouter;
        swapAction.call = _buildKyberCalldataWithFee(
            _USDC_ADDRESS, WMON_ADDRESS, 5e6, recipient,
            centralRegistry.daoAddress(), 4,
            0x80 | 0x20 // _FEE_IN_BPS | _SIMPLE_SWAP
        );

        vm.expectRevert(KyberSwapChecker.KyberSwapChecker__InvalidFlags.selector);
        checker.checkCalldata(swapAction, recipient);
    }

    function test_revert_flags_burnMsgSender() public {
        recipient = address(this);
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kyberSwapRouter;
        swapAction.call = _buildKyberCalldataWithFee(
            _USDC_ADDRESS, WMON_ADDRESS, 5e6, recipient,
            centralRegistry.daoAddress(), 4,
            0x80 | 0x08 // _FEE_IN_BPS | _BURN_FROM_MSG_SENDER
        );

        vm.expectRevert(KyberSwapChecker.KyberSwapChecker__InvalidFlags.selector);
        checker.checkCalldata(swapAction, recipient);
    }

    function test_revert_flags_burnTxOrigin() public {
        recipient = address(this);
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kyberSwapRouter;
        swapAction.call = _buildKyberCalldataWithFee(
            _USDC_ADDRESS, WMON_ADDRESS, 5e6, recipient,
            centralRegistry.daoAddress(), 4,
            0x80 | 0x10 // _FEE_IN_BPS | _BURN_FROM_TX_ORIGIN
        );

        vm.expectRevert(KyberSwapChecker.KyberSwapChecker__InvalidFlags.selector);
        checker.checkCalldata(swapAction, recipient);
    }

    function test_revert_flags_unknownBit() public {
        recipient = address(this);
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kyberSwapRouter;
        swapAction.call = _buildKyberCalldataWithFee(
            _USDC_ADDRESS, WMON_ADDRESS, 5e6, recipient,
            centralRegistry.daoAddress(), 4,
            0x80 | 0x100 // _FEE_IN_BPS | unknown flag
        );

        vm.expectRevert(KyberSwapChecker.KyberSwapChecker__InvalidFlags.selector);
        checker.checkCalldata(swapAction, recipient);
    }

    function test_flags_exactMatch() public {
        recipient = address(this);
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kyberSwapRouter;
        swapAction.call = _buildKyberCalldataWithFee(
            _USDC_ADDRESS, WMON_ADDRESS, 5e6, recipient,
            centralRegistry.daoAddress(), 4,
            0x80 // exactly REQUIRED_FLAGS
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
        desc.flags = 0x80; // REQUIRED_FLAGS — must pass flags to reach permit check
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

        vm.expectRevert(KyberSwapChecker.KyberSwapChecker__InvalidPermit.selector);
        checker.checkCalldata(swapAction, recipient);
    }

    function test_revert_unapprovedExecutor() public {
        address wrongExecutor = makeAddr("wrongExecutor");
        address[] memory wrongExecutors = new address[](1);
        wrongExecutors[0] = wrongExecutor;
        KyberSwapChecker badChecker =
            new KyberSwapChecker(kyberSwapRouter, wrongExecutors, address(centralRegistry)); // wrong executor

        recipient = address(this);
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kyberSwapRouter;
        swapAction.call = _buildKyberCalldata(_USDC_ADDRESS, WMON_ADDRESS, 5e6, recipient);

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
        desc.flags = 0x80;
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

        vm.expectRevert(BaseSwapChecker.CalldataChecker__RecipientError.selector);
        checker.checkCalldata(swapAction, recipient);
    }

    function test_revert_inputTokenNativeZero() public {
        recipient = address(this);
        swapAction.inputToken = address(0);
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kyberSwapRouter;
        swapAction.call = _buildKyberCalldataWithFee(
            address(0), WMON_ADDRESS, 5e6, recipient,
            centralRegistry.daoAddress(), 4, 0x80
        );

        vm.expectRevert(KyberSwapChecker.KyberSwapChecker__InvalidNativeTokenAddress.selector);
        checker.checkCalldata(swapAction, recipient);
    }

    function test_revert_outputTokenNativeZero() public {
        recipient = address(this);
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = address(0);
        swapAction.target = kyberSwapRouter;
        swapAction.call = _buildKyberCalldataWithFee(
            _USDC_ADDRESS, address(0), 5e6, recipient,
            centralRegistry.daoAddress(), 4, 0x80
        );

        vm.expectRevert(KyberSwapChecker.KyberSwapChecker__InvalidNativeTokenAddress.selector);
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
        desc.flags = 0x80;
        desc.feeReceivers = new address[](1);
        desc.feeReceivers[0] = centralRegistry.daoAddress();
        desc.feeAmounts = new uint256[](1);
        desc.feeAmounts[0] = 4;
        desc.srcReceivers = new address[](2);
        desc.srcReceivers[0] = kyberSwapExecutor; // valid
        desc.srcReceivers[1] = address(0);        // burn address — loop must catch
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

        vm.expectRevert(KyberSwapChecker.KyberSwapChecker__InvalidSrcConfig.selector);
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
        desc.flags = 0x80;
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
        desc.flags = 0x80;
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

    // --- Integration (requires re-captured calldata with fees) ---

    // TODO: Re-capture with feeAmount=4, isInBps=true, chargeFeeBy=currency_in,
    // feeReceiver=DAO. Current calldata was captured without fees.
    function test_integration_zapperSwap() public {
        vm.skip(true);
        recipient = address(simpleZapper);
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kyberSwapRouter;
        swapAction.call = hex"e21fd0e9000000000000000000000000000000000000000000000000000000000000002000000000000000000000000063242a4ea82847b20e506b63b0e2e2eff0cc6cb0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a00000000000000000000000000000000000000000000000000000000000000b600000000000000000000000000000000000000000000000000000000000000da00000000000000000000000000000000000000000000000000000000000000aa0000000000000000000000000004c4b40000000000000000000000000004c4b40000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000e00000000000000000000000000000000000000000000000000000000000000041415fbaa07307905b70ccfa0482ae3a973204e7a6a35a7fb14732f225c716451f24a1aede29bc59da8cd74c4f8aeae1982a598a4e397d2011d172136b02e8479d1b0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000009a000000000000000000000000015cf58144ef33af1e14b5208015d11f9143e27b9000000000000000000000000000000000000000000000000000000000000014000000000000000000000000000000000000000000000000000000000000001a000000000000000000000000000487ab000000000000000000000000000501bd0000000000000000000000000004c4b40000000000000000c409ba916d41280000000000000000000000000000000000000cd8f8cfd7b640000000f42400000000000000000000000000000004f82e73edb06d29ff62c91ec8f5ff06571bdeb2900000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000069a8468e0000000000000000000000000000000000000000000000000000000000000980000000000000000000000000000000000000000000000000000000000000000261f598cd00000000000000002c93e1ebe3a3e3f53efe9efb15304ed37750face91dd734600000000000000002c93e1ebe3a3e3f53efe9efb15304ed37750face0000000000000000000000000000000000000000000000000000000000000003000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000005000000000000000000000000000000000000000000000000000000000000000740000000000000000000000000754704bc059f8c67012fed69bc8a327a5aafb60380000000000000000000000000000005000000000000000000000000004c4b4000000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000004c4b40736e774d0000000000000001d1877a31a73c7cb31c02b9e7d7c336531562b21e000000000000000000000000000000000000000000000000000000000000008000000000000000000000000063242a4ea82847b20e506b63b0e2e2eff0cc6cb00000000000000000000000000000000000000000000000000000000000000360000000000000000000000000188d586ddcf52439676ca21a244753fa19f9ea8e0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000020000000000000000000000000754704bc059f8c67012fed69bc8a327a5aafb60300000000000000000000000000000000000000000000000000000000004c4b4000000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000efe302beaa2b3e6e1b18d08d69a9012a000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000010000000000000000000000004445520306c9c70952bdfec28f3989f53d9f80c400000000000000000000000000000000000000000000000000000000000000c000000000000000000000000100000000000000010020c649300be3bb0e87ea76000000000000000000000000000000000000000000000000000000000000014000000000000000000000000000000000000000000000000000000000005b8d8000000000000000000000000000000000000000000000000100060425ff6e09c9000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000069a8429200000000000000000000000000000000000000000000000000000000000000c00000000000000000000000000000000000000000000000000000000000000041869dc5cc050357e831d22dbe8f0e62773b9d2ca36b20dab25dde4004f1d1b58764813acb7217245d363d8a7203e133a5e970f6017fa041288fd6e8707e9cabb91b0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000efe302beaa2b3e6e1b18d08d69a9012a80000000000000000000000000000005000000000000000000000000004c4d3800000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000004c4d388bc041a80000000000000002d1877a31a73c7cb31c02b9e7d7c336531562b21e000000000000000000000000000000000000000000000000000000000000008000000000000000000000000063242a4ea82847b20e506b63b0e2e2eff0cc6cb00000000000000000000000000000000000000000000000000000000000000100000000000000000000000000ed6a1a43d5d6ec164e6e236e4be3341102364d424000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000044a9b318f100000000000000000000000063242a4ea82847b20e506b63b0e2e2eff0cc6cb00000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000000000000000000003bd359c1119da7da1d913d1c4d2b7c461115433a8000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000754704bc059f8c67012fed69bc8a327a5aafb6030000000000000000000000003bd359c1119da7da1d913d1c4d2b7c461115433a000000000000000000000000000000000000000000000000000000000000016000000000000000000000000000000000000000000000000000000000000001a000000000000000000000000000000000000000000000000000000000000001e0000000000000000000000000000000000000000000000000000000000000020000000000000000000000000015cf58144ef33af1e14b5208015d11f9143e27b900000000000000000000000000000000000000000000000000000000004c4b4000000000000000000000000000000000000000000000000ba3c713d5afde600000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000220000000000000000000000000000000000000000000000000000000000000000100000000000000000000000063242a4ea82847b20e506b63b0e2e2eff0cc6cb0000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000004c4b4000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000b97b22536f75726365223a2243757276616e636550726f746f636f6c222c22416d6f756e74496e555344223a22352e313635383636222c22416d6f756e744f7574555344223a22342e393935383235222c22416d6f756e744f7574223a22323236303136343239343339383434353135383430222c22526f7574654944223a2236303866396331334a4c5647614c7a353a3863613437323165595835496d5a7948222c2254696d657374616d70223a313737323633343539307d00000000000000";

        deal(_USDC_ADDRESS, address(this), 5e6);
        IERC20(_USDC_ADDRESS).approve(address(simpleZapper), 5e6);

        borrowableCWMON.setDelegateApproval(address(simpleZapper), true);

        uint256 cWMONBalanceBefore = borrowableCWMON.balanceOf(address(this));

        simpleZapper.swapAndDeposit(address(borrowableCWMON), true, swapAction, 0, true, address(this));

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
        desc.flags = 0x80;
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

        vm.expectRevert(KyberSwapChecker.KyberSwapChecker__InvalidApproveTarget.selector);
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
        desc.flags = 0x80;
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

        vm.expectRevert(KyberSwapChecker.KyberSwapChecker__InvalidSrcConfig.selector);
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
        desc.flags = 0x80;
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

        vm.expectRevert(KyberSwapChecker.KyberSwapChecker__InvalidSrcConfig.selector);
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
        desc.flags = 0x80;
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

        vm.expectRevert(KyberSwapChecker.KyberSwapChecker__InvalidSrcConfig.selector);
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
        desc.flags = 0x80;
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

        vm.expectRevert(KyberSwapChecker.KyberSwapChecker__InvalidMinReturn.selector);
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
        return _buildKyberCalldataWithFee(
            tokenIn, tokenOut, amount, dstReceiver,
            centralRegistry.daoAddress(), 4, // FEE_BPS
            0x80 // REQUIRED_FLAGS (_FEE_IN_BPS)
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
        desc.flags = 0x80; // REQUIRED_FLAGS

        IMetaAggregationRouterV2.SwapExecutionParams memory exec;
        exec.callTarget = kyberSwapExecutor;
        exec.approveTarget = address(0);
        exec.targetData = hex"01";
        exec.desc = desc;

        return abi.encodeWithSelector(
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

        return abi.encodeWithSelector(
            IMetaAggregationRouterV2.swap.selector,
            exec
        );
    }
}
