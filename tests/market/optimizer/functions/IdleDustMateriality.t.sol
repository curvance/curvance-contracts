// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IERC165 } from "contracts/interfaces/IERC165.sol";
import { ERC4626 } from "contracts/libraries/external/ERC4626.sol";
import { LendingOptimizerHarness } from "tests/market/optimizer/LendingOptimizerHarness.sol";
import { TestBaseLendingOptimizer } from "tests/market/optimizer/TestBaseLendingOptimizer.sol";

contract TestLendingOptimizerIdleDustMateriality is TestBaseLendingOptimizer {
    LendingOptimizerHarness internal harness;
    address internal depositor = makeAddr("idle dust depositor");

    function setUp() public override {
        super.setUp();

        address[] memory approvedCTokens = new address[](3);
        approvedCTokens[0] = cUSDC_WMON_MARKET;
        approvedCTokens[1] = cUSDC_WBTC_MARKET;
        approvedCTokens[2] = cUSDC_WETH_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](3);
        allocationCapsBps[0] = 10_000;
        allocationCapsBps[1] = 10_000;
        allocationCapsBps[2] = 10_000;

        harness = new LendingOptimizerHarness(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            1_000
        );

        deal(USDC_MONAD, address(this), 77777);
        IERC20(USDC_MONAD).approve(address(harness), 77777);
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );
        harness.initializeDeposits(cUSDC_WMON_MARKET);

        _depositToMarket(1_000_000e6, cUSDC_WMON_MARKET);
        _depositToMarket(1_000, cUSDC_WBTC_MARKET);
        _depositToMarket(1_000, cUSDC_WETH_MARKET);
    }

    function test_lendingOptimizer_idleDustFromSkippedZeroShareSlices_isBounded() public {
        uint256 depositAmount = 1e6;
        uint256[] memory perMarket = harness.exposed_calculateDepositProRata(depositAmount, false);
        uint256 skipped;
        for (uint256 i; i < perMarket.length; ++i) {
            if (
                perMarket[i] != 0 &&
                IBorrowableCToken(harness.approvedCTokensList(i)).convertToShares(perMarket[i]) == 0
            ) {
                skipped += perMarket[i];
            }
        }

        deal(USDC_MONAD, depositor, depositAmount);
        vm.startPrank(depositor);
        IERC20(USDC_MONAD).approve(address(harness), depositAmount);
        uint256 shares = harness.deposit(depositAmount, depositor);
        vm.stopPrank();

        uint256 idle = IERC20(USDC_MONAD).balanceOf(address(harness));

        assertGt(shares, 0, "deposit should still mint shares");
        assertEq(idle, skipped, "idle underlying should equal skipped zero-share slices");
        assertLe(idle, 2, "live-style dust setup should leave at most two USDC base units idle");
    }

    function test_lendingOptimizer_strictPreviewDepositConsumerCanOverexpectDustShares() public {
        StrictPreviewDepositConsumer consumer = new StrictPreviewDepositConsumer();
        uint256 depositAmount = 1e6;
        uint256 previewedShares = harness.previewDeposit(depositAmount);

        deal(USDC_MONAD, depositor, depositAmount);
        vm.startPrank(depositor);
        IERC20(USDC_MONAD).approve(address(consumer), depositAmount);
        vm.expectRevert("min shares");
        consumer.strictPreviewDeposit(address(harness), depositAmount, depositor);
        vm.stopPrank();

        deal(USDC_MONAD, depositor, depositAmount);
        vm.startPrank(depositor);
        IERC20(USDC_MONAD).approve(address(harness), depositAmount);
        uint256 actualShares = harness.deposit(depositAmount, depositor);
        vm.stopPrank();

        assertLt(actualShares, previewedShares, "skipped cToken dust should reduce actual shares");
        assertLe(previewedShares - actualShares, 2, "previewDeposit gap should stay at dust scale");
    }

    function test_lendingOptimizer_mintInflatesDustSlicesInsteadOfLeavingIdleUnderlying() public {
        uint256 targetShares = harness.convertToShares(1e6);
        assertGt(targetShares, 0, "test setup should mint nonzero optimizer shares");

        uint256 previewedAssets = harness.previewMint(targetShares);
        uint256[] memory perMarket = harness.exposed_calculateDepositProRata(previewedAssets, true);
        uint256 actualAssets;
        for (uint256 i; i < perMarket.length; ++i) {
            actualAssets += perMarket[i];
            if (perMarket[i] != 0) {
                assertGt(
                    IBorrowableCToken(harness.approvedCTokensList(i)).convertToShares(perMarket[i]),
                    0,
                    "mint roundtrip should inflate nonzero legs above cToken dust"
                );
            }
        }

        uint256 idleBefore = IERC20(USDC_MONAD).balanceOf(address(harness));

        deal(USDC_MONAD, depositor, actualAssets);
        vm.startPrank(depositor);
        IERC20(USDC_MONAD).approve(address(harness), actualAssets);
        uint256 chargedAssets = harness.mint(targetShares, depositor);
        vm.stopPrank();

        assertEq(chargedAssets, actualAssets, "mint should charge the roundtrip-inflated assets");
        assertGe(chargedAssets, previewedAssets, "mint should not charge less than previewMint");
        assertLe(chargedAssets - previewedAssets, 10, "mint dust inflation should stay at base-unit scale");
        assertEq(
            IERC20(USDC_MONAD).balanceOf(address(harness)),
            idleBefore,
            "mint should not leave skipped dust idle in this setup"
        );
    }

    function test_lendingOptimizer_skimCanRecoverOnlyObservedIdleDust() public {
        uint256 depositAmount = 1e6;
        deal(USDC_MONAD, depositor, depositAmount);
        vm.startPrank(depositor);
        IERC20(USDC_MONAD).approve(address(harness), depositAmount);
        harness.deposit(depositAmount, depositor);
        vm.stopPrank();

        uint256 idle = IERC20(USDC_MONAD).balanceOf(address(harness));
        uint256 daoBefore = IERC20(USDC_MONAD).balanceOf(liveCentralRegistry.daoAddress());

        if (idle == 0) {
            vm.expectRevert();
            harness.skim();
            return;
        }

        harness.skim();

        assertEq(
            IERC20(USDC_MONAD).balanceOf(liveCentralRegistry.daoAddress()) - daoBefore,
            idle,
            "DAO skim should match observed idle dust"
        );
        assertEq(IERC20(USDC_MONAD).balanceOf(address(harness)), 0, "skim should clear idle dust");
    }

    function test_lendingOptimizer_idleDustFromSkippedSlices_staysSubCentAfterLongYieldGrowth() public {
        skip(10 * 365 days);
        harness.accrueIfNeeded();

        uint256 depositAmount = harness.totalAssets() / 2;
        uint256[] memory perMarket = harness.exposed_calculateDepositProRata(depositAmount, false);
        uint256 skipped;
        for (uint256 i; i < perMarket.length; ++i) {
            if (
                perMarket[i] != 0 &&
                IBorrowableCToken(harness.approvedCTokensList(i)).convertToShares(perMarket[i]) == 0
            ) {
                skipped += perMarket[i];
            }
        }

        deal(USDC_MONAD, depositor, depositAmount);
        vm.startPrank(depositor);
        IERC20(USDC_MONAD).approve(address(harness), depositAmount);
        harness.deposit(depositAmount, depositor);
        vm.stopPrank();

        uint256 idle = IERC20(USDC_MONAD).balanceOf(address(harness));

        assertEq(idle, skipped, "idle underlying should equal skipped zero-share slices");
        assertLe(idle, 10_000, "skipped idle dust should stay below one cent");
    }

    function test_lendingOptimizer_skimDirectUnderlyingDonationDoesNotChangeShareAccounting() public {
        uint256 totalAssetsBefore = harness.totalAssets();
        uint256 exchangeRateBefore = harness.exchangeRate();
        uint256 totalSupplyBefore = harness.totalSupply();
        uint256 holderShares = harness.balanceOf(address(this));
        uint256 holderAssetsBefore = harness.convertToAssets(holderShares);
        uint256 idleBefore = IERC20(USDC_MONAD).balanceOf(address(harness));
        uint256 donation = 123_456e6;
        address donor = makeAddr("direct underlying donor");

        deal(USDC_MONAD, donor, donation);
        vm.prank(donor);
        IERC20(USDC_MONAD).transfer(address(harness), donation);

        assertEq(harness.totalAssets(), totalAssetsBefore, "direct donation should not change cached assets");
        assertEq(harness.exchangeRate(), exchangeRateBefore, "direct donation should not change share price");
        assertEq(harness.totalSupply(), totalSupplyBefore, "direct donation should not mint shares");
        assertEq(harness.convertToAssets(holderShares), holderAssetsBefore, "holder redeem value should stay unchanged");
        assertEq(harness.skimAvailable(), idleBefore + donation, "skim should see only idle underlying");

        uint256 daoBefore = IERC20(USDC_MONAD).balanceOf(liveCentralRegistry.daoAddress());
        harness.skim();

        assertEq(
            IERC20(USDC_MONAD).balanceOf(liveCentralRegistry.daoAddress()) - daoBefore,
            idleBefore + donation,
            "DAO skim should receive idle underlying only"
        );
        assertEq(IERC20(USDC_MONAD).balanceOf(address(harness)), 0, "skim should clear idle underlying");
        assertEq(harness.totalAssets(), totalAssetsBefore, "skim should not change cached assets");
        assertEq(harness.exchangeRate(), exchangeRateBefore, "skim should not change share price");
        assertEq(harness.totalSupply(), totalSupplyBefore, "skim should not change supply");
        assertEq(harness.convertToAssets(holderShares), holderAssetsBefore, "skim should not change holder value");
    }

    function _depositToMarket(uint256 assets, address market) internal {
        deal(USDC_MONAD, address(this), assets);
        IERC20(USDC_MONAD).approve(address(harness), assets);
        harness.depositToMarket(assets, address(this), market);
    }
}

contract StrictPreviewDepositConsumer {
    function strictPreviewDeposit(
        address vault,
        uint256 assets,
        address receiver
    ) external returns (uint256 shares) {
        require(
            IERC165(vault).supportsInterface(type(ERC4626).interfaceId),
            "not ERC4626"
        );

        ERC4626 erc4626Vault = ERC4626(vault);
        uint256 minShares = erc4626Vault.previewDeposit(assets);
        IERC20 asset = IERC20(erc4626Vault.asset());

        require(asset.transferFrom(msg.sender, address(this), assets), "pull");
        require(asset.approve(vault, assets), "approve");

        shares = erc4626Vault.deposit(assets, receiver);
        require(shares >= minShares, "min shares");
    }
}
