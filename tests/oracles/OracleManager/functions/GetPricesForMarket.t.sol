// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseOracleManager } from "../TestBaseOracleManager.sol";
import { IChainlink } from "contracts/interfaces/external/chainlink/IChainlink.sol";
import { ICToken, AccountSnapshot } from "contracts/interfaces/ICToken.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { console2 } from "forge-std/console2.sol";

contract GetPricesForMarketTest is TestBaseOracleManager {
    address[] public assets;

    function setUp() public override {
        super.setUp();

        assets.push(address(borrowableCUSDC));

        _deployStrategyCBALRETH();

        _prepareBALRETH(address(this), 1e18);
        _prepareUSDC(address(this), 1e18);

        balRETH.approve(address(strategyCBALRETH), 1e18);
        
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
        _prepareUSDC(address(this), 1e18);
        vm.prank(address(this));
        usdc.approve(address(borrowableCUSDC), 1e18);

        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCUSDC));

        vm.prank(address(marketManagerIsolated));
        borrowableCUSDC.initializeDeposits(address(this));

        vm.expectRevert(OracleManager.OracleManager__NotSupported.selector);
        oracleManager.getPricesForMarket(address(this), assets, 1);
    }

    function test_getPricesForMarket_fail_whenErrorCodeExceedsBreakpoint()
        public
    {
        _prepareUSDC(address(this), 1e18);
        vm.prank(address(this));
        usdc.approve(address(borrowableCUSDC), 1e18);

        oracleManager.addCTokenSupport(address(borrowableCUSDC));
        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCUSDC));

        vm.prank(address(marketManagerIsolated));
        borrowableCUSDC.initializeDeposits(address(this));

        _addSinglePriceFeed();

        vm.expectRevert(
            OracleManager.OracleManager__ErrorCodeFlagged.selector
        );
        oracleManager.getPricesForMarket(address(this), assets, 0);
    }

    function test_getPricesForMarket_success() public {
        _prepareUSDC(address(this), 1e18);
        vm.prank(address(this));
        usdc.approve(address(borrowableCUSDC), 1e18);

        oracleManager.addCTokenSupport(address(borrowableCUSDC));
        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCUSDC));

        // vm.prank(address(marketManagerIsolated));
        // borrowableCUSDC.initializeDeposits(address(this));

        _addSinglePriceFeed();

        (
            AccountSnapshot[] memory snapshots,
            uint256[] memory underlyingPrices,
            uint256 numAssets
        ) = oracleManager.getPricesForMarket(address(this), assets, 1);

        uint256 exchangeRate = borrowableCUSDC.exchangeRate();
        console2.log("exchangeRate", exchangeRate);

        (, int256 usdcPrice, , , ) = IChainlink(_CHAINLINK_USDC_USD)
            .latestRoundData();

        assertEq(numAssets, 1);

        for (uint256 i = 0; i < numAssets; i++) {
            assertEq(underlyingPrices[i], uint256(usdcPrice) * 1e10);
            assertEq(snapshots[i].asset, address(borrowableCUSDC));
            assertTrue(snapshots[i].isCollateral);
            assertEq(snapshots[i].decimals, usdc.decimals());
            assertEq(
                ICToken(assets[i]).balanceOf(address(this)),
                borrowableCUSDC.balanceOf(address(this)),
                "balanceOf"
            );
            assertEq(snapshots[i].debtBalance, 0, "debtBalance");
            assertEq(snapshots[i].exchangeRate, 1e18, "exchangeRate");
        }
    }
}
