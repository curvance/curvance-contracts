// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { PendlePTAggregator } from "contracts/oracles/adaptors/wrappedAggregators/PendlePTAggregator.sol";
import { TestBaseOracleManager } from "../TestBaseOracleManager.sol";
import { BaseWrappedAggregator } from "contracts/oracles/adaptors/wrappedAggregators/BaseWrappedAggregator.sol";
import { WAD, SECONDS_PER_YEAR } from "contracts/libraries/ConstantsLib.sol";
import { IPPrincipalToken } from "contracts/interfaces/external/pendle/IPPrincipalToken.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { console2 } from "forge-std/console2.sol";

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
            10_000 + 1,
            "100"
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
        // Use CHAINLINK_ETH_USD (not weETH/ETH) since PT-weETH redeems
        // for 1 eETH ≈ 1 ETH, not 1 weETH. The discounted price must be
        // below the underlying asset, not above it.
        _deployAggregatorCorrectly();

        chainlinkAdaptor = new ChainlinkAdaptor(
            ICentralRegistry(address(centralRegistry))
        );
        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));

        chainlinkAdaptor.addAsset(
            PT_weETH_25JUN2026,
            true,   // inUSD — aggregator wraps ETH/USD, result is USD
            address(aggregator),
            0
        );

        oracleManager.addAssetPricingAdaptor(PT_weETH_25JUN2026, address(chainlinkAdaptor), 100, 50, 100, 50);

        (uint256 ptWeETH_USD_Price, uint256 errorCode) = oracleManager.getPrice(
            PT_weETH_25JUN2026,
            true,    // inUSD = true, so price will return in USD denomination.
            false // getLower = false so price will round up.
        );

        assertEq(errorCode, 0);

        // ETH/USD from chainlink: ~$4,709 (8 decimals)
        // Discount:
        //  PT expires at timestamp 1782345600 (Jun 24, 2026)
        //  Current block timestamp ~1759778195 (Oct 06, 2025)
        //  timeToExpiry = 22567405 seconds (~0.7155 years)
        //  discountOneYear = 300 bps = 3%
        //  discount = 0.7155 * 0.03 = 0.02147 (2.147%)
        //  exchangeRate = 1 - 0.02147 = 0.97853 (97.85%)
        // Adjusted PT-eETH/USD ≈ $4,709 * 0.97853 ≈ $4,608
        (, int256 rawEthUsd,,,) = aggregator.underlyingAggregator().latestRoundData();
        (, int256 adjustedAnswer,,,) = aggregator.latestRoundData();

        // PT must be priced below the underlying ETH (it's discounted).
        assertTrue(adjustedAnswer > 0, "PT price should be positive");
        assertTrue(adjustedAnswer < rawEthUsd, "PT should be priced below underlying ETH");

        // Verify the adjusted answer matches the expected discount math.
        uint256 timeToExpiry = IPPrincipalToken(PT_weETH_25JUN2026).expiry() - block.timestamp;
        console2.log("Time to expiry: ", timeToExpiry);
        uint256 exchangeRate = WAD - ((timeToExpiry * discountOneYearBPS * 1e14) / SECONDS_PER_YEAR);
        console2.log("Exchange rate (in 18 decimals): ", exchangeRate);
        int256 expectedAnswer = (rawEthUsd * int256(exchangeRate)) / int256(WAD);
        assertEq(adjustedAnswer, expectedAnswer, "Adjusted answer should match discount math");

        assertTrue(ptWeETH_USD_Price > 0, "PT USD price should be positive");
    }

    function _deployAggregatorCorrectly() internal {
        aggregator = new PendlePTAggregator(
            PT_weETH_25JUN2026,
            eETH,
            CHAINLINK_ETH_USD,
            discountOneYearBPS,
            "100"
        );
    }

}
