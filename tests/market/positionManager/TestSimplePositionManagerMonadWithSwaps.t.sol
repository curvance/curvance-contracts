// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {KuruCalldataChecker} from "contracts/calldata-checker/swap-checker/KuruCalldataChecker.sol";
import {TestBaseMarketIsolated} from "tests/market/TestBaseMarketIsolated.sol";

import {SwapperLib} from "contracts/libraries/SwapperLib.sol";
import {BaseSwapChecker} from "contracts/calldata-checker/swap-checker/BaseSwapChecker.sol";
import {SimpleZapper} from "contracts/plugins/market/SimpleZapper.sol";
import {BorrowableCToken} from "contracts/market/token/BorrowableCToken.sol";
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
    address public kuruRouter = 0x96eaC98928437496DdD0Cd2080E54Fe78BaC99b6;
    address public constant WMON_ADDRESS = 0x760AfE86e5de5fa0Ee542fc7B7B713e1c5425701;
    address public constant USDC_ADDRESS = 0xf817257fed379853cDe0fa4F97AB987181B1E5Ea;

    BorrowableCToken public borrowableCUSDC_MONAD;
    BorrowableCToken public borrowableCWMON;

    KuruCalldataChecker public checker;
    SimplePositionManager public positionManager;

    SwapperLib.Swap public swapAction;
    address public recipient;

    address public feeCollectorAddress = 0xc45F0aDD4981076928537490F8C0e24944288947;


    receive() external payable {}

    fallback() external payable {}

    function setUp() public override {
        _fork("ETH_NODE_URI_MONAD");

        _initMainConstantVariables();

        _deployCentralRegistry();
        _deployCVE();
        _deployRewardManager();
        _deployVeCVE();
        _deployGaugeManager();
        _deployMarketManager();
        _deployOracleManager();

        checker = new KuruCalldataChecker(kuruRouter, feeCollectorAddress, address(centralRegistry.daoAddress()));
        centralRegistry.setExternalCalldataChecker(kuruRouter, address(checker));

        borrowableCUSDC_MONAD = _deployBorrowableCToken(USDC_ADDRESS);
        borrowableCWMON = _deployBorrowableCToken(WMON_ADDRESS);

        MockV3Aggregator chainlinkUSDC_WMON = new MockV3Aggregator(18, 1e18);
        MockV3Aggregator chainlinkWMON = new MockV3Aggregator(18, 3.25e18);

        ChainlinkAdaptor chainlinkAdaptor = new ChainlinkAdaptor(ICentralRegistry(address(centralRegistry)));

        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));

        chainlinkAdaptor.addAsset(USDC_ADDRESS, true, address(chainlinkUSDC_WMON), 0, 100);
        chainlinkAdaptor.addAsset(WMON_ADDRESS, true, address(chainlinkWMON), 0, 100);

        oracleManager.addAssetPricingAdaptor(USDC_ADDRESS, address(chainlinkAdaptor), 100, 50);
        oracleManager.addAssetPricingAdaptor(WMON_ADDRESS, address(chainlinkAdaptor), 100, 50);

        oracleManager.addCTokenSupport(address(borrowableCUSDC_MONAD));
        oracleManager.addCTokenSupport(address(borrowableCWMON));

        deal(USDC_ADDRESS, address(this), 77777);
        IERC20(USDC_ADDRESS).approve(address(borrowableCUSDC_MONAD), type(uint256).max);

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
        deal(USDC_ADDRESS, liquidityProvider, 1_000_000e6);
        vm.startPrank(liquidityProvider);
        IERC20(USDC_ADDRESS).approve(address(borrowableCUSDC_MONAD), type(uint256).max);
        borrowableCUSDC_MONAD.deposit(1_000_000e6, liquidityProvider);

        deal(WMON_ADDRESS, liquidityProvider, 1_000_000e18);
        IERC20(WMON_ADDRESS).approve(address(borrowableCWMON), type(uint256).max);
        borrowableCWMON.deposit(1_000_000e18, liquidityProvider);
        vm.stopPrank();
    }

    function testLeverage_TestVaultPositionManagerMonadWithSwaps() public {
        deal(WMON_ADDRESS, user1, 50e18);
        vm.startPrank(user1);
        IERC20(WMON_ADDRESS).approve(address(borrowableCWMON), 50e18);
        borrowableCWMON.depositAsCollateral(50e18, user1);

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

        leverageAction.swapAction.inputToken = USDC_ADDRESS;
        leverageAction.swapAction.inputAmount = bufferedBorrow;
        leverageAction.swapAction.outputToken = WMON_ADDRESS;
        leverageAction.swapAction.target = address(kuruRouter);
		leverageAction.swapAction.call = _getKuruCalldata(
			address(positionManager),
			USDC_ADDRESS,
			WMON_ADDRESS,
			bufferedBorrow
		);
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
		uint256 collateralAssetsToWithdraw = collateralBefore / 2; // withdraw 50% collateral
		// quote prices from kuru api
		uint256 minOutUSDC = _getKuruAmountOut(address(positionManager), WMON_ADDRESS, USDC_ADDRESS, collateralAssetsToWithdraw);
	
		uint256 bufferedMinOut = (minOutUSDC * 97) / 100;
		uint256 debtToRepay = bufferedMinOut;

        SimplePositionManager.DeleverageAction memory deleverageAction;
        deleverageAction.cToken = ICToken(address(borrowableCWMON));
        deleverageAction.collateralAssets = collateralAssetsToWithdraw;
        deleverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCUSDC_MONAD));
        deleverageAction.repayAssets = debtToRepay;

        deleverageAction.swapActions = new SwapperLib.Swap[](1);
        deleverageAction.swapActions[0].inputToken = WMON_ADDRESS;
        deleverageAction.swapActions[0].inputAmount = collateralAssetsToWithdraw;
        deleverageAction.swapActions[0].outputToken = USDC_ADDRESS;
        deleverageAction.swapActions[0].target = address(kuruRouter);
		deleverageAction.swapActions[0].call = _getKuruCalldata(
			address(positionManager),
			WMON_ADDRESS,
			USDC_ADDRESS,
			collateralAssetsToWithdraw
		);
        deleverageAction.swapActions[0].slippage = 0.5e18;

		collateralBefore = borrowableCWMON.balanceOf(user1);
		debtBefore = borrowableCUSDC_MONAD.debtBalanceUpdated(user1);
        uint256 usdcWalletBefore = IERC20(USDC_ADDRESS).balanceOf(user1);

        vm.startPrank(user1);
        positionManager.deleverage(deleverageAction, 0.5e18);
        vm.stopPrank();

        uint256 collateralAfter = borrowableCWMON.balanceOf(user1);
        uint256 debtAfter = borrowableCUSDC_MONAD.debtBalance(user1);
        uint256 usdcWalletAfter = IERC20(USDC_ADDRESS).balanceOf(user1);

        assertEq(collateralBefore - collateralAfter, collateralAssetsToWithdraw, "Collateral should decrease by withdrawn amount");

        assertEq(debtBefore - debtAfter, debtToRepay, "Debt should decrease by repaid amount");

        assertGt(collateralAfter, 0, "Should have remaining collateral");
        assertGt(debtAfter, 0, "Should have remaining debt");

        uint256 excessUsdc = usdcWalletAfter - usdcWalletBefore;
        assertGt(excessUsdc, 0, "User should receive excess USDC in wallet");
    }
}
