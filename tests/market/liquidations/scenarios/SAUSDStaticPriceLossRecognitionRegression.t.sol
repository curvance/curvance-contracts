// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {TestBaseMarketIsolated} from "tests/market/TestBaseMarketIsolated.sol";
import {MockERC4626} from "tests/libraries/utils/mocks/MockERC4626.sol";
import {BorrowableCToken} from "contracts/market/token/BorrowableCToken.sol";
import {
    MarketManagerIsolated
} from "contracts/market/isolated/MarketManagerIsolated.sol";
import {
    StaticPriceAggregator
} from "contracts/oracles/adaptors/wrappedAggregators/StaticPriceAggregator.sol";
import {IERC20} from "contracts/interfaces/IERC20.sol";
import {MockERC20Token} from "contracts/mocks/MockERC20Token.sol";

contract FeeBearingSAUSD is MockERC4626 {
    constructor(address ausd)
        MockERC4626(ausd, "Staked AUSD", "sAUSD", false, 0)
    {}

    function realizeLoss(uint256 assets, address lossReceiver) external {
        IERC20(_underlying).transfer(lossReceiver, assets);
    }
}

/// @notice Proves that a static $1 sAUSD feed does not recognize a realized
/// ERC4626 loss: Curvance permits collateral removal and blocks liquidation
/// even though the remaining position is deficient at exact vault NAV.
contract SAUSDStaticPriceLossRecognitionRegression is TestBaseMarketIsolated {
    struct RemovalOutcome {
        uint256 timestamp;
        uint256 removedCTokenShares;
        uint256 redeemedSAUSDShares;
        uint256 realizedAUSD;
        uint256 remainingCTokenShares;
        uint256 nominalCollateral;
        uint256 nominalMaxDebt;
        uint256 debt;
        uint256 exactCollateral;
        uint256 exactMaxDebt;
    }

    MockERC20Token internal ausd;
    FeeBearingSAUSD internal sAusd;
    BorrowableCToken internal cSAUSD;

    address internal borrower = makeAddr("sAusdBorrower");
    address internal liquidityProvider = makeAddr("sAusdLiquidityProvider");
    address internal sAusdLiquidator = makeAddr("sAusdLiquidator");
    address internal lossReceiver = makeAddr("sAusdLossReceiver");

    uint256 internal removalShares;

    uint256 internal constant COLLATERAL = 100e18;
    uint256 internal constant BORROW = 65.9e18;
    uint256 internal constant REMOVAL_ASSETS = 5e18;
    uint256 internal constant REALIZED_LOSS = 10e18;
    uint256 internal constant COLLATERAL_RATIO = 7000;
    uint256 internal constant BPS = 10_000;

    function setUp() public override {
        super.setUp();

        ausd = new MockERC20Token();
        sAusd = new FeeBearingSAUSD(address(ausd));
        cSAUSD = _deployBorrowableCToken(address(sAusd));

        StaticPriceAggregator staticPrice = new StaticPriceAggregator(1e18);
        chainlinkAdaptor.addAsset(
            address(sAusd), true, address(staticPrice), 0
        );
        oracleManager.addAssetPricingAdaptor(
            address(sAusd), address(chainlinkAdaptor), 100, 50, 100, 50
        );
        oracleManager.addCTokenSupport(address(cSAUSD));

        _fundInitialDeposits();
        marketManagerIsolated.listTokens(
            address(cSAUSD), address(borrowableCDAI)
        );
        _setCTokenConfigBasic(address(cSAUSD), 2_000_000e18, 0);
        _setCTokenConfigBasic(
            address(borrowableCDAI), 2_000_000e18, 2_000_000e18
        );

        _seedDAILiquidity();
        _openPosition();
        _prepareDAI(sAusdLiquidator, 1_000e18);

        removalShares = cSAUSD.convertToShares(REMOVAL_ASSETS);
        assertGt(removalShares, 0);
    }

    function test_staticPricePermitsLossBlindRemovalAndBlocksLiquidation()
        public
    {
        uint256 snapshot = vm.snapshotState();
        RemovalOutcome memory noLoss = _removeAndRealize(false);

        assertTrue(vm.revertToState(snapshot));
        RemovalOutcome memory lossBlind = _removeAndRealize(true);

        assertEq(noLoss.timestamp, lossBlind.timestamp);
        assertEq(noLoss.removedCTokenShares, lossBlind.removedCTokenShares);
        assertEq(noLoss.redeemedSAUSDShares, lossBlind.redeemedSAUSDShares);
        assertEq(noLoss.remainingCTokenShares, lossBlind.remainingCTokenShares);
        assertEq(noLoss.nominalCollateral, lossBlind.nominalCollateral);
        assertEq(noLoss.nominalMaxDebt, lossBlind.nominalMaxDebt);
        assertEq(noLoss.debt, lossBlind.debt);

        assertGe(noLoss.exactMaxDebt, noLoss.debt);
        assertGe(lossBlind.nominalMaxDebt, lossBlind.debt);
        assertLt(lossBlind.exactMaxDebt, lossBlind.debt);
        assertLt(lossBlind.exactCollateral, noLoss.exactCollateral);
        assertLt(lossBlind.realizedAUSD, noLoss.realizedAUSD);

        _assertLiquidationUnavailableAndAtomic();
    }

    function test_lossAwarePriceRecognizesDeficitAndPreventsRemoval() public {
        sAusd.realizeLoss(REALIZED_LOSS, lossReceiver);
        uint256 navPerShare = sAusd.convertToAssets(1e18);
        chainlinkAdaptor.addAsset(
            address(sAusd),
            true,
            address(new StaticPriceAggregator(navPerShare)),
            0
        );

        (, uint256 lossAwareMaxDebt, uint256 debt) =
            marketManagerIsolated.statusOf(borrower);
        assertLt(lossAwareMaxDebt, debt);

        bytes32 stateBefore = _removalStateHash();
        vm.startPrank(borrower);
        vm.expectRevert(
            MarketManagerIsolated.MarketManager__InsufficientCollateral
            .selector
        );
        cSAUSD.redeemCollateral(removalShares, borrower, borrower);
        vm.stopPrank();
        assertEq(_removalStateHash(), stateBefore);
    }

    function _fundInitialDeposits() internal {
        ausd.mint(address(this), 77777);
        ausd.approve(address(sAusd), 77777);
        sAusd.deposit(77777, address(this));
        sAusd.approve(address(cSAUSD), 77777);

        _prepareDAI(address(this), 77777);
        IERC20(_DAI_ADDRESS).approve(address(borrowableCDAI), 77777);
    }

    function _seedDAILiquidity() internal {
        _prepareDAI(liquidityProvider, 1_000_000e18);
        vm.startPrank(liquidityProvider);
        IERC20(_DAI_ADDRESS)
            .approve(address(borrowableCDAI), type(uint256).max);
        borrowableCDAI.deposit(1_000_000e18, liquidityProvider);
        vm.stopPrank();
    }

    function _openPosition() internal {
        ausd.mint(borrower, COLLATERAL);

        vm.startPrank(borrower);
        ausd.approve(address(sAusd), type(uint256).max);
        sAusd.deposit(COLLATERAL, borrower);
        sAusd.approve(address(cSAUSD), type(uint256).max);
        cSAUSD.depositAsCollateral(COLLATERAL, borrower);
        vm.stopPrank();

        skip(1201);
        mockDaiFeed.setMockAnswer(1e8);
        _refreshMockFeeds();

        vm.prank(borrower);
        borrowableCDAI.borrow(BORROW, borrower);

        skip(1201);
        _refreshMockFeeds();
    }

    function _removeAndRealize(bool realizeLoss)
        internal
        returns (RemovalOutcome memory outcome)
    {
        if (realizeLoss) {
            sAusd.realizeLoss(REALIZED_LOSS, lossReceiver);
        }

        outcome.timestamp = block.timestamp;
        outcome.removedCTokenShares = removalShares;
        uint256 ausdBefore = ausd.balanceOf(borrower);

        vm.startPrank(borrower);
        outcome.redeemedSAUSDShares =
            cSAUSD.redeemCollateral(removalShares, borrower, borrower);
        sAusd.redeem(outcome.redeemedSAUSDShares, borrower, borrower);
        vm.stopPrank();

        outcome.realizedAUSD = ausd.balanceOf(borrower) - ausdBefore;
        outcome.remainingCTokenShares = cSAUSD.collateralPosted(borrower);
        (outcome.nominalCollateral, outcome.nominalMaxDebt, outcome.debt) =
            marketManagerIsolated.statusOf(borrower);

        uint256 remainingSAUSDShares =
            cSAUSD.convertToAssets(outcome.remainingCTokenShares);
        outcome.exactCollateral = sAusd.convertToAssets(remainingSAUSDShares);
        outcome.exactMaxDebt = outcome.exactCollateral * COLLATERAL_RATIO / BPS;
    }

    function _assertLiquidationUnavailableAndAtomic() internal {
        address[] memory accounts = new address[](1);
        accounts[0] = borrower;
        bytes32 stateBefore = _liquidationStateHash();

        vm.startPrank(sAusdLiquidator);
        IERC20(_DAI_ADDRESS)
            .approve(address(borrowableCDAI), type(uint256).max);
        vm.expectRevert(
            MarketManagerIsolated.MarketManager__NoLiquidationAvailable
            .selector
        );
        borrowableCDAI.liquidate(accounts, address(cSAUSD));
        vm.stopPrank();

        assertEq(_liquidationStateHash(), stateBefore);
    }

    function _removalStateHash() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                cSAUSD.collateralPosted(borrower),
                cSAUSD.balanceOf(borrower),
                cSAUSD.totalAssets(),
                sAusd.balanceOf(borrower),
                ausd.balanceOf(borrower)
            )
        );
    }

    function _liquidationStateHash() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                cSAUSD.collateralPosted(borrower),
                cSAUSD.balanceOf(borrower),
                borrowableCDAI.debtBalance(borrower),
                borrowableCDAI.totalAssets(),
                borrowableCDAI.marketOutstandingDebt()
            )
        );
    }
}
