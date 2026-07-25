// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {
    TestBaseBorrowableCToken
} from "tests/market/token/BorrowableCToken/TestBaseBorrowableCToken.sol";
import {OracleManager} from "contracts/oracles/OracleManager.sol";

contract ChainlinkAdaptorApprovalMigrationPoC is TestBaseBorrowableCToken {
    struct ConsumerState {
        uint256 receiverBalance;
        uint256 marketCash;
        uint256 accountDebt;
        uint256 marketDebt;
        uint256 totalAssets;
        uint256 cooldown;
        uint256 vestingRate;
        uint256 vestingEnd;
        uint256 lastVestingClaim;
        uint256 debtIndex;
        uint256 debtPosition;
        bytes32 accountAssetsHash;
    }

    function test_adaptorApprovalRemovalRetainsRouteFailStopsAndRecovers()
        public
    {
        borrowableCUSDC.deposit(200e6, address(this));
        pendleStrategyCTokenSTETH.postCollateral(_ONE - 1);

        // Match the configured singleton-route boundary under review before
        // changing the global approval bit.
        oracleManager.removeAssetPricingAdaptor(
            _USDC_ADDRESS, address(dualChainlinkAdaptor)
        );

        _assertSingletonRouteRetained();
        bytes32 pricingConfigBefore = _pricingConfigHash();

        (uint256 priceBefore, uint256 errorCode) =
            oracleManager.getPrice(_USDC_ADDRESS, true, false);
        assertGt(priceBefore, 0);
        assertEq(errorCode, 0);

        // An ordinary account cannot create the fail-stop condition.
        vm.expectRevert(OracleManager.OracleManager__Unauthorized.selector);
        vm.prank(makeAddr("unauthorized adaptor migrator"));
        oracleManager.removeApprovedAdaptor(address(chainlinkAdaptor));

        assertTrue(oracleManager.isApprovedAdaptor(address(chainlinkAdaptor)));
        _assertSingletonRouteRetained();
        assertEq(_pricingConfigHash(), pricingConfigBefore);

        ConsumerState memory stateBefore = _captureConsumerState();

        oracleManager.removeApprovedAdaptor(address(chainlinkAdaptor));

        assertFalse(oracleManager.isApprovedAdaptor(address(chainlinkAdaptor)));
        _assertSingletonRouteRetained();
        assertEq(_pricingConfigHash(), pricingConfigBefore);

        vm.expectRevert(
            OracleManager.OracleManager__AdaptorIsNotApproved.selector
        );
        oracleManager.getPrice(_USDC_ADDRESS, true, false);

        vm.expectRevert(
            OracleManager.OracleManager__AdaptorIsNotApproved.selector
        );
        borrowableCUSDC.borrow(100e6, address(this));

        assertEq(
            _consumerStateHash(_captureConsumerState()),
            _consumerStateHash(stateBefore),
            "failed consumer call must roll back every captured state field"
        );

        // Reapproval restores the exact retained route and consumer behavior.
        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));
        assertTrue(oracleManager.isApprovedAdaptor(address(chainlinkAdaptor)));
        _assertSingletonRouteRetained();
        assertEq(_pricingConfigHash(), pricingConfigBefore);

        (uint256 priceAfter, uint256 errorCodeAfter) =
            oracleManager.getPrice(_USDC_ADDRESS, true, false);
        assertEq(priceAfter, priceBefore);
        assertEq(errorCodeAfter, 0);

        borrowableCUSDC.borrow(100e6, address(this));
        ConsumerState memory stateAfter = _captureConsumerState();
        assertEq(
            stateAfter.receiverBalance, stateBefore.receiverBalance + 100e6
        );
        assertEq(stateAfter.marketCash, stateBefore.marketCash - 100e6);
        assertEq(stateAfter.accountDebt, stateBefore.accountDebt + 100e6);
        assertEq(stateAfter.marketDebt, stateBefore.marketDebt + 100e6);
    }

    function _assertSingletonRouteRetained() internal view {
        address[] memory route =
            oracleManager.getPricingAdaptors(_USDC_ADDRESS);
        assertEq(route.length, 1);
        assertEq(route[0], address(chainlinkAdaptor));
    }

    function _captureConsumerState()
        internal
        view
        returns (ConsumerState memory state)
    {
        state.receiverBalance = usdc.balanceOf(address(this));
        state.marketCash = usdc.balanceOf(address(borrowableCUSDC));
        state.accountDebt = borrowableCUSDC.debtBalance(address(this));
        state.marketDebt = borrowableCUSDC.marketOutstandingDebt();
        state.totalAssets = borrowableCUSDC.totalAssets();
        state.cooldown = marketManagerIsolated.accountAssets(address(this));
        state.debtPosition = marketManagerIsolated.accountPositions(
            address(borrowableCUSDC), address(this)
        );
        (
            state.vestingRate,
            state.vestingEnd,
            state.lastVestingClaim,
            state.debtIndex
        ) = borrowableCUSDC.getYieldInformation();
        state.accountAssetsHash = keccak256(
            abi.encode(marketManagerIsolated.assetsOf(address(this)))
        );
    }

    function _consumerStateHash(ConsumerState memory state)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(state));
    }

    function _pricingConfigHash() internal view returns (bytes32) {
        (
            uint16 badSourceBoundUSD,
            uint16 cautionBoundUSD,
            uint16 badSourceBoundNative,
            uint16 cautionBoundNative
        ) = oracleManager.assetPricingConfig(_USDC_ADDRESS);

        return keccak256(
            abi.encode(
                badSourceBoundUSD,
                cautionBoundUSD,
                badSourceBoundNative,
                cautionBoundNative,
                oracleManager.getPricingAdaptors(_USDC_ADDRESS)
            )
        );
    }
}
