// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { UpshiftVaultPositionManager } from "contracts/market/position-management/UpshiftVaultPositionManager.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { ICToken, AccountSnapshot } from "contracts/interfaces/ICToken.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { IVault } from "contracts/interfaces/IVault.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

/// @dev
/// Test overview:
/// - This suite exercises UpshiftVaultPositionManager on Monad using live contracts.
///
/// Market:
/// - sAUSD/AUSD:
///   - Collateral: BorrowableCToken(sAUSD)
///   - Debt: BorrowableCToken(AUSD)
///
/// Flow (no swap needed since sAUSD underlying is AUSD):
/// - Deleverage: Redeem sAUSD via requestRedeem -> receive AUSD -> repay AUSD loan.
///
/// Setup requirements:
/// - Token caps must be raised: Live contracts have conservative collateral/debt caps
///   that are too low for meaningful test amounts. We prank as emergencyCouncil to
///   increase these caps.
/// - Lending liquidity must be added: Borrowing AUSD requires liquidity in the cAUSD
///   lending pool. We deposit AUSD via a liquidity provider before tests run.
/// - Kyber swaps for token acquisition: AUSD and sAUSD use non-standard storage
///   layouts (proxy contracts) that prevent Foundry's `deal()` cheatcode from working.
///   Instead, we swap WMON -> AUSD via KyberSwap, then deposit into sAUSD vault.
contract TestUpshiftVaultPositionManager is TestBaseMarketIsolated {

    UpshiftVaultPositionManager public positionManager;

    // Live Monad contracts
    ICentralRegistry public liveCentralRegistry = ICentralRegistry(0x1310f352f1389969Ece6741671c4B919523912fF);
    MarketManagerIsolated public liveMarketManager = MarketManagerIsolated(0xBBE7A3c45aDBb16F6490767b663428c34aA341Eb);
    BorrowableCToken public borrowableCSAUSD = BorrowableCToken(0x84C5aF20b58818631164Bb7d798E457fcFACD9Ac);
    BorrowableCToken public borrowableCAUSD = BorrowableCToken(0xfD493ce1A0ae986e09d17004B7E748817a47d73c);

    address public SAUSD_ADDRESS = 0xD793c04B87386A6bb84ee61D98e0065FdE7fdA5E;
    address public AUSD_ADDRESS = 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a;
    address public WMON_ADDRESS = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;

    // KyberSwap router
    address public kyberSwapRouter = 0x6131B5fae19EA4f9D964eAc0408E4408b66337b5;

    // Acquired balances for tests
    uint256 public user1SAUSDBalance;
    uint256 public liquidityProviderAUSDBalance;

    function setUp() public override {
        // Fork Monad
        vm.createSelectFork(vm.envString("MON_NODE_URI_MONAD_MAINNET"));

        address emergencyCouncil = liveCentralRegistry.emergencyCouncil();

        // Raise collateral cap for csAUSD and debt cap for cAUSD
        _updateTokenCaps(emergencyCouncil);

        // Add AUSD lending liquidity so borrowing works
        // AUSD has weird storage, can't deal directly - use Kyber swap
        _addLendingLiquidity();

        // Deploy position manager
        positionManager = new UpshiftVaultPositionManager(
            liveCentralRegistry,
            address(liveMarketManager),
            WMON_ADDRESS
        );

        // Add position manager to market
        vm.prank(emergencyCouncil);
        liveMarketManager.addPositionManager(address(positionManager));

        // Acquire sAUSD for user1 via Kyber swap (AUSD/sAUSD has weird storage, can't deal directly)
        _acquireSAUSDForUser();
    }

    /// @notice Test deleverage: redeem sAUSD -> receive AUSD -> repay loan (no swap needed)
    function testDeleverageNoSwap() public {
        uint256 depositAmount = user1SAUSDBalance / 2;

        vm.startPrank(user1);

        // Deposit sAUSD as collateral
        IERC20(SAUSD_ADDRESS).approve(address(borrowableCSAUSD), type(uint256).max);
        borrowableCSAUSD.depositAsCollateral(depositAmount, user1);

        // Borrow AUSD against sAUSD collateral
        borrowableCAUSD.borrow(depositAmount / 5, user1);

        skip(20 minutes);
        borrowableCAUSD.accrueIfNeeded();

        AccountSnapshot memory debtBefore = borrowableCAUSD.getSnapshot(user1);
        AccountSnapshot memory collBefore = borrowableCSAUSD.getSnapshot(user1);

        // Deleverage: redeem some sAUSD -> get AUSD -> repay (no swap)
        uint256 repayAssets = debtBefore.debtBalance / 10; // repay 10% of loan
        uint256 sAusdToRedeem = depositAmount / 10;

        UpshiftVaultPositionManager.DeleverageAction memory deleverageAction;
        deleverageAction.cToken = ICToken(address(borrowableCSAUSD));
        deleverageAction.collateralAssets = sAusdToRedeem;
        deleverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCAUSD));
        deleverageAction.repayAssets = repayAssets;
        // No swap actions needed - redeemed asset (AUSD) is the debt asset

        borrowableCSAUSD.approve(address(positionManager), type(uint256).max);

        positionManager.deleverage(deleverageAction, 0.01e18);

        AccountSnapshot memory debtAfter = borrowableCAUSD.getSnapshot(user1);
        AccountSnapshot memory collAfter = borrowableCSAUSD.getSnapshot(user1);

        assertLt(debtAfter.debtBalance, debtBefore.debtBalance, "Debt should be reduced after deleverage");
        assertLt(collAfter.collateralPosted, collBefore.collateralPosted, "Collateral should be reduced after deleverage");

        vm.stopPrank();
    }

    /// INTERNAL HELPERS ///

    function _updateTokenCaps(address emergencyCouncil) internal {
        uint256 BPS = 10_000;

        // Get current config values for csAUSD
        (uint256 collRatio, uint256 collReqSoft, uint256 collReqHard) =
            liveMarketManager.collConfig(address(borrowableCSAUSD));
        (
            uint256 liqIncBase, uint256 liqIncCurve,
            uint256 liqIncMin, uint256 liqIncMax,
            uint256 closeFactorBase, ,
            uint256 closeFactorMin, uint256 closeFactorMax
        ) = liveMarketManager.liquidationConfig(address(borrowableCSAUSD));

        // Update csAUSD with higher collateral cap (only changing caps)
        // Note: collReqSoft/Hard and liqInc values are stored with BPS added,
        // so we subtract BPS to get the raw values expected by updateTokenConfig
        MarketManagerIsolated.TokenConfig memory csAusdConfig = MarketManagerIsolated.TokenConfig({
            cToken: address(borrowableCSAUSD),
            collRatio: collRatio,
            collReqSoft: collReqSoft - BPS,
            collReqHard: collReqHard - BPS,
            liqIncBase: liqIncBase - BPS,
            liqIncHard: (liqIncBase - BPS) + liqIncCurve,
            liqIncMin: liqIncMin - BPS,
            liqIncMax: liqIncMax - BPS,
            closeFactorBase: closeFactorBase,
            closeFactorMin: closeFactorMin,
            closeFactorMax: closeFactorMax,
            collateralCap: 1_000_000e18, // 1M sAUSD collateral cap
            debtCap: 1_000_000e18 // 1M sAUSD debt cap
        });

        vm.prank(emergencyCouncil);
        liveMarketManager.updateTokenConfig(csAusdConfig);

        // Get current config values for cAUSD
        (collRatio, collReqSoft, collReqHard) =
            liveMarketManager.collConfig(address(borrowableCAUSD));
        (
            liqIncBase, liqIncCurve,
            liqIncMin, liqIncMax,
            closeFactorBase, ,
            closeFactorMin, closeFactorMax
        ) = liveMarketManager.liquidationConfig(address(borrowableCAUSD));

        // Update cAUSD with higher debt cap (only changing caps)
        MarketManagerIsolated.TokenConfig memory cAusdConfig = MarketManagerIsolated.TokenConfig({
            cToken: address(borrowableCAUSD),
            collRatio: collRatio,
            collReqSoft: collReqSoft - BPS,
            collReqHard: collReqHard - BPS,
            liqIncBase: liqIncBase - BPS,
            liqIncHard: (liqIncBase - BPS) + liqIncCurve,
            liqIncMin: liqIncMin - BPS,
            liqIncMax: liqIncMax - BPS,
            closeFactorBase: closeFactorBase,
            closeFactorMin: closeFactorMin,
            closeFactorMax: closeFactorMax,
            collateralCap: 1_000_000e18, // 1M AUSD collateral cap
            debtCap: 1_000_000e18 // 1M AUSD debt cap
        });

        vm.prank(emergencyCouncil);
        liveMarketManager.updateTokenConfig(cAusdConfig);
    }

    function _addLendingLiquidity() internal {
        // Add AUSD liquidity so borrowing works
        // AUSD has weird storage, can't deal directly - use Kyber swap
        address liquidityProvider = makeAddr("liquidityProvider");
        uint256 wmonAmount = 500_000e18;
        deal(WMON_ADDRESS, liquidityProvider, wmonAmount);

        vm.startPrank(liquidityProvider);
        IERC20(WMON_ADDRESS).approve(kyberSwapRouter, wmonAmount);

        bytes memory swapCalldata = _getKyberCalldata(
            block.chainid,
            WMON_ADDRESS,
            AUSD_ADDRESS,
            wmonAmount,
            liquidityProvider,
            500 // 5% slippage
        );

        (bool success,) = kyberSwapRouter.call(swapCalldata);
        require(success, "KyberSwap WMON->AUSD failed for liquidity provider");

        liquidityProviderAUSDBalance = IERC20(AUSD_ADDRESS).balanceOf(liquidityProvider);
        require(liquidityProviderAUSDBalance > 0, "Liquidity provider should have AUSD");

        IERC20(AUSD_ADDRESS).approve(address(borrowableCAUSD), type(uint256).max);
        borrowableCAUSD.deposit(liquidityProviderAUSDBalance, liquidityProvider);
        vm.stopPrank();
    }

    function _acquireSAUSDForUser() internal {
        // Acquire sAUSD for user1 via Kyber swap WMON->AUSD, then deposit AUSD into sAUSD vault
        uint256 wmonAmount = 100_000e18;
        deal(WMON_ADDRESS, user1, wmonAmount);

        vm.startPrank(user1);
        IERC20(WMON_ADDRESS).approve(kyberSwapRouter, wmonAmount);

        bytes memory swapCalldata = _getKyberCalldata(
            block.chainid,
            WMON_ADDRESS,
            AUSD_ADDRESS,
            wmonAmount,
            user1,
            500 // 5% slippage
        );

        (bool success,) = kyberSwapRouter.call(swapCalldata);
        require(success, "KyberSwap WMON->AUSD failed for user1");

        uint256 ausdBalance = IERC20(AUSD_ADDRESS).balanceOf(user1);
        require(ausdBalance > 0, "User1 should have AUSD");

        // Deposit AUSD into sAUSD vault to get sAUSD
        IERC20(AUSD_ADDRESS).approve(SAUSD_ADDRESS, ausdBalance);
        user1SAUSDBalance = IVault(SAUSD_ADDRESS).deposit(ausdBalance, user1);

        require(user1SAUSDBalance > 0, "User1 should have sAUSD");

        vm.stopPrank();
    }
}
