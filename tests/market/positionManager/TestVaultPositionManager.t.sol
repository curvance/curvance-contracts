// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { VaultPositionManager } from "contracts/market/position-management/VaultPositionManager.sol";
import { SimpleCToken } from "contracts/market/token/SimpleCToken.sol";
import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { ICToken, AccountSnapshot } from "contracts/interfaces/ICToken.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IVault } from "contracts/interfaces/IVault.sol";
import { IUniswapV3Router } from "contracts/interfaces/external/uniswap/IUniswapV3Router.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { console2 } from "forge-std/console2.sol";

/// Test suite is set into two parts:
/// 1. Test leverage and deleverage operations with SimpleCSFRAX and borrowableCUSDC
///    where sFRAX is collateralized against USDC debt, which includes swaps.
/// 2. Test leverage and deleverage operations with SimpleCSFRAX and borrowableCFRAX
///    where FRAX is collateralized against sFRAX, while also being the underlying asset, and not including swaps.

contract TestVaultPositionManager is TestBaseMarketIsolated {

    VaultPositionManager public positionManager;

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

        // Price sFRAX using FRAX/USD
        chainlinkAdaptor.addAsset(
            _SFRAX_ADDRESS,
            true,
            _CHAINLINK_FRAX_USD,
            0
        );

        oracleManager.addAssetPriceFeed(_SFRAX_ADDRESS, address(chainlinkAdaptor));
        oracleManager.addCTokenSupport(address(simpleCSFRAX));

        // Price FRAX
        chainlinkAdaptor.addAsset(
            _FRAX_ADDRESS,
            true,
            _CHAINLINK_FRAX_USD,
            0
        );
        oracleManager.addAssetPriceFeed(_FRAX_ADDRESS, address(chainlinkAdaptor));

        borrowableCFRAX = _deployBorrowableCToken(_FRAX_ADDRESS);
        oracleManager.addCTokenSupport(address(borrowableCFRAX));

    }

    /// Borrowed asset: USDC ///

    function testLeverage_BorrowedDifferentFromUnderlying() public {
        _setUpCSFRAX_USDCPool();

        // User deposits sFRAX shares as collateral
        deal(_SFRAX_ADDRESS, user1, 500e18);

        vm.startPrank(user1);
        IERC20(_SFRAX_ADDRESS).approve(address(simpleCSFRAX), type(uint256).max);
        uint256 depositShares = 500e18;
        simpleCSFRAX.deposit(depositShares, user1);
        simpleCSFRAX.postCollateral(depositShares);

        // borrow a small amount first
        vm.startPrank(user1);
        borrowableCUSDC.borrow(50e6, user1);

        uint256 amountForLeverage = positionManager.maxRemainingLeverageOf(
            user1,
            address(borrowableCUSDC)
        ) / 2;

        console2.log("amountForLeverage", amountForLeverage);

        VaultPositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCUSDC));
        leverageAction.borrowAssets = amountForLeverage;
        leverageAction.cToken = ICToken(address(simpleCSFRAX));
        leverageAction.swapAction.inputToken = address(usdc);
        leverageAction.swapAction.inputAmount = amountForLeverage;
        leverageAction.swapAction.outputToken = _FRAX_ADDRESS;
        leverageAction.swapAction.target = _UNISWAP_V3_SWAP_ROUTER;

        // Swap USDC to FRAX using USDC/FRAX pool with 0.5% slippage
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
        leverageAction.swapAction.slippage = 0.5e18;

        // Execute leverage
        positionManager.leverage(leverageAction, 0.5e18);

        AccountSnapshot memory debtSnap = borrowableCUSDC.getSnapshot(user1);
        AccountSnapshot memory collSnap = simpleCSFRAX.getSnapshot(user1);

        assertGt(debtSnap.debtBalance, 50e6, "Debt should increase after leverage");
        assertGt(collSnap.collateralPosted, 0, "Collateral should be posted");

        vm.stopPrank();
    }

    function testDepositAndLeverage_BorrowedDifferentFromUnderlying() public {
        _setUpCSFRAX_USDCPool();
        
        vm.startPrank(user1);

        deal(_SFRAX_ADDRESS, user1, 500e18);
        IERC20(_SFRAX_ADDRESS).approve(address(positionManager), type(uint256).max);

        // Set position manager as delegate
        simpleCSFRAX.setDelegateApproval(address(positionManager), true);

        uint256 amountForLeverage = 800e6;

        VaultPositionManager.LeverageAction memory leverageAction;
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
        leverageAction.swapAction.slippage = 0.5e18;

        positionManager.depositAndLeverage(500e18, leverageAction, 0.05e18);

        AccountSnapshot memory collSnap = simpleCSFRAX.getSnapshot(user1);
        AccountSnapshot memory debtSnap = borrowableCUSDC.getSnapshot(user1);

        assertGt(collSnap.collateralPosted, 0, "Collateral should be posted");
        assertGt(debtSnap.debtBalance, 0, "Debt should be incurred");

        vm.stopPrank();
    }

    function testDeleverage_BorrowedDifferentFromUnderlying() public {

        // First create a leveraged position
        testLeverage_BorrowedDifferentFromUnderlying();

        // Cooldown and accrue
        vm.warp(block.timestamp + 20 minutes);
        borrowableCUSDC.accrueIfNeeded();

        vm.startPrank(user1);

        AccountSnapshot memory debtBefore = borrowableCUSDC.getSnapshot(user1);
        AccountSnapshot memory collBefore = simpleCSFRAX.getSnapshot(user1);

        // Deleverage: redeem sFRAX shares and swap FRAX -> USDC to repay part of debt
        VaultPositionManager.DeleverageAction memory deleverageAction;
        deleverageAction.cToken = ICToken(address(simpleCSFRAX));
        // redeem a modest portion to avoid large price impact in tests
        deleverageAction.collateralAssets = collBefore.collateralPosted / 10;
        deleverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCUSDC));
        // target a small, safe repayment in USDC units (6 decimals)
        deleverageAction.repayAssets = 1_000_000; // 1 USDC

        // Determine exact FRAX amount we will swap using vault preview
        uint256 expectedFRAXAmount = IVault(_SFRAX_ADDRESS).previewRedeem(
            deleverageAction.collateralAssets
        );

        // Build swap actions FRAX -> USDC using 0.05% pool
        deleverageAction.swapActions = new SwapperLib.Swap[](1);
        deleverageAction.swapActions[0].inputToken = _FRAX_ADDRESS;
        deleverageAction.swapActions[0].inputAmount = expectedFRAXAmount;
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
        params.amountIn = expectedFRAXAmount;
        params.amountOutMinimum = 0;

        deleverageAction.swapActions[0].call = abi.encodeWithSelector(
            IUniswapV3Router.exactInput.selector,
            params
        );
        deleverageAction.swapActions[0].slippage = 0.5e18;

        // Approve PM to move user's collateral shares if required by token logic
        simpleCSFRAX.approve(address(positionManager), type(uint256).max);

        positionManager.deleverage(deleverageAction, 0.5e18);

        AccountSnapshot memory debtAfter = borrowableCUSDC.getSnapshot(user1);
        AccountSnapshot memory collAfter = simpleCSFRAX.getSnapshot(user1);

        assertLt(
            debtAfter.debtBalance,
            debtBefore.debtBalance,
            "Debt should be reduced after deleverage"
        );
        assertLt(
            collAfter.collateralPosted,
            collBefore.collateralPosted,
            "Collateral should be reduced after deleverage"
        );

        vm.stopPrank();
    }

    /// Borrowed asset: FRAX ///

    function testLeverage_BorrowedSameAsUnderlying() public {
        _setUpCSFRAX_FRAXPool();

        // User deposits sFRAX shares as collateral
        deal(_SFRAX_ADDRESS, user1, 500e18);

        vm.startPrank(user1);
        IERC20(_SFRAX_ADDRESS).approve(address(simpleCSFRAX), type(uint256).max);
        uint256 depositShares = 500e18;
        simpleCSFRAX.deposit(depositShares, user1);
        simpleCSFRAX.postCollateral(depositShares);

        // borrow a small amount first
        vm.startPrank(user1);
        borrowableCFRAX.borrow(50e18, user1);

        uint256 amountForLeverage = positionManager.maxRemainingLeverageOf(
            user1,
            address(borrowableCUSDC)
        ) / 2;

        console2.log("amountForLeverage", amountForLeverage);

        VaultPositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCFRAX));
        leverageAction.borrowAssets = amountForLeverage;
        leverageAction.cToken = ICToken(address(simpleCSFRAX));

        // Execute leverage
        positionManager.leverage(leverageAction, 0.5e18);

        AccountSnapshot memory debtSnap = borrowableCFRAX.getSnapshot(user1);
        AccountSnapshot memory collSnap = simpleCSFRAX.getSnapshot(user1);

        assertGt(debtSnap.debtBalance, 50e6, "Debt should increase after leverage");
        assertGt(collSnap.collateralPosted, 0, "Collateral should be posted");

        vm.stopPrank();
    }

    function testDepositAndLeverage_BorrowedSameAsUnderlying() public {
        _setUpCSFRAX_FRAXPool();

        vm.startPrank(user1);

        deal(_SFRAX_ADDRESS, user1, 500e18);
        IERC20(_SFRAX_ADDRESS).approve(address(positionManager), type(uint256).max);

        simpleCSFRAX.setDelegateApproval(address(positionManager), true);

        uint256 amountForLeverage = 800e18;

        VaultPositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCFRAX));
        leverageAction.borrowAssets = amountForLeverage;
        leverageAction.cToken = ICToken(address(simpleCSFRAX));

        positionManager.depositAndLeverage(500e18, leverageAction, 0.05e18);

        AccountSnapshot memory collSnap = simpleCSFRAX.getSnapshot(user1);
        AccountSnapshot memory debtSnap = borrowableCFRAX.getSnapshot(user1);

        assertGt(collSnap.collateralPosted, 0, "Collateral should be posted");
        assertGt(debtSnap.debtBalance, 0, "Debt should be incurred");

        vm.stopPrank();
    }

    function testDeleverage_BorrowedSameAsUnderlying() public {

        testLeverage_BorrowedSameAsUnderlying();

        vm.warp(block.timestamp + 20 minutes);
        borrowableCFRAX.accrueIfNeeded();

        vm.startPrank(user1);

        AccountSnapshot memory debtBefore = borrowableCFRAX.getSnapshot(user1);
        AccountSnapshot memory collBefore = simpleCSFRAX.getSnapshot(user1);

        VaultPositionManager.DeleverageAction memory deleverageAction;
        deleverageAction.cToken = ICToken(address(simpleCSFRAX));

        uint256 collateralShares = collBefore.collateralPosted / 2;
        deleverageAction.collateralAssets = collateralShares;

        deleverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCFRAX));

        deleverageAction.repayAssets = debtBefore.debtBalance;

        simpleCSFRAX.approve(address(positionManager), type(uint256).max);

        positionManager.deleverage(deleverageAction, 0.5e18);

        AccountSnapshot memory debtAfter = borrowableCFRAX.getSnapshot(user1);
        AccountSnapshot memory collAfter = simpleCSFRAX.getSnapshot(user1);

        assertLt(debtAfter.debtBalance, debtBefore.debtBalance, "Debt should be reduced after deleverage");
        assertLt(collAfter.collateralPosted, collBefore.collateralPosted, "Collateral should be reduced after deleverage");

        vm.stopPrank();
    }

    /// Market setups ///

    function _setUpCSFRAX_USDCPool() internal {
        _prepareUSDC(address(this), 100e6);
        usdc.approve(address(borrowableCUSDC), 77777);

        deal(_SFRAX_ADDRESS, address(this), 77777);
        IERC20(_SFRAX_ADDRESS).approve(address(simpleCSFRAX), 77777);

        marketManagerIsolated.listTokens(address(simpleCSFRAX), address(borrowableCUSDC));

        _setCTokenConfigBasic(address(simpleCSFRAX), 1_000_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 1_000_000e6, 1_000_000e6);

        positionManager = new VaultPositionManager(
            ICentralRegistry(address(centralRegistry)),
            address(marketManagerIsolated),
            _WETH_ADDRESS
        );
        marketManagerIsolated.addPositionManager(address(positionManager));

        // Provide liquidity
        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareUSDC(liquidityProvider, 1_000_000e6);
        vm.startPrank(liquidityProvider);
        usdc.approve(address(borrowableCUSDC), type(uint256).max);
        borrowableCUSDC.deposit(1_000_000e6, liquidityProvider);
        vm.stopPrank();
    }

    function _setUpCSFRAX_FRAXPool() internal {
        deal(_FRAX_ADDRESS, address(this), 77777);
        IERC20(_FRAX_ADDRESS).approve(address(borrowableCFRAX), 77777);

        deal(_SFRAX_ADDRESS, address(this), 77777);
        IERC20(_SFRAX_ADDRESS).approve(address(simpleCSFRAX), 77777);

        marketManagerIsolated.listTokens(address(simpleCSFRAX), address(borrowableCFRAX));

        _setCTokenConfigBasic(address(simpleCSFRAX), 1_000_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCFRAX), 1_000_000e18, 1_000_000e18);

        positionManager = new VaultPositionManager(
            ICentralRegistry(address(centralRegistry)),
            address(marketManagerIsolated),
            _WETH_ADDRESS
        );
        marketManagerIsolated.addPositionManager(address(positionManager));

        // Provide liquidity
        address liquidityProvider = makeAddr("liquidityProvider");
        deal(_FRAX_ADDRESS, liquidityProvider, 1_000_000e18);
        vm.startPrank(liquidityProvider);
        IERC20(_FRAX_ADDRESS).approve(address(borrowableCFRAX), type(uint256).max);
        borrowableCFRAX.deposit(1_000_000e18, liquidityProvider);
        vm.stopPrank();
    }
}
