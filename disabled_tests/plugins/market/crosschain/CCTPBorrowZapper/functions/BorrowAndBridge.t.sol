// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {CCTPBorrowZapper} from "contracts/plugins/market/crosschain/CCTPBorrowZapper.sol";
import {MarketManagerIsolated} from "contracts/market/isolated/MarketManagerIsolated.sol";

import {SwapperLib} from "contracts/libraries/SwapperLib.sol";

import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";
import {ChainConfig} from "contracts/interfaces/ICentralRegistry.sol";
import {ITokenMessenger} from "contracts/interfaces/external/wormhole/ITokenMessenger.sol";
import {IWormholeRelayer} from "contracts/interfaces/external/wormhole/IWormholeRelayer.sol";

import {IUniswapV3Router} from "contracts/interfaces/external/uniswap/IUniswapV3Router.sol";

import {TestBaseMarketIsolated} from "tests/market/TestBaseMarketIsolated.sol";
import {MockDataFeed} from "contracts/mocks/MockDataFeed.sol";
import {MockCalldataChecker} from "contracts/mocks/MockCalldataChecker.sol";

contract BorrowAndBridgeTest is TestBaseMarketIsolated {
    address internal _UNISWAP_V3_SWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    uint256 internal constant _TEST_SWAP_SLIPPAGE = 0.999e18;
    address internal destinationReceiver;

    CCTPBorrowZapper public CCTPZapper;

    SwapperLib.Swap public swapAction;
    IUniswapV3Router.ExactInputSingleParams public params;

    function setUp() public override {
        _fork(20287400);

        _init();

        // use mock pricing for testing
        mockDaiFeed = new MockDataFeed(_CHAINLINK_DAI_USD);
        chainlinkAdaptor.addAsset(_DAI_ADDRESS, true, address(mockDaiFeed), 0);
        dualChainlinkAdaptor.addAsset(_DAI_ADDRESS, true, address(mockDaiFeed), 0);
        mockWethFeed = new MockDataFeed(_CHAINLINK_ETH_USD);
        chainlinkAdaptor.addAsset(_WETH_ADDRESS, true, address(mockWethFeed), 0);
        dualChainlinkAdaptor.addAsset(_WETH_ADDRESS, true, address(mockWethFeed), 0);
        mockRethFeed = new MockDataFeed(_CHAINLINK_RETH_ETH);
        chainlinkAdaptor.addAsset(_RETH_ADDRESS, false, address(mockRethFeed), 0);
        dualChainlinkAdaptor.addAsset(_RETH_ADDRESS, false, address(mockRethFeed), 0);
        // start epoch
        vm.warp(gaugeManager.gaugeStartTime());
        vm.roll(block.number + 1000);

        _refreshMockFeeds();

        (, int256 ethPrice,,,) = mockWethFeed.latestRoundData();
        chainlinkEthUsd.updateAnswer(ethPrice);

        // Setup borrowable CDAI.
        {
            _prepareDAI(address(this), 200000e18);
            dai.approve(address(borrowableCDAI), 200000e18);
        }

        // Setup pendleStrategyCTokenSTETH.
        {
            deal(address(LP_wstETH_24Dec2025), address(this), _ONE);
            LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), _ONE);
        }

        marketManagerIsolated.listTokens(address(pendleStrategyCTokenSTETH), address(borrowableCDAI));

        _setCTokenConfigBasic(address(pendleStrategyCTokenSTETH), 100_000e18, 0);
        _setCTokenConfigLowValues(address(borrowableCDAI), 100_000e18, 100_000e18);

        // provide enough liquidity
        _provideEnoughLiquidityForLeverage();

        deal(user1, _ONE);
        destinationReceiver = makeAddr("CCTP Receiver");

        CCTPZapper = new CCTPBorrowZapper(ICentralRegistry(address(centralRegistry)));

        ChainConfig memory config;
        config.isSupported = true;
        config.messagingChainId = 23;
        config.domain = 3;
        config.messagingHub = address(messagingHub);
        config.votingHub = address(votingHub);
        config.cveAddress = address(cve);
        config.feeTokenAddress = _USDC_ADDRESS;
        config.crosschainRelayer = makeAddr("Wormhole Relayer");

        // Support chainId 42161.
        centralRegistry.addChain(42161, config);
        CCTPZapper.setCCTPDeliveryProvider(
            42161, IWormholeRelayer(centralRegistry.crosschainRelayer()).getDefaultDeliveryProvider(), true
        );

        deal(address(LP_wstETH_24Dec2025), user1, _ONE);

        // try mint()
        vm.startPrank(user1);
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), _ONE);
        pendleStrategyCTokenSTETH.deposit(_ONE, user1);
        pendleStrategyCTokenSTETH.postCollateral(_ONE);
        vm.stopPrank();

        assertEq(pendleStrategyCTokenSTETH.balanceOf(user1), _ONE);
        assertEq(pendleStrategyCTokenSTETH.exchangeRate(), _ONE);

        centralRegistry.setExternalCalldataChecker(
            _UNISWAP_V3_SWAP_ROUTER, address(new MockCalldataChecker(_UNISWAP_V3_SWAP_ROUTER))
        );

        swapAction.inputToken = _DAI_ADDRESS;
        swapAction.inputAmount = 500e18;
        swapAction.outputToken = _USDC_ADDRESS;
        swapAction.target = _UNISWAP_V3_SWAP_ROUTER;
        swapAction.slippage = _TEST_SWAP_SLIPPAGE;
        params.tokenIn = _DAI_ADDRESS;
        params.tokenOut = _USDC_ADDRESS;
        params.fee = 3000;
        params.recipient = address(CCTPZapper);
        params.deadline = block.timestamp;
        params.amountIn = 500e18;
        params.amountOutMinimum = 0;
        params.sqrtPriceLimitX96 = 0;
        swapAction.call = abi.encodeWithSelector(IUniswapV3Router.exactInputSingle.selector, params);
    }

    function test_borrowAndBridge_fail_whenSwapActionIsInvalid() public {
        swapAction.inputToken = _USDC_ADDRESS;

        vm.startPrank(user1);

        borrowableCDAI.setDelegateApproval(address(CCTPZapper), true);

        vm.expectRevert(CCTPBorrowZapper.CCTPBorrowZapper__InvalidSwapAction.selector);
        CCTPZapper.borrowAndBridge{value: _ONE}(
            address(borrowableCDAI), 500e18, swapAction, 42161, 0, destinationReceiver
        );

        vm.stopPrank();
    }

    function test_borrowAndBridge_fail_whenCCTPIsNotConfigured() public {
        centralRegistry.setTokenMessager(address(0));

        vm.startPrank(user1);

        borrowableCDAI.setDelegateApproval(address(CCTPZapper), true);

        vm.expectRevert(CCTPBorrowZapper.CCTPBorrowZapper__CCTPIsNotConfigured.selector);
        CCTPZapper.borrowAndBridge{value: _ONE}(
            address(borrowableCDAI), 500e18, swapAction, 42161, 0, destinationReceiver
        );

        vm.stopPrank();
    }

    function test_borrowAndBridge_fail_whenGasTokenIsNotEnough() public {
        uint256 messageFee = CCTPZapper.quoteMessageFee(42161, 0);

        vm.startPrank(user1);

        borrowableCDAI.setDelegateApproval(address(CCTPZapper), true);

        vm.expectRevert(CCTPBorrowZapper.CCTPBorrowZapper__InsufficientGasToken.selector);
        CCTPZapper.borrowAndBridge{value: messageFee - 1}(
            address(borrowableCDAI), 500e18, swapAction, 42161, 0, destinationReceiver
        );

        vm.stopPrank();
    }

    function test_borrowAndBridge_fail_TightSwapSafeSlippage() public {
        swapAction.slippage = 0;
        uint256 debtBefore = borrowableCDAI.debtBalance(user1);
        uint256 userDaiBefore = dai.balanceOf(user1);
        uint256 userUsdcBefore = usdc.balanceOf(user1);
        uint256 zapperDaiBefore = dai.balanceOf(address(CCTPZapper));
        uint256 zapperUsdcBefore = usdc.balanceOf(address(CCTPZapper));
        uint256 userNativeBefore = user1.balance;

        vm.startPrank(user1);

        borrowableCDAI.setDelegateApproval(address(CCTPZapper), true);

        vm.expectPartialRevert(SwapperLib.SwapperLib__Slippage.selector);
        CCTPZapper.borrowAndBridge{value: _ONE}(
            address(borrowableCDAI), 500e18, swapAction, 42161, 0, destinationReceiver
        );

        vm.stopPrank();

        assertEq(borrowableCDAI.debtBalance(user1), debtBefore);
        assertEq(dai.balanceOf(user1), userDaiBefore);
        assertEq(usdc.balanceOf(user1), userUsdcBefore);
        assertEq(dai.balanceOf(address(CCTPZapper)), zapperDaiBefore);
        assertEq(usdc.balanceOf(address(CCTPZapper)), zapperUsdcBefore);
        assertEq(user1.balance, userNativeBefore);
    }

    function test_borrowAndBridge_success() public {
        uint256 messageFee = CCTPZapper.quoteMessageFee(42161, 0);
        uint256 balance = user1.balance;
        uint256 debtBefore = borrowableCDAI.debtBalance(user1);
        uint256 userDaiBefore = dai.balanceOf(user1);
        uint256 userUsdcBefore = usdc.balanceOf(user1);

        vm.startPrank(user1);

        borrowableCDAI.setDelegateApproval(address(CCTPZapper), true);
        CCTPZapper.borrowAndBridge{value: _ONE}(
            address(borrowableCDAI), 500e18, swapAction, 42161, 0, destinationReceiver
        );

        vm.stopPrank();

        assertEq(user1.balance, balance - messageFee);
        assertEq(borrowableCDAI.debtBalance(user1), debtBefore + 500e18);
        assertEq(dai.balanceOf(user1), userDaiBefore);
        assertEq(usdc.balanceOf(user1), userUsdcBefore);
    }

    function test_borrowAndBridge_fail_whenDestinationReceiverIsZero() public {
        vm.startPrank(user1);
        borrowableCDAI.setDelegateApproval(address(CCTPZapper), true);

        vm.expectRevert(CCTPBorrowZapper.CCTPBorrowZapper__InvalidDestinationReceiver.selector);
        CCTPZapper.borrowAndBridge{value: _ONE}(address(borrowableCDAI), 500e18, swapAction, 42161, 0, address(0));
        vm.stopPrank();
    }

    function test_borrowAndBridge_routesCCTPAndWormholeToDestinationReceiver() public {
        MockTokenMessengerForCCTPBorrowZapper tokenMessenger = new MockTokenMessengerForCCTPBorrowZapper();
        MockWormholeRelayerForCCTPBorrowZapper relayer = new MockWormholeRelayerForCCTPBorrowZapper();
        centralRegistry.setTokenMessager(address(tokenMessenger));
        centralRegistry.setCrosschainRelayer(address(relayer));
        CCTPZapper.setCCTPDeliveryProvider(42161, relayer.getDefaultDeliveryProvider(), true);

        uint256 messageFee = CCTPZapper.quoteMessageFee(42161, 0);

        vm.startPrank(user1);
        borrowableCDAI.setDelegateApproval(address(CCTPZapper), true);
        CCTPZapper.borrowAndBridge{value: messageFee}(
            address(borrowableCDAI), 500e18, swapAction, 42161, 0, destinationReceiver
        );
        vm.stopPrank();

        bytes32 receiverAsBytes32 = bytes32(uint256(uint160(destinationReceiver)));

        assertEq(tokenMessenger.lastMintRecipient(), receiverAsBytes32);
        assertEq(tokenMessenger.lastDestinationCaller(), receiverAsBytes32);
        assertEq(relayer.lastTargetChain(), 23);
        assertEq(relayer.lastTargetAddress(), destinationReceiver);
        assertEq(abi.decode(relayer.lastPayload(), (address)), user1);
        assertEq(relayer.lastRefundChain(), 23);
        assertEq(relayer.lastRefundAddress(), destinationReceiver);
        assertEq(relayer.lastDeliveryProvider(), relayer.getDefaultDeliveryProvider());
    }

    function test_borrowAndBridge_usesCheckedDeliveryProviderIfDefaultChangesDuringBurn() public {
        MockTokenMessengerForCCTPBorrowZapper tokenMessenger = new MockTokenMessengerForCCTPBorrowZapper();
        MockWormholeRelayerForCCTPBorrowZapper relayer = new MockWormholeRelayerForCCTPBorrowZapper();
        address checkedProvider = makeAddr("checked provider");
        address mutatedProvider = makeAddr("mutated provider");
        relayer.setDefaultDeliveryProvider(checkedProvider);
        tokenMessenger.setProviderMutation(relayer, mutatedProvider);
        centralRegistry.setTokenMessager(address(tokenMessenger));
        centralRegistry.setCrosschainRelayer(address(relayer));
        CCTPZapper.setCCTPDeliveryProvider(42161, checkedProvider, true);

        uint256 messageFee = CCTPZapper.quoteMessageFee(42161, 0);

        vm.startPrank(user1);
        borrowableCDAI.setDelegateApproval(address(CCTPZapper), true);
        CCTPZapper.borrowAndBridge{value: messageFee}(
            address(borrowableCDAI), 500e18, swapAction, 42161, 0, destinationReceiver
        );
        vm.stopPrank();

        assertEq(relayer.getDefaultDeliveryProvider(), mutatedProvider);
        assertEq(relayer.lastDeliveryProvider(), checkedProvider);
    }

    function test_borrowAndBridge_doesNotBridgePreExistingFeeTokenResidue() public {
        MockTokenMessengerForCCTPBorrowZapper tokenMessenger = new MockTokenMessengerForCCTPBorrowZapper();
        MockWormholeRelayerForCCTPBorrowZapper relayer = new MockWormholeRelayerForCCTPBorrowZapper();
        centralRegistry.setTokenMessager(address(tokenMessenger));
        centralRegistry.setCrosschainRelayer(address(relayer));
        CCTPZapper.setCCTPDeliveryProvider(42161, relayer.getDefaultDeliveryProvider(), true);

        _prepareUSDC(address(CCTPZapper), 123e6);
        uint256 balancePrior = usdc.balanceOf(address(CCTPZapper));
        uint256 messageFee = CCTPZapper.quoteMessageFee(42161, 0);

        vm.startPrank(user1);
        borrowableCDAI.setDelegateApproval(address(CCTPZapper), true);
        CCTPZapper.borrowAndBridge{value: messageFee}(
            address(borrowableCDAI), 500e18, swapAction, 42161, 0, destinationReceiver
        );
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(CCTPZapper)), balancePrior + tokenMessenger.lastAmount());
        assertGt(tokenMessenger.lastAmount(), 0);
    }

    function test_borrowAndBridge_feeTokenBorrowDoesNotBridgePreExistingFeeTokenResidue() public {
        MockTokenMessengerForCCTPBorrowZapper tokenMessenger = new MockTokenMessengerForCCTPBorrowZapper();
        MockWormholeRelayerForCCTPBorrowZapper relayer = new MockWormholeRelayerForCCTPBorrowZapper();
        centralRegistry.setTokenMessager(address(tokenMessenger));
        centralRegistry.setCrosschainRelayer(address(relayer));
        CCTPZapper.setCCTPDeliveryProvider(42161, relayer.getDefaultDeliveryProvider(), true);
        _setFeeTokenBeforeGenesis(_DAI_ADDRESS);

        SwapperLib.Swap memory noSwapAction;
        _prepareDAI(address(CCTPZapper), 123e18);
        uint256 balancePrior = dai.balanceOf(address(CCTPZapper));
        uint256 debtBefore = borrowableCDAI.debtBalance(user1);
        uint256 messageFee = CCTPZapper.quoteMessageFee(42161, 0);

        vm.startPrank(user1);
        borrowableCDAI.setDelegateApproval(address(CCTPZapper), true);
        CCTPZapper.borrowAndBridge{value: messageFee}(
            address(borrowableCDAI), 500e18, noSwapAction, 42161, 0, destinationReceiver
        );
        vm.stopPrank();

        assertEq(tokenMessenger.lastAmount(), 500e18);
        assertEq(borrowableCDAI.debtBalance(user1), debtBefore + 500e18);
        assertEq(dai.balanceOf(address(CCTPZapper)), balancePrior + tokenMessenger.lastAmount());
    }

    function test_borrowAndBridge_destinationDeliveryToReceiverFinalizesCCTP() public {
        MockTokenMessengerForCCTPBorrowZapper tokenMessenger = new MockTokenMessengerForCCTPBorrowZapper();
        MockWormholeRelayerForCCTPBorrowZapper relayer = new MockWormholeRelayerForCCTPBorrowZapper();
        MockMessageTransmitterForCCTPBorrowZapper transmitter = new MockMessageTransmitterForCCTPBorrowZapper();
        centralRegistry.setTokenMessager(address(tokenMessenger));
        centralRegistry.setCrosschainRelayer(address(relayer));
        CCTPZapper.setCCTPDeliveryProvider(42161, relayer.getDefaultDeliveryProvider(), true);

        uint256 messageFee = CCTPZapper.quoteMessageFee(42161, 0);
        MockCCTPReceiverForCCTPBorrowZapper receiver = new MockCCTPReceiverForCCTPBorrowZapper(transmitter);

        vm.startPrank(user1);
        borrowableCDAI.setDelegateApproval(address(CCTPZapper), true);
        CCTPZapper.borrowAndBridge{value: messageFee}(
            address(borrowableCDAI), 500e18, swapAction, 42161, 0, address(receiver)
        );
        vm.stopPrank();

        bytes[] memory cctpAttestation = new bytes[](1);
        cctpAttestation[0] = abi.encode(bytes("message"), bytes("attestation"));

        assertEq(relayer.lastTargetAddress(), address(receiver));
        assertEq(abi.decode(relayer.lastPayload(), (address)), user1);

        relayer.deliverToLastTarget(cctpAttestation);
        assertEq(transmitter.receiveMessageCalls(), 1);
    }

    function test_borrowAndBridge_fail_beforeDebtWhenCCTPDeliveryProviderIsUnsupported() public {
        MockTokenMessengerForCCTPBorrowZapper tokenMessenger = new MockTokenMessengerForCCTPBorrowZapper();
        MockUnsupportedCCTPRelayerForCCTPBorrowZapper relayer = new MockUnsupportedCCTPRelayerForCCTPBorrowZapper();
        MockMessageTransmitterForCCTPBorrowZapper transmitter = new MockMessageTransmitterForCCTPBorrowZapper();
        centralRegistry.setTokenMessager(address(tokenMessenger));
        centralRegistry.setCrosschainRelayer(address(relayer));

        uint256 messageFee = CCTPZapper.quoteMessageFee(42161, 0);
        MockCCTPReceiverForCCTPBorrowZapper receiver = new MockCCTPReceiverForCCTPBorrowZapper(transmitter);
        uint256 debtBefore = borrowableCDAI.debtBalance(user1);

        vm.startPrank(user1);
        borrowableCDAI.setDelegateApproval(address(CCTPZapper), true);
        vm.expectRevert(CCTPBorrowZapper.CCTPBorrowZapper__InvalidDeliveryProvider.selector);
        CCTPZapper.borrowAndBridge{value: messageFee}(
            address(borrowableCDAI), 500e18, swapAction, 42161, 0, address(receiver)
        );
        vm.stopPrank();

        assertEq(borrowableCDAI.debtBalance(user1), debtBefore);
        assertEq(tokenMessenger.lastAmount(), 0);
        assertEq(relayer.lastMessageKeyType(), 0);
        assertEq(transmitter.receiveMessageCalls(), 0);
    }

    function test_setCCTPDeliveryProvider_canRevokeAfterChainRemoval() public {
        address provider = IWormholeRelayer(centralRegistry.crosschainRelayer()).getDefaultDeliveryProvider();

        assertTrue(CCTPZapper.isCCTPDeliveryProvider(42161, provider));

        centralRegistry.removeChain(42161, address(messagingHub), address(votingHub));

        CCTPZapper.setCCTPDeliveryProvider(42161, provider, false);

        assertFalse(CCTPZapper.isCCTPDeliveryProvider(42161, provider));

        vm.expectRevert(CCTPBorrowZapper.CCTPBorrowZapper__CCTPIsNotConfigured.selector);
        CCTPZapper.setCCTPDeliveryProvider(42161, provider, true);
    }

    function _provideEnoughLiquidityForLeverage() internal {
        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareDAI(liquidityProvider, 200000e18);
        deal(address(LP_wstETH_24Dec2025), liquidityProvider, 10e18);
        // Mint borrowable cDAI.
        vm.startPrank(liquidityProvider);
        dai.approve(address(borrowableCDAI), 200000e18);
        borrowableCDAI.deposit(200000e18, liquidityProvider);
        // Mint cBALETH.
        LP_wstETH_24Dec2025.approve(address(pendleStrategyCTokenSTETH), 10e18);
        pendleStrategyCTokenSTETH.deposit(10e18, liquidityProvider);
        vm.stopPrank();
    }

    function _setFeeTokenBeforeGenesis(address newFeeToken) internal {
        uint256 currentTimestamp = block.timestamp;
        vm.warp(centralRegistry.genesisEpoch() - 1);
        centralRegistry.setFeeToken(newFeeToken);
        vm.warp(currentTimestamp);
    }
}

contract MockTokenMessengerForCCTPBorrowZapper is ITokenMessenger {
    uint64 public nextNonce = 123;
    uint256 public lastAmount;
    bytes32 public lastMintRecipient;
    bytes32 public lastDestinationCaller;
    MockWormholeRelayerForCCTPBorrowZapper public relayerToMutate;
    address public providerAfterBurn;

    function setProviderMutation(MockWormholeRelayerForCCTPBorrowZapper relayer, address provider) external {
        relayerToMutate = relayer;
        providerAfterBurn = provider;
    }

    function depositForBurnWithCaller(uint256 amount, uint32, bytes32 mintRecipient, address, bytes32 destinationCaller)
        external
        returns (uint64 nonce)
    {
        lastAmount = amount;
        lastMintRecipient = mintRecipient;
        lastDestinationCaller = destinationCaller;
        if (address(relayerToMutate) != address(0)) {
            relayerToMutate.setDefaultDeliveryProvider(providerAfterBurn);
        }
        return nextNonce;
    }

    function remoteTokenMessengers(uint32) external pure returns (bytes32) {
        return bytes32(uint256(1));
    }
}

contract MockWormholeRelayerForCCTPBorrowZapper is IWormholeRelayer {
    uint16 public lastTargetChain;
    address public lastTargetAddress;
    bytes public lastPayload;
    uint16 public lastRefundChain;
    address public lastRefundAddress;
    address public lastDeliveryProvider;
    uint8 public lastMessageKeyType;
    address public defaultDeliveryProvider = address(this);

    function sendToEvm(
        uint16 targetChain,
        address targetAddress,
        bytes memory payload,
        uint256,
        uint256,
        uint256,
        uint16 refundChain,
        address refundAddress,
        address deliveryProvider,
        MessageKey[] memory messageKeys,
        uint8
    ) external payable returns (uint64 sequence) {
        lastTargetChain = targetChain;
        lastTargetAddress = targetAddress;
        lastPayload = payload;
        lastRefundChain = refundChain;
        lastRefundAddress = refundAddress;
        lastDeliveryProvider = deliveryProvider;
        if (messageKeys.length > 0) {
            lastMessageKeyType = messageKeys[0].keyType;
        }
        return 456;
    }

    function setDefaultDeliveryProvider(address provider) external {
        defaultDeliveryProvider = provider;
    }

    function deliverToLastTarget(bytes[] memory additionalVaas) public virtual {
        _deliverTo(lastTargetAddress, additionalVaas);
    }

    function deliverTo(address target, bytes[] memory additionalVaas) external {
        _deliverTo(target, additionalVaas);
    }

    function _deliverTo(address target, bytes[] memory additionalVaas) internal {
        ITestWormholeReceiver(target)
            .receiveWormholeMessages(
                "", additionalVaas, bytes32(uint256(uint160(address(this)))), lastTargetChain, keccak256("delivery")
            );
    }

    function sendPayloadToEvm(uint16, address, bytes memory, uint256, uint256)
        external
        payable
        returns (uint64 sequence)
    {
        return 0;
    }

    function sendPayloadToEvm(uint16, address, bytes memory, uint256, uint256, uint16, address)
        external
        payable
        returns (uint64 sequence)
    {
        return 0;
    }

    function sendVaasToEvm(uint16, address, bytes memory, uint256, uint256, VaaKey[] memory)
        external
        payable
        returns (uint64 sequence)
    {
        return 0;
    }

    function getDefaultDeliveryProvider() external view returns (address) {
        return defaultDeliveryProvider;
    }

    function quoteEVMDeliveryPrice(uint16, uint256, uint256)
        external
        pure
        returns (uint256 nativePriceQuote, uint256 targetChainRefundPerGasUnused)
    {
        return (0.01 ether, 0);
    }
}

contract MockUnsupportedCCTPRelayerForCCTPBorrowZapper is MockWormholeRelayerForCCTPBorrowZapper {
    error UnsupportedCCTPKeyType();

    function deliverToLastTarget(bytes[] memory) public override {
        if (lastMessageKeyType == 2) {
            revert UnsupportedCCTPKeyType();
        }
    }
}

interface ITestWormholeReceiver {
    function receiveWormholeMessages(
        bytes memory payload,
        bytes[] memory additionalVaas,
        bytes32 sourceAddress,
        uint16 sourceChain,
        bytes32 deliveryHash
    ) external payable;
}

contract MockMessageTransmitterForCCTPBorrowZapper {
    uint256 public receiveMessageCalls;

    function receiveMessage(bytes memory, bytes memory) external returns (bool) {
        ++receiveMessageCalls;
        return true;
    }
}

contract MockCCTPReceiverForCCTPBorrowZapper is ITestWormholeReceiver {
    MockMessageTransmitterForCCTPBorrowZapper public immutable transmitter;

    constructor(MockMessageTransmitterForCCTPBorrowZapper transmitter_) {
        transmitter = transmitter_;
    }

    function receiveWormholeMessages(bytes memory, bytes[] memory additionalVaas, bytes32, uint16, bytes32)
        external
        payable
    {
        (bytes memory message, bytes memory attestation) = abi.decode(additionalVaas[0], (bytes, bytes));
        transmitter.receiveMessage(message, attestation);
    }
}
