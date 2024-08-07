// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { IChainlink } from "contracts/interfaces/external/chainlink/IChainlink.sol";
import { TestBaseOracleRouter } from "../TestBaseOracleRouter.sol";
import { OracleRouter } from "contracts/oracles/OracleRouter.sol";

contract GetPricesForAssetTest is TestBaseOracleRouter {
    function test_getPricesForAsset_fail_whenNoFeedsAvailable() public {
        vm.expectRevert(OracleRouter.OracleRouter__NotSupported.selector);
        oracleRouter.getPricesForAsset(_USDC_ADDRESS, true);
    }

    function test_getPricesForAsset_success() public {
        _addSinglePriceFeed();

        (, int256 usdcPrice, , , ) = IChainlink(_CHAINLINK_USDC_USD)
            .latestRoundData();

        OracleRouter.FeedData[] memory feedDatas = oracleRouter
            .getPricesForAsset(_USDC_ADDRESS, true);

        for (uint256 i = 0; i < feedDatas.length; i++) {
            assertEq(feedDatas[i].price, uint256(usdcPrice) * 1e10);
            assertFalse(feedDatas[i].hadError);
        }

        (, int256 ethPrice, , , ) = IChainlink(_CHAINLINK_USDC_ETH)
            .latestRoundData();

        feedDatas = oracleRouter.getPricesForAsset(_USDC_ADDRESS, false);

        for (uint256 i = 0; i < feedDatas.length; i++) {
            assertEq(feedDatas[i].price, uint256(ethPrice));
            assertFalse(feedDatas[i].hadError);
        }
    }

    function test_mToken_getPricesForAsset_success() public {
        deal(_USDC_ADDRESS, address(this), 1e18);
        vm.prank(address(this));
        usdc.approve(address(dUSDC), 1e18);
        vm.prank(address(marketManager));
        dUSDC.startMarket(address(this));

        oracleRouter.addApprovedAdaptor(address(chainlinkAdaptor));
        chainlinkAdaptor.addAsset(
            address(dUSDC),
            _CHAINLINK_USDC_USD,
            0,
            true
        );
        oracleRouter.addAssetPriceFeed(
            _USDC_ADDRESS,
            address(chainlinkAdaptor)
        );
        oracleRouter.addMTokenSupport(address(dUSDC));

        (, int256 usdcPrice, , , ) = IChainlink(_CHAINLINK_USDC_USD)
            .latestRoundData();

        OracleRouter.FeedData[] memory feedDatas = oracleRouter
            .getPricesForAsset(address(dUSDC), true);

        for (uint256 i = 0; i < feedDatas.length; i++) {
            assertEq(feedDatas[i].price, uint256(usdcPrice) * 1e10);
            assertFalse(feedDatas[i].hadError);
        }
    }
}
