// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { EarnAUSDVaultPositionManager } from "contracts/market/position-management/EarnAUSDPositionManager.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { ICToken } from "contracts/interfaces/ICToken.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IEarnAUSDVault } from "contracts/interfaces/external/Upshift/IEarnAUSDVault.sol";
import { IChainlink } from "contracts/interfaces/external/chainlink/IChainlink.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

/// @dev Minimal interface to query oracle adaptor asset config
interface IOracleAdaptor {
    function assetConfig(address asset, bool inUSD) external view returns (
        bool isConfigured,
        IChainlink aggregatorProxy,
        uint8 decimals,
        uint24 heartbeat
    );
}

contract TestEarnAUSDPositionManager is TestBaseMarketIsolated {

    EarnAUSDVaultPositionManager public positionManager;

    // Live addresses for Monad mainnet
    MarketManagerIsolated public marketManager = MarketManagerIsolated(0xd6365555f6a697C7C295bA741100AA644cE28545);
    BorrowableCToken public cEarnAUSD = BorrowableCToken(0x852FF1EC21D63b405eC431e04AE3AC760e29263D);
    BorrowableCToken public cAUSD = BorrowableCToken(0xAd4AA2a713fB86FBb6b60dE2aF9E32a11DB6Abf2);

    address public AUSD = 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a;
    address public EARN_AUSD_VAULT = 0x36eDbF0C834591BFdfCaC0Ef9605528c75c406aA;
    address public EARN_AUSD_RECEIPT_TOKEN = 0x103222f020e98Bba0AD9809A011FDF8e6F067496;
    address public WMON = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;

    address public liveCentralRegistry = 0x1310f352f1389969Ece6741671c4B919523912fF;

    // KyberSwap router
    address public kyberSwapRouter = 0x6131B5fae19EA4f9D964eAc0408E4408b66337b5;

    uint256 public user1AUSDBalance;
    uint256 public user1EarnAUSDBalance;

    function setUp() public override {
        vm.createSelectFork(vm.envString("MON_NODE_URI_MONAD_MAINNET"));

        positionManager = new EarnAUSDVaultPositionManager(
            ICentralRegistry(liveCentralRegistry),
            address(marketManager),
            WMON,
            AUSD,
            EARN_AUSD_VAULT,
            EARN_AUSD_RECEIPT_TOKEN
        );

        // Use emergencyCouncil which has market permissions on the live deployment
        address emergencyCouncil = ICentralRegistry(liveCentralRegistry).emergencyCouncil();

        vm.prank(emergencyCouncil);
        marketManager.addPositionManager(address(positionManager));

        // Acquire AUSD and earnAUSD once via Kyber swap (AUSD has weird storage, can't deal directly)
        // Swap everything in setUp so we dont have to call the api 10,000 times for each test.
        uint256 wmonAmount = 100_000e18;
        deal(WMON, user1, wmonAmount);

        vm.startPrank(user1);
        IERC20(WMON).approve(kyberSwapRouter, wmonAmount);

        bytes memory swapCalldata = _getKyberCalldata(
            block.chainid,
            WMON,
            AUSD,
            wmonAmount,
            user1,
            500 // 5% slippage
        );

        (bool success,) = kyberSwapRouter.call(swapCalldata);
        require(success, "KyberSwap WMON->AUSD failed in setUp");

        user1AUSDBalance = IERC20(AUSD).balanceOf(user1);

        assertGt(user1AUSDBalance, 0, "User should have AUSD balance");

        // Convert half to earnAUSD
        uint256 ausdToDeposit = user1AUSDBalance / 2;
        IERC20(AUSD).approve(EARN_AUSD_VAULT, ausdToDeposit);
        user1EarnAUSDBalance = IEarnAUSDVault(EARN_AUSD_VAULT).deposit(AUSD, ausdToDeposit, user1);

        // Update remaining AUSD balance
        user1AUSDBalance = IERC20(AUSD).balanceOf(user1);

        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_constructor_setsImmutablesCorrectly() public view {
        assertEq(positionManager.AUSD(), AUSD);
        assertEq(positionManager.earnAUSDVault(), EARN_AUSD_VAULT);
        assertEq(positionManager.earnAUSDReceiptToken(), EARN_AUSD_RECEIPT_TOKEN);
    }

    function test_constructor_revertsOnInvalidVault() public {
        // Deploy with a vault that doesn't have mint/burn permissions
        address fakeVault = makeAddr("fakeVault");
        
        vm.expectRevert(EarnAUSDVaultPositionManager.EarnAUSDPositionManager__InvalidVault.selector);
        new EarnAUSDVaultPositionManager(
            ICentralRegistry(liveCentralRegistry),
            address(marketManager),
            WMON,
            AUSD,
            fakeVault,
            EARN_AUSD_RECEIPT_TOKEN
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // LEVERAGE TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_leverage_depositEarnAUSDAsBorrowCollateral() public {
        // Use pre-acquired earnAUSD from setUp
        uint256 earnAUSDAmount = user1EarnAUSDBalance / 4;

        // Deposit earnAUSD as collateral into cEarnAUSD
        vm.startPrank(user1);
        IERC20(EARN_AUSD_RECEIPT_TOKEN).approve(address(cEarnAUSD), earnAUSDAmount);
        cEarnAUSD.depositAsCollateral(earnAUSDAmount, user1);
        vm.stopPrank();

        uint256 collateralPosted = cEarnAUSD.collateralPosted(user1);
        assertGt(collateralPosted, 0, "Should have collateral posted");
    }

    function test_leverage_borrowAUSDAgainstEarnAUSD() public {
        // Use pre-acquired earnAUSD from setUp
        uint256 earnAUSDAmount = user1EarnAUSDBalance / 4;

        vm.startPrank(user1);
        IERC20(EARN_AUSD_RECEIPT_TOKEN).approve(address(cEarnAUSD), earnAUSDAmount);
        cEarnAUSD.depositAsCollateral(earnAUSDAmount, user1);

        // Check if we can borrow (need liquidity in cAUSD)
        uint256 ausdLiquidity = IERC20(AUSD).balanceOf(address(cAUSD));
        console2.log("AUSD liquidity in cAUSD:", ausdLiquidity);

        if (ausdLiquidity > 0) {
            // Attempt small borrow (AUSD has 6 decimals)
            uint256 borrowAmount = ausdLiquidity > 100e6 ? 100e6 : ausdLiquidity / 2;

            uint256 ausdBefore = IERC20(AUSD).balanceOf(user1);
            cAUSD.borrow(borrowAmount, user1);
            uint256 ausdAfter = IERC20(AUSD).balanceOf(user1);

            assertEq(ausdAfter - ausdBefore, borrowAmount, "Should receive borrowed AUSD");
        }

        vm.stopPrank();
    }

    function test_leverage_withPositionManager() public {
        // Use pre-acquired earnAUSD from setUp
        uint256 earnAUSDAmount = user1EarnAUSDBalance / 4;

        vm.startPrank(user1);
        IERC20(EARN_AUSD_RECEIPT_TOKEN).approve(address(cEarnAUSD), earnAUSDAmount);
        cEarnAUSD.depositAsCollateral(earnAUSDAmount, user1);
        
        uint256 collateralBefore = cEarnAUSD.balanceOf(user1);
        uint256 debtBefore = cAUSD.debtBalance(user1);
        
        // Prepare leverage action: borrow AUSD -> deposit into vault -> get more earnAUSD
        uint256 borrowAmount = 500e6;
        
        EarnAUSDVaultPositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken = IBorrowableCToken(address(cAUSD));
        leverageAction.borrowAssets = borrowAmount;
        leverageAction.cToken = ICToken(address(cEarnAUSD));
        
        // For EarnAUSD vault, no swap needed when borrowing AUSD to deposit into vault
        // The SingleSidedVaultPositionManager handles this case
        leverageAction.swapAction.inputToken = AUSD;
        leverageAction.swapAction.inputAmount = borrowAmount;
        leverageAction.swapAction.outputToken = AUSD; // Same token, no swap needed
        leverageAction.swapAction.call = ""; // Empty call means direct deposit
        leverageAction.swapAction.target = address(0);
        
        positionManager.leverage(leverageAction, 0.5e18);
        vm.stopPrank();
        
        uint256 collateralAfter = cEarnAUSD.balanceOf(user1);
        uint256 debtAfter = cAUSD.debtBalance(user1);
        
        assertGt(collateralAfter, collateralBefore, "Collateral should increase after leverage");
        assertEq(debtBefore, 0, "Should start with no debt");
        assertEq(debtAfter, borrowAmount, "Debt should equal borrowed amount");
    }

    function test_earnAUSDPositionManager_depositAndLeverage() public {
        // Use pre-acquired earnAUSD from setUp for initial deposit
        uint256 initialDeposit = user1EarnAUSDBalance / 8;

        vm.startPrank(user1);

        // Approve position manager to transfer earnAUSD for the initial deposit
        IERC20(EARN_AUSD_RECEIPT_TOKEN).approve(address(positionManager), initialDeposit);

        uint256 collateralBefore = cEarnAUSD.balanceOf(user1);
        uint256 debtBefore = cAUSD.debtBalance(user1);

        // Prepare leverage action: borrow AUSD -> deposit into vault -> get more earnAUSD
        uint256 borrowAmount = 500e6;

        EarnAUSDVaultPositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken = IBorrowableCToken(address(cAUSD));
        leverageAction.borrowAssets = borrowAmount;
        leverageAction.cToken = ICToken(address(cEarnAUSD));

        // For EarnAUSD vault, no swap needed when borrowing AUSD to deposit into vault
        // The SingleSidedVaultPositionManager handles this case (debtAsset == underlying)
        leverageAction.swapAction.inputToken = AUSD;
        leverageAction.swapAction.inputAmount = borrowAmount;
        leverageAction.swapAction.outputToken = AUSD; // Same token, no swap needed
        leverageAction.swapAction.call = ""; // Empty call means direct deposit
        leverageAction.swapAction.target = address(0);

        positionManager.depositAndLeverage(initialDeposit, leverageAction, 0.5e18);
        vm.stopPrank();

        uint256 collateralAfter = cEarnAUSD.balanceOf(user1);
        uint256 debtAfter = cAUSD.debtBalance(user1);

        assertGt(collateralAfter, collateralBefore, "Collateral should increase after depositAndLeverage");
        assertEq(debtBefore, 0, "Should start with no debt");
        assertEq(debtAfter, borrowAmount, "Debt should equal borrowed amount");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DELEVERAGE TESTS  
    // ═══════════════════════════════════════════════════════════════════════════

    function test_deleverage_swapEarnAUSDForDebtAsset() public {
        // Use pre-acquired earnAUSD from setUp
        uint256 earnAUSDAmount = user1EarnAUSDBalance / 4;

        vm.startPrank(user1);
        IERC20(EARN_AUSD_RECEIPT_TOKEN).approve(address(cEarnAUSD), earnAUSDAmount);
        cEarnAUSD.depositAsCollateral(earnAUSDAmount, user1);

        // Borrow some AUSD to create debt
        uint256 borrowAmount = 100e6;
        cAUSD.borrow(borrowAmount, user1);
        vm.stopPrank();

        // Get oracle prices before skipping time (while data is fresh)
        IOracleAdaptor chainlinkAdaptor = IOracleAdaptor(0xACfE3fCcae79445836E03c5359BB96bd352b9C00);
        IOracleAdaptor redstoneClassicAdaptor = IOracleAdaptor(0x0fA602b3e748438A3F1599206Ed6DC497ab3331E);

        // Get aggregator addresses from adaptors (using inUSD = true)
        (, IChainlink earnAUSDAggregator,,) = chainlinkAdaptor.assetConfig(EARN_AUSD_RECEIPT_TOKEN, true);
        (, IChainlink ausdAggregator,,) = redstoneClassicAdaptor.assetConfig(AUSD, true);

        // Get current prices before time skip
        (, int256 earnAUSDPrice,,,) = earnAUSDAggregator.latestRoundData();
        (, int256 ausdPrice,,,) = ausdAggregator.latestRoundData();

        // Skip minimum hold period before deleveraging
        skip(20 minutes);

        // Mock oracle feeds to return same prices but fresh timestamps
        vm.mockCall(
            address(earnAUSDAggregator),
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(1), earnAUSDPrice, block.timestamp, block.timestamp, uint80(1))
        );
        vm.mockCall(
            address(ausdAggregator),
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(1), ausdPrice, block.timestamp, block.timestamp, uint80(1))
        );

        // Now test deleverage
        uint256 collateralBefore = cEarnAUSD.balanceOf(user1);
        uint256 debtBefore = cAUSD.debtBalanceUpdated(user1);

        // Quote how much AUSD we'll get for swapping earnAUSD to determine collateral to withdraw
        // We want to repay about half the debt
        uint256 targetRepay = debtBefore / 2;

        // Quote how much earnAUSD we need to swap to get targetRepay AUSD
        // Start with a reasonable amount and use Kyber quote
        uint256 collateralToWithdraw = collateralBefore / 20; // Start with 5%

        uint256 expectedAUSDOut = _getKyberAmountOut(
            block.chainid,
            EARN_AUSD_RECEIPT_TOKEN,
            AUSD,
            collateralToWithdraw,
            address(positionManager),
            500 // 5% slippage
        );

        console2.log("Collateral to withdraw (earnAUSD):", collateralToWithdraw);
        console2.log("Expected AUSD out from swap:", expectedAUSDOut);
        console2.log("Debt before:", debtBefore);

        vm.startPrank(user1);

        EarnAUSDVaultPositionManager.DeleverageAction memory deleverageAction;
        deleverageAction.cToken = ICToken(address(cEarnAUSD));
        deleverageAction.collateralAssets = collateralToWithdraw;
        deleverageAction.borrowableCToken = IBorrowableCToken(address(cAUSD));
        // repayAssets is minimum to repay - apply 10% slippage buffer
        deleverageAction.repayAssets = (expectedAUSDOut * 90) / 100;

        // Setup swap from earnAUSD to AUSD via KyberSwap
        deleverageAction.swapActions = new SwapperLib.Swap[](1);
        deleverageAction.swapActions[0].inputToken = EARN_AUSD_RECEIPT_TOKEN;
        deleverageAction.swapActions[0].inputAmount = collateralToWithdraw;
        deleverageAction.swapActions[0].outputToken = AUSD;
        deleverageAction.swapActions[0].target = kyberSwapRouter;
        deleverageAction.swapActions[0].slippage = 0.5e18;

        // Get swap calldata from KyberSwap
        deleverageAction.swapActions[0].call = _getKyberCalldata(
            block.chainid,
            EARN_AUSD_RECEIPT_TOKEN,
            AUSD,
            collateralToWithdraw,
            address(positionManager),
            500 // 5% slippage
        );

        positionManager.deleverage(deleverageAction, 0.5e18);
        vm.stopPrank();

        uint256 collateralAfter = cEarnAUSD.balanceOf(user1);
        uint256 debtAfter = cAUSD.debtBalanceUpdated(user1);

        assertEq(collateralBefore - collateralAfter, collateralToWithdraw, "Collateral should decrease");
        assertLt(debtAfter, debtBefore, "Debt should decrease after repayment");
    }
}
