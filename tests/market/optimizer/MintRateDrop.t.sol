// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { TestBaseLendingOptimizer } from "./TestBaseLendingOptimizer.sol";
import { LendingOptimizerHarness } from "./LendingOptimizerHarness.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";


contract MintRateDropTest is TestBaseLendingOptimizer {

    function setUp() public override {
        super.setUp();
    }

    function test_mint_rate_drops() public {
        _deployOptimizer();
        _initAndDeposit();

        // Warp for non-1:1 cToken rate (needed for double-floor to trigger).
        vm.warp(block.timestamp + 365 days);
        optimizer.accrueIfNeeded();

        uint256 rateBefore = _exchangeRateWAD();
        uint256 optA = optimizer.totalAssets();
        uint256 optS = optimizer.totalSupply();

        IBorrowableCToken cToken = IBorrowableCToken(cUSDC_WMON_MARKET);
        uint256 cA = cToken.totalAssets();
        uint256 cS = cToken.totalSupply();

        emit log_named_uint("rate before (WAD)     ", rateBefore);
        emit log_named_uint("optA                  ", optA);
        emit log_named_uint("optS                  ", optS);

        // Find a shares amount where the cToken double-floor loses 1 wei.
        uint256 shares = _findMintRateDropShares(optA, optS, cA, cS);
        uint256 assets = FixedPointMathLib.fullMulDivUp(shares, optA, optS);

        // Show the double-floor math.
        uint256 cSharesReceived = FixedPointMathLib.fullMulDiv(assets, cS, cA);
        uint256 trackedAssets = FixedPointMathLib.fullMulDiv(cSharesReceived, cA, cS);

        emit log_named_uint("mint shares           ", shares);
        emit log_named_uint("user pays (assets)    ", assets);
        emit log_named_uint("cToken shares received", cSharesReceived);
        emit log_named_uint("trackedAssets (2xfloor)", trackedAssets);
        emit log_named_uint("double-floor loss     ", assets - trackedAssets);

        // Do the mint as a new user.
        address minter = address(0xBEEF);
        deal(USDC_MONAD, minter, assets);
        optimizer.accrueIfNeeded();
        rateBefore = _exchangeRateWAD();
        vm.startPrank(minter);
        IERC20(USDC_MONAD).approve(address(optimizer), assets);
        optimizer.mint(shares, minter);
        vm.stopPrank();

        // Read rate IMMEDIATELY after mint (before next accrual re-syncs).
        uint256 rateAfter = _exchangeRateWAD();

        emit log_named_uint("rate after  (WAD)     ", rateAfter);
        emit log_named_uint("totalAssets after     ", optimizer.totalAssets());
        emit log_named_uint("totalSupply after     ", optimizer.totalSupply());
        emit log_named_uint("RATE DROP   (WAD)     ", rateBefore - rateAfter);

        assertTrue(rateAfter < rateBefore, "Rate should drop after mint due to double-floor loss");
    }

    function _exchangeRateWAD() internal view returns (uint256) {
        return FixedPointMathLib.fullMulDiv(1e18, optimizer.totalAssets(), optimizer.totalSupply());
    }

    // --- Helpers ---

    function _deployOptimizer() internal {
        address[] memory approvedCTokens = new address[](1);
        approvedCTokens[0] = cUSDC_WMON_MARKET;
        uint256[] memory caps = new uint256[](1);
        caps[0] = 10_000;

        optimizer = new LendingOptimizerHarness(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            caps,
            0 // 0% fee
        );

        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(
                ICentralRegistry.hasMarketPermissions.selector,
                address(this)
            ),
            abi.encode(true)
        );
    }

    function _initAndDeposit() internal {
        uint256 initAssets = 77777;
        deal(USDC_MONAD, address(this), initAssets);
        IERC20(USDC_MONAD).approve(address(optimizer), initAssets);
        optimizer.initializeDeposits(cUSDC_WMON_MARKET);

        address user = address(0xCAFE);
        uint256 depositAmount = 500_000e6;
        deal(USDC_MONAD, user, depositAmount);
        vm.startPrank(user);
        IERC20(USDC_MONAD).approve(address(optimizer), depositAmount);
        optimizer.deposit(depositAmount, user);
        vm.stopPrank();
    }

    /// @notice Find a shares count where mint() causes a rate drop.
    ///   The cToken deposit path does: cShares = floor(assets * cS / cA),
    ///   then trackedAssets = floor(cShares * cA / cS).
    ///   When this double-floor loses 1 wei, trackedAssets < shares * optA / optS,
    ///   and the rate drops.
    function _findMintRateDropShares(
        uint256 optA, uint256 optS,
        uint256 cA, uint256 cS
    ) internal pure returns (uint256) {
        for (uint256 shares = 1; shares <= 50_000; shares++) {
            // previewMint: ceil(shares * optA / optS)
            uint256 assets = FixedPointMathLib.fullMulDivUp(shares, optA, optS);

            // cToken deposit: floor(assets * cS / cA)
            uint256 cShares = FixedPointMathLib.fullMulDiv(assets, cS, cA);

            // convertToAssets: floor(cShares * cA / cS)
            uint256 trackedAssets = FixedPointMathLib.fullMulDiv(cShares, cA, cS);

            // Double floor lost at least 1 wei.
            if (trackedAssets >= assets) continue;

            // Rate drops when: trackedAssets * optS < optA * shares
            if (trackedAssets * optS < optA * shares) return shares;
        }
        revert("No mint rate-drop shares found");
    }
}
