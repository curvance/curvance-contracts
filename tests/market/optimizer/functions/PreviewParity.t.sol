// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IERC165 } from "contracts/interfaces/IERC165.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { ERC4626 } from "contracts/libraries/external/ERC4626.sol";
import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { TestBaseLendingOptimizer } from "tests/market/optimizer/TestBaseLendingOptimizer.sol";

contract TestLendingOptimizerPreviewParity is TestBaseLendingOptimizer {
    address internal depositor = address(0x12012);

    function setUp() public override {
        super.setUp();
        _setUpThreeMarkets();
        _depositToAllMarkets(500_000e6);
    }

    function test_lendingOptimizer_previewMint_canUnderquoteActualAssets() public {
        uint256 shares = 100_000_000;
        uint256 previewedAssets = optimizer.previewMint(shares);

        deal(USDC_MONAD, depositor, previewedAssets + 10);
        vm.startPrank(depositor);
        IERC20(USDC_MONAD).approve(address(optimizer), previewedAssets + 10);
        uint256 actualAssets = optimizer.mint(shares, depositor);
        vm.stopPrank();

        assertGt(actualAssets, previewedAssets, "expected mint to require more assets than previewMint");
    }

    function test_lendingOptimizer_erc4626AutoDetectedPreviewMintCanUnderfundStrictConsumer()
        public
    {
        StrictPreviewMintConsumer consumer = new StrictPreviewMintConsumer();
        uint256 shares = 100_000_000;
        uint256 previewedAssets = optimizer.previewMint(shares);

        deal(USDC_MONAD, depositor, previewedAssets);
        vm.startPrank(depositor);
        IERC20(USDC_MONAD).approve(address(consumer), previewedAssets);
        uint256 depositorAssetsBefore = IERC20(USDC_MONAD).balanceOf(depositor);
        uint256 totalAssetsBefore = optimizer.totalAssets();
        uint256 totalSupplyBefore = optimizer.totalSupply();
        vm.expectRevert();
        consumer.strictPreviewMint(address(optimizer), shares, depositor);
        assertEq(
            IERC20(USDC_MONAD).balanceOf(depositor),
            depositorAssetsBefore,
            "strict preview mint revert should roll back user assets"
        );
        assertEq(
            IERC20(USDC_MONAD).balanceOf(address(consumer)),
            0,
            "strict preview mint revert should not strand assets"
        );
        assertEq(
            optimizer.balanceOf(depositor),
            0,
            "strict preview mint revert should not mint shares"
        );
        assertEq(
            optimizer.totalAssets(),
            totalAssetsBefore,
            "strict preview mint revert should roll back optimizer assets"
        );
        assertEq(
            optimizer.totalSupply(),
            totalSupplyBefore,
            "strict preview mint revert should roll back optimizer supply"
        );
        vm.stopPrank();

        deal(USDC_MONAD, depositor, previewedAssets + 10);
        vm.startPrank(depositor);
        IERC20(USDC_MONAD).approve(address(optimizer), previewedAssets + 10);
        uint256 actualAssets = optimizer.mint(shares, depositor);
        vm.stopPrank();

        assertGt(actualAssets, previewedAssets, "strict preview funding underfunds mint");
        assertLe(actualAssets - previewedAssets, 10, "previewMint gap should stay at dust scale");
    }

    function test_lendingOptimizer_strictPreviewWithdrawConsumerUsesConservativeShareLimit()
        public
    {
        StrictPreviewWithdrawConsumer consumer = new StrictPreviewWithdrawConsumer();
        uint256 depositAmount = 5_000_000e6;
        deal(USDC_MONAD, depositor, depositAmount);
        vm.startPrank(depositor);
        IERC20(USDC_MONAD).approve(address(optimizer), depositAmount);
        optimizer.deposit(depositAmount, depositor);

        uint256 assets = 200_000e6;
        uint256 maxShares = optimizer.previewWithdraw(assets);
        uint256 sharesBefore = optimizer.balanceOf(depositor);
        uint256 assetsBefore = IERC20(USDC_MONAD).balanceOf(depositor);

        IERC20(address(optimizer)).approve(address(consumer), maxShares);
        uint256 actualShares =
            consumer.strictPreviewWithdraw(address(optimizer), assets, depositor);
        vm.stopPrank();

        assertLe(actualShares, maxShares, "previewWithdraw should cap burned shares");
        assertEq(
            sharesBefore - optimizer.balanceOf(depositor),
            actualShares,
            "strict consumer should burn actual shares"
        );
        assertEq(
            IERC20(USDC_MONAD).balanceOf(depositor) - assetsBefore,
            assets,
            "strict consumer should forward withdrawn assets"
        );
    }

    function test_lendingOptimizer_conversionPreviewsRoundAgainstCaller()
        public
    {
        uint256 assets = 123_456_789;
        uint256 shares = 987_654_321;

        assertGe(
            optimizer.previewWithdraw(assets),
            optimizer.convertToShares(assets),
            "withdraw preview should round shares up vs convertToShares"
        );
        assertGe(
            optimizer.previewMint(shares),
            optimizer.convertToAssets(shares),
            "mint preview should round assets up vs convertToAssets"
        );
    }

    function test_lendingOptimizer_previewRedeem_canOverquoteActualAssets() public {
        uint256 depositAmount = 5_000_000e6;
        deal(USDC_MONAD, depositor, depositAmount);
        vm.startPrank(depositor);
        IERC20(USDC_MONAD).approve(address(optimizer), depositAmount);
        optimizer.deposit(depositAmount, depositor);

        uint256 shares = 200_000_000_000;
        uint256 previewedAssets = optimizer.previewRedeem(shares);
        uint256 actualAssets = optimizer.redeem(shares, depositor, depositor);
        vm.stopPrank();

        assertLt(actualAssets, previewedAssets, "expected redeem to return fewer assets than previewRedeem");
    }

    function test_lendingOptimizer_strictPreviewRedeemConsumerCanOverexpectAssets()
        public
    {
        StrictPreviewRedeemConsumer consumer = new StrictPreviewRedeemConsumer();
        uint256 depositAmount = 5_000_000e6;
        deal(USDC_MONAD, depositor, depositAmount);
        vm.startPrank(depositor);
        IERC20(USDC_MONAD).approve(address(optimizer), depositAmount);
        optimizer.deposit(depositAmount, depositor);

        uint256 shares = 200_000_000_000;
        uint256 sharesBefore = optimizer.balanceOf(depositor);
        assertGe(sharesBefore, shares, "test setup should mint enough shares");

        uint256 previewedAssets = optimizer.previewRedeem(shares);
        IERC20(address(optimizer)).approve(address(consumer), shares);

        vm.expectRevert("min assets");
        consumer.strictPreviewRedeem(address(optimizer), shares, depositor);

        assertEq(
            optimizer.balanceOf(depositor),
            sharesBefore,
            "strict consumer revert should roll back share burn"
        );

        uint256 actualAssets = optimizer.redeem(shares, depositor, depositor);
        vm.stopPrank();

        assertLt(actualAssets, previewedAssets, "strict preview redeem can overexpect assets");
        assertLe(previewedAssets - actualAssets, 3, "previewRedeem gap should stay at dust scale");
    }

    function test_lendingOptimizer_rawConversionViewsStayStaleUntilAccrualAndFees()
        public
    {
        uint256 shares = optimizer.balanceOf(address(this)) / 2;
        assertGt(shares, 0, "test setup must have shares");

        uint256 staleAssets = optimizer.convertToAssets(shares);
        uint256 daoSharesBefore =
            optimizer.balanceOf(liveCentralRegistry.daoAddress());

        skip(365 days);

        assertEq(
            optimizer.convertToAssets(shares),
            staleAssets,
            "raw conversion view should stay cached before accrual"
        );

        optimizer.accrueIfNeeded();

        assertGt(
            optimizer.convertToAssets(shares),
            staleAssets,
            "accrual should reveal pending yield in raw conversion view"
        );
        assertGt(
            optimizer.balanceOf(liveCentralRegistry.daoAddress()),
            daoSharesBefore,
            "performance fee shares should mint when yield exceeds watermark"
        );
    }

    function test_lendingOptimizer_maxViewsSeparateMintAndRedeemPauses()
        public
    {
        address owner = address(this);
        MarketManagerIsolated market =
            MarketManagerIsolated(_marketMgrs[cUSDC_WMON_MARKET]);

        assertGt(optimizer.maxDeposit(owner), 0, "deposit max precondition");
        assertGt(optimizer.maxMint(owner), 0, "mint max precondition");
        assertGt(optimizer.maxWithdraw(owner), 0, "withdraw max precondition");
        assertGt(optimizer.maxRedeem(owner), 0, "redeem max precondition");

        market.setMintPaused(cUSDC_WMON_MARKET, true);

        assertEq(optimizer.maxDeposit(owner), 0, "mint pause blocks deposits");
        assertEq(optimizer.maxMint(owner), 0, "mint pause blocks mints");
        assertGt(
            optimizer.maxWithdraw(owner),
            0,
            "mint pause alone should not zero withdraw max"
        );
        assertGt(
            optimizer.maxRedeem(owner),
            0,
            "mint pause alone should not zero redeem max"
        );

        market.setMintPaused(cUSDC_WMON_MARKET, false);
        market.setRedeemPaused(true);

        assertGt(
            optimizer.maxDeposit(owner),
            0,
            "redeem pause alone should not zero deposit max"
        );
        assertGt(
            optimizer.maxMint(owner),
            0,
            "redeem pause alone should not zero mint max"
        );
        assertEq(optimizer.maxWithdraw(owner), 0, "redeem pause blocks withdraw max");
        assertEq(optimizer.maxRedeem(owner), 0, "redeem pause blocks redeem max");
    }

    function test_lendingOptimizer_maxRedeemEnvelopeAfterMarketRemoval()
        public
    {
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(
                liveCentralRegistry.hasMarketPermissions.selector,
                address(this)
            ),
            abi.encode(true)
        );

        LendingOptimizer.ReallocationAction[] memory removeActions =
            new LendingOptimizer.ReallocationAction[](2);
        removeActions[0] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WMON_MARKET),
            int256(6_000)
        );
        removeActions[1] = LendingOptimizer.ReallocationAction(
            IBorrowableCToken(cUSDC_WBTC_MARKET),
            int256(4_000)
        );

        uint256 removedMarketAssetsBefore =
            IBorrowableCToken(cUSDC_WETH_MARKET).convertToAssets(
                IBorrowableCToken(cUSDC_WETH_MARKET).balanceOf(
                    address(optimizer)
                )
            );
        assertGt(removedMarketAssetsBefore, 0, "removed market precondition");

        optimizer.removeApprovedAsset(
            cUSDC_WETH_MARKET,
            removeActions,
            _unconstrainedBoundsForRemoval(cUSDC_WETH_MARKET)
        );

        assertEq(
            IBorrowableCToken(cUSDC_WETH_MARKET).balanceOf(address(optimizer)),
            0,
            "removed market must not back max views"
        );
        assertEq(optimizer.numApprovedMarkets(), 2, "post-removal market count");

        uint256 remainingLiquidity;
        uint256 remainingMarketValue;
        for (uint256 i; i < optimizer.numApprovedMarkets(); ++i) {
            address market = optimizer.approvedCTokensList(i);
            IBorrowableCToken cToken = IBorrowableCToken(market);
            uint256 marketAssets = cToken.convertToAssets(
                cToken.balanceOf(address(optimizer))
            );
            remainingMarketValue += marketAssets;
            uint256 marketLiquidity = cToken.assetsHeld();
            remainingLiquidity += marketAssets < marketLiquidity
                ? marketAssets
                : marketLiquidity;
            assertTrue(market != cUSDC_WETH_MARKET, "removed market excluded");
        }

        uint256 maxWithdraw = optimizer.maxWithdraw(address(this));
        uint256 maxRedeem = optimizer.maxRedeem(address(this));
        assertLe(maxWithdraw, remainingLiquidity, "maxWithdraw uses active liquidity");
        assertEq(maxRedeem, optimizer.balanceOf(address(this)), "maxRedeem full owner shares");

        uint256 expectedAssets = optimizer.previewRedeem(maxRedeem);
        assertLe(expectedAssets, remainingMarketValue, "previewRedeem bounded by active markets");

        uint256 actualAssets = optimizer.redeem(
            maxRedeem,
            address(this),
            address(this)
        );

        assertApproxEqAbs(
            actualAssets,
            expectedAssets,
            3,
            "redeem(maxRedeem) should settle against active markets"
        );
        assertEq(optimizer.balanceOf(address(this)), 0, "full exit burns shares");
    }
}

contract StrictPreviewMintConsumer {
    function strictPreviewMint(
        address vault,
        uint256 shares,
        address receiver
    ) external returns (uint256 assets) {
        require(
            IERC165(vault).supportsInterface(type(ERC4626).interfaceId),
            "not ERC4626"
        );

        ERC4626 erc4626Vault = ERC4626(vault);
        assets = erc4626Vault.previewMint(shares);
        IERC20 asset = IERC20(erc4626Vault.asset());

        require(asset.transferFrom(msg.sender, address(this), assets), "pull");
        require(asset.approve(vault, assets), "approve");

        assets = erc4626Vault.mint(shares, receiver);
    }
}

contract StrictPreviewWithdrawConsumer {
    function strictPreviewWithdraw(
        address vault,
        uint256 assets,
        address receiver
    ) external returns (uint256 shares) {
        require(
            IERC165(vault).supportsInterface(type(ERC4626).interfaceId),
            "not ERC4626"
        );

        ERC4626 erc4626Vault = ERC4626(vault);
        uint256 maxShares = erc4626Vault.previewWithdraw(assets);
        IERC20 asset = IERC20(erc4626Vault.asset());

        shares = erc4626Vault.withdraw(assets, address(this), msg.sender);
        require(shares <= maxShares, "max shares");
        require(asset.transfer(receiver, assets), "transfer");
    }
}

contract StrictPreviewRedeemConsumer {
    function strictPreviewRedeem(
        address vault,
        uint256 shares,
        address receiver
    ) external returns (uint256 assets) {
        require(
            IERC165(vault).supportsInterface(type(ERC4626).interfaceId),
            "not ERC4626"
        );

        ERC4626 erc4626Vault = ERC4626(vault);
        uint256 minAssets = erc4626Vault.previewRedeem(shares);
        IERC20 asset = IERC20(erc4626Vault.asset());

        assets = erc4626Vault.redeem(shares, address(this), msg.sender);
        require(assets >= minAssets, "min assets");
        require(asset.transfer(receiver, assets), "transfer");
    }
}
