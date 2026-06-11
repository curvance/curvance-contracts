// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { CommonLib } from "contracts/libraries/CommonLib.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { BAD_SOURCE } from "contracts/libraries/ConstantsLib.sol";

contract OracleManagerRedeployParityTest is TestBaseMarketIsolated {
    struct BorrowProbe {
        uint256 userUsdcBalance;
        uint256 debtBalance;
        uint256 marketOutstandingDebt;
        uint256 maxDebt;
        uint256 debt;
    }

    struct CollateralMovementProbe {
        uint256 ownerShares;
        uint256 receiverShares;
        uint256 ownerCollateral;
        uint256 marketCollateral;
        uint256 ownerDaiBalance;
        uint256 assetsRedeemed;
    }

    function setUp() public override {
        super.setUp();

        _prepareDAI(address(this), 77777);
        _prepareUSDC(address(this), 77777);
        dai.approve(address(borrowableCDAI), type(uint256).max);
        usdc.approve(address(borrowableCUSDC), type(uint256).max);

        marketManagerIsolated.listTokens(address(borrowableCDAI), address(borrowableCUSDC));
    }

    function test_oracleManagerRedeployParity_matchesExplicitDaiUsdcMarketTuple() public {
        OracleManager replacement = _deployReplacementOracleManager(true);

        _assertAssetPricingParity(replacement, _DAI_ADDRESS);
        _assertAssetPricingParity(replacement, _USDC_ADDRESS);
        _assertCTokenParity(replacement, address(borrowableCDAI));
        _assertCTokenParity(replacement, address(borrowableCUSDC));
        _assertPriceParity(replacement, _DAI_ADDRESS, true);
        _assertPriceParity(replacement, _USDC_ADDRESS, true);
        _assertPriceParity(replacement, _DAI_ADDRESS, false);
        _assertPriceParity(replacement, _USDC_ADDRESS, false);
        _assertIsolatedPairParitySameState(replacement);
        _assertRegistryCutoverRoutesThroughReplacement(replacement);
        _assertRegistryCutoverPreservesBorrowConsumerPath(replacement);
        _assertRegistryCutoverPreservesTransferConsumerPath(replacement);
        _assertRegistryCutoverPreservesRedeemConsumerPath(replacement);
        _assertRegistryCutoverPreservesCanLiquidateConsumerPath(replacement);
    }

    function test_oracleManagerRedeployParity_detectsMissingCTokenSupport() public {
        OracleManager replacement = _deployReplacementOracleManager(false);

        vm.expectRevert(OracleManager.OracleManager__NotSupported.selector);
        replacement.getPriceIsolatedPair(
            address(borrowableCDAI),
            address(borrowableCUSDC),
            BAD_SOURCE
        );
    }

    function test_oracleManagerRedeployParity_detectsMissingDebtCTokenSupport() public {
        OracleManager replacement = _deployReplacementOracleManager(false);
        replacement.addCTokenSupport(address(borrowableCDAI));

        vm.expectRevert(OracleManager.OracleManager__NotSupported.selector);
        replacement.getPriceIsolatedPair(
            address(borrowableCDAI),
            address(borrowableCUSDC),
            BAD_SOURCE
        );
    }

    function _deployReplacementOracleManager(
        bool includeCTokenSupport
    ) internal returns (OracleManager replacement) {
        replacement = new OracleManager(ICentralRegistry(address(centralRegistry)));

        replacement.addApprovedAdaptor(address(chainlinkAdaptor));
        replacement.addApprovedAdaptor(address(dualChainlinkAdaptor));

        _addDualAdaptorSupport(replacement, _DAI_ADDRESS);
        _addDualAdaptorSupport(replacement, _USDC_ADDRESS);

        if (includeCTokenSupport) {
            replacement.addCTokenSupport(address(borrowableCDAI));
            replacement.addCTokenSupport(address(borrowableCUSDC));
        }
    }

    function _addDualAdaptorSupport(OracleManager manager, address asset) internal {
        manager.addAssetPricingAdaptor(
            asset,
            address(chainlinkAdaptor),
            250,
            150,
            250,
            150
        );
        manager.addAssetPricingAdaptor(
            asset,
            address(dualChainlinkAdaptor),
            250,
            150,
            250,
            150
        );
    }

    function _assertAssetPricingParity(OracleManager replacement, address asset) internal view {
        (
            uint16 oldBadSourceBoundUSD,
            uint16 oldCautionBoundUSD,
            uint16 oldBadSourceBoundNative,
            uint16 oldCautionBoundNative
        ) = oracleManager.assetPricingConfig(asset);
        (
            uint16 newBadSourceBoundUSD,
            uint16 newCautionBoundUSD,
            uint16 newBadSourceBoundNative,
            uint16 newCautionBoundNative
        ) = replacement.assetPricingConfig(asset);

        assertEq(newBadSourceBoundUSD, oldBadSourceBoundUSD, "bad source USD bound");
        assertEq(newCautionBoundUSD, oldCautionBoundUSD, "caution USD bound");
        assertEq(newBadSourceBoundNative, oldBadSourceBoundNative, "bad source native bound");
        assertEq(newCautionBoundNative, oldCautionBoundNative, "caution native bound");

        address[] memory oldAdaptors = oracleManager.getPricingAdaptors(asset);
        address[] memory newAdaptors = replacement.getPricingAdaptors(asset);
        assertEq(newAdaptors.length, oldAdaptors.length, "adaptor count");
        for (uint256 i; i < oldAdaptors.length; ++i) {
            assertEq(newAdaptors[i], oldAdaptors[i], "adaptor order");
        }
    }

    function _assertCTokenParity(OracleManager replacement, address cToken) internal view {
        assertEq(replacement.cTokens(cToken), oracleManager.cTokens(cToken), "cToken underlying");
    }

    function _assertPriceParity(
        OracleManager replacement,
        address asset,
        bool inUSD
    ) internal view {
        (uint256 oldLower, uint256 oldLowerError) =
            oracleManager.getPrice(asset, inUSD, true);
        (uint256 newLower, uint256 newLowerError) =
            replacement.getPrice(asset, inUSD, true);
        (uint256 oldUpper, uint256 oldUpperError) =
            oracleManager.getPrice(asset, inUSD, false);
        (uint256 newUpper, uint256 newUpperError) =
            replacement.getPrice(asset, inUSD, false);

        assertEq(newLower, oldLower, "lower price");
        assertEq(newLowerError, oldLowerError, "lower error");
        assertEq(newUpper, oldUpper, "upper price");
        assertEq(newUpperError, oldUpperError, "upper error");
    }

    function _assertIsolatedPairParitySameState(OracleManager replacement) internal {
        uint256 snapshotId = vm.snapshotState();
        (uint256 oldCollateralPrice, uint256 oldDebtPrice) =
            oracleManager.getPriceIsolatedPair(
                address(borrowableCDAI),
                address(borrowableCUSDC),
                BAD_SOURCE
            );
        assertTrue(vm.revertToState(snapshotId), "failed to restore pre-old-manager price state");

        uint256 replacementSnapshotId = vm.snapshotState();
        (uint256 newCollateralPrice, uint256 newDebtPrice) =
            replacement.getPriceIsolatedPair(
                address(borrowableCDAI),
                address(borrowableCUSDC),
                BAD_SOURCE
            );
        assertTrue(vm.revertToState(replacementSnapshotId), "failed to restore pre-new-manager price state");

        assertEq(newCollateralPrice, oldCollateralPrice, "collateral price");
        assertEq(newDebtPrice, oldDebtPrice, "debt price");
    }

    function _assertRegistryCutoverRoutesThroughReplacement(
        OracleManager replacement
    ) internal {
        uint256 snapshotId = vm.snapshotState();
        (uint256 oldCollateralPrice, uint256 oldDebtPrice) =
            oracleManager.getPriceIsolatedPair(
                address(borrowableCDAI),
                address(borrowableCUSDC),
                BAD_SOURCE
            );
        assertTrue(vm.revertToState(snapshotId), "failed to restore pre-cutover price state");

        uint256 cutoverState = vm.snapshotState();
        centralRegistry.setOracleManager(address(replacement));
        assertEq(centralRegistry.oracleManager(), address(replacement), "oracle manager cutover");

        (uint256 routedCollateralPrice, uint256 routedDebtPrice) =
            CommonLib._oracleManager(ICentralRegistry(address(centralRegistry)))
                .getPriceIsolatedPair(
                    address(borrowableCDAI),
                    address(borrowableCUSDC),
                    BAD_SOURCE
                );

        assertEq(routedCollateralPrice, oldCollateralPrice, "routed collateral price");
        assertEq(routedDebtPrice, oldDebtPrice, "routed debt price");
        assertTrue(vm.revertToState(cutoverState), "failed to restore post-cutover route state");
    }

    function _assertRegistryCutoverPreservesCanLiquidateConsumerPath(
        OracleManager replacement
    ) internal {
        uint256 cleanState = vm.snapshotState();
        _setupDaiUsdcLiquidationFixture();

        uint256 snapshotId = vm.snapshotState();
        (IMarketManager.LiqResult memory oldResult, uint256 oldDebtAmount) =
            _probeDaiUsdcLiquidation();
        assertTrue(vm.revertToState(snapshotId), "failed to restore pre-old-manager consumer state");

        centralRegistry.setOracleManager(address(replacement));
        assertEq(centralRegistry.oracleManager(), address(replacement), "oracle manager cutover");

        (IMarketManager.LiqResult memory newResult, uint256 newDebtAmount) =
            _probeDaiUsdcLiquidation();

        assertEq(newResult.liquidatedShares.length, oldResult.liquidatedShares.length, "liquidated shares length");
        assertEq(newResult.liquidatedShares[0], oldResult.liquidatedShares[0], "liquidated shares");
        assertEq(newResult.debtRepaid, oldResult.debtRepaid, "debt repaid");
        assertEq(newResult.badDebtRealized, oldResult.badDebtRealized, "bad debt");
        assertEq(newDebtAmount, oldDebtAmount, "adjusted debt amount");
        assertTrue(vm.revertToState(cleanState), "failed to restore pre-liquidation consumer state");
    }

    function _assertRegistryCutoverPreservesBorrowConsumerPath(
        OracleManager replacement
    ) internal {
        uint256 cleanState = vm.snapshotState();
        _setupDaiUsdcCollateralAndLiquidityFixture();

        uint256 baseState = vm.snapshotState();
        BorrowProbe memory oldProbe = _probeDaiUsdcBorrow();
        assertTrue(vm.revertToState(baseState), "failed to restore pre-old-manager borrow state");

        centralRegistry.setOracleManager(address(replacement));
        BorrowProbe memory newProbe = _probeDaiUsdcBorrow();

        assertEq(newProbe.userUsdcBalance, oldProbe.userUsdcBalance, "borrow user balance");
        assertEq(newProbe.debtBalance, oldProbe.debtBalance, "borrow debt balance");
        assertEq(newProbe.marketOutstandingDebt, oldProbe.marketOutstandingDebt, "borrow market debt");
        assertEq(newProbe.maxDebt, oldProbe.maxDebt, "borrow max debt");
        assertEq(newProbe.debt, oldProbe.debt, "borrow account debt");
        assertTrue(vm.revertToState(cleanState), "failed to restore pre-borrow consumer state");
    }

    function _assertRegistryCutoverPreservesTransferConsumerPath(
        OracleManager replacement
    ) internal {
        uint256 cleanState = vm.snapshotState();
        _setupDaiUsdcHealthyDebtFixture();
        uint256 shares = borrowableCDAI.collateralPosted(user1) / 10;
        address receiver = makeAddr("redeployParityTransferReceiver");

        uint256 baseState = vm.snapshotState();
        CollateralMovementProbe memory oldProbe = _probeDaiCollateralTransfer(receiver, shares);
        assertTrue(vm.revertToState(baseState), "failed to restore pre-old-manager transfer state");

        centralRegistry.setOracleManager(address(replacement));
        CollateralMovementProbe memory newProbe = _probeDaiCollateralTransfer(receiver, shares);

        assertEq(newProbe.ownerShares, oldProbe.ownerShares, "transfer owner shares");
        assertEq(newProbe.receiverShares, oldProbe.receiverShares, "transfer receiver shares");
        assertEq(newProbe.ownerCollateral, oldProbe.ownerCollateral, "transfer owner collateral");
        assertEq(newProbe.marketCollateral, oldProbe.marketCollateral, "transfer market collateral");
        assertTrue(vm.revertToState(cleanState), "failed to restore pre-transfer consumer state");
    }

    function _assertRegistryCutoverPreservesRedeemConsumerPath(
        OracleManager replacement
    ) internal {
        uint256 cleanState = vm.snapshotState();
        _setupDaiUsdcHealthyDebtFixture();
        uint256 shares = borrowableCDAI.collateralPosted(user1) / 10;

        uint256 baseState = vm.snapshotState();
        CollateralMovementProbe memory oldProbe = _probeDaiCollateralRedeem(shares);
        assertTrue(vm.revertToState(baseState), "failed to restore pre-old-manager redeem state");

        centralRegistry.setOracleManager(address(replacement));
        CollateralMovementProbe memory newProbe = _probeDaiCollateralRedeem(shares);

        assertEq(newProbe.ownerShares, oldProbe.ownerShares, "redeem owner shares");
        assertEq(newProbe.ownerCollateral, oldProbe.ownerCollateral, "redeem owner collateral");
        assertEq(newProbe.marketCollateral, oldProbe.marketCollateral, "redeem market collateral");
        assertEq(newProbe.ownerDaiBalance, oldProbe.ownerDaiBalance, "redeem owner DAI");
        assertEq(newProbe.assetsRedeemed, oldProbe.assetsRedeemed, "redeem assets");
        assertTrue(vm.revertToState(cleanState), "failed to restore pre-redeem consumer state");
    }

    function _setupDaiUsdcCollateralAndLiquidityFixture() internal {
        _setCTokenConfigBasic(address(borrowableCDAI), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 0, 100_000e6);

        _prepareUSDC(address(this), 100_000e6);
        usdc.approve(address(borrowableCUSDC), 100_000e6);
        borrowableCUSDC.deposit(100_000e6, address(this));

        _prepareDAI(user1, 1_000e18);
        vm.startPrank(user1);
        dai.approve(address(borrowableCDAI), 1_000e18);
        borrowableCDAI.depositAsCollateral(1_000e18, user1);
        vm.stopPrank();
    }

    function _setupDaiUsdcHealthyDebtFixture() internal {
        _setupDaiUsdcCollateralAndLiquidityFixture();

        vm.prank(user1);
        borrowableCUSDC.borrow(100e6, user1);

        vm.warp(marketManagerIsolated.accountAssets(user1) + marketManagerIsolated.MIN_HOLD_PERIOD());
        _refreshMockFeeds();
    }

    function _setupDaiUsdcLiquidationFixture() internal {
        _setupDaiUsdcCollateralAndLiquidityFixture();

        vm.startPrank(user1);
        borrowableCUSDC.borrow(500e6, user1);
        vm.stopPrank();

        mockDaiFeed.setMockAnswer(0.5e8);
    }

    function _probeDaiUsdcLiquidation()
        internal
        returns (IMarketManager.LiqResult memory result, uint256 adjustedDebtAmount)
    {
        address[] memory accounts = new address[](1);
        accounts[0] = user1;

        uint256[] memory debtAmounts = new uint256[](1);
        debtAmounts[0] = 500e6;

        IMarketManager.LiqAction memory action = IMarketManager.LiqAction({
            collateralToken: address(borrowableCDAI),
            debtToken: address(borrowableCUSDC),
            numAccounts: 1,
            liquidateExact: false,
            liquidatedShares: 0,
            debtRepaid: 0,
            badDebt: 0
        });

        vm.prank(address(borrowableCUSDC));
        uint256[] memory adjustedDebtAmounts;
        (result, adjustedDebtAmounts) = marketManagerIsolated.canLiquidate(
            debtAmounts,
            address(this),
            accounts,
            action
        );
        adjustedDebtAmount = adjustedDebtAmounts[0];
    }

    function _probeDaiUsdcBorrow() internal returns (BorrowProbe memory result) {
        vm.prank(user1);
        borrowableCUSDC.borrow(100e6, user1);

        (, result.maxDebt, result.debt) = marketManagerIsolated.statusOf(user1);
        result.userUsdcBalance = usdc.balanceOf(user1);
        result.debtBalance = borrowableCUSDC.debtBalance(user1);
        result.marketOutstandingDebt = borrowableCUSDC.marketOutstandingDebt();
    }

    function _probeDaiCollateralTransfer(
        address receiver,
        uint256 shares
    ) internal returns (CollateralMovementProbe memory result) {
        vm.prank(user1);
        borrowableCDAI.transfer(receiver, shares);

        result.ownerShares = borrowableCDAI.balanceOf(user1);
        result.receiverShares = borrowableCDAI.balanceOf(receiver);
        result.ownerCollateral = borrowableCDAI.collateralPosted(user1);
        result.marketCollateral = borrowableCDAI.marketCollateralPosted();
    }

    function _probeDaiCollateralRedeem(
        uint256 shares
    ) internal returns (CollateralMovementProbe memory result) {
        vm.prank(user1);
        result.assetsRedeemed = borrowableCDAI.redeem(shares, user1, user1);

        result.ownerShares = borrowableCDAI.balanceOf(user1);
        result.ownerCollateral = borrowableCDAI.collateralPosted(user1);
        result.marketCollateral = borrowableCDAI.marketCollateralPosted();
        result.ownerDaiBalance = dai.balanceOf(user1);
    }
}
