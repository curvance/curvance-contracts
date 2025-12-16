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

import {console2} from "forge-std/console2.sol";

// positionManager address: 0xDB25A7b768311dE128BBDa7B8426c3f9C74f3240;

contract TestSimplePositionManagerMonadWithSwaps is TestBaseMarketIsolated {
    address public kyberSwapRouter = 0x6131B5fae19EA4f9D964eAc0408E4408b66337b5;
    address public kyberSwapExecutor = 0x63242A4Ea82847b20E506b63B0e2e2eFF0CC6cB0;
    address public kuruRouter = 0xb3e6778480b2E488385E8205eA05E20060B813cb;
    address public constant WMON_ADDRESS = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;

    BorrowableCToken public borrowableCUSDC_MONAD;
    BorrowableCToken public borrowableCWMON;

    KyberSwapChecker public kyberSwapChecker;
    KuruCalldataChecker public kuruSwapChecker;
    SimplePositionManager public positionManager;

    SwapperLib.Swap public swapAction;
    address public recipient;

    address public feeCollectorAddress = 0x62eE1b8D1EFdF8f73c78dB87b888406b194e266a;


    receive() external payable {}

    fallback() external payable {}

    function setUp() public override {
        _fork("MON_NODE_URI_MONAD_MAINNET");

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

        MockV3Aggregator chainlinkUSDC_USD = new MockV3Aggregator(8, 1e8);
        // use the real Chainlink feed on Monad mainnet
        address chainlinkWMON_USD = 0xBcD78f76005B7515837af6b50c7C52BCf73822fb;

        ChainlinkAdaptor chainlinkAdaptor = new ChainlinkAdaptor(ICentralRegistry(address(centralRegistry)));

        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));

        chainlinkAdaptor.addAsset(_USDC_ADDRESS, true, address(chainlinkUSDC_USD), 0);
        chainlinkAdaptor.addAsset(WMON_ADDRESS, true, chainlinkWMON_USD, 0);

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

        console2.log("positionManager", address(positionManager));

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

    function testLeverage_TestVaultPositionManagerMonadWithSwaps() public {
        deal(WMON_ADDRESS, user1, 5000e18);
        vm.startPrank(user1);
        IERC20(WMON_ADDRESS).approve(address(borrowableCWMON), 5000e18);
        borrowableCWMON.depositAsCollateral(5000e18, user1);

        (,,, uint256 maxDebtBorrowable,,) = protocolReader.hypotheticalLeverageOf(
            user1, address(borrowableCWMON), address(borrowableCUSDC_MONAD), 0, 0
        );

        uint256 collateralBefore = borrowableCWMON.balanceOf(user1);
        uint256 debtBefore = borrowableCUSDC_MONAD.debtBalance(user1);

        uint256 bufferedBorrow = (maxDebtBorrowable * 50) / 100; // 50% of max

        SimplePositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCUSDC_MONAD));
        leverageAction.borrowAssets = bufferedBorrow;
        leverageAction.cToken = ICToken(address(borrowableCWMON));

        leverageAction.swapAction.inputToken = _USDC_ADDRESS;
        leverageAction.swapAction.inputAmount = bufferedBorrow;
        leverageAction.swapAction.outputToken = WMON_ADDRESS;

        uint8 aggregatorCode;

        (leverageAction.swapAction.call, aggregatorCode) = _getSwapDataWithFallback(
            block.chainid,
            address(positionManager),
            _USDC_ADDRESS,
            WMON_ADDRESS,
            bufferedBorrow,
            address(positionManager),
            500
        );

        console2.log("aggregatorCode", aggregatorCode);
        if(aggregatorCode == 1) {
            leverageAction.swapAction.target = address(kyberSwapRouter);
        } else if(aggregatorCode == 2) {
            leverageAction.swapAction.target = kuruRouter;
        } else {
            revert("Both Kyber and Kuru paths failed");
        }
        leverageAction.swapAction.slippage = 0.5e18;

        positionManager.leverage(leverageAction, 0.5e18);
        vm.stopPrank();

        uint256 collateralAfter = borrowableCWMON.balanceOf(user1);
        uint256 debtAfter = borrowableCUSDC_MONAD.debtBalance(user1);

        assertGt(collateralAfter, collateralBefore, "Collateral should increase after leverage");

        assertEq(debtBefore, 0, "Should start with no debt");
        assertEq(debtAfter, bufferedBorrow, "Debt should equal borrowed amount");

    }

    function testDeleverage_TestVaultPositionManagerMonadWithSwaps() public {
        testLeverage_TestVaultPositionManagerMonadWithSwaps();
        skip(20 minutes);

		uint256 collateralBefore = borrowableCWMON.balanceOf(user1);
		uint256 debtBefore = borrowableCUSDC_MONAD.debtBalanceUpdated(user1);
		uint256 collateralAssetsToWithdraw = collateralBefore / 20; // withdraw 5% collateral
		uint256 minOutUSDC;

		try this._getKyberAmountOut(
			block.chainid,
			WMON_ADDRESS,
			_USDC_ADDRESS,
			collateralAssetsToWithdraw,
			address(positionManager),
			500
		) returns (uint256 kyberOut) {
			minOutUSDC = kyberOut;
		} catch {
			// quote prices from kuru as a fallback
			minOutUSDC = _getKuruAmountOut(
				user1,
				WMON_ADDRESS,
				_USDC_ADDRESS,
				collateralAssetsToWithdraw
			);
		}

		uint256 bufferedMinOut = (minOutUSDC * 97) / 100;
		// Cap repay amount at actual debt to handle low liquidity scenarios
		uint256 debtToRepay = bufferedMinOut > debtBefore ? debtBefore : bufferedMinOut;

        SimplePositionManager.DeleverageAction memory deleverageAction;
        deleverageAction.cToken = ICToken(address(borrowableCWMON));
        deleverageAction.collateralAssets = collateralAssetsToWithdraw;
        deleverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCUSDC_MONAD));
        deleverageAction.repayAssets = debtToRepay;

        deleverageAction.swapActions = new SwapperLib.Swap[](1);
        deleverageAction.swapActions[0].inputToken = WMON_ADDRESS;
        deleverageAction.swapActions[0].inputAmount = collateralAssetsToWithdraw;
        deleverageAction.swapActions[0].outputToken = _USDC_ADDRESS;
        deleverageAction.swapActions[0].target = address(kyberSwapRouter);

        uint256 aggregatorCode;

        (deleverageAction.swapActions[0].call, aggregatorCode) = _getSwapDataWithFallback(
            block.chainid,
            address(positionManager),
            WMON_ADDRESS,
            _USDC_ADDRESS,
            collateralAssetsToWithdraw,
            address(positionManager),
            500
        );
        if(aggregatorCode == 1) {
            deleverageAction.swapActions[0].target = address(kyberSwapRouter);
        } else if(aggregatorCode == 2) {
            deleverageAction.swapActions[0].target = kuruRouter;
        } else {
            revert("Both Kyber and Kuru paths failed");
        }

        deleverageAction.swapActions[0].slippage = 0.5e18;

		collateralBefore = borrowableCWMON.balanceOf(user1);
		debtBefore = borrowableCUSDC_MONAD.debtBalanceUpdated(user1);
        uint256 usdcWalletBefore = IERC20(_USDC_ADDRESS).balanceOf(user1);

        vm.startPrank(user1);
        positionManager.deleverage(deleverageAction, 0.5e18);
        vm.stopPrank();

        uint256 collateralAfter = borrowableCWMON.balanceOf(user1);
        uint256 debtAfter = borrowableCUSDC_MONAD.debtBalance(user1);
        uint256 usdcWalletAfter = IERC20(_USDC_ADDRESS).balanceOf(user1);

        assertEq(collateralBefore - collateralAfter, collateralAssetsToWithdraw, "Collateral should decrease by withdrawn amount");

        assertEq(debtBefore - debtAfter, debtToRepay, "Debt should decrease by repaid amount");
    }

    function testDeleverage_fail_whenBelowMinLoan() public {
        deal(WMON_ADDRESS, user1, 500e18);
        vm.startPrank(user1);
        IERC20(WMON_ADDRESS).approve(address(borrowableCWMON), 500e18);
        borrowableCWMON.depositAsCollateral(500e18, user1);

        (,,, uint256 maxDebtBorrowable,,) = protocolReader.hypotheticalLeverageOf(
            user1, address(borrowableCWMON), address(borrowableCUSDC_MONAD), 0, 0
        );

        uint256 collateralBefore = borrowableCWMON.balanceOf(user1);
        uint256 debtBefore = borrowableCUSDC_MONAD.debtBalance(user1);

        uint256 bufferedBorrow = (maxDebtBorrowable * 50) / 100; // 50% of max

        SimplePositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCUSDC_MONAD));
        leverageAction.borrowAssets = bufferedBorrow;
        leverageAction.cToken = ICToken(address(borrowableCWMON));

        leverageAction.swapAction.inputToken = _USDC_ADDRESS;
        leverageAction.swapAction.inputAmount = bufferedBorrow;
        leverageAction.swapAction.outputToken = WMON_ADDRESS;
        leverageAction.swapAction.target = address(kyberSwapRouter);

        uint8 aggregatorCode;
        (leverageAction.swapAction.call, aggregatorCode) = _getSwapDataWithFallback(
            block.chainid,
            address(positionManager),
            _USDC_ADDRESS,
            WMON_ADDRESS,
            bufferedBorrow,
            address(positionManager),
            500
        );
        if(aggregatorCode == 1) {
            leverageAction.swapAction.target = address(kyberSwapRouter);
        } else if(aggregatorCode == 2) {
            leverageAction.swapAction.target = kuruRouter;
        } else {
            revert("Both Kyber and Kuru paths failed");
        }

        leverageAction.swapAction.slippage = 0.5e18;

        positionManager.leverage(leverageAction, 0.5e18);
        vm.stopPrank();

        uint256 collateralAfter = borrowableCWMON.balanceOf(user1);
        uint256 debtAfter = borrowableCUSDC_MONAD.debtBalance(user1);

        assertGt(collateralAfter, collateralBefore, "Collateral should increase after leverage");

        assertEq(debtBefore, 0, "Should start with no debt");
        assertEq(debtAfter, bufferedBorrow, "Debt should equal borrowed amount");

        skip(20 minutes);

        // deleverage below min loan
		collateralBefore = borrowableCWMON.balanceOf(user1);
		debtBefore = borrowableCUSDC_MONAD.debtBalanceUpdated(user1);

		uint256 targetRemainingDebt = 5e6; // $5 USDC
		uint256 debtToRepay = debtBefore - targetRemainingDebt;

		uint256 collateralAssetsToWithdraw = (collateralBefore * 50) / 100;

		SimplePositionManager.DeleverageAction memory deleverageAction;
        deleverageAction.cToken = ICToken(address(borrowableCWMON));
        deleverageAction.collateralAssets = collateralAssetsToWithdraw;
        deleverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCUSDC_MONAD));
        deleverageAction.repayAssets = debtToRepay;

        deleverageAction.swapActions = new SwapperLib.Swap[](1);
        deleverageAction.swapActions[0].inputToken = WMON_ADDRESS;
        deleverageAction.swapActions[0].inputAmount = collateralAssetsToWithdraw;
        deleverageAction.swapActions[0].outputToken = _USDC_ADDRESS;
        deleverageAction.swapActions[0].target = address(kyberSwapRouter);

        (deleverageAction.swapActions[0].call, aggregatorCode) = _getSwapDataWithFallback(
            block.chainid,
            address(positionManager),
            WMON_ADDRESS,
            _USDC_ADDRESS,
            collateralAssetsToWithdraw,
            address(positionManager),
            500
        );
        if(aggregatorCode == 1) {
            deleverageAction.swapActions[0].target = address(kyberSwapRouter);
        } else if(aggregatorCode == 2) {
            deleverageAction.swapActions[0].target = kuruRouter;
        } else {
            revert("Both Kyber and Kuru paths failed");
        }

        console2.log("aggregatorCode", aggregatorCode);

        deleverageAction.swapActions[0].slippage = 0.5e18;

		collateralBefore = borrowableCWMON.balanceOf(user1);
		debtBefore = borrowableCUSDC_MONAD.debtBalanceUpdated(user1);
        uint256 usdcWalletBefore = IERC20(_USDC_ADDRESS).balanceOf(user1);

        vm.startPrank(user1);

        vm.expectRevert(LiquidityManagerIsolated.LiquidityManager__InsufficientLoanSize.selector);
        positionManager.deleverage(deleverageAction, 0.5e18);
        vm.stopPrank();
    }
}
