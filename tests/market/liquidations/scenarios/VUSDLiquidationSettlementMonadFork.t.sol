// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {CentralRegistry} from "contracts/architecture/CentralRegistry.sol";
import {BorrowableCToken} from "contracts/market/token/BorrowableCToken.sol";
import {
    MarketManagerIsolated
} from "contracts/market/isolated/MarketManagerIsolated.sol";
import {OracleManager} from "contracts/oracles/OracleManager.sol";
import {IERC20} from "contracts/interfaces/IERC20.sol";
import {
    SafeTransferLib
} from "contracts/libraries/external/SafeTransferLib.sol";

interface IGuardedPriceAdaptor {
    function setGuardedPriceConfig(
        address asset,
        bool inUSD,
        uint256 timestampStart,
        uint256 ips,
        uint256 basePrice,
        uint256 minPrice
    ) external;
}

interface IAccountableAsyncRedeemVault is IERC20 {
    function allowed(address account) external view returns (bool);

    function requestRedeem(uint256 shares, address controller, address owner)
        external
        returns (uint256 requestId);

    function processUpToRequestId(uint256 maxRequestId)
        external
        returns (uint256 processedShares, uint256 assetsUsed);

    function queue()
        external
        view
        returns (uint128 nextRequestId, uint128 lastRequestId);

    function totalQueuedShares() external view returns (uint256);

    function pendingRedeemRequest(uint256 requestId, address controller)
        external
        view
        returns (uint256 pendingShares);
}

/// @notice Pinned production-fork proof of the vUSD liquidation-to-realization
///         boundary. Liquidation remains permissionless and share-only, while
///         direct redemption and the asynchronous underlying exit are gated.
/// @dev The local PriceGuard change creates the documented plausible proposed
///      liquidation state. It does not claim a currently unhealthy borrower.
contract VUSDLiquidationSettlementMonadFork is Test {
    uint256 internal constant FORK_BLOCK = 88_438_699;

    address internal constant CENTRAL_REGISTRY =
        0x1310f352f1389969Ece6741671c4B919523912fF;
    address internal constant MARKET_MANAGER =
        0x2DB9AB1bB00d7000b21A2EbcE7D1a9b91F351E72;
    address internal constant CVUSD =
        0x42369AFe4bA4225b800b8024Acc5F14f42A3836C;
    address internal constant CAUSD =
        0x4806902Ec0320e5334c2B2679FFB58C830348F1c;
    address internal constant VUSD =
        0x8d3F9f9Eb2f5E8B48EFBB4074440D1E2A34Bc365;
    address internal constant ORACLE_MANAGER =
        0x65ADF8aE8420A58278De066593E6fF1713A137c5;
    address internal constant CHAINLINK_ADAPTOR =
        0x42B318abFDE82a43B3685eB65a5863B9367B22e1;
    address internal constant AUSD_DONOR_CTOKEN =
        0xAd4AA2a713fB86FBb6b60dE2aF9E32a11DB6Abf2;

    address internal constant BORROWER =
        0x0104118920e1FB1379D3C80c0e81F3173B81116A;
    address internal constant ALLOWLISTED_LIQUIDATOR =
        0xeC0D6aF584C9816Db3938De9A3F882AEe601aE08;

    uint256 internal constant DEBT_TO_LIQUIDATE = 100_000e6;
    uint256 internal constant EXPECTED_SEIZED_SHARES = 137_316.051096e6;
    uint256 internal constant EXPECTED_BAD_DEBT_REALIZED = 4_066.897026e6;
    uint256 internal constant EXPECTED_DEBT_REMOVED =
        DEBT_TO_LIQUIDATE + EXPECTED_BAD_DEBT_REALIZED;
    uint256 internal constant QUEUED_VUSD = 100_000e6;
    bytes4 internal constant UNAUTHORIZED_SELECTOR = 0x82b42900;

    CentralRegistry internal constant centralRegistry =
        CentralRegistry(CENTRAL_REGISTRY);
    MarketManagerIsolated internal constant marketManager =
        MarketManagerIsolated(MARKET_MANAGER);
    BorrowableCToken internal constant cVUSD = BorrowableCToken(CVUSD);
    BorrowableCToken internal constant cAUSD = BorrowableCToken(CAUSD);
    OracleManager internal constant oracleManager =
        OracleManager(ORACLE_MANAGER);
    IAccountableAsyncRedeemVault internal constant vUSD =
        IAccountableAsyncRedeemVault(VUSD);

    IERC20 internal ausd;
    address internal ordinaryHolder;

    struct RedemptionState {
        uint256 holderShares;
        uint256 totalSupply;
        uint256 totalAssets;
        uint256 cTokenVUSDBalance;
        uint256 holderVUSDBalance;
        uint256 vUSDTotalSupply;
        uint256 totalQueuedShares;
        uint128 nextRequestId;
        uint128 lastRequestId;
    }

    struct LiquidationState {
        uint256 borrowerDebt;
        uint256 borrowerShares;
        uint256 borrowerPosted;
        uint256 liquidatorShares;
        uint256 liquidatorPosted;
        uint256 borrowerVUSD;
        uint256 liquidatorVUSD;
        uint256 cTokenVUSD;
        uint256 cTokenSupply;
        uint256 cTokenAssets;
        uint256 marketDebt;
        uint256 marketAUSD;
        uint256 debtMarketTotalAssets;
    }

    function setUp() public {
        vm.createSelectFork(
            vm.envString("MON_NODE_URI_MONAD_ARCHIVE"), FORK_BLOCK
        );

        ordinaryHolder = makeAddr("ordinary-nonallowlisted-holder");
        ausd = IERC20(cAUSD.asset());

        assertEq(cVUSD.asset(), VUSD, "wrong cVUSD underlying");
        assertEq(
            address(cVUSD.marketManager()),
            MARKET_MANAGER,
            "wrong cVUSD manager"
        );
        assertEq(
            address(cAUSD.marketManager()),
            MARKET_MANAGER,
            "wrong cAUSD manager"
        );
        assertEq(
            oracleManager.cTokens(CVUSD), VUSD, "wrong cVUSD oracle mapping"
        );

        address[] memory adaptors = oracleManager.getPricingAdaptors(VUSD);
        assertEq(adaptors.length, 1, "unexpected vUSD route count");
        assertEq(adaptors[0], CHAINLINK_ADAPTOR, "wrong vUSD adaptor");

        assertTrue(vUSD.allowed(CVUSD), "cVUSD is not allowlisted");
        assertTrue(
            vUSD.allowed(ALLOWLISTED_LIQUIDATOR),
            "settlement receiver is not allowlisted"
        );
        assertFalse(
            vUSD.allowed(ordinaryHolder), "ordinary holder allowlisted"
        );
        assertEq(
            cAUSD.debtBalance(ALLOWLISTED_LIQUIDATOR), 0, "liquidator has debt"
        );
        assertEq(
            cVUSD.collateralPosted(ALLOWLISTED_LIQUIDATOR),
            cVUSD.balanceOf(ALLOWLISTED_LIQUIDATOR),
            "liquidator has unposted preexisting shares"
        );
        assertEq(
            vUSD.pendingRedeemRequest(1, ALLOWLISTED_LIQUIDATOR),
            0,
            "liquidator owns request 1"
        );
        assertEq(
            vUSD.pendingRedeemRequest(2, ALLOWLISTED_LIQUIDATOR),
            0,
            "liquidator owns request 2"
        );

        cVUSD.accrueIfNeeded();
        cAUSD.accrueIfNeeded();

        _fundLiquidatorFromUnrelatedMarket();
        vm.prank(ALLOWLISTED_LIQUIDATOR);
        ausd.approve(CAUSD, type(uint256).max);
    }

    function test_liquidationMovesOnlyCVUSDSharesThenAllowlistedExitQueuesButCannotBeForced()
        public
    {
        _assertHealthyControlAndInstallCap();
        uint256 seizedShares = _liquidateAndAssertShareOnly();
        _assertRedemptionControlsAndQueueBoundary(seizedShares);
    }

    function _assertHealthyControlAndInstallCap() internal {
        vm.prank(ALLOWLISTED_LIQUIDATOR);
        vm.expectRevert(
            MarketManagerIsolated.MarketManager__NoLiquidationAvailable
            .selector
        );
        _liquidateExact();

        (uint256 liveVUSDPrice, uint256 liveErrorCode) =
            oracleManager.getPrice(VUSD, true, true);
        assertEq(liveErrorCode, 0, "live vUSD route unhealthy");
        assertGt(
            liveVUSDPrice, 0.75e18, "live price already below proposed cap"
        );

        vm.prank(centralRegistry.emergencyCouncil());
        IGuardedPriceAdaptor(CHAINLINK_ADAPTOR)
            .setGuardedPriceConfig(VUSD, true, 0, 0, 0.75e18, 0);

        (uint256 cappedVUSDPrice, uint256 cappedErrorCode) =
            oracleManager.getPrice(VUSD, true, true);
        assertEq(cappedVUSDPrice, 0.75e18, "vUSD cap did not bind");
        assertEq(cappedErrorCode, 0, "capped route unhealthy");
    }

    function _liquidateAndAssertShareOnly()
        internal
        returns (uint256 seizedShares)
    {
        LiquidationState memory beforeState = _liquidationState();
        assertGt(
            beforeState.borrowerDebt,
            DEBT_TO_LIQUIDATE,
            "borrower debt too small"
        );
        assertEq(
            beforeState.borrowerShares,
            beforeState.borrowerPosted,
            "borrower has unexpected unposted shares"
        );

        vm.prank(ALLOWLISTED_LIQUIDATOR);
        _liquidateExact();

        seizedShares = cVUSD.balanceOf(ALLOWLISTED_LIQUIDATOR)
            - beforeState.liquidatorShares;
        uint256 debtRemoved =
            beforeState.borrowerDebt - cAUSD.debtBalance(BORROWER);
        assertEq(seizedShares, EXPECTED_SEIZED_SHARES, "wrong seized shares");
        assertEq(
            debtRemoved, EXPECTED_DEBT_REMOVED, "wrong total debt removed"
        );
        assertEq(
            cVUSD.balanceOf(BORROWER),
            beforeState.borrowerShares - seizedShares,
            "wrong borrower share delta"
        );
        assertEq(
            cVUSD.collateralPosted(BORROWER),
            beforeState.borrowerPosted - seizedShares,
            "wrong posted-collateral delta"
        );
        assertEq(
            cVUSD.collateralPosted(ALLOWLISTED_LIQUIDATOR),
            beforeState.liquidatorPosted,
            "seized shares were posted"
        );
        assertEq(
            cAUSD.debtBalance(BORROWER),
            beforeState.borrowerDebt - EXPECTED_DEBT_REMOVED,
            "wrong borrower debt delta"
        );
        assertEq(
            cAUSD.marketOutstandingDebt(),
            beforeState.marketDebt - EXPECTED_DEBT_REMOVED,
            "wrong market debt delta"
        );
        assertEq(
            cAUSD.totalAssets(),
            beforeState.debtMarketTotalAssets - EXPECTED_BAD_DEBT_REALIZED,
            "wrong bad-debt asset delta"
        );
        assertEq(
            ausd.balanceOf(CAUSD),
            beforeState.marketAUSD + DEBT_TO_LIQUIDATE,
            "wrong market AUSD delta"
        );
        assertEq(
            cVUSD.totalSupply(),
            beforeState.cTokenSupply,
            "seizure changed supply"
        );
        assertEq(
            cVUSD.totalAssets(),
            beforeState.cTokenAssets,
            "seizure changed assets"
        );

        // The liquidation leg never invokes vUSD: all three relevant vUSD
        // balances remain byte-for-byte unchanged.
        assertEq(
            vUSD.balanceOf(BORROWER),
            beforeState.borrowerVUSD,
            "borrower vUSD changed"
        );
        assertEq(
            vUSD.balanceOf(ALLOWLISTED_LIQUIDATOR),
            beforeState.liquidatorVUSD,
            "liquidator vUSD changed during seizure"
        );
        assertEq(
            vUSD.balanceOf(CVUSD),
            beforeState.cTokenVUSD,
            "cToken vUSD changed"
        );
    }

    function _assertRedemptionControlsAndQueueBoundary(uint256 seizedShares)
        internal
    {
        // Make an ordinary EOA a holder of one atomic cVUSD share. Its direct
        // self-redemption reaches the external allowlist and rolls back every
        // Curvance and queue/accounting write when vUSD rejects the transfer.
        vm.prank(ALLOWLISTED_LIQUIDATOR);
        cVUSD.transfer(ordinaryHolder, 1);
        RedemptionState memory beforeRejectedRedeem =
            _redemptionState(ordinaryHolder);

        vm.prank(ordinaryHolder);
        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        cVUSD.redeem(1, ordinaryHolder, ordinaryHolder);
        _assertRedemptionStateEq(
            beforeRejectedRedeem, _redemptionState(ordinaryHolder)
        );

        // A non-owner also cannot burn the allowlisted holder's seized shares.
        uint256 liquidatorSharesBeforeTheft =
            cVUSD.balanceOf(ALLOWLISTED_LIQUIDATOR);
        vm.prank(ordinaryHolder);
        vm.expectRevert();
        cVUSD.redeem(1, ordinaryHolder, ALLOWLISTED_LIQUIDATOR);
        assertEq(
            cVUSD.balanceOf(ALLOWLISTED_LIQUIDATOR),
            liquidatorSharesBeforeTheft,
            "third party burned liquidator shares"
        );
        assertEq(
            cVUSD.totalSupply(),
            beforeRejectedRedeem.totalSupply,
            "theft attempt changed supply"
        );

        uint256 seizedSharesRemaining = seizedShares - 1;
        assertGe(
            liquidatorSharesBeforeTheft,
            seizedSharesRemaining,
            "seized shares missing after transfer"
        );

        _assertAllowlistedRedemptionAndQueue(seizedSharesRemaining);
    }

    function _assertAllowlistedRedemptionAndQueue(uint256 sharesToRedeem)
        internal
    {
        uint256 liquidatorSharesBeforeRedeem =
            cVUSD.balanceOf(ALLOWLISTED_LIQUIDATOR);
        uint256 liquidatorVUSDBeforeRedeem =
            vUSD.balanceOf(ALLOWLISTED_LIQUIDATOR);
        uint256 cTokenVUSDBeforeRedeem = vUSD.balanceOf(CVUSD);
        uint256 supplyBeforeRedeem = cVUSD.totalSupply();

        vm.prank(ALLOWLISTED_LIQUIDATOR);
        uint256 redeemedVUSD = cVUSD.redeem(
            sharesToRedeem, ALLOWLISTED_LIQUIDATOR, ALLOWLISTED_LIQUIDATOR
        );
        assertEq(
            redeemedVUSD, sharesToRedeem, "cVUSD did not redeem one-for-one"
        );
        assertEq(
            cVUSD.balanceOf(ALLOWLISTED_LIQUIDATOR),
            liquidatorSharesBeforeRedeem - sharesToRedeem,
            "wrong liquidator share burn"
        );
        assertEq(
            vUSD.balanceOf(ALLOWLISTED_LIQUIDATOR),
            liquidatorVUSDBeforeRedeem + redeemedVUSD,
            "allowlisted receiver did not receive vUSD"
        );
        assertEq(
            vUSD.balanceOf(CVUSD),
            cTokenVUSDBeforeRedeem - redeemedVUSD,
            "cToken vUSD did not leave"
        );
        assertEq(
            cVUSD.totalSupply(),
            supplyBeforeRedeem - sharesToRedeem,
            "cVUSD shares not burned"
        );

        (uint128 nextBefore, uint128 lastBefore) = vUSD.queue();
        uint256 queuedSharesBefore = vUSD.totalQueuedShares();
        uint256 vUSDTotalSupplyBeforeRequest = vUSD.totalSupply();
        uint256 liquidatorVUSDBeforeRequest =
            vUSD.balanceOf(ALLOWLISTED_LIQUIDATOR);
        uint256 vaultVUSDBeforeRequest = vUSD.balanceOf(VUSD);
        assertEq(nextBefore, 1, "unexpected queue head");
        assertEq(lastBefore, 2, "unexpected queue tail");

        vm.prank(ALLOWLISTED_LIQUIDATOR);
        uint256 requestId = vUSD.requestRedeem(
            QUEUED_VUSD, ALLOWLISTED_LIQUIDATOR, ALLOWLISTED_LIQUIDATOR
        );

        (uint128 nextAfter, uint128 lastAfter) = vUSD.queue();
        assertEq(requestId, lastBefore + 1, "unexpected request id");
        assertEq(nextAfter, nextBefore, "request advanced queue head");
        assertEq(
            lastAfter, lastBefore + 1, "request did not extend queue tail"
        );
        assertEq(
            vUSD.pendingRedeemRequest(requestId, ALLOWLISTED_LIQUIDATOR),
            QUEUED_VUSD,
            "request not pending"
        );
        assertEq(
            vUSD.totalQueuedShares(),
            queuedSharesBefore + QUEUED_VUSD,
            "wrong queued-share delta"
        );
        assertEq(
            vUSD.balanceOf(ALLOWLISTED_LIQUIDATOR),
            liquidatorVUSDBeforeRequest - QUEUED_VUSD,
            "request did not debit controller"
        );
        assertEq(
            vUSD.balanceOf(VUSD),
            vaultVUSDBeforeRequest + QUEUED_VUSD,
            "request did not escrow shares"
        );
        assertGe(
            vUSD.totalSupply(),
            vUSDTotalSupplyBeforeRequest,
            "request burned vUSD supply"
        );

        // Neither an ordinary cVUSD holder nor the allowlisted liquidator can
        // force operator-owned processing. Each failed call is atomic.
        _expectUnauthorizedProcess(ordinaryHolder, requestId);
        _expectUnauthorizedProcess(ALLOWLISTED_LIQUIDATOR, requestId);

        (uint128 finalNext, uint128 finalLast) = vUSD.queue();
        assertEq(finalNext, nextAfter, "failed processing changed queue head");
        assertEq(finalLast, lastAfter, "failed processing changed queue tail");
        assertEq(
            vUSD.pendingRedeemRequest(requestId, ALLOWLISTED_LIQUIDATOR),
            QUEUED_VUSD,
            "failed processing changed request"
        );
        assertEq(
            vUSD.totalQueuedShares(),
            queuedSharesBefore + QUEUED_VUSD,
            "failed processing changed queued shares"
        );
    }

    function _liquidateExact() internal {
        address[] memory accounts = new address[](1);
        accounts[0] = BORROWER;
        uint256[] memory debtAmounts = new uint256[](1);
        debtAmounts[0] = DEBT_TO_LIQUIDATE;
        cAUSD.liquidateExact(debtAmounts, accounts, CVUSD);
    }

    function _fundLiquidatorFromUnrelatedMarket() internal {
        BorrowableCToken donor = BorrowableCToken(AUSD_DONOR_CTOKEN);
        assertEq(donor.asset(), address(ausd), "donor is not a cAUSD market");
        assertTrue(
            address(donor.marketManager()) != MARKET_MANAGER,
            "donor belongs to tested market"
        );
        assertTrue(AUSD_DONOR_CTOKEN != CAUSD, "donor is tested cAUSD");

        uint256 donorBalanceBefore = ausd.balanceOf(AUSD_DONOR_CTOKEN);
        uint256 liquidatorBalanceBefore =
            ausd.balanceOf(ALLOWLISTED_LIQUIDATOR);
        assertGe(
            donorBalanceBefore,
            DEBT_TO_LIQUIDATE,
            "unrelated cAUSD donor lacks cash"
        );

        // Test-fixture funding uses unrelated live cAUSD cash because AUSD's
        // proxy storage is intentionally not guessed or rewritten by `deal`.
        vm.prank(AUSD_DONOR_CTOKEN);
        assertTrue(
            ausd.transfer(ALLOWLISTED_LIQUIDATOR, DEBT_TO_LIQUIDATE),
            "donor transfer failed"
        );

        assertEq(
            ausd.balanceOf(AUSD_DONOR_CTOKEN),
            donorBalanceBefore - DEBT_TO_LIQUIDATE,
            "wrong donor AUSD delta"
        );
        assertEq(
            ausd.balanceOf(ALLOWLISTED_LIQUIDATOR),
            liquidatorBalanceBefore + DEBT_TO_LIQUIDATE,
            "wrong liquidator funding delta"
        );
    }

    function _liquidationState()
        internal
        view
        returns (LiquidationState memory state)
    {
        state.borrowerDebt = cAUSD.debtBalance(BORROWER);
        state.borrowerShares = cVUSD.balanceOf(BORROWER);
        state.borrowerPosted = cVUSD.collateralPosted(BORROWER);
        state.liquidatorShares = cVUSD.balanceOf(ALLOWLISTED_LIQUIDATOR);
        state.liquidatorPosted = cVUSD.collateralPosted(ALLOWLISTED_LIQUIDATOR);
        state.borrowerVUSD = vUSD.balanceOf(BORROWER);
        state.liquidatorVUSD = vUSD.balanceOf(ALLOWLISTED_LIQUIDATOR);
        state.cTokenVUSD = vUSD.balanceOf(CVUSD);
        state.cTokenSupply = cVUSD.totalSupply();
        state.cTokenAssets = cVUSD.totalAssets();
        state.marketDebt = cAUSD.marketOutstandingDebt();
        state.marketAUSD = ausd.balanceOf(CAUSD);
        state.debtMarketTotalAssets = cAUSD.totalAssets();
    }

    function _expectUnauthorizedProcess(address caller, uint256 requestId)
        internal
    {
        vm.prank(caller);
        vm.expectRevert(UNAUTHORIZED_SELECTOR);
        vUSD.processUpToRequestId(requestId);
    }

    function _redemptionState(address holder)
        internal
        view
        returns (RedemptionState memory state)
    {
        state.holderShares = cVUSD.balanceOf(holder);
        state.totalSupply = cVUSD.totalSupply();
        state.totalAssets = cVUSD.totalAssets();
        state.cTokenVUSDBalance = vUSD.balanceOf(CVUSD);
        state.holderVUSDBalance = vUSD.balanceOf(holder);
        state.vUSDTotalSupply = vUSD.totalSupply();
        state.totalQueuedShares = vUSD.totalQueuedShares();
        (state.nextRequestId, state.lastRequestId) = vUSD.queue();
    }

    function _assertRedemptionStateEq(
        RedemptionState memory expected,
        RedemptionState memory actual
    ) internal pure {
        assertEq(
            actual.holderShares, expected.holderShares, "holder shares changed"
        );
        assertEq(
            actual.totalSupply, expected.totalSupply, "cVUSD supply changed"
        );
        assertEq(
            actual.totalAssets, expected.totalAssets, "cVUSD assets changed"
        );
        assertEq(
            actual.cTokenVUSDBalance,
            expected.cTokenVUSDBalance,
            "cToken vUSD changed"
        );
        assertEq(
            actual.holderVUSDBalance,
            expected.holderVUSDBalance,
            "holder vUSD changed"
        );
        assertEq(
            actual.vUSDTotalSupply,
            expected.vUSDTotalSupply,
            "vUSD supply changed"
        );
        assertEq(
            actual.totalQueuedShares,
            expected.totalQueuedShares,
            "queued shares changed"
        );
        assertEq(
            actual.nextRequestId, expected.nextRequestId, "queue head changed"
        );
        assertEq(
            actual.lastRequestId, expected.lastRequestId, "queue tail changed"
        );
    }
}
