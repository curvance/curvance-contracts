// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { IChainlink } from "contracts/interfaces/external/chainlink/IChainlink.sol";
import { TestBaseOracleManager } from "../TestBaseOracleManager.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";

contract GetPricesForAssetTest is TestBaseOracleManager {
    function test_getPricesForAsset_fail_whenNoFeedsAvailable() public {
        vm.expectRevert(OracleManager.OracleManager__NotSupported.selector);
        oracleManager.getPricesForAsset(_USDC_ADDRESS, true);
    }

    function test_getPricesForAsset_success() public {
        _addSinglePriceFeed();

        (, int256 usdcPrice, , , ) = IChainlink(_CHAINLINK_USDC_USD)
            .latestRoundData();

        OracleManager.FeedData[] memory feedDatas = oracleManager
            .getPricesForAsset(_USDC_ADDRESS, true);

        for (uint256 i = 0; i < feedDatas.length; i++) {
            assertEq(feedDatas[i].price, uint256(usdcPrice) * 1e10);
            assertFalse(feedDatas[i].hadError);
        }

        (, int256 ethPrice, , , ) = IChainlink(_CHAINLINK_USDC_ETH)
            .latestRoundData();

        feedDatas = oracleManager.getPricesForAsset(_USDC_ADDRESS, false);

        for (uint256 i = 0; i < feedDatas.length; i++) {
            assertEq(feedDatas[i].price, uint256(ethPrice));
            assertFalse(feedDatas[i].hadError);
        }
    }

    function test_mToken_getPricesForAsset_success() public {
        deal(_USDC_ADDRESS, address(this), 1e18);
        vm.prank(address(this));
        usdc.approve(address(eUSDC), 1e18);

        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));
        chainlinkAdaptor.addAsset(
            address(eUSDC),
            _CHAINLINK_USDC_USD,
            0,
            true
        );
        oracleManager.addAssetPriceFeed(
            _USDC_ADDRESS,
            address(chainlinkAdaptor)
        );
        oracleManager.addMTokenSupport(address(eUSDC));

        marketManager.listToken(address(eUSDC));

        vm.prank(address(marketManager));
        eUSDC.startMarket(address(this));

        (, int256 usdcPrice, , , ) = IChainlink(_CHAINLINK_USDC_USD)
            .latestRoundData();

        OracleManager.FeedData[] memory feedDatas = oracleManager
            .getPricesForAsset(address(eUSDC), true);

        for (uint256 i = 0; i < feedDatas.length; i++) {
            assertEq(feedDatas[i].price, uint256(usdcPrice) * 1e10);
            assertFalse(feedDatas[i].hadError);
        }
    }
}
