// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { PendlePTAggregator } from "contracts/oracles/adaptors/wrappedAggregators/PendlePTAggregator.sol";
import { ICToken } from "contracts/interfaces/ICToken.sol";
import { TestBaseOracleManager } from "../TestBaseOracleManager.sol";
import { BaseWrappedAggregator } from "contracts/oracles/adaptors/wrappedAggregators/BaseWrappedAggregator.sol";
import { WAD, SECONDS_PER_YEAR } from "contracts/libraries/ConstantsLib.sol";
import { IPPrincipalToken } from "contracts/interfaces/external/pendle/IPPrincipalToken.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract TestPendlePtAggregator is TestBaseOracleManager {
    PendlePTAggregator public aggregator;

    address internal PT_weETH_25JUN2026 = 0x8E8b8d3b2DcA78cb04B9914b7EC1Ad72F671f96D;
    address internal CHAINLINK_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address internal CHAINLINK_weETH_ETH = 0x5c9C449BbC9a6075A2c061dF312a35fd1E05fF22;
    address internal eETH = 0x35fA164735182de50811E8e2E824cFb9B6118ac2 ;
    uint256 internal discountOneYearBPS = 300; // 3% APY (4.54% advertised)

    function setUp() public override {
        _fork(23520963);

        _deployCentralRegistry();
        _deployOracleManager();
    }

    function test_fail_InvalidDiscountedOneYear() public {

        vm.expectRevert(BaseWrappedAggregator.BaseWrappedAggregator__InvalidConfig.selector);
        aggregator = new PendlePTAggregator(
            PT_weETH_25JUN2026,
            eETH,
            CHAINLINK_weETH_ETH,
            10_000 + 1
        );

    }

    function test_fail_InvalidTimeToExpiry() public {
        vm.mockCall(
            address(IPPrincipalToken(PT_weETH_25JUN2026)),
            abi.encodeWithSelector(IPPrincipalToken.expiry.selector),
            abi.encode(block.timestamp +  SECONDS_PER_YEAR + 1)
        );

        vm.expectRevert(BaseWrappedAggregator.BaseWrappedAggregator__InvalidConfig.selector);
        _deployAggregatorCorrectly();
    }

    function test_success_deployAggregator() public {
        _deployAggregatorCorrectly();

        assertEq(address(aggregator.PT()), PT_weETH_25JUN2026);
        assertEq(address(aggregator.asset()), eETH);
        assertEq(address(aggregator.underlyingAggregator()), CHAINLINK_ETH_USD);
    }

    function test_success_getPrice() public {

        aggregator = new PendlePTAggregator(
            PT_weETH_25JUN2026,
            eETH,
            CHAINLINK_weETH_ETH,
            discountOneYearBPS
        );

        chainlinkAdaptor = new ChainlinkAdaptor(
            ICentralRegistry(address(centralRegistry))
        );

        chainlinkAdaptor.addAsset(
            _ETH_ADDRESS,
            true,   // inUSD
            CHAINLINK_ETH_USD,
            0,
            100
        );

        chainlinkAdaptor.addAsset(
            PT_weETH_25JUN2026,
            false,  // not in USD
            address(aggregator),
            0,
            100
        );

        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));
        oracleManager.addAssetPriceFeed(_ETH_ADDRESS, address(chainlinkAdaptor));
        oracleManager.addAssetPriceFeed(PT_weETH_25JUN2026, address(chainlinkAdaptor));

        (uint256 ptWeETH_USD_Price, uint256 errorCode) = oracleManager.getPrice(
            PT_weETH_25JUN2026,
            true,    // inUSD
            false
        );

        assertEq(errorCode, 0);

        // weETH/ETH from chainlink: ~1.0776 ETH
        // Discount:
        //  PT expires at timestamp 1782345600 (Jun 24, 2026)
        //  Current block timestamp ~1759778195 (Oct 06, 2025)
        //  timeToExpiry = 1782345600 - 1759778195 = 22567405 seconds (~0.7155 years)
        //  discountOneYear = 300 bps
        //  discount: = (0.7155 years * 0.03) = 0.021465 (2.1465%)
        //  exchangeRate = 1 - 0.021465 = 0.978535 (97.85%)
        // Adjusted PT-weETH/ETH = 1.0776 * 0.9785 = ~1.0544 ETH
        (, int256 answer,,,) = aggregator.latestRoundData();
        assertEq(answer, 1054459710151640166, "Adjusted PT-weETH/ETH should be ~1.0544");

        // ETH/USD from chainlink: ~$4,709
        // PT-weETH/USD = 1.0544 * 4709 = ~$4,965.56
        assertEq(ptWeETH_USD_Price, 4965565071651032072197, "PT-weETH/USD should be ~$4,965.56");
    }

    function _deployAggregatorCorrectly() internal {
        aggregator = new PendlePTAggregator(
            PT_weETH_25JUN2026,
            eETH,
            CHAINLINK_ETH_USD,
            discountOneYearBPS
        );
    }

}