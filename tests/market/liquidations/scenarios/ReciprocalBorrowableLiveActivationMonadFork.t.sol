// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {CentralRegistry} from "contracts/architecture/CentralRegistry.sol";
import {
    MarketManagerIsolated
} from "contracts/market/isolated/MarketManagerIsolated.sol";
import {BorrowableCToken} from "contracts/market/token/BorrowableCToken.sol";

/// @notice Pinned production-fork falsifier for reciprocal Borrowable
///         liquidation activation, including the auction-priority buffer.
/// @dev These are the five current debt rows that exceeded their ordinary
///      borrowing limit at the pinned block. All other enumerated debt rows
///      were farther from liquidation by construction.
contract ReciprocalBorrowableLiveActivationMonadFork is Test {
    uint256 internal constant FORK_BLOCK = 89_550_724;

    address internal constant CENTRAL_REGISTRY =
        0x1310f352f1389969Ece6741671c4B919523912fF;
    address internal constant AUCTION_EXECUTOR =
        0x0121D18d43E747f711d5d54e6b5dCf1E442ca7cC;
    address internal constant LIQUIDATOR =
        0x000000000000000000000000000000000000dEaD;

    address internal constant WMON_AUSD_MANAGER =
        0x05e70717fA8BD0F21a9F826d093d99f6Da4f1554;
    address internal constant WMON_AUSD_DEBT_AUSD =
        0x6E182EB501800C555bd5E662E6D350D627F504D8;
    address internal constant WMON_AUSD_COLLATERAL_WMON =
        0xE01d426B589c7834a5F6B20D7e992A705d3c22ED;

    address internal constant WMON_USDC_MANAGER =
        0xa6A2A92F126b79Ee0804845ee6B52899b4491093;
    address internal constant WMON_USDC_DEBT_USDC =
        0x8EE9FC28B8Da872c38A496e9dDB9700bb7261774;
    address internal constant WMON_USDC_COLLATERAL_WMON =
        0x1e240E30E51491546deC3aF16B0b4EAC8Dd110D4;

    address internal constant WBTC_USDC_MANAGER =
        0x01C4a0d396EFE982B1B103BE9910321d34e1aEA9;
    address internal constant WBTC_USDC_DEBT_WBTC =
        0x3D2Ff9F862D89Ba526a0fC166bD56ABe04EF28d5;
    address internal constant WBTC_USDC_COLLATERAL_USDC =
        0x7C9d4f1695C6282Da5e5509Aa51fC9fb417C6f1d;

    address internal constant ACCOUNT_6D2C =
        0x6d2CeA496ba329A0Ce2a8e58719fC162C3d82c04;
    address internal constant ACCOUNT_6662 =
        0x6662304e3198C8D54530fBdf02A869fA84537639;
    address internal constant ACCOUNT_20FB =
        0x20FbA32aEccd8B98A3E3072dd3bCD6A7D81d8DB0;
    address internal constant ACCOUNT_CDF1 =
        0xCdF198A569FEE3AF4D4e2aA82F4B696C21A64396;

    CentralRegistry internal constant centralRegistry =
        CentralRegistry(CENTRAL_REGISTRY);

    function setUp() public {
        vm.createSelectFork(
            vm.envString("MON_NODE_URI_MONAD_ARCHIVE"), FORK_BLOCK
        );

        assertEq(block.number, FORK_BLOCK, "wrong fork block");
        assertTrue(
            centralRegistry.hasAuctionPermissions(AUCTION_EXECUTOR),
            "auction executor is not authorized"
        );
        assertGt(
            AUCTION_EXECUTOR.code.length, 0, "auction executor has no code"
        );
    }

    function test_auctionPriorityStillFindsNoLiquidationForClosestLiveRows()
        public
    {
        _assertAuctionLiquidationUnavailable(
            WMON_AUSD_MANAGER,
            WMON_AUSD_DEBT_AUSD,
            WMON_AUSD_COLLATERAL_WMON,
            ACCOUNT_6D2C
        );
        _assertAuctionLiquidationUnavailable(
            WMON_USDC_MANAGER,
            WMON_USDC_DEBT_USDC,
            WMON_USDC_COLLATERAL_WMON,
            ACCOUNT_6662
        );
        _assertAuctionLiquidationUnavailable(
            WMON_USDC_MANAGER,
            WMON_USDC_DEBT_USDC,
            WMON_USDC_COLLATERAL_WMON,
            ACCOUNT_6D2C
        );
        _assertAuctionLiquidationUnavailable(
            WBTC_USDC_MANAGER,
            WBTC_USDC_DEBT_WBTC,
            WBTC_USDC_COLLATERAL_USDC,
            ACCOUNT_20FB
        );
        _assertAuctionLiquidationUnavailable(
            WBTC_USDC_MANAGER,
            WBTC_USDC_DEBT_WBTC,
            WBTC_USDC_COLLATERAL_USDC,
            ACCOUNT_CDF1
        );
    }

    function _assertAuctionLiquidationUnavailable(
        address manager,
        address debtToken,
        address collateralToken,
        address account
    ) internal {
        MarketManagerIsolated marketManager = MarketManagerIsolated(manager);

        vm.prank(AUCTION_EXECUTOR);
        marketManager.setTransientLiquidationConfig(collateralToken, 0, 0);

        vm.prank(AUCTION_EXECUTOR);
        centralRegistry.unlockAuctionForMarket(manager);

        (address unlockedCollateral,,) =
            marketManager.getTransientLiquidationConfig();
        assertEq(
            unlockedCollateral, collateralToken, "wrong transient collateral"
        );

        vm.prank(manager);
        assertTrue(
            centralRegistry.isMarketUnlocked(), "market was not unlocked"
        );

        address[] memory accounts = new address[](1);
        accounts[0] = account;

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__NoLiquidationAvailable
            .selector
        );
        vm.prank(LIQUIDATOR);
        BorrowableCToken(debtToken).liquidate(accounts, collateralToken);
    }
}
