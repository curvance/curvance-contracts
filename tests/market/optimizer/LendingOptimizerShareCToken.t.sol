// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {LendingOptimizer} from "contracts/market/optimizer/LendingOptimizer.sol";
import {LendingOptimizerShareCToken} from "contracts/market/token/LendingOptimizerShareCToken.sol";
import {BaseCToken} from "contracts/market/token/BaseCToken.sol";
import {BorrowableCToken} from "contracts/market/token/BorrowableCToken.sol";
import {DynamicIRM} from "contracts/market/DynamicIRM.sol";
import {MarketManagerIsolated} from "contracts/market/isolated/MarketManagerIsolated.sol";
import {OracleManager} from "contracts/oracles/OracleManager.sol";
import {VaultAggregator} from "contracts/oracles/adaptors/wrappedAggregators/VaultAggregator.sol";
import {BAD_SOURCE, WAD} from "contracts/libraries/ConstantsLib.sol";
import {FixedPointMathLib} from "contracts/libraries/external/FixedPointMathLib.sol";
import {PluginDelegable} from "contracts/libraries/PluginDelegable.sol";
import {BasePositionManager} from "contracts/market/position-management/BasePositionManager.sol";
import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";
import {IBorrowableCToken} from "contracts/interfaces/IBorrowableCToken.sol";
import {ICToken, AccountSnapshot} from "contracts/interfaces/ICToken.sol";
import {ILendingOptimizer} from "contracts/interfaces/ILendingOptimizer.sol";
import {IOracleAdaptor} from "contracts/interfaces/IOracleAdaptor.sol";
import {IERC165} from "contracts/interfaces/IERC165.sol";
import {IPositionManager} from "contracts/interfaces/IPositionManager.sol";
import {IERC20} from "contracts/interfaces/IERC20.sol";
import {ERC20} from "contracts/libraries/external/ERC20.sol";
import {MockV3Aggregator} from "contracts/mocks/MockV3Aggregator.sol";
import {CentralRegistry} from "contracts/architecture/CentralRegistry.sol";
import {MockERC20} from "tests/libraries/utils/mocks/MockERC20.sol";

import {LendingOptimizerHarness} from "./LendingOptimizerHarness.sol";
import {TestBaseLendingOptimizer} from "./TestBaseLendingOptimizer.sol";

contract TestLendingOptimizerShareCToken is TestBaseLendingOptimizer {
    LendingOptimizerShareCToken internal optimizerCToken;

    function setUp() public override {
        super.setUp();
        _setUpOneMarket();

        DynamicIRM irm = _deployOptimizerCTokenIRM();
        optimizerCToken = new LendingOptimizerShareCToken(
            liveCentralRegistry, ILendingOptimizer(address(optimizer)), _marketMgrs[cUSDC_WMON_MARKET], address(irm)
        );
        irm.setLinkedToken(address(optimizerCToken));
        _initializeOptimizerCToken();
    }

    function test_lendingOptimizerShareCToken_symbolsStayReadable() public {
        assertEq(optimizer.symbol(), "vFlagUSDC");
        assertEq(optimizerCToken.symbol(), "cvFlagUSDC");
        assertEq(optimizerCToken.asset(), address(optimizer));
        assertTrue(optimizerCToken.isBorrowable(), "DynamicIRM requires borrowable identity");
        assertEq(optimizerCToken.marketOutstandingDebt(), 0, "wrapper debt must start at zero");
    }

    function test_lendingOptimizerShareCToken_optimizerSupportsInterface() public view {
        assertTrue(optimizer.supportsInterface(type(ILendingOptimizer).interfaceId));
        assertTrue(optimizerCToken.supportsInterface(type(ICToken).interfaceId));
    }

    function test_lendingOptimizerShareCToken_rejectsNonOptimizerAsset() public {
        MockERC20 fakeOptimizer = new MockERC20("Fake Optimizer", "fOPT", 6);
        DynamicIRM irm = _deployOptimizerCTokenIRM();

        vm.expectRevert(LendingOptimizerShareCToken.LendingOptimizerShareCToken__InvalidOptimizer.selector);
        new LendingOptimizerShareCToken(
            liveCentralRegistry,
            ILendingOptimizer(address(fakeOptimizer)),
            _marketMgrs[cUSDC_WMON_MARKET],
            address(irm)
        );
    }

    function test_lendingOptimizerShareCToken_rejectsERC165OptimizerWithZeroAsset() public {
        MockInvalidLendingOptimizer fakeOptimizer =
            new MockInvalidLendingOptimizer(liveCentralRegistry, address(0), _singleFakeMarket());
        DynamicIRM irm = _deployOptimizerCTokenIRM();

        vm.expectRevert(LendingOptimizerShareCToken.LendingOptimizerShareCToken__InvalidOptimizer.selector);
        new LendingOptimizerShareCToken(
            liveCentralRegistry,
            ILendingOptimizer(address(fakeOptimizer)),
            _marketMgrs[cUSDC_WMON_MARKET],
            address(irm)
        );
    }

    function test_lendingOptimizerShareCToken_rejectsERC165OptimizerWithNoApprovedMarkets() public {
        MockInvalidLendingOptimizer fakeOptimizer =
            new MockInvalidLendingOptimizer(liveCentralRegistry, USDC_MONAD, new address[](0));
        DynamicIRM irm = _deployOptimizerCTokenIRM();

        vm.expectRevert(LendingOptimizerShareCToken.LendingOptimizerShareCToken__InvalidOptimizer.selector);
        new LendingOptimizerShareCToken(
            liveCentralRegistry,
            ILendingOptimizer(address(fakeOptimizer)),
            _marketMgrs[cUSDC_WMON_MARKET],
            address(irm)
        );
    }

    function test_lendingOptimizerShareCToken_rejectsERC165OptimizerFromDifferentRegistry() public {
        MockInvalidLendingOptimizer fakeOptimizer = new MockInvalidLendingOptimizer(
            ICentralRegistry(makeAddr("wrongCentralRegistry")), USDC_MONAD, _singleFakeMarket()
        );
        DynamicIRM irm = _deployOptimizerCTokenIRM();

        vm.expectRevert(LendingOptimizerShareCToken.LendingOptimizerShareCToken__InvalidOptimizer.selector);
        new LendingOptimizerShareCToken(
            liveCentralRegistry,
            ILendingOptimizer(address(fakeOptimizer)),
            _marketMgrs[cUSDC_WMON_MARKET],
            address(irm)
        );
    }

    function test_lendingOptimizerShareCToken_dynamicIRMAcceptsBorrowableIdentity() public {
        DynamicIRM irm = DynamicIRM(address(optimizerCToken.IRM()));

        assertEq(irm.linkedToken(), address(optimizerCToken));
        assertTrue(optimizerCToken.isBorrowable(), "wrapper must remain DynamicIRM-compatible");
    }

    function test_lendingOptimizerShareCToken_snapshotHasBorrowableIdentityWithoutDebt() public {
        uint256 assetsBefore = _depositAndSkipForOptimizerYield();

        AccountSnapshot memory snapshot = optimizerCToken.getSnapshotUpdated(address(this));

        assertGt(optimizer.totalAssets(), assetsBefore, "snapshot path must sync optimizer NAV");
        assertEq(snapshot.asset, address(optimizerCToken));
        assertEq(snapshot.underlying, address(optimizer));
        assertEq(snapshot.decimals, optimizerCToken.decimals());
        assertTrue(snapshot.isCollateral, "zero-debt wrapper snapshot remains collateral-eligible");
        assertEq(snapshot.collateralPosted, 0);
        assertEq(snapshot.debtBalance, 0, "share wrapper must not report debt");
    }

    function test_lendingOptimizerShareCToken_accrueIfNeededAccruesOptimizerAndParent() public {
        uint256 assetsBefore = _depositAndSkipForOptimizerYield();
        (,, uint256 lastVestingClaimBefore,) = optimizerCToken.getYieldInformation();

        optimizerCToken.accrueIfNeeded();

        assertGt(optimizer.totalAssets(), assetsBefore, "direct accrue must sync optimizer NAV");
        (,, uint256 lastVestingClaimAfter,) = optimizerCToken.getYieldInformation();
        assertGt(lastVestingClaimAfter, lastVestingClaimBefore, "direct accrue must run parent cToken accrual");
        assertEq(lastVestingClaimAfter, block.timestamp, "parent accrual timestamp");
    }

    function test_lendingOptimizerShareCToken_getSnapshotUpdatedAccruesOptimizer() public {
        uint256 assetsBefore = _depositAndSkipForOptimizerYield();

        optimizerCToken.getSnapshotUpdated(address(this));

        assertGt(optimizer.totalAssets(), assetsBefore, "snapshot path must sync optimizer NAV");
    }

    function test_lendingOptimizerShareCToken_exchangeRateUpdatedAccruesOptimizer() public {
        uint256 assetsBefore = _depositAndSkipForOptimizerYield();
        (,, uint256 lastVestingClaimBefore,) = optimizerCToken.getYieldInformation();

        optimizerCToken.exchangeRateUpdated();

        assertGt(optimizer.totalAssets(), assetsBefore, "liquidation pricing path must sync optimizer NAV");
        (,, uint256 lastVestingClaimAfter,) = optimizerCToken.getYieldInformation();
        assertGt(lastVestingClaimAfter, lastVestingClaimBefore, "wrapper parent accrual must run");
        assertEq(lastVestingClaimAfter, block.timestamp, "wrapper parent accrual timestamp");
    }

    function test_lendingOptimizerShareCToken_isolatedPairPricingAccruesOptimizerBeforeVaultAggregator() public {
        uint256 assetsBefore = _depositIntoWrapperAndSkipForOptimizerYield();
        _registerOptimizerShareVaultPriceFeed();
        _refreshUsdcPriceFeed();
        _oracleManager.addCTokenSupport(address(optimizerCToken));

        assertEq(optimizer.totalAssets(), assetsBefore, "precondition: optimizer NAV is stale before isolated pricing");
        (uint256 staleOptimizerPrice, uint256 staleErrorCode) =
            _oracleManager.getPrice(address(optimizer), true, true);
        assertEq(staleErrorCode, 0);

        (uint256 collateralSharesPrice, uint256 debtUnderlyingPrice) = _oracleManager.getPriceIsolatedPair(
            address(optimizerCToken),
            cUSDC_WMON_MARKET,
            BAD_SOURCE
        );

        assertGt(optimizer.totalAssets(), assetsBefore, "isolated pair path must sync optimizer NAV before pricing");
        (uint256 freshOptimizerPrice, uint256 freshErrorCode) =
            _oracleManager.getPrice(address(optimizer), true, true);
        assertEq(freshErrorCode, 0);
        assertGt(freshOptimizerPrice, staleOptimizerPrice, "fresh VaultAggregator price should include accrued NAV");

        uint256 expectedCollateralSharesPrice = FixedPointMathLib.mulDiv(
            freshOptimizerPrice,
            optimizerCToken.exchangeRate(),
            WAD
        );
        assertEq(collateralSharesPrice, expectedCollateralSharesPrice);
        assertEq(debtUnderlyingPrice, WAD);
    }

    function test_lendingOptimizerShareCToken_getPricesForMarketAccruesOptimizerBeforeVaultAggregator() public {
        uint256 assetsBefore = _depositWrapperCollateralAndSkipForOptimizerYield();
        _registerOptimizerShareVaultPriceFeed();
        _oracleManager.addCTokenSupport(address(optimizerCToken));

        assertEq(optimizer.totalAssets(), assetsBefore, "precondition: optimizer NAV is stale before market pricing");
        (uint256 staleOptimizerPrice, uint256 staleErrorCode) =
            _oracleManager.getPrice(address(optimizer), true, true);
        assertEq(staleErrorCode, 0);

        address[] memory assets = new address[](1);
        assets[0] = address(optimizerCToken);
        (AccountSnapshot[] memory snapshots, uint256[] memory prices, uint256 numAssets) =
            _oracleManager.getPricesForMarket(address(this), assets, BAD_SOURCE);

        assertEq(numAssets, 1);
        assertTrue(snapshots[0].isCollateral, "wrapper collateral should price in shares");
        assertGt(optimizer.totalAssets(), assetsBefore, "market pricing path must sync optimizer NAV before pricing");

        (uint256 freshOptimizerPrice, uint256 freshErrorCode) =
            _oracleManager.getPrice(address(optimizer), true, true);
        assertEq(freshErrorCode, 0);
        assertGt(freshOptimizerPrice, staleOptimizerPrice, "fresh VaultAggregator price should include accrued NAV");

        uint256 expectedCollateralSharesPrice = FixedPointMathLib.mulDiv(
            freshOptimizerPrice,
            optimizerCToken.exchangeRate(),
            WAD
        );
        assertEq(prices[0], expectedCollateralSharesPrice);
    }

    function test_lendingOptimizerShareCToken_marketDebtViewsAccrueOptimizerAndStayZero() public {
        uint256 assetsBefore = _depositAndSkipForOptimizerYield();

        assertEq(optimizerCToken.marketOutstandingDebtUpdated(), 0);
        assertGt(optimizer.totalAssets(), assetsBefore, "market debt path must sync optimizer NAV");

        assetsBefore = optimizer.totalAssets();
        skip(30 days);

        assertEq(optimizerCToken.debtBalanceUpdated(address(this)), 0);
        assertGt(optimizer.totalAssets(), assetsBefore, "account debt path must sync optimizer NAV");
    }

    function test_lendingOptimizerShareCToken_adminInterestFeeUpdateAccruesOptimizer() public {
        uint256 assetsBefore = _depositAndSkipForOptimizerYield();

        optimizerCToken.setInterestFee(0);

        assertEq(optimizerCToken.interestFee(), 0);
        assertGt(optimizer.totalAssets(), assetsBefore, "admin fee path must sync optimizer NAV first");
    }

    function test_lendingOptimizer_transferAccruesOptimizer() public {
        address owner = makeAddr("optimizerTransferOwner");
        uint256 assetsBefore = _depositAndSkipForOptimizerYield(owner);
        address receiver = makeAddr("optimizerTransferReceiver");
        uint256 shares = optimizer.balanceOf(owner) / 3;
        uint256 ownerBalanceBefore = optimizer.balanceOf(owner);
        uint256 receiverBalanceBefore = optimizer.balanceOf(receiver);

        vm.prank(owner);
        assertTrue(optimizer.transfer(receiver, shares));

        assertGt(optimizer.totalAssets(), assetsBefore, "optimizer transfer path must sync NAV");
        assertEq(optimizer.balanceOf(owner), ownerBalanceBefore - shares);
        assertEq(optimizer.balanceOf(receiver), receiverBalanceBefore + shares);
    }

    function test_lendingOptimizer_transferFromAccruesOptimizer() public {
        address owner = makeAddr("optimizerTransferFromOwner");
        uint256 assetsBefore = _depositAndSkipForOptimizerYield(owner);
        address spender = makeAddr("optimizerTransferSpender");
        address receiver = makeAddr("optimizerTransferFromReceiver");
        uint256 shares = optimizer.balanceOf(owner) / 3;
        uint256 ownerBalanceBefore = optimizer.balanceOf(owner);
        uint256 receiverBalanceBefore = optimizer.balanceOf(receiver);

        vm.prank(owner);
        optimizer.approve(spender, shares);
        vm.prank(spender);
        assertTrue(optimizer.transferFrom(owner, receiver, shares));

        assertGt(optimizer.totalAssets(), assetsBefore, "optimizer transferFrom path must sync NAV");
        assertEq(optimizer.balanceOf(owner), ownerBalanceBefore - shares);
        assertEq(optimizer.balanceOf(receiver), receiverBalanceBefore + shares);
        assertEq(optimizer.allowance(owner, spender), 0);
    }

    function test_lendingOptimizer_transferRejectsZeroAndSelfTransfer() public {
        _depositAndSkipForOptimizerYield();

        vm.expectRevert(LendingOptimizer.LendingOptimizer__ZeroAmount.selector);
        optimizer.transfer(makeAddr("optimizerZeroTransferReceiver"), 0);

        vm.expectRevert(LendingOptimizer.LendingOptimizer__InvalidParameter.selector);
        optimizer.transfer(address(this), 1);
    }

    function test_lendingOptimizer_transferRejectsZeroBeforeSelfTransfer() public {
        _depositAndSkipForOptimizerYield();

        vm.expectRevert(LendingOptimizer.LendingOptimizer__ZeroAmount.selector);
        optimizer.transfer(address(this), 0);
    }

    function test_lendingOptimizer_transferFromRejectsZeroAndSelfTransfer() public {
        _depositAndSkipForOptimizerYield();
        address spender = makeAddr("optimizerTransferFromRejectSpender");
        address receiver = makeAddr("optimizerTransferFromRejectReceiver");

        optimizer.approve(spender, 1);
        vm.prank(spender);
        vm.expectRevert(LendingOptimizer.LendingOptimizer__ZeroAmount.selector);
        optimizer.transferFrom(address(this), receiver, 0);

        vm.prank(spender);
        vm.expectRevert(LendingOptimizer.LendingOptimizer__InvalidParameter.selector);
        optimizer.transferFrom(address(this), address(this), 1);
    }

    function test_lendingOptimizer_transferFromRejectsInvalidBeforeAllowance() public {
        _depositAndSkipForOptimizerYield();
        address spender = makeAddr("optimizerTransferFromNoAllowanceSpender");
        address receiver = makeAddr("optimizerTransferFromNoAllowanceReceiver");

        vm.prank(spender);
        vm.expectRevert(LendingOptimizer.LendingOptimizer__ZeroAmount.selector);
        optimizer.transferFrom(address(this), receiver, 0);

        vm.prank(spender);
        vm.expectRevert(LendingOptimizer.LendingOptimizer__InvalidParameter.selector);
        optimizer.transferFrom(address(this), address(this), 1);

        assertEq(optimizer.allowance(address(this), spender), 0);
    }

    function test_lendingOptimizer_transferFromRejectsZeroBeforeSelfTransfer() public {
        _depositAndSkipForOptimizerYield();
        address spender = makeAddr("optimizerTransferFromZeroBeforeSelfSpender");

        vm.prank(spender);
        vm.expectRevert(LendingOptimizer.LendingOptimizer__ZeroAmount.selector);
        optimizer.transferFrom(address(this), address(this), 0);
    }

    function test_lendingOptimizerShareCToken_depositAccruesOptimizerAndMintsWrapperShares() public {
        uint256 assetsBefore = _depositAndSkipForOptimizerYield();
        uint256 optimizerShares = optimizer.balanceOf(address(this)) / 2;
        address receiver = makeAddr("depositReceiver");
        uint256 expectedShares = optimizerCToken.previewDeposit(optimizerShares);
        uint256 receiverBalance = optimizerCToken.balanceOf(receiver);
        uint256 totalAssetsBefore = optimizerCToken.totalAssets();

        IERC20(address(optimizer)).approve(address(optimizerCToken), optimizerShares);
        _mockCanMint();
        uint256 shares = optimizerCToken.deposit(optimizerShares, receiver);

        assertGt(optimizer.totalAssets(), assetsBefore, "deposit path must sync optimizer NAV");
        assertEq(shares, expectedShares);
        assertEq(optimizerCToken.balanceOf(receiver), receiverBalance + shares);
        assertEq(optimizerCToken.totalAssets(), totalAssetsBefore + optimizerShares);
        vm.clearMockedCalls();
    }

    function test_lendingOptimizerShareCToken_mintAccruesOptimizerAndConsumesPreviewAssets() public {
        uint256 assetsBefore = _depositAndSkipForOptimizerYield();
        uint256 shares = 12345;
        uint256 expectedAssets = optimizerCToken.previewMint(shares);
        address receiver = makeAddr("mintReceiver");
        uint256 receiverBalance = optimizerCToken.balanceOf(receiver);
        uint256 totalAssetsBefore = optimizerCToken.totalAssets();

        IERC20(address(optimizer)).approve(address(optimizerCToken), expectedAssets);
        _mockCanMint();
        uint256 assets = optimizerCToken.mint(shares, receiver);

        assertGt(optimizer.totalAssets(), assetsBefore, "mint path must sync optimizer NAV");
        assertEq(assets, expectedAssets);
        assertEq(optimizerCToken.balanceOf(receiver), receiverBalance + shares);
        assertEq(optimizerCToken.totalAssets(), totalAssetsBefore + assets);
        vm.clearMockedCalls();
    }

    function test_lendingOptimizerShareCToken_depositAsCollateralAccruesAndPostsCollateral() public {
        uint256 assetsBefore = _depositAndSkipForOptimizerYield();
        uint256 optimizerShares = optimizer.balanceOf(address(this)) / 2;
        uint256 expectedShares = optimizerCToken.previewDeposit(optimizerShares);

        IERC20(address(optimizer)).approve(address(optimizerCToken), optimizerShares);
        _mockCanMint();
        _mockCanCollateralize(address(this), expectedShares);
        uint256 shares = optimizerCToken.depositAsCollateral(optimizerShares, address(this));

        assertGt(optimizer.totalAssets(), assetsBefore, "depositAsCollateral path must sync optimizer NAV");
        assertEq(shares, expectedShares);
        assertEq(optimizerCToken.collateralPosted(address(this)), expectedShares);
        assertEq(optimizerCToken.marketCollateralPosted(), expectedShares);
        vm.clearMockedCalls();
    }

    function test_lendingOptimizerShareCToken_redeemAccruesOptimizerAndReturnsOptimizerShares() public {
        uint256 assetsBefore = _depositIntoWrapperAndSkipForOptimizerYield();
        address receiver = makeAddr("redeemReceiver");
        uint256 shares = optimizerCToken.balanceOf(address(this)) / 2;
        uint256 expectedAssets = optimizerCToken.previewRedeem(shares);
        uint256 receiverAssetsBefore = optimizer.balanceOf(receiver);
        uint256 totalAssetsBefore = optimizerCToken.totalAssets();

        _mockCanRedeem(address(this), shares, false, 0);
        uint256 assets = optimizerCToken.redeem(shares, receiver, address(this));

        assertGt(optimizer.totalAssets(), assetsBefore, "redeem path must sync optimizer NAV");
        assertEq(assets, expectedAssets);
        assertEq(optimizer.balanceOf(receiver), receiverAssetsBefore + assets);
        assertEq(optimizerCToken.totalAssets(), totalAssetsBefore - assets);
        vm.clearMockedCalls();
    }

    function test_lendingOptimizerShareCToken_withdrawAccruesOptimizerAndBurnsPreviewShares() public {
        uint256 assetsBefore = _depositIntoWrapperAndSkipForOptimizerYield();
        address receiver = makeAddr("withdrawReceiver");
        uint256 assets = optimizerCToken.convertToAssets(optimizerCToken.balanceOf(address(this)) / 2);
        uint256 expectedShares = optimizerCToken.previewWithdraw(assets);
        uint256 receiverAssetsBefore = optimizer.balanceOf(receiver);
        uint256 totalAssetsBefore = optimizerCToken.totalAssets();

        _mockCanRedeem(address(this), expectedShares, false, 0);
        uint256 shares = optimizerCToken.withdraw(assets, receiver, address(this));

        assertGt(optimizer.totalAssets(), assetsBefore, "withdraw path must sync optimizer NAV");
        assertEq(shares, expectedShares);
        assertEq(optimizer.balanceOf(receiver), receiverAssetsBefore + assets);
        assertEq(optimizerCToken.totalAssets(), totalAssetsBefore - assets);
        vm.clearMockedCalls();
    }

    function test_lendingOptimizerShareCToken_redeemForRequiresDelegateAndPreservesReceiver() public {
        address owner = makeAddr("wrapperRedeemForOwner");
        address delegate = makeAddr("wrapperRedeemForDelegate");
        address receiver = makeAddr("wrapperRedeemForReceiver");
        uint256 assetsBefore = _depositIntoWrapperAndSkipForOptimizerYield(owner);
        uint256 shares = optimizerCToken.balanceOf(owner) / 2;
        uint256 expectedAssets = optimizerCToken.previewRedeem(shares);
        uint256 ownerSharesBefore = optimizerCToken.balanceOf(owner);
        uint256 receiverAssetsBefore = optimizer.balanceOf(receiver);
        uint256 delegateAssetsBefore = optimizer.balanceOf(delegate);

        vm.prank(delegate);
        vm.expectRevert(PluginDelegable.PluginDelegable__Unauthorized.selector);
        optimizerCToken.redeemFor(shares, receiver, owner);

        vm.prank(owner);
        optimizerCToken.setDelegateApproval(delegate, true);

        _mockCanRedeem(owner, shares, false, 0);
        vm.prank(delegate);
        uint256 assets = optimizerCToken.redeemFor(shares, receiver, owner);

        assertGt(optimizer.totalAssets(), assetsBefore, "redeemFor must sync optimizer NAV");
        assertEq(assets, expectedAssets);
        assertEq(optimizerCToken.balanceOf(owner), ownerSharesBefore - shares);
        assertEq(optimizer.balanceOf(receiver), receiverAssetsBefore + assets);
        assertEq(optimizer.balanceOf(delegate), delegateAssetsBefore);
        vm.clearMockedCalls();
    }

    function test_lendingOptimizerShareCToken_redeemCollateralForcesCollateralRemoval() public {
        _depositWrapperCollateral();
        uint256 assetsBefore = optimizer.totalAssets();
        skip(30 days);

        uint256 shares = optimizerCToken.collateralPosted(address(this)) / 2;
        uint256 postedBefore = optimizerCToken.collateralPosted(address(this));
        address receiver = makeAddr("redeemCollateralReceiver");
        uint256 expectedAssets = optimizerCToken.previewRedeem(shares);

        _mockCanRedeem(address(this), shares, true, shares);
        uint256 assets = optimizerCToken.redeemCollateral(shares, receiver, address(this));

        assertGt(optimizer.totalAssets(), assetsBefore, "redeemCollateral path must sync optimizer NAV");
        assertEq(assets, expectedAssets);
        assertEq(optimizerCToken.collateralPosted(address(this)), postedBefore - shares);
        assertEq(optimizerCToken.marketCollateralPosted(), postedBefore - shares);
        vm.clearMockedCalls();
    }

    function test_lendingOptimizerShareCToken_withdrawCollateralForcesCollateralRemoval() public {
        _depositWrapperCollateral();
        uint256 assetsBefore = optimizer.totalAssets();
        skip(30 days);

        uint256 postedBefore = optimizerCToken.collateralPosted(address(this));
        uint256 assets = optimizerCToken.convertToAssets(postedBefore / 2);
        uint256 expectedShares = optimizerCToken.previewWithdraw(assets);
        address receiver = makeAddr("withdrawCollateralReceiver");

        _mockCanRedeem(address(this), expectedShares, true, expectedShares);
        uint256 shares = optimizerCToken.withdrawCollateral(assets, receiver, address(this));

        assertGt(optimizer.totalAssets(), assetsBefore, "withdrawCollateral path must sync optimizer NAV");
        assertEq(shares, expectedShares);
        assertEq(optimizerCToken.collateralPosted(address(this)), postedBefore - expectedShares);
        assertEq(optimizerCToken.marketCollateralPosted(), postedBefore - expectedShares);
        vm.clearMockedCalls();
    }

    function test_lendingOptimizerShareCToken_transferAccruesOptimizer() public {
        uint256 assetsBefore = _depositIntoWrapperAndSkipForOptimizerYield();
        address receiver = makeAddr("transferReceiver");
        uint256 shares = 1;

        _mockCanTransfer(address(this), receiver, shares);
        optimizerCToken.transfer(receiver, shares);

        assertGt(optimizer.totalAssets(), assetsBefore, "transfer path must sync optimizer NAV");
        vm.clearMockedCalls();
    }

    function test_lendingOptimizerShareCToken_transferFromAccruesOptimizer() public {
        uint256 assetsBefore = _depositIntoWrapperAndSkipForOptimizerYield();
        address spender = makeAddr("transferSpender");
        address receiver = makeAddr("transferFromReceiver");
        uint256 shares = 1;

        optimizerCToken.approve(spender, shares);
        _mockCanTransfer(address(this), receiver, shares);
        vm.prank(spender);
        optimizerCToken.transferFrom(address(this), receiver, shares);

        assertGt(optimizer.totalAssets(), assetsBefore, "transferFrom path must sync optimizer NAV");
        vm.clearMockedCalls();
    }

    function test_lendingOptimizerShareCToken_transferRejectsZeroAndSelfTransfer() public {
        _depositIntoWrapperAndSkipForOptimizerYield();

        vm.expectRevert(BaseCToken.BaseCToken__ZeroAmount.selector);
        optimizerCToken.transfer(makeAddr("zeroTransferReceiver"), 0);

        vm.expectRevert(BaseCToken.BaseCToken__TransferError.selector);
        optimizerCToken.transfer(address(this), 1);
    }

    function test_lendingOptimizerShareCToken_transferFromRejectsZeroAndSelfTransfer() public {
        _depositIntoWrapperAndSkipForOptimizerYield();
        address spender = makeAddr("transferFromRejectSpender");
        address receiver = makeAddr("transferFromRejectReceiver");

        optimizerCToken.approve(spender, 1);
        vm.prank(spender);
        vm.expectRevert(BaseCToken.BaseCToken__ZeroAmount.selector);
        optimizerCToken.transferFrom(address(this), receiver, 0);

        vm.prank(spender);
        vm.expectRevert(BaseCToken.BaseCToken__TransferError.selector);
        optimizerCToken.transferFrom(address(this), address(this), 1);
    }

    function test_lendingOptimizerShareCToken_transferRemovesCollateralReturnedByMarketManager() public {
        _depositWrapperCollateral();
        uint256 assetsBefore = optimizer.totalAssets();
        skip(30 days);

        address receiver = makeAddr("collateralTransferReceiver");
        uint256 shares = optimizerCToken.collateralPosted(address(this)) / 2;
        uint256 collateralBefore = optimizerCToken.collateralPosted(address(this));
        uint256 marketCollateralBefore = optimizerCToken.marketCollateralPosted();

        _mockCanTransfer(address(this), receiver, shares, shares);
        optimizerCToken.transfer(receiver, shares);

        assertGt(optimizer.totalAssets(), assetsBefore, "collateralized transfer path must sync optimizer NAV");
        assertEq(optimizerCToken.collateralPosted(address(this)), collateralBefore - shares);
        assertEq(optimizerCToken.marketCollateralPosted(), marketCollateralBefore - shares);
        vm.clearMockedCalls();
    }

    function test_lendingOptimizerShareCToken_cannotBeApprovedOptimizerMarket() public {
        vm.expectRevert(LendingOptimizer.LendingOptimizer__InvalidUnderlying.selector);
        optimizer.addApprovedAsset(address(optimizerCToken), 1_000);
    }

    function test_lendingOptimizer_addApprovedAssetAllowsNormalMarketPair() public {
        optimizer.addApprovedAsset(cUSDC_WBTC_MARKET, 1_000);

        assertEq(optimizer.allocationCaps(cUSDC_WBTC_MARKET), WAD / 10);
    }

    function test_lendingOptimizerShareCToken_launchMarketIsCollateralOnlyAndPriceGuarded() public {
        (
            MarketManagerIsolated optimizerMarket,
            BorrowableCToken debtCToken,
            LendingOptimizerShareCToken shareCToken
        ) = _deployOptimizerShareLaunchMarket();

        assertEq(address(shareCToken.marketManager()), address(optimizerMarket));
        assertEq(address(debtCToken.marketManager()), address(optimizerMarket));
        assertEq(shareCToken.asset(), address(optimizer));
        assertEq(debtCToken.asset(), USDC_MONAD);
        assertTrue(shareCToken.isBorrowable(), "DynamicIRM-compatible identity");
        assertTrue(debtCToken.isBorrowable(), "paired debt side is borrowable");
        assertEq(_oracleManager.cTokens(address(shareCToken)), address(optimizer));
        assertEq(_oracleManager.cTokens(address(debtCToken)), USDC_MONAD);

        address[] memory listedTokens = optimizerMarket.queryTokensListed();
        assertEq(listedTokens.length, 2);
        assertEq(listedTokens[0], address(shareCToken));
        assertEq(listedTokens[1], address(debtCToken));

        assertEq(optimizerMarket.collateralCaps(address(shareCToken)), 1_000_000e6);
        assertEq(optimizerMarket.debtCaps(address(shareCToken)), 0);
        assertEq(optimizerMarket.collateralCaps(address(debtCToken)), 0);
        assertEq(optimizerMarket.debtCaps(address(debtCToken)), 1_000_000e6);

        IOracleAdaptor.PriceGuard memory guard = _chainlinkAdaptor.getPriceGuard(address(optimizer), true);
        assertEq(uint256(guard.minPrice), 0);
        assertEq(uint256(guard.basePrice), WAD);
        assertEq(uint256(guard.ips), 0);
        assertEq(uint256(guard.timestampStart), 0);

        vm.expectRevert(LendingOptimizerShareCToken.LendingOptimizerShareCToken__BorrowDisabled.selector);
        shareCToken.borrow(1, address(this));

        vm.expectRevert(LendingOptimizerShareCToken.LendingOptimizerShareCToken__BorrowDisabled.selector);
        shareCToken.borrowFor(1, address(this), address(this));

        IPositionManager.LeverageAction memory action;
        vm.expectRevert(LendingOptimizerShareCToken.LendingOptimizerShareCToken__BorrowDisabled.selector);
        shareCToken.borrowForPositionManager(1, address(this), action);

        vm.expectRevert(LendingOptimizerShareCToken.LendingOptimizerShareCToken__BorrowDisabled.selector);
        shareCToken.flashLoan(1, "");
    }

    function test_lendingOptimizerShareCToken_launchBorrowPathAccruesOptimizerBeforeCollateralCheck()
        public
    {
        (
            MarketManagerIsolated optimizerMarket,
            BorrowableCToken debtCToken,
            LendingOptimizerShareCToken shareCToken
        ) = _deployOptimizerShareLaunchMarket();

        uint256 lendAssets = 100_000e6;
        deal(USDC_MONAD, address(this), lendAssets);
        IERC20(USDC_MONAD).approve(address(debtCToken), lendAssets);
        debtCToken.deposit(lendAssets, address(this));

        uint256 optimizerShares = optimizer.balanceOf(address(this));
        IERC20(address(optimizer)).approve(address(shareCToken), optimizerShares);
        uint256 wrapperShares = shareCToken.deposit(optimizerShares, address(this));
        shareCToken.postCollateral(wrapperShares);

        uint256 staleTotalAssets = optimizer.totalAssets();
        skip(30 days);
        _refreshUsdcPriceFeed();
        _setOptimizerVaultFeedAnswer(1e8);
        assertEq(optimizer.totalAssets(), staleTotalAssets, "precondition: optimizer NAV is stale before borrow");

        debtCToken.borrow(20_000e6, address(this));

        assertGt(optimizer.totalAssets(), staleTotalAssets, "borrow collateral check must sync optimizer NAV");
        assertEq(shareCToken.collateralPosted(address(this)), wrapperShares);
        assertEq(debtCToken.debtBalance(address(this)), 20_000e6);
    }

    function test_lendingOptimizerShareCToken_launchWithdrawCollateralAfterRepayAccruesOptimizer()
        public
    {
        (
            MarketManagerIsolated optimizerMarket,
            BorrowableCToken debtCToken,
            LendingOptimizerShareCToken shareCToken
        ) = _deployOptimizerShareLaunchMarket();

        uint256 lendAssets = 100_000e6;
        deal(USDC_MONAD, address(this), lendAssets);
        IERC20(USDC_MONAD).approve(address(debtCToken), lendAssets);
        debtCToken.deposit(lendAssets, address(this));

        uint256 optimizerShares = optimizer.balanceOf(address(this));
        IERC20(address(optimizer)).approve(address(shareCToken), optimizerShares);
        uint256 wrapperShares = shareCToken.deposit(optimizerShares, address(this));
        shareCToken.postCollateral(wrapperShares);
        debtCToken.borrow(20_000e6, address(this));

        uint256 staleTotalAssets = optimizer.totalAssets();
        skip(30 days);
        _refreshUsdcPriceFeed();
        _setOptimizerVaultFeedAnswer(1e8);
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "precondition: optimizer NAV is stale before collateral exit"
        );

        deal(USDC_MONAD, address(this), 25_000e6);
        IERC20(USDC_MONAD).approve(address(debtCToken), type(uint256).max);
        debtCToken.repay(0);

        uint256 optimizerSharesToWithdraw = shareCToken.convertToAssets(wrapperShares / 2);
        uint256 expectedWrapperSharesBurned = shareCToken.previewWithdraw(optimizerSharesToWithdraw);
        uint256 receiverOptimizerSharesBefore = optimizer.balanceOf(user1);
        uint256 wrapperBalanceBefore = shareCToken.balanceOf(address(this));
        uint256 marketCollateralBefore = shareCToken.marketCollateralPosted();

        uint256 wrapperSharesBurned = shareCToken.withdrawCollateral(
            optimizerSharesToWithdraw,
            user1,
            address(this)
        );

        assertGt(
            optimizer.totalAssets(),
            staleTotalAssets,
            "collateral exit must sync optimizer NAV"
        );
        assertEq(wrapperSharesBurned, expectedWrapperSharesBurned);
        assertEq(
            optimizer.balanceOf(user1),
            receiverOptimizerSharesBefore + optimizerSharesToWithdraw,
            "receiver should get exact optimizer shares"
        );
        assertEq(
            shareCToken.balanceOf(address(this)),
            wrapperBalanceBefore - wrapperSharesBurned,
            "wrapper shares should burn from owner"
        );
        assertEq(
            shareCToken.collateralPosted(address(this)),
            wrapperShares - wrapperSharesBurned,
            "owner collateral should reduce by burned shares"
        );
        assertEq(
            shareCToken.marketCollateralPosted(),
            marketCollateralBefore - wrapperSharesBurned,
            "market collateral should reduce by burned shares"
        );

        (, uint256 maxDebt, uint256 debt) = optimizerMarket.statusOf(address(this));
        assertEq(debt, 0, "repay should clear launch debt before collateral exit");
        assertGe(maxDebt, debt, "account should remain healthy after collateral exit");
    }

    function test_lendingOptimizerShareCToken_partialRepayThenCollateralRemovalAccruesOptimizer()
        public
    {
        (
            ,
            BorrowableCToken debtCToken,
            LendingOptimizerShareCToken shareCToken
        ) = _deployOptimizerShareLaunchMarket();

        uint256 lendAssets = 100_000e6;
        deal(USDC_MONAD, address(this), lendAssets);
        IERC20(USDC_MONAD).approve(address(debtCToken), lendAssets);
        debtCToken.deposit(lendAssets, address(this));

        uint256 optimizerShares = optimizer.balanceOf(address(this));
        IERC20(address(optimizer)).approve(address(shareCToken), optimizerShares);
        uint256 wrapperShares = shareCToken.deposit(optimizerShares, address(this));
        shareCToken.postCollateral(wrapperShares);
        debtCToken.borrow(20_000e6, address(this));

        uint256 staleTotalAssets = optimizer.totalAssets();
        skip(30 days);
        _refreshUsdcPriceFeed();
        _setOptimizerVaultFeedAnswer(1e8);
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "precondition: optimizer NAV is stale before partial repay"
        );

        uint256 repayAssets = 5_000e6;
        deal(USDC_MONAD, address(this), repayAssets);
        IERC20(USDC_MONAD).approve(address(debtCToken), repayAssets);
        debtCToken.repay(repayAssets);

        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "partial repay reviews debt asset only and should not sync optimizer NAV"
        );
        uint256 debtAfterPartialRepay = debtCToken.debtBalance(address(this));
        assertGt(debtAfterPartialRepay, 10_000e6, "partial repay should leave live debt");

        {
            (, uint256 maxDebt, uint256 debt) =
                shareCToken.marketManager().statusOf(address(this));
            assertGt(
                optimizer.totalAssets(),
                staleTotalAssets,
                "statusOf after partial repay must sync optimizer-share collateral NAV"
            );
            assertGt(debt, 0, "partial repay should leave market debt live");
            assertGe(maxDebt, debt, "account should remain healthy after partial repay");
        }

        uint256 secondStaleTotalAssets = optimizer.totalAssets();
        skip(30 days);
        _refreshUsdcPriceFeed();
        _setOptimizerVaultFeedAnswer(1e8);
        assertEq(
            optimizer.totalAssets(),
            secondStaleTotalAssets,
            "precondition: optimizer NAV is stale before collateral removal"
        );

        {
            uint256 optimizerSharesToWithdraw = optimizerShares / 20;
            uint256 receiverOptimizerSharesBefore = optimizer.balanceOf(user1);
            uint256 wrapperBalanceBefore = shareCToken.balanceOf(address(this));
            uint256 marketCollateralBefore = shareCToken.marketCollateralPosted();

            uint256 wrapperSharesBurned = shareCToken.withdrawCollateral(
                optimizerSharesToWithdraw,
                user1,
                address(this)
            );

            assertGt(
                optimizer.totalAssets(),
                secondStaleTotalAssets,
                "collateral removal with live debt must sync optimizer NAV"
            );
            assertEq(
                optimizer.balanceOf(user1),
                receiverOptimizerSharesBefore + optimizerSharesToWithdraw,
                "receiver should get exact optimizer shares"
            );
            assertEq(
                shareCToken.balanceOf(address(this)),
                wrapperBalanceBefore - wrapperSharesBurned,
                "wrapper shares should burn from owner"
            );
            assertEq(
                shareCToken.marketCollateralPosted(),
                marketCollateralBefore - wrapperSharesBurned,
                "market collateral should reduce by burned shares"
            );
        }

        {
            (, uint256 maxDebt, uint256 debt) =
                shareCToken.marketManager().statusOf(address(this));
            assertGt(
                debt,
                0,
                "partial repay should still leave debt after collateral removal"
            );
            assertGe(maxDebt, debt, "account should remain healthy after collateral removal");
        }
    }

    function test_lendingOptimizerShareCToken_positionManagerBorrowPostsFreshOptimizerCollateral()
        public
    {
        (
            MarketManagerIsolated optimizerMarket,
            BorrowableCToken debtCToken,
            LendingOptimizerShareCToken shareCToken
        ) = _deployOptimizerShareLaunchMarket();
        OptimizerSharePositionManagerHarness positionManager = _deployOptimizerSharePositionManager(optimizerMarket);

        uint256 lendAssets = 100_000e6;
        deal(USDC_MONAD, address(this), lendAssets);
        IERC20(USDC_MONAD).approve(address(debtCToken), lendAssets);
        debtCToken.deposit(lendAssets, address(this));

        uint256 optimizerShares = optimizer.balanceOf(address(this)) / 2;
        uint256 expectedShares = shareCToken.previewDeposit(optimizerShares);
        IERC20(address(optimizer)).transfer(address(positionManager), optimizerShares);

        uint256 staleTotalAssets = optimizer.totalAssets();
        skip(30 days);
        _refreshUsdcPriceFeed();
        _setOptimizerVaultFeedAnswer(1e8);
        assertEq(optimizer.totalAssets(), staleTotalAssets, "precondition: optimizer NAV is stale before PM borrow");

        address account = makeAddr("optimizerSharePmAccount");
        IPositionManager.LeverageAction memory action;
        action.borrowableCToken = IBorrowableCToken(address(debtCToken));
        action.borrowAssets = 20_000e6;
        action.cToken = ICToken(address(shareCToken));
        action.expectedShares = expectedShares;

        vm.prank(account);
        positionManager.leverage(action, 0);

        assertGt(optimizer.totalAssets(), staleTotalAssets, "PM borrow collateral check must sync optimizer NAV");
        assertEq(shareCToken.collateralPosted(account), expectedShares);
        assertEq(debtCToken.debtBalance(account), action.borrowAssets);
        assertEq(IERC20(address(optimizer)).balanceOf(address(positionManager)), 0, "PM optimizer residue");
        assertEq(IERC20(USDC_MONAD).balanceOf(address(positionManager)), 0, "PM debt residue");
        assertEq(IERC20(USDC_MONAD).balanceOf(positionManager.swapSink()), action.borrowAssets, "swap sink debt");
    }

    function test_lendingOptimizerShareCToken_positionManagerBorrowRevertsAtomicallyWhenExpectedSharesTooHigh()
        public
    {
        (
            MarketManagerIsolated optimizerMarket,
            BorrowableCToken debtCToken,
            LendingOptimizerShareCToken shareCToken
        ) = _deployOptimizerShareLaunchMarket();
        OptimizerSharePositionManagerHarness positionManager = _deployOptimizerSharePositionManager(optimizerMarket);

        uint256 lendAssets = 100_000e6;
        deal(USDC_MONAD, address(this), lendAssets);
        IERC20(USDC_MONAD).approve(address(debtCToken), lendAssets);
        debtCToken.deposit(lendAssets, address(this));

        uint256 optimizerShares = optimizer.balanceOf(address(this)) / 2;
        uint256 expectedShares = shareCToken.previewDeposit(optimizerShares);
        IERC20(address(optimizer)).transfer(address(positionManager), optimizerShares);

        address account = makeAddr("optimizerSharePmSlippageAccount");
        IPositionManager.LeverageAction memory action;
        action.borrowableCToken = IBorrowableCToken(address(debtCToken));
        action.borrowAssets = 20_000e6;
        action.cToken = ICToken(address(shareCToken));
        action.expectedShares = expectedShares + 1;

        vm.prank(account);
        vm.expectRevert(BasePositionManager.BasePositionManager__InvalidSlippage.selector);
        positionManager.leverage(action, 0);

        assertEq(shareCToken.collateralPosted(account), 0, "collateral must roll back");
        assertEq(debtCToken.debtBalance(account), 0, "debt must roll back");
        assertEq(IERC20(address(optimizer)).balanceOf(address(positionManager)), optimizerShares, "PM inventory");
        assertEq(IERC20(USDC_MONAD).balanceOf(address(positionManager)), 0, "PM debt residue");
        assertEq(IERC20(USDC_MONAD).balanceOf(positionManager.swapSink()), 0, "swap sink must roll back");
    }

    function test_lendingOptimizerShareCToken_positionManagerDeleverageAccruesOptimizerAndRepaysDebt()
        public
    {
        (
            MarketManagerIsolated optimizerMarket,
            BorrowableCToken debtCToken,
            LendingOptimizerShareCToken shareCToken
        ) = _deployOptimizerShareLaunchMarket();
        OptimizerSharePositionManagerHarness positionManager = _deployOptimizerSharePositionManager(optimizerMarket);

        uint256 lendAssets = 100_000e6;
        deal(USDC_MONAD, address(this), lendAssets);
        IERC20(USDC_MONAD).approve(address(debtCToken), lendAssets);
        debtCToken.deposit(lendAssets, address(this));

        address account = makeAddr("optimizerSharePmDeleverageAccount");
        uint256 optimizerShares = optimizer.balanceOf(address(this)) / 2;
        uint256 expectedShares = shareCToken.previewDeposit(optimizerShares);
        IERC20(address(optimizer)).transfer(address(positionManager), optimizerShares);

        IPositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken = IBorrowableCToken(address(debtCToken));
        leverageAction.borrowAssets = 20_000e6;
        leverageAction.cToken = ICToken(address(shareCToken));
        leverageAction.expectedShares = expectedShares;

        vm.prank(account);
        positionManager.leverage(leverageAction, 0);

        uint256 collateralBefore = shareCToken.collateralPosted(account);
        uint256 debtBefore = debtCToken.debtBalance(account);
        uint256 collateralAssets = 5_000e6;
        uint256 expectedWrapperSharesBurned = shareCToken.previewWithdraw(collateralAssets);
        uint256 repayAssets = 5_000e6;
        deal(USDC_MONAD, address(positionManager), repayAssets);

        uint256 staleTotalAssets = optimizer.totalAssets();
        skip(30 days);
        _refreshUsdcPriceFeed();
        _setOptimizerVaultFeedAnswer(1e8);
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "precondition: optimizer NAV is stale before PM deleverage"
        );

        IPositionManager.DeleverageAction memory deleverageAction;
        deleverageAction.cToken = ICToken(address(shareCToken));
        deleverageAction.collateralAssets = collateralAssets;
        deleverageAction.borrowableCToken = IBorrowableCToken(address(debtCToken));
        deleverageAction.repayAssets = repayAssets;

        vm.prank(account);
        positionManager.deleverage(deleverageAction, 0.05e18);

        assertGt(optimizer.totalAssets(), staleTotalAssets, "PM deleverage must sync optimizer NAV");
        assertEq(
            shareCToken.collateralPosted(account),
            collateralBefore - expectedWrapperSharesBurned,
            "collateral should reduce by redeemed wrapper shares"
        );
        assertLt(debtCToken.debtBalance(account), debtBefore, "deleverage should repay debt");
        assertEq(IERC20(USDC_MONAD).balanceOf(address(positionManager)), 0, "PM debt residue");
        assertEq(IERC20(address(optimizer)).balanceOf(address(positionManager)), 0, "PM optimizer residue");
        assertEq(
            IERC20(address(optimizer)).balanceOf(positionManager.swapSink()),
            collateralAssets,
            "swap sink should receive redeemed optimizer shares"
        );
    }

    function test_lendingOptimizerShareCToken_oracleSupportRemovalLeavesMarketLiveButBlocksLiquidation()
        public
    {
        (
            MarketManagerIsolated optimizerMarket,
            BorrowableCToken debtCToken,
            LendingOptimizerShareCToken shareCToken
        ) = _deployOptimizerShareLaunchMarket();

        uint256 lendAssets = 100_000e6;
        deal(USDC_MONAD, address(this), lendAssets);
        IERC20(USDC_MONAD).approve(address(debtCToken), lendAssets);
        debtCToken.deposit(lendAssets, address(this));

        uint256 optimizerShares = optimizer.balanceOf(address(this));
        IERC20(address(optimizer)).approve(address(shareCToken), optimizerShares);
        uint256 wrapperShares = shareCToken.deposit(optimizerShares, address(this));

        _oracleManager.removeCTokenSupport(address(shareCToken));
        assertEq(_oracleManager.cTokens(address(shareCToken)), address(0));
        assertEq(optimizerMarket.collateralCaps(address(shareCToken)), 1_000_000e6);
        assertEq(optimizerMarket.debtCaps(address(debtCToken)), 1_000_000e6);

        shareCToken.postCollateral(wrapperShares);
        debtCToken.borrow(20_000e6, address(this));

        assertEq(shareCToken.collateralPosted(address(this)), wrapperShares);
        assertEq(debtCToken.debtBalance(address(this)), 20_000e6);

        address[] memory accounts = new address[](1);
        accounts[0] = address(this);
        vm.prank(makeAddr("oracleSupportRemovalLiquidator"));
        vm.expectRevert(OracleManager.OracleManager__NotSupported.selector);
        debtCToken.liquidate(accounts, address(shareCToken));
    }

    function test_lendingOptimizerShareCToken_liquidationAccruesStaleOptimizerCollateral()
        public
    {
        (
            ,
            BorrowableCToken debtCToken,
            LendingOptimizerShareCToken shareCToken
        ) = _deployOptimizerShareLaunchMarket();

        uint256 lendAssets = 300_000e6;
        uint256 borrowAssets = 130_000e6;
        deal(USDC_MONAD, address(this), lendAssets);
        IERC20(USDC_MONAD).approve(address(debtCToken), lendAssets);
        debtCToken.deposit(lendAssets, address(this));

        uint256 optimizerShares = optimizer.balanceOf(address(this));
        IERC20(address(optimizer)).approve(address(shareCToken), optimizerShares);
        uint256 wrapperShares = shareCToken.deposit(optimizerShares, address(this));
        shareCToken.postCollateral(wrapperShares);
        debtCToken.borrow(borrowAssets, address(this));

        uint256 staleTotalAssets = optimizer.totalAssets();
        skip(30 days);
        _refreshUsdcPriceFeed();
        _setOptimizerVaultFeedAnswer(0.5e8);
        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "precondition: optimizer NAV is stale before liquidation"
        );

        address liquidator = makeAddr("optimizerShareLiquidator");
        deal(USDC_MONAD, liquidator, 100_000e6);
        vm.startPrank(liquidator);
        IERC20(USDC_MONAD).approve(address(debtCToken), type(uint256).max);
        address[] memory accounts = new address[](1);
        accounts[0] = address(this);
        debtCToken.liquidate(accounts, address(shareCToken));
        vm.stopPrank();

        assertGt(
            optimizer.totalAssets(),
            staleTotalAssets,
            "liquidation pricing must sync optimizer NAV before seizing collateral"
        );
        assertLt(
            debtCToken.debtBalance(address(this)),
            borrowAssets,
            "liquidation should repay borrower debt"
        );
        assertGt(
            shareCToken.balanceOf(liquidator),
            0,
            "liquidator should receive optimizer-share collateral"
        );
    }

    function test_lendingOptimizerShareCToken_priceGuardCapsUpsideAndAllowsDownside() public {
        _deployOptimizerShareLaunchMarket();

        _setOptimizerVaultFeedAnswer(2e8);
        (uint256 cappedPrice, uint256 cappedErrorCode) =
            _oracleManager.getPrice(address(optimizer), true, false);
        assertEq(cappedErrorCode, 0);
        assertEq(cappedPrice, WAD, "optimizer share price should be capped at basePrice");

        _setOptimizerVaultFeedAnswer(0.5e8);
        (uint256 downsidePrice, uint256 downsideErrorCode) =
            _oracleManager.getPrice(address(optimizer), true, true);
        assertEq(downsideErrorCode, 0);
        assertEq(downsidePrice, WAD / 2, "minPrice zero must not block downside pricing");
    }

    function test_lendingOptimizer_rejectsApprovedDebtMarketPairedWithOptimizerShares() public {
        (, BorrowableCToken debtCToken,) = _deployOptimizerShareLaunchMarket();

        vm.expectRevert(LendingOptimizer.LendingOptimizer__InvalidMarketManager.selector);
        optimizer.addApprovedAsset(address(debtCToken), 1_000);
    }

    function test_lendingOptimizerShareCToken_borrowingAndFlashloanDisabledInContract() public {
        vm.expectRevert(LendingOptimizerShareCToken.LendingOptimizerShareCToken__BorrowDisabled.selector);
        optimizerCToken.borrow(1, address(this));

        vm.expectRevert(LendingOptimizerShareCToken.LendingOptimizerShareCToken__BorrowDisabled.selector);
        optimizerCToken.borrowFor(1, address(this), address(this));

        IPositionManager.LeverageAction memory action;
        vm.expectRevert(LendingOptimizerShareCToken.LendingOptimizerShareCToken__BorrowDisabled.selector);
        optimizerCToken.borrowForPositionManager(1, address(this), action);

        vm.expectRevert(LendingOptimizerShareCToken.LendingOptimizerShareCToken__BorrowDisabled.selector);
        optimizerCToken.flashLoan(1, "");
    }

    function testFuzz_lendingOptimizerShareCToken_borrowSurfacesAlwaysDisabled(
        uint256 assets,
        address receiver,
        address owner,
        address caller,
        bytes calldata data
    ) public {
        IPositionManager.LeverageAction memory action;

        vm.prank(caller);
        vm.expectRevert(LendingOptimizerShareCToken.LendingOptimizerShareCToken__BorrowDisabled.selector);
        optimizerCToken.borrow(assets, receiver);

        vm.prank(caller);
        vm.expectRevert(LendingOptimizerShareCToken.LendingOptimizerShareCToken__BorrowDisabled.selector);
        optimizerCToken.borrowFor(assets, receiver, owner);

        vm.prank(caller);
        vm.expectRevert(LendingOptimizerShareCToken.LendingOptimizerShareCToken__BorrowDisabled.selector);
        optimizerCToken.borrowForPositionManager(assets, owner, action);

        vm.prank(caller);
        vm.expectRevert(LendingOptimizerShareCToken.LendingOptimizerShareCToken__BorrowDisabled.selector);
        optimizerCToken.flashLoan(assets, data);
    }

    function testFuzz_lendingOptimizer_transferMovesBalancesAndAccrues(uint256 rawShares, address receiver) public {
        address owner = makeAddr("fuzzOptimizerTransferOwner");
        vm.assume(receiver != address(0));
        vm.assume(receiver != address(this));
        vm.assume(receiver != owner);

        uint256 assetsBefore = _depositAndSkipForOptimizerYield(owner);
        uint256 ownerBalanceBefore = optimizer.balanceOf(owner);
        uint256 receiverBalanceBefore = optimizer.balanceOf(receiver);
        uint256 shares = bound(rawShares, 1, ownerBalanceBefore);

        vm.prank(owner);
        assertTrue(optimizer.transfer(receiver, shares));

        assertGt(optimizer.totalAssets(), assetsBefore, "fuzz optimizer transfer must sync NAV");
        assertEq(optimizer.balanceOf(owner), ownerBalanceBefore - shares);
        assertEq(optimizer.balanceOf(receiver), receiverBalanceBefore + shares);
    }

    function testFuzz_lendingOptimizer_transferFromMovesBalancesAndAccrues(
        uint256 rawShares,
        address receiver
    ) public {
        address owner = makeAddr("fuzzOptimizerTransferFromOwner");
        address spender = makeAddr("fuzzOptimizerTransferFromSpender");
        vm.assume(receiver != address(0));
        vm.assume(receiver != address(this));
        vm.assume(receiver != owner);

        uint256 assetsBefore = _depositAndSkipForOptimizerYield(owner);
        uint256 ownerBalanceBefore = optimizer.balanceOf(owner);
        uint256 receiverBalanceBefore = optimizer.balanceOf(receiver);
        uint256 shares = bound(rawShares, 1, ownerBalanceBefore);

        vm.prank(owner);
        optimizer.approve(spender, shares);
        vm.prank(spender);
        assertTrue(optimizer.transferFrom(owner, receiver, shares));

        assertGt(optimizer.totalAssets(), assetsBefore, "fuzz optimizer transferFrom must sync NAV");
        assertEq(optimizer.balanceOf(owner), ownerBalanceBefore - shares);
        assertEq(optimizer.balanceOf(receiver), receiverBalanceBefore + shares);
        assertEq(optimizer.allowance(owner, spender), 0);
    }

    function testFuzz_lendingOptimizerShareCToken_transferMovesBalancesAndAccrues(
        uint256 rawShares,
        address receiver
    ) public {
        vm.assume(receiver != address(0));
        vm.assume(receiver != address(this));

        uint256 assetsBefore = _depositIntoWrapperAndSkipForOptimizerYield();
        uint256 ownerBalanceBefore = optimizerCToken.balanceOf(address(this));
        uint256 receiverBalanceBefore = optimizerCToken.balanceOf(receiver);
        uint256 shares = bound(rawShares, 1, ownerBalanceBefore);

        _mockCanTransfer(address(this), receiver, shares);
        assertTrue(optimizerCToken.transfer(receiver, shares));

        assertGt(optimizer.totalAssets(), assetsBefore, "fuzz transfer must sync optimizer NAV");
        assertEq(optimizerCToken.balanceOf(address(this)), ownerBalanceBefore - shares);
        assertEq(optimizerCToken.balanceOf(receiver), receiverBalanceBefore + shares);
        vm.clearMockedCalls();
    }

    function testFuzz_lendingOptimizerShareCToken_transferFromMovesBalancesAndAccrues(
        uint256 rawShares,
        address receiver
    ) public {
        address owner = makeAddr("fuzzTransferFromOwner");
        address spender = makeAddr("fuzzTransferFromSpender");
        vm.assume(receiver != address(0));
        vm.assume(receiver != owner);

        uint256 assetsBefore = _depositIntoWrapperAndSkipForOptimizerYield(owner);
        uint256 ownerBalanceBefore = optimizerCToken.balanceOf(owner);
        uint256 receiverBalanceBefore = optimizerCToken.balanceOf(receiver);
        uint256 shares = bound(rawShares, 1, ownerBalanceBefore);

        vm.prank(owner);
        optimizerCToken.approve(spender, shares);
        _mockCanTransfer(owner, receiver, shares);
        vm.prank(spender);
        assertTrue(optimizerCToken.transferFrom(owner, receiver, shares));

        assertGt(optimizer.totalAssets(), assetsBefore, "fuzz transferFrom must sync optimizer NAV");
        assertEq(optimizerCToken.balanceOf(owner), ownerBalanceBefore - shares);
        assertEq(optimizerCToken.balanceOf(receiver), receiverBalanceBefore + shares);
        assertEq(optimizerCToken.allowance(owner, spender), 0);
        vm.clearMockedCalls();
    }

    function testFuzz_lendingOptimizerShareCToken_depositAndMintAccounting(
        uint256 rawDepositAssets,
        uint256 rawMintShares,
        address receiver
    ) public {
        vm.assume(receiver != address(0));

        uint256 assetsBefore = _depositAndSkipForOptimizerYield();
        uint256 optimizerShares = optimizer.balanceOf(address(this));
        uint256 depositAssets = bound(rawDepositAssets, 1, optimizerShares / 2);
        uint256 expectedDepositShares = optimizerCToken.previewDeposit(depositAssets);

        IERC20(address(optimizer)).approve(address(optimizerCToken), optimizerShares);
        _mockCanMint();
        uint256 depositShares = optimizerCToken.deposit(depositAssets, receiver);

        assertGt(optimizer.totalAssets(), assetsBefore, "fuzz deposit must sync optimizer NAV");
        assertEq(depositShares, expectedDepositShares);
        assertEq(optimizerCToken.balanceOf(receiver), depositShares);

        assetsBefore = optimizer.totalAssets();
        skip(30 days);

        uint256 remainingOptimizerShares = optimizer.balanceOf(address(this));
        uint256 maxMintShares = optimizerCToken.convertToShares(remainingOptimizerShares / 2);
        uint256 mintShares = bound(rawMintShares, 1, maxMintShares);
        uint256 expectedMintAssets = optimizerCToken.previewMint(mintShares);
        _mockCanMint();
        uint256 mintAssets = optimizerCToken.mint(mintShares, receiver);

        assertGt(optimizer.totalAssets(), assetsBefore, "fuzz mint must sync optimizer NAV");
        assertEq(mintAssets, expectedMintAssets);
        assertEq(optimizerCToken.balanceOf(receiver), depositShares + mintShares);
        vm.clearMockedCalls();
    }

    function testFuzz_lendingOptimizerShareCToken_redeemAndWithdrawAccounting(
        uint256 rawRedeemShares,
        uint256 rawWithdrawAssets,
        address receiver
    ) public {
        vm.assume(receiver != address(0));

        uint256 assetsBefore = _depositIntoWrapperAndSkipForOptimizerYield();
        uint256 balanceBeforeRedeem = optimizerCToken.balanceOf(address(this));
        uint256 redeemShares = bound(rawRedeemShares, 1, balanceBeforeRedeem / 2);
        uint256 expectedRedeemAssets = optimizerCToken.previewRedeem(redeemShares);

        _mockCanRedeem(address(this), redeemShares, false, 0);
        uint256 redeemedAssets = optimizerCToken.redeem(redeemShares, receiver, address(this));

        assertGt(optimizer.totalAssets(), assetsBefore, "fuzz redeem must sync optimizer NAV");
        assertEq(redeemedAssets, expectedRedeemAssets);

        assetsBefore = optimizer.totalAssets();
        skip(30 days);

        uint256 maxWithdrawAssets = optimizerCToken.convertToAssets(optimizerCToken.balanceOf(address(this)));
        uint256 withdrawAssets = bound(rawWithdrawAssets, 1, maxWithdrawAssets);
        uint256 expectedWithdrawShares = optimizerCToken.previewWithdraw(withdrawAssets);

        _mockCanRedeem(address(this), expectedWithdrawShares, false, 0);
        uint256 withdrawnShares = optimizerCToken.withdraw(withdrawAssets, receiver, address(this));

        assertGt(optimizer.totalAssets(), assetsBefore, "fuzz withdraw must sync optimizer NAV");
        assertEq(withdrawnShares, expectedWithdrawShares);
        assertEq(optimizerCToken.balanceOf(address(this)), balanceBeforeRedeem - redeemShares - withdrawnShares);
        vm.clearMockedCalls();
    }

    function testFuzz_lendingOptimizerShareCToken_collateralizedTransferAccounting(
        uint256 rawPostedShares,
        uint256 rawTransferShares,
        uint256 rawCollateralRedeemed,
        address receiver
    ) public {
        vm.assume(receiver != address(0));
        vm.assume(receiver != address(this));

        _depositIntoWrapperAndSkipForOptimizerYield();
        uint256 ownerBalance = optimizerCToken.balanceOf(address(this));
        uint256 postedShares = bound(rawPostedShares, 1, ownerBalance);

        _mockCanCollateralize(address(this), postedShares);
        optimizerCToken.postCollateral(postedShares);

        uint256 assetsBefore = optimizer.totalAssets();
        skip(30 days);

        uint256 transferShares = bound(rawTransferShares, 1, ownerBalance);
        uint256 collateralRedeemed = bound(rawCollateralRedeemed, 0, postedShares);

        _mockCanTransfer(address(this), receiver, transferShares, collateralRedeemed);
        optimizerCToken.transfer(receiver, transferShares);

        assertGt(optimizer.totalAssets(), assetsBefore, "fuzz collateralized transfer must sync optimizer NAV");
        assertEq(optimizerCToken.collateralPosted(address(this)), postedShares - collateralRedeemed);
        assertEq(optimizerCToken.marketCollateralPosted(), postedShares - collateralRedeemed);
        vm.clearMockedCalls();
    }

    function _depositAndSkipForOptimizerYield() internal returns (uint256 assetsBefore) {
        return _depositAndSkipForOptimizerYield(address(this));
    }

    function _depositAndSkipForOptimizerYield(address receiver) internal returns (uint256 assetsBefore) {
        uint256 depositAmount = 100_000e6;
        deal(USDC_MONAD, address(this), depositAmount);
        IERC20(USDC_MONAD).approve(address(optimizer), depositAmount);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(depositAmount, receiver, cUSDC_WMON_MARKET);

        assetsBefore = optimizer.totalAssets();
        skip(30 days);
    }

    function _depositIntoWrapperAndSkipForOptimizerYield() internal returns (uint256 assetsBefore) {
        return _depositIntoWrapperAndSkipForOptimizerYield(address(this));
    }

    function _depositIntoWrapperAndSkipForOptimizerYield(address receiver) internal returns (uint256 assetsBefore) {
        uint256 depositAmount = 100_000e6;
        deal(USDC_MONAD, address(this), depositAmount);
        IERC20(USDC_MONAD).approve(address(optimizer), depositAmount);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(depositAmount, address(this), cUSDC_WMON_MARKET);

        uint256 optimizerShares = optimizer.balanceOf(address(this));
        IERC20(address(optimizer)).approve(address(optimizerCToken), optimizerShares);
        _mockCanMint();
        optimizerCToken.deposit(optimizerShares, receiver);

        assetsBefore = optimizer.totalAssets();
        skip(30 days);
    }

    function _depositWrapperCollateral() internal {
        _depositIntoWrapperAndSkipForOptimizerYield();
        uint256 shares = optimizerCToken.balanceOf(address(this));

        _mockCanCollateralize(address(this), shares);
        optimizerCToken.postCollateral(shares);
        vm.clearMockedCalls();
    }

    function _depositWrapperCollateralAndSkipForOptimizerYield() internal returns (uint256 assetsBefore) {
        _depositIntoWrapperAndSkipForOptimizerYield();
        uint256 shares = optimizerCToken.balanceOf(address(this));

        _mockCanCollateralize(address(this), shares);
        optimizerCToken.postCollateral(shares);
        vm.clearMockedCalls();

        assetsBefore = optimizer.totalAssets();
        skip(30 days);
    }

    function _deployOptimizerCTokenIRM() internal returns (DynamicIRM) {
        return new DynamicIRM(liveCentralRegistry, 1200, 2000, 8500, 500, 200, 100000);
    }

    function _initializeOptimizerCToken() internal {
        _mintOptimizerShares(100_000e6);

        IERC20(address(optimizer)).approve(address(optimizerCToken), 77777);
        vm.prank(_marketMgrs[cUSDC_WMON_MARKET]);
        optimizerCToken.initializeDeposits(address(this));
    }

    function _deployOptimizerShareLaunchMarket()
        internal
        returns (
            MarketManagerIsolated optimizerMarket,
            BorrowableCToken debtCToken,
            LendingOptimizerShareCToken shareCToken
        )
    {
        CentralRegistry cr = CentralRegistry(address(liveCentralRegistry));
        optimizerMarket = new MarketManagerIsolated(liveCentralRegistry, 10e18, false);
        cr.addMarketManager(address(optimizerMarket));

        DynamicIRM debtIRM = _deployOptimizerCTokenIRM();
        debtCToken = new BorrowableCToken(
            liveCentralRegistry,
            IERC20(USDC_MONAD),
            address(optimizerMarket),
            address(debtIRM)
        );
        debtIRM.setLinkedToken(address(debtCToken));

        DynamicIRM shareIRM = _deployOptimizerCTokenIRM();
        shareCToken = new LendingOptimizerShareCToken(
            liveCentralRegistry,
            ILendingOptimizer(address(optimizer)),
            address(optimizerMarket),
            address(shareIRM)
        );
        shareIRM.setLinkedToken(address(shareCToken));

        _registerOptimizerShareVaultPriceFeed();
        _chainlinkAdaptor.setGuardedPriceConfig(address(optimizer), true, 0, 0, WAD, 0);
        _oracleManager.addCTokenSupport(address(debtCToken));
        _oracleManager.addCTokenSupport(address(shareCToken));

        _mintOptimizerShares(100_000e6);
        IERC20(address(optimizer)).approve(address(shareCToken), 77777);
        deal(USDC_MONAD, address(this), 77777);
        IERC20(USDC_MONAD).approve(address(debtCToken), 77777);
        optimizerMarket.listTokens(address(shareCToken), address(debtCToken));

        _configureToken(optimizerMarket, address(shareCToken), 7000, 1_000_000e6, 0);
        _configureToken(optimizerMarket, address(debtCToken), 0, 0, 1_000_000e6);
    }

    function _deployOptimizerSharePositionManager(
        MarketManagerIsolated optimizerMarket
    ) internal returns (OptimizerSharePositionManagerHarness positionManager) {
        positionManager = new OptimizerSharePositionManagerHarness(
            liveCentralRegistry,
            address(optimizerMarket),
            address(0),
            makeAddr("optimizerSharePmSwapSink")
        );
        optimizerMarket.addPositionManager(address(positionManager));
    }

    function _registerOptimizerShareVaultPriceFeed() internal {
        MockV3Aggregator usdcFeed = new MockV3Aggregator(8, 1e8);
        VaultAggregator optimizerVaultFeed = new VaultAggregator(
            address(optimizer),
            USDC_MONAD,
            address(usdcFeed),
            "optimizer/USD"
        );

        _chainlinkAdaptor.addAsset(address(optimizer), true, address(optimizerVaultFeed), 0);
        _oracleManager.addAssetPricingAdaptor(
            address(optimizer),
            address(_chainlinkAdaptor),
            0,
            0,
            0,
            0
        );
    }

    function _setOptimizerVaultFeedAnswer(int256 answer) internal {
        MockV3Aggregator usdcFeed = new MockV3Aggregator(8, answer);
        VaultAggregator optimizerVaultFeed = new VaultAggregator(
            address(optimizer),
            USDC_MONAD,
            address(usdcFeed),
            "optimizer/USD"
        );

        _chainlinkAdaptor.addAsset(address(optimizer), true, address(optimizerVaultFeed), 0);
    }

    function _refreshUsdcPriceFeed() internal {
        MockV3Aggregator usdcFeed = new MockV3Aggregator(8, 1e8);
        _chainlinkAdaptor.addAsset(USDC_MONAD, true, address(usdcFeed), 0);
    }

    function _mintOptimizerShares(uint256 assets) internal {
        deal(USDC_MONAD, address(this), assets);
        IERC20(USDC_MONAD).approve(address(optimizer), assets);
        optimizer.deposit(assets, address(this));
    }

    function _mockCanMint() internal {
        vm.mockCall(
            _marketMgrs[cUSDC_WMON_MARKET],
            abi.encodeWithSignature("canMint(address)", address(optimizerCToken)),
            hex""
        );
    }

    function _mockCanTransfer(address owner, address receiver, uint256 shares) internal {
        _mockCanTransfer(owner, receiver, shares, 0);
    }

    function _mockCanTransfer(address owner, address receiver, uint256 shares, uint256 collateralRedeemed) internal {
        vm.mockCall(
            _marketMgrs[cUSDC_WMON_MARKET],
            abi.encodeWithSignature(
                "canTransfer(address,uint256,address,uint256,uint256,bool)",
                address(optimizerCToken),
                shares,
                owner,
                optimizerCToken.balanceOf(owner),
                optimizerCToken.collateralPosted(owner),
                optimizerCToken.collateralPosted(owner) > 0 ? true : false
            ),
            abi.encode(collateralRedeemed)
        );
    }

    function _mockCanCollateralize(address owner, uint256 newNetCollateral) internal {
        vm.mockCall(
            _marketMgrs[cUSDC_WMON_MARKET],
            abi.encodeWithSignature(
                "canCollateralize(address,address,uint256)", address(optimizerCToken), owner, newNetCollateral
            ),
            hex""
        );
    }

    function _mockCanRedeem(
        address owner,
        uint256 shares,
        bool forceRedeemCollateral,
        uint256 collateralRedeemed
    ) internal {
        vm.mockCall(
            _marketMgrs[cUSDC_WMON_MARKET],
            abi.encodeWithSignature(
                "canRedeemWithCollateralRemoval(address,uint256,address,uint256,uint256,bool)",
                address(optimizerCToken),
                shares,
                owner,
                optimizerCToken.balanceOf(owner),
                optimizerCToken.collateralPosted(owner),
                forceRedeemCollateral
            ),
            abi.encode(collateralRedeemed)
        );
    }

    function _singleFakeMarket() internal pure returns (address[] memory markets) {
        markets = new address[](1);
        markets[0] = address(1);
    }
}

contract OptimizerSharePositionManagerHarness is BasePositionManager {
    address public immutable swapSink;

    constructor(
        ICentralRegistry cr,
        address mm,
        address wNative,
        address newSwapSink
    ) BasePositionManager(cr, mm, wNative) {
        swapSink = newSwapSink;
    }

    function _swapDebtAssetToCollateralAsset(
        LeverageAction memory action,
        address
    ) internal override {
        bool success = IERC20(action.borrowableCToken.asset()).transfer(swapSink, action.borrowAssets);
        require(success, "debt sink transfer failed");
    }

    function _swapCollateralAssetToDebtAsset(
        DeleverageAction memory action
    ) internal override {
        address collateralAsset = action.cToken.asset();
        uint256 collateralBalance = IERC20(collateralAsset).balanceOf(address(this));
        if (collateralBalance > 0) {
            bool success = IERC20(collateralAsset).transfer(swapSink, collateralBalance);
            require(success, "collateral sink transfer failed");
        }
    }
}

contract MockInvalidLendingOptimizer is MockERC20, ILendingOptimizer {
    uint256 public constant MAX_FEE_BPS = 1000;
    uint256 public constant MAX_MARKETS = 8;

    ICentralRegistry public immutable centralRegistry;
    address public immutable asset;

    address[] internal _approvedMarkets;

    mapping(address => uint256) public allocationCaps;
    uint256 public fee;
    uint256 public exchangeRateHighWatermark;
    uint8 public mintPaused;
    uint256 public totalAssets;

    constructor(ICentralRegistry centralRegistry_, address asset_, address[] memory approvedMarkets)
        MockERC20("Fake Lending Optimizer", "fLO", 6)
    {
        centralRegistry = centralRegistry_;
        asset = asset_;
        _approvedMarkets = approvedMarkets;
    }

    function balanceOf(address account) public view override(ERC20, ILendingOptimizer) returns (uint256) {
        return super.balanceOf(account);
    }

    function approvedCTokensList(uint256 index) external view returns (address) {
        return _approvedMarkets[index];
    }

    function convertToAssets(uint256 shares) external pure returns (uint256) {
        return shares;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = assets;
        totalAssets += assets;
        _mint(receiver, shares);
    }

    function initializeDeposits(address) external {}

    function addApprovedAsset(address newAsset, uint256) external {
        _approvedMarkets.push(newAsset);
    }

    function updateCap(address cToken, uint256 newCapBps) external {
        allocationCaps[cToken] = newCapBps;
    }

    function setFee(uint256 newFeeBps) external {
        fee = newFeeBps;
    }

    function setMintPaused(bool state) external {
        mintPaused = state ? 2 : 1;
    }

    function exchangeRate() external pure returns (uint256) {
        return 1e18;
    }

    function exchangeRateUpdated() external pure returns (uint256) {
        return 1e18;
    }

    function accrueIfNeeded() external {}

    function skim() external {}

    function skimAvailable() external pure returns (uint256) {
        return 0;
    }

    function numApprovedMarkets() external view returns (uint256) {
        return _approvedMarkets.length;
    }

    function getApprovedMarkets() external view returns (address[] memory) {
        return _approvedMarkets;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == type(ILendingOptimizer).interfaceId;
    }
}
