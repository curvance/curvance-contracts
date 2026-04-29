// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { DualSidedVaultPositionManager } from "contracts/market/position-management/DualSidedVaultPositionManager.sol";
import { SimpleCToken } from "contracts/market/token/SimpleCToken.sol";
import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { ICToken, AccountSnapshot } from "contracts/interfaces/ICToken.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IUniswapV3Router } from "contracts/interfaces/external/uniswap/IUniswapV3Router.sol";
import { StakedFraxAggregator } from "contracts/oracles/adaptors/wrappedAggregators/StakedFraxAggregator.sol";
import { BasePositionManager } from "contracts/market/position-management/BasePositionManager.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

/// @dev
/// Test overview:
/// - This suite exercises DualSidedVaultPositionManager on an Ethereum mainnet fork.
///
/// Markets:
/// - sFRAX/USDC (with swap):
///   - Collateral: SimpleCToken(sFRAX)
///   - Debt: BorrowableCToken(USDC)
///   - Leverage: Borrow USDC -> swap to FRAX -> deposit FRAX into sFRAX -> post collateral.
///   - Deleverage: Redeem sFRAX -> receive FRAX -> swap to USDC -> repay loan.
///
/// - sFRAX/FRAX (no swap):
///   - Collateral: SimpleCToken(sFRAX)
///   - Debt: BorrowableCToken(FRAX)
///   - Leverage: Borrow FRAX -> deposit FRAX into sFRAX -> post collateral.
///   - Deleverage: Redeem sFRAX -> receive FRAX -> repay loan.
contract TestDualSidedVaultPositionManager is TestBaseMarketIsolated {

    DualSidedVaultPositionManager public positionManager;

    address internal _UNISWAP_V3_SWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address internal _SFRAX_ADDRESS = 0xA663B02CF0a4b149d2aD41910CB81e23e1c41c32;

    SimpleCToken public simpleCSFRAX;
    BorrowableCToken public borrowableCFRAX;

    receive() external payable {}

    fallback() external payable {}

    function setUp() public override {
        _fork(21_000_000);

        _init();

        centralRegistry.setExternalCalldataChecker(
            _UNISWAP_V3_SWAP_ROUTER,
            address(new MockCalldataChecker(_UNISWAP_V3_SWAP_ROUTER))
        );

        simpleCSFRAX = new SimpleCToken(
            ICentralRegistry(address(centralRegistry)),
            IERC20(_SFRAX_ADDRESS),
            address(marketManagerIsolated)
        );

        // Price sFRAX using FRAX with PPS via StakedFraxAggregator
        StakedFraxAggregator sfrxAgg = new StakedFraxAggregator(
            _SFRAX_ADDRESS,
            _FRAX_ADDRESS,
            _CHAINLINK_FRAX_USD,
            "SFRAX"
        );
        chainlinkAdaptor.addAsset(
            _SFRAX_ADDRESS,
            true,
            address(sfrxAgg),
            0
        );
        oracleManager.addAssetPricingAdaptor(_SFRAX_ADDRESS, address(chainlinkAdaptor), 100, 50, 100, 50);
        oracleManager.addCTokenSupport(address(simpleCSFRAX));

        // Price FRAX
        chainlinkAdaptor.addAsset(
            _FRAX_ADDRESS,
            true,
            _CHAINLINK_FRAX_USD,
            0
        );
        oracleManager.addAssetPricingAdaptor(_FRAX_ADDRESS, address(chainlinkAdaptor), 100, 50, 100, 50);

        // Deploy borrowableCFRAX for no-swap tests
        borrowableCFRAX = _deployBorrowableCToken(_FRAX_ADDRESS);
        oracleManager.addCTokenSupport(address(borrowableCFRAX));
    }

    /// sFRAX/USDC TESTS (WITH SWAP) ///

    /// @notice Test leverage: borrow USDC -> swap to FRAX -> deposit into sFRAX
    function testLeverageWithSwap() public {
        _setUpMarketWithSwap();

        // User deposits sFRAX shares as collateral
        deal(_SFRAX_ADDRESS, user1, 500e18);

        vm.startPrank(user1);
        IERC20(_SFRAX_ADDRESS).approve(address(simpleCSFRAX), type(uint256).max);
        simpleCSFRAX.deposit(500e18, user1);
        simpleCSFRAX.postCollateral(500e18);

        // Borrow a small amount first to establish position
        borrowableCUSDC.borrow(50e6, user1);

        uint256 amountForLeverage = _maxRemainingLeverageOfHelper(
            user1,
            address(borrowableCUSDC)
        ) / 2;

        DualSidedVaultPositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCUSDC));
        leverageAction.borrowAssets = amountForLeverage;
        leverageAction.cToken = ICToken(address(simpleCSFRAX));
        leverageAction.swapAction.inputToken = address(usdc);
        leverageAction.swapAction.inputAmount = amountForLeverage;
        leverageAction.swapAction.outputToken = _FRAX_ADDRESS;
        leverageAction.swapAction.target = _UNISWAP_V3_SWAP_ROUTER;

        // Swap USDC to FRAX via Uniswap V3
        IUniswapV3Router.ExactInputParams memory params;
        params.path = abi.encodePacked(
            address(usdc),
            uint24(500),
            _FRAX_ADDRESS
        );
        params.recipient = address(positionManager);
        params.deadline = block.timestamp + 1 hours;
        params.amountIn = amountForLeverage;
        params.amountOutMinimum = 0;

        leverageAction.swapAction.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInput.selector,
            params
        );
        leverageAction.swapAction.slippage = 0.01e18;

        // Execute leverage
        positionManager.leverage(leverageAction, 0.01e18);

        AccountSnapshot memory debtSnap = borrowableCUSDC.getSnapshot(user1);
        AccountSnapshot memory collSnap = simpleCSFRAX.getSnapshot(user1);

        assertGt(debtSnap.debtBalance, 50e6, "Debt should increase after leverage");
        assertGt(collSnap.collateralPosted, 0, "Collateral should be posted");

        vm.stopPrank();
    }

    /// @notice Test depositAndLeverage: deposit sFRAX + borrow USDC -> swap to FRAX -> deposit into sFRAX
    function testDepositAndLeverageWithSwap() public {
        _setUpMarketWithSwap();

        vm.startPrank(user1);

        deal(_SFRAX_ADDRESS, user1, 500e18);
        IERC20(_SFRAX_ADDRESS).approve(address(positionManager), type(uint256).max);

        uint256 amountForLeverage = 800e6;

        DualSidedVaultPositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCUSDC));
        leverageAction.borrowAssets = amountForLeverage;
        leverageAction.cToken = ICToken(address(simpleCSFRAX));
        leverageAction.swapAction.inputToken = address(usdc);
        leverageAction.swapAction.inputAmount = amountForLeverage;
        leverageAction.swapAction.outputToken = _FRAX_ADDRESS;
        leverageAction.swapAction.target = _UNISWAP_V3_SWAP_ROUTER;

        IUniswapV3Router.ExactInputParams memory params;
        params.path = abi.encodePacked(
            address(usdc),
            uint24(500),
            _FRAX_ADDRESS
        );
        params.recipient = address(positionManager);
        params.deadline = block.timestamp + 1 hours;
        params.amountIn = amountForLeverage;
        params.amountOutMinimum = 0;

        leverageAction.swapAction.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInput.selector,
            params
        );
        leverageAction.swapAction.slippage = 0.01e18;

        positionManager.depositAndLeverage(500e18, leverageAction, 0.01e18);

        AccountSnapshot memory collSnap = simpleCSFRAX.getSnapshot(user1);
        AccountSnapshot memory debtSnap = borrowableCUSDC.getSnapshot(user1);

        assertGt(collSnap.collateralPosted, 0, "Collateral should be posted");
        assertGt(debtSnap.debtBalance, 0, "Debt should be incurred");

        vm.stopPrank();
    }

    /// @notice Test deleverage: redeem sFRAX -> receive FRAX -> swap to USDC -> repay loan
    function testDeleverageWithSwap() public {
        _setUpMarketWithSwap();

        // First establish a leveraged position
        deal(_SFRAX_ADDRESS, user1, 500e18);

        vm.startPrank(user1);
        IERC20(_SFRAX_ADDRESS).approve(address(simpleCSFRAX), type(uint256).max);
        simpleCSFRAX.deposit(500e18, user1);
        simpleCSFRAX.postCollateral(500e18);

        // Borrow USDC against sFRAX collateral
        borrowableCUSDC.borrow(200e6, user1);

        skip(20 minutes);
        borrowableCUSDC.accrueIfNeeded();

        AccountSnapshot memory debtBefore = borrowableCUSDC.getSnapshot(user1);
        AccountSnapshot memory collBefore = simpleCSFRAX.getSnapshot(user1);

        // Deleverage: redeem some sFRAX -> get FRAX -> swap to USDC -> repay
        uint256 repayAssets = debtBefore.debtBalance / 10; // repay 10% of loan
        // sFRAX shares to redeem (approximate, accounting for exchange rate)
        uint256 sFraxToRedeem = 25e18;

        DualSidedVaultPositionManager.DeleverageAction memory deleverageAction;
        deleverageAction.cToken = ICToken(address(simpleCSFRAX));
        deleverageAction.collateralAssets = sFraxToRedeem;
        deleverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCUSDC));
        deleverageAction.repayAssets = repayAssets;

        // Swap FRAX to USDC
        deleverageAction.swapActions = new SwapperLib.Swap[](1);
        deleverageAction.swapActions[0].inputToken = _FRAX_ADDRESS;
        deleverageAction.swapActions[0].inputAmount = sFraxToRedeem;
        deleverageAction.swapActions[0].outputToken = address(usdc);
        deleverageAction.swapActions[0].target = _UNISWAP_V3_SWAP_ROUTER;

        IUniswapV3Router.ExactInputParams memory params;
        params.path = abi.encodePacked(
            _FRAX_ADDRESS,
            uint24(500),
            address(usdc)
        );
        params.recipient = address(positionManager);
        params.deadline = block.timestamp + 1 hours;
        params.amountIn = sFraxToRedeem;
        params.amountOutMinimum = 0;

        deleverageAction.swapActions[0].call = abi.encodeWithSelector(
            IUniswapV3Router.exactInput.selector,
            params
        );
        deleverageAction.swapActions[0].slippage = 0.2e18;

        simpleCSFRAX.approve(address(positionManager), type(uint256).max);

        positionManager.deleverage(deleverageAction, 0.01e18);

        AccountSnapshot memory debtAfter = borrowableCUSDC.getSnapshot(user1);
        AccountSnapshot memory collAfter = simpleCSFRAX.getSnapshot(user1);

        assertLt(debtAfter.debtBalance, debtBefore.debtBalance, "Debt should be reduced after deleverage");
        assertLt(collAfter.collateralPosted, collBefore.collateralPosted, "Collateral should be reduced after deleverage");

        vm.stopPrank();
    }

    /// sFRAX/FRAX TESTS (NO SWAP) ///

    /// @notice Test leverage: borrow FRAX -> deposit into sFRAX (no swap needed)
    function testLeverageNoSwap() public {
        _setUpMarketNoSwap();

        // User deposits sFRAX shares as collateral
        deal(_SFRAX_ADDRESS, user1, 500e18);

        vm.startPrank(user1);
        IERC20(_SFRAX_ADDRESS).approve(address(simpleCSFRAX), type(uint256).max);
        simpleCSFRAX.deposit(500e18, user1);
        simpleCSFRAX.postCollateral(500e18);

        // Borrow a small amount first to establish position
        borrowableCFRAX.borrow(50e18, user1);

        uint256 amountForLeverage = _maxRemainingLeverageOfHelper(
            user1,
            address(borrowableCFRAX)
        ) / 2;

        DualSidedVaultPositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCFRAX));
        leverageAction.borrowAssets = amountForLeverage;
        leverageAction.cToken = ICToken(address(simpleCSFRAX));
        // No swap action needed - borrowed asset (FRAX) is the vault underlying

        // Execute leverage
        positionManager.leverage(leverageAction, 0.01e18);

        AccountSnapshot memory debtSnap = borrowableCFRAX.getSnapshot(user1);
        AccountSnapshot memory collSnap = simpleCSFRAX.getSnapshot(user1);

        assertGt(debtSnap.debtBalance, 50e18, "Debt should increase after leverage");
        assertGt(collSnap.collateralPosted, 0, "Collateral should be posted");

        vm.stopPrank();
    }

    /// @notice Test depositAndLeverage: deposit sFRAX + borrow FRAX -> deposit into sFRAX (no swap needed)
    function testDepositAndLeverageNoSwap() public {
        _setUpMarketNoSwap();

        vm.startPrank(user1);

        deal(_SFRAX_ADDRESS, user1, 500e18);
        IERC20(_SFRAX_ADDRESS).approve(address(positionManager), type(uint256).max);

        uint256 amountForLeverage = 800e18;

        DualSidedVaultPositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCFRAX));
        leverageAction.borrowAssets = amountForLeverage;
        leverageAction.cToken = ICToken(address(simpleCSFRAX));
        // No swap action needed

        positionManager.depositAndLeverage(500e18, leverageAction, 0.01e18);

        AccountSnapshot memory collSnap = simpleCSFRAX.getSnapshot(user1);
        AccountSnapshot memory debtSnap = borrowableCFRAX.getSnapshot(user1);

        assertGt(collSnap.collateralPosted, 0, "Collateral should be posted");
        assertGt(debtSnap.debtBalance, 0, "Debt should be incurred");

        vm.stopPrank();
    }

    /// @notice Test deleverage: redeem sFRAX -> receive FRAX -> repay loan (no swap needed)
    function testDeleverageNoSwap() public {
        _setUpMarketNoSwap();

        // First establish a leveraged position
        deal(_SFRAX_ADDRESS, user1, 500e18);

        vm.startPrank(user1);
        IERC20(_SFRAX_ADDRESS).approve(address(simpleCSFRAX), type(uint256).max);
        simpleCSFRAX.deposit(500e18, user1);
        simpleCSFRAX.postCollateral(500e18);

        // Borrow FRAX against sFRAX collateral
        borrowableCFRAX.borrow(200e18, user1);

        skip(20 minutes);
        borrowableCFRAX.accrueIfNeeded();

        AccountSnapshot memory debtBefore = borrowableCFRAX.getSnapshot(user1);
        AccountSnapshot memory collBefore = simpleCSFRAX.getSnapshot(user1);

        // Deleverage: redeem some sFRAX -> get FRAX -> repay (no swap)
        uint256 repayAssets = debtBefore.debtBalance / 10; // repay 10% of loan
        uint256 sFraxToRedeem = 25e18;

        DualSidedVaultPositionManager.DeleverageAction memory deleverageAction;
        deleverageAction.cToken = ICToken(address(simpleCSFRAX));
        deleverageAction.collateralAssets = sFraxToRedeem;
        deleverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCFRAX));
        deleverageAction.repayAssets = repayAssets;
        // No swap actions needed - redeemed asset (FRAX) is the debt asset

        simpleCSFRAX.approve(address(positionManager), type(uint256).max);

        positionManager.deleverage(deleverageAction, 0.01e18);

        AccountSnapshot memory debtAfter = borrowableCFRAX.getSnapshot(user1);
        AccountSnapshot memory collAfter = simpleCSFRAX.getSnapshot(user1);

        assertLt(debtAfter.debtBalance, debtBefore.debtBalance, "Debt should be reduced after deleverage");
        assertLt(collAfter.collateralPosted, collBefore.collateralPosted, "Collateral should be reduced after deleverage");

        vm.stopPrank();
    }

    /// DELEVERAGE FAIL TESTS ///

    /// @notice Test deleverage fails when collateralAssets is zero
    function test_Deleverage_fail_whenZeroCollateralAssets() public {
        _setUpMarketWithSwap();

        deal(_SFRAX_ADDRESS, user1, 500e18);

        vm.startPrank(user1);
        IERC20(_SFRAX_ADDRESS).approve(address(simpleCSFRAX), type(uint256).max);
        simpleCSFRAX.deposit(500e18, user1);
        simpleCSFRAX.postCollateral(500e18);
        borrowableCUSDC.borrow(200e6, user1);

        DualSidedVaultPositionManager.DeleverageAction memory deleverageAction;
        deleverageAction.cToken = ICToken(address(simpleCSFRAX));
        deleverageAction.collateralAssets = 0; // zero collateral
        deleverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCUSDC));
        deleverageAction.repayAssets = 20e6;

        simpleCSFRAX.approve(address(positionManager), type(uint256).max);

        vm.expectRevert(BaseCToken.BaseCToken__ZeroAmount.selector);
        positionManager.deleverage(deleverageAction, 0.01e18);

        vm.stopPrank();
    }

    /// @notice Test deleverage fails when swapActions length is not 1 (when swap is needed)
    function test_Deleverage_fail_whenSwapActionsLengthNotOne() public {
        _setUpMarketWithSwap();

        deal(_SFRAX_ADDRESS, user1, 500e18);

        vm.startPrank(user1);
        IERC20(_SFRAX_ADDRESS).approve(address(simpleCSFRAX), type(uint256).max);
        simpleCSFRAX.deposit(500e18, user1);
        simpleCSFRAX.postCollateral(500e18);
        borrowableCUSDC.borrow(200e6, user1);

        uint256 sFraxToRedeem = 25e18;

        DualSidedVaultPositionManager.DeleverageAction memory deleverageAction;
        deleverageAction.cToken = ICToken(address(simpleCSFRAX));
        deleverageAction.collateralAssets = sFraxToRedeem;
        deleverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCUSDC));
        deleverageAction.repayAssets = 20e6;
        // No swapActions provided (length 0), but swap is needed since FRAX != USDC

        simpleCSFRAX.approve(address(positionManager), type(uint256).max);

        vm.expectRevert(BasePositionManager.BasePositionManager__InvalidParam.selector);
        positionManager.deleverage(deleverageAction, 0.01e18);

        vm.stopPrank();
    }

    /// @notice Test deleverage fails when swap call is empty
    function test_Deleverage_fail_whenSwapCallEmpty() public {
        _setUpMarketWithSwap();

        deal(_SFRAX_ADDRESS, user1, 500e18);

        vm.startPrank(user1);
        IERC20(_SFRAX_ADDRESS).approve(address(simpleCSFRAX), type(uint256).max);
        simpleCSFRAX.deposit(500e18, user1);
        simpleCSFRAX.postCollateral(500e18);
        borrowableCUSDC.borrow(200e6, user1);

        uint256 sFraxToRedeem = 25e18;

        DualSidedVaultPositionManager.DeleverageAction memory deleverageAction;
        deleverageAction.cToken = ICToken(address(simpleCSFRAX));
        deleverageAction.collateralAssets = sFraxToRedeem;
        deleverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCUSDC));
        deleverageAction.repayAssets = 20e6;

        deleverageAction.swapActions = new SwapperLib.Swap[](1);
        deleverageAction.swapActions[0].inputToken = _FRAX_ADDRESS;
        deleverageAction.swapActions[0].inputAmount = sFraxToRedeem;
        deleverageAction.swapActions[0].outputToken = address(usdc);
        deleverageAction.swapActions[0].target = _UNISWAP_V3_SWAP_ROUTER;
        deleverageAction.swapActions[0].call = ""; // empty call

        simpleCSFRAX.approve(address(positionManager), type(uint256).max);

        vm.expectRevert(BasePositionManager.BasePositionManager__InvalidParam.selector);
        positionManager.deleverage(deleverageAction, 0.01e18);

        vm.stopPrank();
    }

    /// @notice Test deleverage fails when swap target is zero
    function test_Deleverage_fail_whenSwapTargetZero() public {
        _setUpMarketWithSwap();

        deal(_SFRAX_ADDRESS, user1, 500e18);

        vm.startPrank(user1);
        IERC20(_SFRAX_ADDRESS).approve(address(simpleCSFRAX), type(uint256).max);
        simpleCSFRAX.deposit(500e18, user1);
        simpleCSFRAX.postCollateral(500e18);
        borrowableCUSDC.borrow(200e6, user1);

        uint256 sFraxToRedeem = 25e18;

        DualSidedVaultPositionManager.DeleverageAction memory deleverageAction;
        deleverageAction.cToken = ICToken(address(simpleCSFRAX));
        deleverageAction.collateralAssets = sFraxToRedeem;
        deleverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCUSDC));
        deleverageAction.repayAssets = 20e6;

        deleverageAction.swapActions = new SwapperLib.Swap[](1);
        deleverageAction.swapActions[0].inputToken = _FRAX_ADDRESS;
        deleverageAction.swapActions[0].inputAmount = sFraxToRedeem;
        deleverageAction.swapActions[0].outputToken = address(usdc);
        deleverageAction.swapActions[0].target = address(0); // zero target
        deleverageAction.swapActions[0].call = hex"deadbeef";

        simpleCSFRAX.approve(address(positionManager), type(uint256).max);

        vm.expectRevert(BasePositionManager.BasePositionManager__InvalidParam.selector);
        positionManager.deleverage(deleverageAction, 0.01e18);

        vm.stopPrank();
    }

    /// @notice Test deleverage fails when input token doesn't match vault underlying
    function test_Deleverage_fail_whenInvalidInputToken() public {
        _setUpMarketWithSwap();

        deal(_SFRAX_ADDRESS, user1, 500e18);

        vm.startPrank(user1);
        IERC20(_SFRAX_ADDRESS).approve(address(simpleCSFRAX), type(uint256).max);
        simpleCSFRAX.deposit(500e18, user1);
        simpleCSFRAX.postCollateral(500e18);
        borrowableCUSDC.borrow(200e6, user1);

        uint256 sFraxToRedeem = 25e18;

        DualSidedVaultPositionManager.DeleverageAction memory deleverageAction;
        deleverageAction.cToken = ICToken(address(simpleCSFRAX));
        deleverageAction.collateralAssets = sFraxToRedeem;
        deleverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCUSDC));
        deleverageAction.repayAssets = 20e6;

        deleverageAction.swapActions = new SwapperLib.Swap[](1);
        deleverageAction.swapActions[0].inputToken = address(usdc); // wrong - should be FRAX
        deleverageAction.swapActions[0].inputAmount = sFraxToRedeem;
        deleverageAction.swapActions[0].outputToken = address(usdc);
        deleverageAction.swapActions[0].target = _UNISWAP_V3_SWAP_ROUTER;
        deleverageAction.swapActions[0].call = hex"deadbeef";

        simpleCSFRAX.approve(address(positionManager), type(uint256).max);

        vm.expectRevert(BasePositionManager.BasePositionManager__InvalidParam.selector);
        positionManager.deleverage(deleverageAction, 0.01e18);

        vm.stopPrank();
    }

    /// @notice Test deleverage fails when output token doesn't match debt asset
    function test_Deleverage_fail_whenInvalidOutputToken() public {
        _setUpMarketWithSwap();

        deal(_SFRAX_ADDRESS, user1, 500e18);

        vm.startPrank(user1);
        IERC20(_SFRAX_ADDRESS).approve(address(simpleCSFRAX), type(uint256).max);
        simpleCSFRAX.deposit(500e18, user1);
        simpleCSFRAX.postCollateral(500e18);
        borrowableCUSDC.borrow(200e6, user1);

        uint256 sFraxToRedeem = 25e18;

        DualSidedVaultPositionManager.DeleverageAction memory deleverageAction;
        deleverageAction.cToken = ICToken(address(simpleCSFRAX));
        deleverageAction.collateralAssets = sFraxToRedeem;
        deleverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCUSDC));
        deleverageAction.repayAssets = 20e6;

        deleverageAction.swapActions = new SwapperLib.Swap[](1);
        deleverageAction.swapActions[0].inputToken = _FRAX_ADDRESS;
        deleverageAction.swapActions[0].inputAmount = sFraxToRedeem;
        deleverageAction.swapActions[0].outputToken = _FRAX_ADDRESS; // wrong - should be USDC
        deleverageAction.swapActions[0].target = _UNISWAP_V3_SWAP_ROUTER;
        deleverageAction.swapActions[0].call = hex"deadbeef";

        simpleCSFRAX.approve(address(positionManager), type(uint256).max);

        vm.expectRevert(BasePositionManager.BasePositionManager__InvalidParam.selector);
        positionManager.deleverage(deleverageAction, 0.01e18);

        vm.stopPrank();
    }

    /// INTERNAL HELPERS ///

    function _setUpMarketWithSwap() internal {
        _prepareUSDC(address(this), 100e6);
        usdc.approve(address(borrowableCUSDC), 77777);

        deal(_SFRAX_ADDRESS, address(this), 77777);
        IERC20(_SFRAX_ADDRESS).approve(address(simpleCSFRAX), 77777);

        marketManagerIsolated.listTokens(address(simpleCSFRAX), address(borrowableCUSDC));

        _setCTokenConfigBasic(address(simpleCSFRAX), 1_000_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 1_000_000e6, 1_000_000e6);

        positionManager = new DualSidedVaultPositionManager(
            ICentralRegistry(address(centralRegistry)),
            address(marketManagerIsolated),
            _WETH_ADDRESS
        );
        marketManagerIsolated.addPositionManager(address(positionManager));

        // Provide USDC liquidity for borrowing
        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareUSDC(liquidityProvider, 1_000_000e6);
        vm.startPrank(liquidityProvider);
        usdc.approve(address(borrowableCUSDC), type(uint256).max);
        borrowableCUSDC.deposit(1_000_000e6, liquidityProvider);
        vm.stopPrank();
    }

    function _setUpMarketNoSwap() internal {
        deal(_FRAX_ADDRESS, address(this), 77777);
        IERC20(_FRAX_ADDRESS).approve(address(borrowableCFRAX), 77777);

        deal(_SFRAX_ADDRESS, address(this), 77777);
        IERC20(_SFRAX_ADDRESS).approve(address(simpleCSFRAX), 77777);

        marketManagerIsolated.listTokens(address(simpleCSFRAX), address(borrowableCFRAX));

        _setCTokenConfigBasic(address(simpleCSFRAX), 1_000_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCFRAX), 1_000_000e18, 1_000_000e18);

        positionManager = new DualSidedVaultPositionManager(
            ICentralRegistry(address(centralRegistry)),
            address(marketManagerIsolated),
            _WETH_ADDRESS
        );
        marketManagerIsolated.addPositionManager(address(positionManager));

        // Provide FRAX liquidity for borrowing
        address liquidityProvider = makeAddr("liquidityProvider");
        deal(_FRAX_ADDRESS, liquidityProvider, 1_000_000e18);
        vm.startPrank(liquidityProvider);
        IERC20(_FRAX_ADDRESS).approve(address(borrowableCFRAX), type(uint256).max);
        borrowableCFRAX.deposit(1_000_000e18, liquidityProvider);
        vm.stopPrank();
    }
}
