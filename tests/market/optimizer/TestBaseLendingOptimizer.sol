// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { ICToken } from "contracts/interfaces/ICToken.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IChainlink } from "contracts/interfaces/external/chainlink/IChainlink.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";


contract TestBaseLendingOptimizer is TestBaseMarketIsolated {

    LendingOptimizer optimizer;

    ICentralRegistry public liveCentralRegistry = ICentralRegistry(0x1310f352f1389969Ece6741671c4B919523912fF);

    // USDC address on Monad
    address constant USDC_MONAD = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603;

    address cUSDC_WMON_MARKET = 0x8EE9FC28B8Da872c38A496e9dDB9700bb7261774;
    address cUSDC_WBTC_MARKET = 0x7C9d4f1695C6282Da5e5509Aa51fC9fb417C6f1d;
    address cUSDC_WETH_MARKET = 0x21aDBb60a5fB909e7F1fB48aACC4569615CD97b5;

    function setUp() public virtual override {
        vm.createSelectFork(vm.envString("MON_NODE_URI_MONAD_MAINNET"));
    }

    /// @dev Calculates expected shares using the ERC4626 formula:
    ///      shares = assets * totalSupply / totalAssets
    /// @param assets The amount of assets to deposit
    /// @param totalAssetsBefore Total assets before the deposit
    /// @param totalSupplyBefore Total supply before the deposit
    /// @return expectedShares The expected shares to be minted
    function _calculateExpectedShares(
        uint256 assets,
        uint256 totalAssetsBefore,
        uint256 totalSupplyBefore
    ) internal pure returns (uint256 expectedShares) {
        if (totalSupplyBefore == 0 || totalAssetsBefore == 0) {
            // First deposit: 1:1 ratio
            return assets;
        }
        // shares = assets * totalSupply / totalAssets (round down)
        expectedShares = (assets * totalSupplyBefore) / totalAssetsBefore;
    }

    /// @dev Verifies that shares minted match the previewDeposit invariant.
    /// @notice Uses previewDeposit() as the reference, which includes fully-diluted
    ///         pricing during active vesting to prevent yield frontrunning.
    ///         Must be called AFTER accrueIfNeeded() to match deposit()'s internal state.
    /// @param assets The deposited assets
    /// @param sharesMinted The shares that were minted
    function _assertSharesMatchInvariant(
        uint256 assets,
        uint256 sharesMinted,
        uint256,
        uint256
    ) internal view {
        uint256 expectedShares = optimizer.previewDeposit(assets);

        // Allow for small difference due to cToken rounding in _depositToMarket.
        // The actual deposit tracks assets via cToken.convertToAssets(cToken.deposit()),
        // which may differ slightly from the raw `assets` input.
        uint256 diff = sharesMinted > expectedShares
            ? sharesMinted - expectedShares
            : expectedShares - sharesMinted;

        require(diff <= 1, "Shares minted deviate from exchange rate invariant");
    }

    function _setUpOneMarket() internal {
        address[] memory approvedCTokens = new address[](1);
        approvedCTokens[0] = cUSDC_WMON_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](1);
        allocationCapsBps[0] = 10_000;

        optimizer = new LendingOptimizer(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            1_000,
            1 days
        );

        uint256 initAssets = 77777;
        deal(USDC_MONAD, address(this), initAssets);
        IERC20(USDC_MONAD).approve(address(optimizer), initAssets);
        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );
        optimizer.initializeDeposits(0);
    }

    function _setUpTwoMarkets() internal {
        address[] memory approvedCTokens = new address[](2);
        approvedCTokens[0] = cUSDC_WMON_MARKET;
        approvedCTokens[1] = cUSDC_WBTC_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](2);
        allocationCapsBps[0] = 6_000;
        allocationCapsBps[1] = 5_000;

        optimizer = new LendingOptimizer(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            1_000,
            1 days
        );

        uint256 initAssets = 77777;
        deal(USDC_MONAD, address(this), initAssets);
        IERC20(USDC_MONAD).approve(address(optimizer), initAssets);
        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );
        optimizer.initializeDeposits(0);
    }

    function _setUpThreeMarkets() internal {
        address[] memory approvedCTokens = new address[](3);
        approvedCTokens[0] = cUSDC_WMON_MARKET;
        approvedCTokens[1] = cUSDC_WBTC_MARKET;
        approvedCTokens[2] = cUSDC_WETH_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](3);
        allocationCapsBps[0] = 6_000;
        allocationCapsBps[1] = 5_000;
        allocationCapsBps[2] = 2_000;

        optimizer = new LendingOptimizer(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            1_000,
            1 days
        );

        uint256 initAssets = 77777;
        deal(USDC_MONAD, address(this), initAssets);
        IERC20(USDC_MONAD).approve(address(optimizer), initAssets);
        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );
        optimizer.initializeDeposits(0);
    }

    function _depositToAllMarkets(uint256 amountPerMarket) internal {
        address[3] memory markets = [cUSDC_WMON_MARKET, cUSDC_WBTC_MARKET, cUSDC_WETH_MARKET];
        
        for (uint256 i = 0; i < 3; i++) {
            deal(USDC_MONAD, address(this), amountPerMarket);
            IERC20(USDC_MONAD).approve(address(optimizer), amountPerMarket);
            optimizer.deposit(amountPerMarket, address(this), markets[i]);
        }
    }

}