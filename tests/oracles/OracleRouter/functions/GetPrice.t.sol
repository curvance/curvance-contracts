// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseOracleRouter } from "../TestBaseOracleRouter.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IChainlink } from "contracts/interfaces/external/chainlink/IChainlink.sol";
import { OracleRouter, BAD_SOURCE } from "contracts/oracles/OracleRouter.sol";
import { PriceReturnData } from "contracts/interfaces/IOracleAdaptor.sol";

contract Oracle {
    address internal constant _FXS_TOKEN =
        0x3432B6A60D23Ca0dFCa7761B7ab56459D9C964D0;
    address internal constant _ETH_ADDRESS =
        0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    function isSupportedAsset(address asset) external view returns (bool) {
        return (asset == _ETH_ADDRESS || asset == _FXS_TOKEN);
    }

    function getPrice(
        address asset,
        bool inUSD,
        bool getLower
    ) external view returns (PriceReturnData memory rd) {
        if (asset == _FXS_TOKEN) {
            // for simplicity, let's assume that...
            // 1) we don't offer ETH support for FXS, so always return USD
            // 2) the oracles are identical, so getLower == !getLower
            // 3) current price is $6, so just return that
            return PriceReturnData(6e18, false, true);
        } else if (asset == _ETH_ADDRESS) {
            // price of ETH in ETH is 1
            if (!inUSD) return PriceReturnData(1e18, false, false);

            // price of ETH in USD works, but let's have a range
            if (getLower) return PriceReturnData(3900e18, false, true);
            if (!getLower) return PriceReturnData(4000e18, false, true);
        } else {
            // only these two tokens are supported
            return PriceReturnData(0, true, true);
        }
    }
}

contract GetPriceTest is TestBaseOracleRouter {
    address internal constant _FXS_TOKEN =
        0x3432B6A60D23Ca0dFCa7761B7ab56459D9C964D0;

    function test_getPrice_fail_whenNoFeedsAvailable() public {
        vm.expectRevert(OracleRouter.OracleRouter__NotSupported.selector);
        oracleRouter.getPrice(_USDC_ADDRESS, true, true);
    }

    function test_getPrice_success_withBadSourceErrorCode_whenSequencerIsDown()
        public
    {
        _addSinglePriceFeed();
        sequencer.setMockAnswer(1);

        (uint256 price, uint256 errorCode) = oracleRouter.getPrice(
            _USDC_ADDRESS,
            true,
            true
        );
        assertEq(price, 0);
        assertEq(errorCode, BAD_SOURCE);
    }

    function test_getPrice_fail_withBadSourceErrorCode_whenGracePeriodNotOver()
        public
    {
        _addSinglePriceFeed();
        sequencer.setMockStartedAt(block.timestamp);

        (uint256 price, uint256 errorCode) = oracleRouter.getPrice(
            _USDC_ADDRESS,
            true,
            true
        );
        assertEq(price, 0);
        assertEq(errorCode, BAD_SOURCE);
    }

    function test_getPrice_success() public {
        _addSinglePriceFeed();

        (, int256 usdcPrice, , , ) = IChainlink(_CHAINLINK_USDC_USD)
            .latestRoundData();

        (uint256 price, uint256 errorCode) = oracleRouter.getPrice(
            _USDC_ADDRESS,
            true,
            true
        );

        assertEq(price, uint256(usdcPrice) * 1e10);
        assertEq(errorCode, 0);

        (, int256 ethPrice, , , ) = IChainlink(_CHAINLINK_USDC_ETH)
            .latestRoundData();

        (price, errorCode) = oracleRouter.getPrice(_USDC_ADDRESS, false, true);

        assertEq(price, uint256(ethPrice));
        assertEq(errorCode, 0);
    }

    function test_getPrice_ETHUSD_LowerIsNotHigher_success() public {
        OracleRouter oracleRouter = new OracleRouter(
            ICentralRegistry(address(centralRegistry))
        );
        Oracle feed = new Oracle();

        oracleRouter.addApprovedAdaptor(address(feed));
        oracleRouter.addAssetPriceFeed(_ETH_ADDRESS, address(feed));
        oracleRouter.addAssetPriceFeed(_FXS_TOKEN, address(feed));

        (uint256 lower, ) = oracleRouter.getPrice({
            asset: _FXS_TOKEN,
            inUSD: false,
            getLower: true
        });
        (uint256 higher, ) = oracleRouter.getPrice({
            asset: _FXS_TOKEN,
            inUSD: false,
            getLower: false
        });

        assert(higher > lower);
    }
}
