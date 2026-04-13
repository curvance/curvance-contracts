// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {KyberSwapChecker} from "contracts/calldata-checker/swap-checker/KyberSwapChecker.sol";
import {KuruCalldataChecker} from "contracts/calldata-checker/swap-checker/KuruCalldataChecker.sol";
import {TestBaseMarketIsolated} from "tests/market/TestBaseMarketIsolated.sol";

import {SwapperLib} from "contracts/libraries/SwapperLib.sol";
import {BaseSwapChecker} from "contracts/calldata-checker/swap-checker/BaseSwapChecker.sol";
import {SimpleZapper} from "contracts/plugins/market/SimpleZapper.sol";
import {BorrowableCToken} from "contracts/market/token/BorrowableCToken.sol";
import {LiquidityManagerIsolated} from "contracts/market/isolated/LiquidityManagerIsolated.sol";
import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";
import {MockV3Aggregator} from "contracts/mocks/MockV3Aggregator.sol";
import {ChainlinkAdaptor} from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import {IERC20} from "contracts/interfaces/IERC20.sol";
import {SimplePositionManager} from "contracts/market/position-management/SimplePositionManager.sol";
import {ProtocolReader} from "contracts/views/ProtocolReader.sol";
import {IBorrowableCToken} from "contracts/interfaces/IBorrowableCToken.sol";
import {ICToken} from "contracts/interfaces/ICToken.sol";

/// @title Position manager tests with real KyberSwap calldata on Monad fork.
/// @dev Forks a specific block and uses pre-fetched swap calldata for
///      deterministic execution. No FFI or API calls at test time.
contract TestSimplePositionManagerMonadWithSwaps is TestBaseMarketIsolated {
    uint256 constant FORK_BLOCK = 67913438;

    address public kyberSwapRouter = 0x6131B5fae19EA4f9D964eAc0408E4408b66337b5;
    address public kyberSwapExecutor = 0x63242A4Ea82847b20E506b63B0e2e2eFF0CC6cB0;
    address public kuruRouter = 0xb3e6778480b2E488385E8205eA05E20060B813cb;
    address public constant WMON_ADDRESS = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;
    address public constant CHAINLINK_WMON_USD = 0x9a7FAe39f78f7711d46F28E9fd2271ECdca58f9a;

    BorrowableCToken public borrowableCUSDC_MONAD;
    BorrowableCToken public borrowableCWMON;

    KyberSwapChecker public kyberSwapChecker;
    KuruCalldataChecker public kuruSwapChecker;
    SimplePositionManager public positionManager;

    MockV3Aggregator public chainlinkUSDC_USD;
    address public feeCollectorAddress = 0x62eE1b8D1EFdF8f73c78dB87b888406b194e266a;

    uint256 constant LEVERAGE_BORROW_AMOUNT = 25e6;
    uint256 constant DELEVERAGE_WMON_AMOUNT = 312e18;

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
        kyberSwapChecker = new KyberSwapChecker(kyberSwapRouter, kyberSwapExecutors, address(centralRegistry));
        centralRegistry.setExternalCalldataChecker(kyberSwapRouter, address(kyberSwapChecker));
        kuruSwapChecker = new KuruCalldataChecker(kuruRouter, feeCollectorAddress, address(centralRegistry.daoAddress()));
        centralRegistry.setExternalCalldataChecker(kuruRouter, address(kuruSwapChecker));

        borrowableCUSDC_MONAD = _deployBorrowableCToken(_USDC_ADDRESS);
        borrowableCWMON = _deployBorrowableCToken(WMON_ADDRESS);

        chainlinkUSDC_USD = new MockV3Aggregator(8, 1e8);

        ChainlinkAdaptor chainlinkAdaptor = new ChainlinkAdaptor(ICentralRegistry(address(centralRegistry)));
        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));

        chainlinkAdaptor.addAsset(_USDC_ADDRESS, true, address(chainlinkUSDC_USD), 0);
        chainlinkAdaptor.addAsset(WMON_ADDRESS, true, CHAINLINK_WMON_USD, 0);

        oracleManager.addAssetPricingAdaptor(_USDC_ADDRESS, address(chainlinkAdaptor), 100, 50, 100, 50);
        oracleManager.addAssetPricingAdaptor(WMON_ADDRESS, address(chainlinkAdaptor), 100, 50, 100, 50);

        oracleManager.addCTokenSupport(address(borrowableCUSDC_MONAD));
        oracleManager.addCTokenSupport(address(borrowableCWMON));

        deal(_USDC_ADDRESS, address(this), 77777);
        IERC20(_USDC_ADDRESS).approve(address(borrowableCUSDC_MONAD), type(uint256).max);

        deal(WMON_ADDRESS, address(this), 77777);
        IERC20(WMON_ADDRESS).approve(address(borrowableCWMON), type(uint256).max);

        marketManagerIsolated.listTokens(address(borrowableCUSDC_MONAD), address(borrowableCWMON));

        _setCTokenConfigBasic(address(borrowableCWMON), 1_000_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC_MONAD), 0, 1_000_000e6);

        positionManager = new SimplePositionManager(
            ICentralRegistry(address(centralRegistry)), address(marketManagerIsolated), WMON_ADDRESS
        );
        marketManagerIsolated.addPositionManager(address(positionManager));

        protocolReader = new ProtocolReader(ICentralRegistry(address(centralRegistry)));

        address liquidityProvider = makeAddr("liquidityProvider");
        deal(_USDC_ADDRESS, liquidityProvider, 1_000_000e6);
        vm.startPrank(liquidityProvider);
        IERC20(_USDC_ADDRESS).approve(address(borrowableCUSDC_MONAD), type(uint256).max);
        borrowableCUSDC_MONAD.deposit(1_000_000e6, liquidityProvider);

        deal(WMON_ADDRESS, liquidityProvider, 1_000_000e18);
        IERC20(WMON_ADDRESS).approve(address(borrowableCWMON), type(uint256).max);
        borrowableCWMON.deposit(1_000_000e18, liquidityProvider);
        vm.stopPrank();
    }

    // ================================================================
    // Calldata helpers (KyberSwap API, block ~67913438)
    // feeAmount=4, isInBps=true, chargeFeeBy=currency_in, feeReceiver=DAO
    // ================================================================

    function _leverageCalldata() internal pure returns (bytes memory) {
        return hex"e21fd0e9000000000000000000000000000000000000000000000000000000000000002000000000000000000000000063242a4ea82847b20e506b63b0e2e2eff0cc6cb0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000008800000000000000000000000000000000000000000000000000000000000000540000000000000000000000000017d5130000000000000000000000000017d5130000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000e00000000000000000000000000000000000000000000000000000000000000041ced55346f45d26a4e56aceeaab947a1da86620708085ec3a6041fd07fb00fae2055b6f4278cb0c736b86641293bcb25fadd1288510a19116265dee915dba22a21c000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000440000000000000000000000000db25a7b768311de128bbda7b8426c3f9c74f3240000000000000000000000000000000000000000000000000000000000000014000000000000000000000000000000000000000000000000000000000000001a0000000000000000000000000016a40540000000000000000000000000190620c000000000000000000000000017d51300000000000000027331fc89a818c0000000000000000000000000000000000000291a9720e49880000000f42400000000000000000000000000000004f82e73edb06d29ff62c91ec8f5ff06571bdeb2900000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000069dd50c20000000000000000000000000000000000000000000000000000000000000420000000000000000000000000000000000000000000000000000000000000000261f598cd000000000000000029443467522688c0d201d27e37a32f56c83d107b2164c94f000000000000000029443467522688c0d201d27e37a32f56c83d107b0000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000001e0000000000000000000000000754704bc059f8c67012fed69bc8a327a5aafb60380000000000000000000000000000018000000000000000000000000017d513000000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000017d5130a357fd2d0000000000000001fe25d210dfe5cdff81917aa7067bac446ecac27c000000000000000000000000000000000000000000000000000000000000008000000000000000000000000063242a4ea82847b20e506b63b0e2e2eff0cc6cb00000000000000000000000000000000000000000000000000000000000000060000000000000000000000000fa32f9ec28787d1f9c5ba5c39e54e59984fef3f000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000148b3190a9f707c429b7c013ab20000000000000000000000003bd359c1119da7da1d913d1c4d2b7c461115433a8000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000754704bc059f8c67012fed69bc8a327a5aafb6030000000000000000000000003bd359c1119da7da1d913d1c4d2b7c461115433a000000000000000000000000000000000000000000000000000000000000016000000000000000000000000000000000000000000000000000000000000001a000000000000000000000000000000000000000000000000000000000000001e00000000000000000000000000000000000000000000000000000000000000220000000000000000000000000db25a7b768311de128bbda7b8426c3f9c74f324000000000000000000000000000000000000000000000000000000000017d78400000000000000000000000000000000000000000000000266a6bf2abe55b1eb800000000000000000000000000000000000000000000000000000000000002800000000000000000000000000000000000000000000000000000000000000260000000000000000000000000000000000000000000000000000000000000000100000000000000000000000063242a4ea82847b20e506b63b0e2e2eff0cc6cb0000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000017d513000000000000000000000000000000000000000000000000000000000000000010000000000000000000000007fa9385be102ac3eac297483dd6233d62b3e149600000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000bb7b22536f75726365223a2243757276616e636550726f746f636f6c222c22416d6f756e74496e555344223a2232352e323236363536222c22416d6f756e744f7574555344223a2232352e323431303239222c22416d6f756e744f7574223a22373233313036393032343630383038383232373834222c22526f7574654944223a223434336336383064444a4a4d33366c543a616339633866316564616c5051494352222c2254696d657374616d70223a313737363131303631307d0000000000";
    }

    function _deleverageCalldata() internal pure returns (bytes memory) {
        return hex"e21fd0e9000000000000000000000000000000000000000000000000000000000000002000000000000000000000000063242a4ea82847b20e506b63b0e2e2eff0cc6cb0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000005c0000000000000000000000000000000000000000000000000000000000000084000000000000000000000000000000000000000000000000000000000000005000000000000000010e8234a03ade800000000000000000010e8234a03ade80000000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000e000000000000000000000000000000000000000000000000000000000000000415ced8cbca07578b64e683db162672b840dcc3de7cc28ae1560ddb8387b5b5a6d73a906ee6c151de3c4f937d20665684f09c60cdb725b33053d65009adecc0a551c000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000400000000000000000000000000db25a7b768311de128bbda7b8426c3f9c74f32400000000000000000000000000000000000000000000000000000000000000140000000000000000000000000000000000000000000000000000000000000018000000000000000100fbb1fe9e53600000000000000000011c08b741d769a00000000000000000010e8234a03ade8000000000000000000000000000000a473b8000000000000000000000000000000000000000000000a0000000f42400000000000000000000000000000004f82e73edb06d29ff62c91ec8f5ff06571bdeb2900000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000069dd50c300000000000000000000000000000000000000000000000000000000000003e0000000000000000000000000000000000000000000000000000000000000000161f598cd000000000000000029443467522688c0d201d27e37a32f56c83d107b0000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000001c00000000000000000000000003bd359c1119da7da1d913d1c4d2b7c461115433a800000000000000000011ba61a82a0000000000000000010e8234a03ade80000000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000010e8234a03ade800003b9d6e090000000000000001434f969593f9bb2655283ebf648733b7f46330aa000000000000000000000000000000000000000000000000000000000000008000000000000000000000000063242a4ea82847b20e506b63b0e2e2eff0cc6cb0000000000000000000000000000000000000000000000000000000000000004000000000000000000000000063e48b725540a3db24acf6682a29f877808c53f2000000000000000000000000000000000000000000000000000000010009046c000000000000000000000000754704bc059f8c67012fed69bc8a327a5aafb60380000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003bd359c1119da7da1d913d1c4d2b7c461115433a000000000000000000000000754704bc059f8c67012fed69bc8a327a5aafb603000000000000000000000000000000000000000000000000000000000000016000000000000000000000000000000000000000000000000000000000000001a000000000000000000000000000000000000000000000000000000000000001e00000000000000000000000000000000000000000000000000000000000000220000000000000000000000000db25a7b768311de128bbda7b8426c3f9c74f3240000000000000000000000000000000000000000000000010e9deaaf401e000000000000000000000000000000000000000000000000000000000000000a129b900000000000000000000000000000000000000000000000000000000000002800000000000000000000000000000000000000000000000000000000000000260000000000000000000000000000000000000000000000000000000000000000100000000000000000000000063242a4ea82847b20e506b63b0e2e2eff0cc6cb00000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000010e8234a03ade8000000000000000000000000000000000000000000000000000000000000000000010000000000000000000000007fa9385be102ac3eac297483dd6233d62b3e149600000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000ae7b22536f75726365223a2243757276616e636550726f746f636f6c222c22416d6f756e74496e555344223a2231302e383835383437222c22416d6f756e744f7574555344223a2231302e383733393431222c22416d6f756e744f7574223a223130373737353238222c22526f7574654944223a2235323332623838394c516448426f66323a313738316564373070623541695a5272222c2254696d657374616d70223a313737363131303631317d000000000000000000000000000000000000";
    }

    // ================================================================
    // Test 1: Leverage
    // ================================================================

    function testLeverage_TestSimplePositionManagerMonadWithSwaps() public {
        deal(WMON_ADDRESS, user1, 5000e18);
        vm.startPrank(user1);
        IERC20(WMON_ADDRESS).approve(address(borrowableCWMON), 5000e18);
        borrowableCWMON.depositAsCollateral(5000e18, user1);

        uint256 collateralBefore = borrowableCWMON.balanceOf(user1);
        uint256 debtBefore = borrowableCUSDC_MONAD.debtBalance(user1);

        SimplePositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCUSDC_MONAD));
        leverageAction.borrowAssets = LEVERAGE_BORROW_AMOUNT;
        leverageAction.cToken = ICToken(address(borrowableCWMON));

        leverageAction.swapAction.inputToken = _USDC_ADDRESS;
        leverageAction.swapAction.inputAmount = LEVERAGE_BORROW_AMOUNT;
        leverageAction.swapAction.outputToken = WMON_ADDRESS;
        leverageAction.swapAction.target = kyberSwapRouter;
        leverageAction.swapAction.call = _leverageCalldata();
        leverageAction.swapAction.slippage = 0.02e18; // 2%

        positionManager.leverage(leverageAction, 0.02e18); // 2%
        vm.stopPrank();

        uint256 collateralAfter = borrowableCWMON.balanceOf(user1);
        uint256 debtAfter = borrowableCUSDC_MONAD.debtBalance(user1);

        assertGt(collateralAfter, collateralBefore, "Collateral should increase after leverage");
        assertEq(debtBefore, 0, "Should start with no debt");
        assertEq(debtAfter, LEVERAGE_BORROW_AMOUNT, "Debt should equal borrowed amount");
    }

    // ================================================================
    // Test 2: Deleverage
    // ================================================================

    function testDeleverage_TestSimplePositionManagerMonadWithSwaps() public {
        testLeverage_TestSimplePositionManagerMonadWithSwaps();

        skip(20 minutes);

        uint256 collateralBefore = borrowableCWMON.balanceOf(user1);
        uint256 debtBefore = borrowableCUSDC_MONAD.debtBalanceUpdated(user1);

        SimplePositionManager.DeleverageAction memory deleverageAction;
        deleverageAction.cToken = ICToken(address(borrowableCWMON));
        deleverageAction.collateralAssets = DELEVERAGE_WMON_AMOUNT;
        deleverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCUSDC_MONAD));
        deleverageAction.repayAssets = 1;

        deleverageAction.swapActions = new SwapperLib.Swap[](1);
        deleverageAction.swapActions[0].inputToken = WMON_ADDRESS;
        deleverageAction.swapActions[0].inputAmount = DELEVERAGE_WMON_AMOUNT;
        deleverageAction.swapActions[0].outputToken = _USDC_ADDRESS;
        deleverageAction.swapActions[0].target = kyberSwapRouter;
        deleverageAction.swapActions[0].call = _deleverageCalldata();
        deleverageAction.swapActions[0].slippage = 0.02e18; // 2%

        vm.startPrank(user1);
        positionManager.deleverage(deleverageAction, 0.02e18); // 2%
        vm.stopPrank();

        uint256 collateralAfter = borrowableCWMON.balanceOf(user1);
        uint256 debtAfter = borrowableCUSDC_MONAD.debtBalanceUpdated(user1);

        assertLt(collateralAfter, collateralBefore, "Collateral should decrease after deleverage");
        assertLt(debtAfter, debtBefore, "Debt should decrease after deleverage");
    }

    // ================================================================
    // Test 3: Deleverage fails when below min loan
    // ================================================================

    /// @notice Tests that deleverage reverts with InsufficientLoanSize when
    ///         a partial repay leaves debt below the minimum loan threshold.
    function testDeleverage_fail_whenBelowMinLoan() public {
        testLeverage_TestSimplePositionManagerMonadWithSwaps();

        skip(20 minutes);

        chainlinkUSDC_USD.updateAnswer(1e5); // $0.001

        (, int256 monPrice,, uint256 updAt,) =
            MockV3Aggregator(CHAINLINK_WMON_USD).latestRoundData();
        vm.mockCall(
            CHAINLINK_WMON_USD,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(999), monPrice / 1000, updAt, updAt, uint80(999))
        );

        SimplePositionManager.DeleverageAction memory deleverageAction;
        deleverageAction.cToken = ICToken(address(borrowableCWMON));
        deleverageAction.collateralAssets = DELEVERAGE_WMON_AMOUNT;
        deleverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCUSDC_MONAD));
        deleverageAction.repayAssets = 1;

        deleverageAction.swapActions = new SwapperLib.Swap[](1);
        deleverageAction.swapActions[0].inputToken = WMON_ADDRESS;
        deleverageAction.swapActions[0].inputAmount = DELEVERAGE_WMON_AMOUNT;
        deleverageAction.swapActions[0].outputToken = _USDC_ADDRESS;
        deleverageAction.swapActions[0].target = kyberSwapRouter;
        deleverageAction.swapActions[0].call = _deleverageCalldata();
        // High slippage tolerance is intentional — oracle prices are
        // distorted above, so the oracle-based and position-level slippage
        // checks need room to pass. The test targets InsufficientLoanSize.
        deleverageAction.swapActions[0].slippage = 0.5e18;

        vm.startPrank(user1);
        vm.expectRevert(LiquidityManagerIsolated.LiquidityManager__InsufficientLoanSize.selector);
        positionManager.deleverage(deleverageAction, 0.95e18);
        vm.stopPrank();
    }
}
