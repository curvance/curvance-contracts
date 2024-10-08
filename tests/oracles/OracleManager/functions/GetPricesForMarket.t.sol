// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseOracleManager } from "../TestBaseOracleManager.sol";
import { IChainlink } from "contracts/interfaces/external/chainlink/IChainlink.sol";
import { IMToken, AccountSnapshot } from "contracts/interfaces/market/IMToken.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";

contract GetPricesForMarket is TestBaseOracleManager {
    IMToken[] public assets;

    function setUp() public override {
        super.setUp();

        assets.push(IMToken(address(eUSDC)));
    }

    function test_getPricesForMarket_fail_whenAssetsLengthIsZero() public {
        assets.pop();

        (
            AccountSnapshot[] memory snapshots,
            uint256[] memory underlyingPrices,
            uint256 numAssets
        ) = oracleManager.getPricesForMarket(address(this), assets, 1);
        assertEq(snapshots.length, 0);
        assertEq(underlyingPrices.length, 0);
        assertEq(numAssets, 0);
    }

    function test_getPricesForMarket_fail_whenMarketNotStarted() public {
        vm.expectRevert();
        oracleManager.getPricesForMarket(address(this), assets, 1);
    }

    function test_getPricesForMarket_fail_whenNoFeedsAvailable() public {
        deal(_USDC_ADDRESS, address(this), 1e18);
        vm.prank(address(this));
        usdc.approve(address(eUSDC), 1e18);

        marketManager.listToken(address(eUSDC));

        vm.prank(address(marketManager));
        eUSDC.startMarket(address(this));

        vm.expectRevert(OracleManager.OracleManager__NotSupported.selector);
        oracleManager.getPricesForMarket(address(this), assets, 1);
    }

    function test_getPricesForMarket_fail_whenErrorCodeExceedsBreakpoint()
        public
    {
        deal(_USDC_ADDRESS, address(this), 1e18);
        vm.prank(address(this));
        usdc.approve(address(eUSDC), 1e18);

        marketManager.listToken(address(eUSDC));
        _addSinglePriceFeed();

        vm.prank(address(marketManager));
        eUSDC.startMarket(address(this));

        vm.expectRevert(OracleRouter.OracleRouter__ErrorCodeFlagged.selector);
        oracleRouter.getPricesForMarket(address(this), assets, 0);
    }

    function test_getPricesForMarket_success() public {
        deal(_USDC_ADDRESS, address(this), 1e18);
        vm.prank(address(this));
        usdc.approve(address(eUSDC), 1e18);

        marketManager.listToken(address(eUSDC));

        vm.prank(address(marketManager));
        eUSDC.startMarket(address(this));

        _addSinglePriceFeed();

        (
            AccountSnapshot[] memory snapshots,
            uint256[] memory underlyingPrices,
            uint256 numAssets
        ) = oracleManager.getPricesForMarket(address(this), assets, 1);

        (, int256 usdcPrice, , , ) = IChainlink(_CHAINLINK_USDC_USD)
            .latestRoundData();

        assertEq(numAssets, 1);

        for (uint256 i = 0; i < numAssets; i++) {
            assertEq(underlyingPrices[i], uint256(usdcPrice) * 1e10);
            assertEq(snapshots[i].asset, address(eUSDC));
            assertFalse(snapshots[i].isPToken);
            assertEq(snapshots[i].decimals, usdc.decimals());
            assertEq(
                assets[i].balanceOf(address(this)),
                eUSDC.balanceOf(address(this))
            );
            assertEq(snapshots[i].debtBalance, 0);
            assertEq(snapshots[i].exchangeRate, 0);
        }
    }
}
