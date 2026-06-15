// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";

import { WAD } from "contracts/libraries/ConstantsLib.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";

import { IOracleAdaptor } from "contracts/interfaces/IOracleAdaptor.sol";
import { IOracleManager } from "contracts/interfaces/IOracleManager.sol";
import { IChainlink } from "contracts/interfaces/external/chainlink/IChainlink.sol";
import { IERC4626 } from "lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

interface IVaultAggregator {
    function vault() external view returns (address);
    function asset() external view returns (address);
    function underlyingAggregator() external view returns (IChainlink);
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
    function getAdjustedAnswer(int256 answer) external view returns (int256);
}

contract TestVaultAggregatorMonadFork is Test {
    // Deployed contract addresses on Monad mainnet.
    address constant VAULT_AGGREGATOR_AUSD_VUSD = 0x084BC7bE1326Ee1FD5387a4A48fD6999A79BFa8b;
    address constant VAULT_AGGREGATOR_AUSD_SAUSD = 0x73Af3E1848636D4DE6A61050D5487d6f09A7A1Be;
    address constant CHAINLINK_ADAPTOR = 0xACfE3fCcae79445836E03c5359BB96bd352b9C00;
    address constant REDSTONE_CLASSIC_ADAPTOR = 0x0fA602b3e748438A3F1599206Ed6DC497ab3331E;
    address constant ORACLE_MANAGER = 0x32faD39e79FAc67f80d1C86CbD1598043e52CDb6;
    address constant SAUSD_MARKET_TOKEN = 0x84C5aF20b58818631164Bb7d798E457fcFACD9Ac;

    IVaultAggregator vaultAgg;
    IOracleAdaptor adaptor;
    IOracleAdaptor redstoneAdaptor;
    IOracleManager oracleManager;

    address vault;
    address asset;
    IChainlink underlyingAgg;
    uint8 aggDecimals;

    uint256 fork;

    function setUp() public {
        fork = vm.createSelectFork(
            vm.envString("MON_NODE_URI_MONAD_MAINNET")
        );

        vaultAgg = IVaultAggregator(VAULT_AGGREGATOR_AUSD_VUSD);
        adaptor = IOracleAdaptor(CHAINLINK_ADAPTOR);
        redstoneAdaptor = IOracleAdaptor(REDSTONE_CLASSIC_ADAPTOR);
        oracleManager = IOracleManager(ORACLE_MANAGER);

        vault = vaultAgg.vault();
        asset = vaultAgg.asset();
        underlyingAgg = vaultAgg.underlyingAggregator();
        aggDecimals = vaultAgg.decimals();
    }

    function test_vaultAggregatorReturnsAdjustedPrice() public view {
        // Get the underlying aggregator's raw answer.
        (uint80 roundId, int256 rawAnswer,, uint256 updatedAt,) = underlyingAgg.latestRoundData();
        assertGt(rawAnswer, 0, "underlying feed should be positive");

        // Get the vault aggregator's adjusted answer.
        (, int256 adjustedAnswer,, uint256 vaultAggUpdatedAt,) = vaultAgg.latestRoundData();
        assertGt(adjustedAnswer, 0, "adjusted answer should be positive");

        // Compute expected adjusted answer manually:
        // result = (rawAnswer * exchangeRate) / assetDecimalPrecision
        uint256 vaultDecimals = IERC20(vault).decimals();
        uint256 assetDecimals = IERC20(asset).decimals();
        uint256 vaultDecimalPrecision = 10 ** vaultDecimals;
        uint256 assetDecimalPrecision = 10 ** assetDecimals;

        uint256 exchangeRate = IERC4626(vault).convertToAssets(vaultDecimalPrecision);
        int256 expectedAnswer = (rawAnswer * int256(exchangeRate)) / int256(assetDecimalPrecision);

        assertEq(adjustedAnswer, expectedAnswer, "adjusted answer should match manual calculation");

        console2.log("--- Contract Addresses ---");
        console2.log("VaultAggregator:", VAULT_AGGREGATOR_AUSD_VUSD);
        console2.log("ChainlinkAdaptor:", CHAINLINK_ADAPTOR);
        console2.log("Vault (vUSD):", vault);
        console2.log("Asset (AUSD):", asset);
        console2.log("Underlying aggregator:", address(underlyingAgg));
        console2.log("Aggregator decimals:", aggDecimals);
        console2.log("");
        console2.log("--- Underlying Feed ---");
        console2.log("Round ID:", roundId);
        console2.log("Raw answer (8 dec):", uint256(rawAnswer));
        console2.log("Raw answer as USD: $", uint256(rawAnswer) * 1e10);
        console2.log("Updated at:", updatedAt);
        console2.log("Block timestamp:", block.timestamp);
        console2.log("Feed age (s):", block.timestamp - updatedAt);
        console2.log("");
        console2.log("--- Vault Exchange Rate ---");
        console2.log("Vault decimals:", vaultDecimals);
        console2.log("Asset decimals:", assetDecimals);
        console2.log("convertToAssets(1e", vaultDecimals, "):", exchangeRate);
        console2.log("");
        console2.log("--- VaultAggregator Output ---");
        console2.log("Adjusted answer (8 dec):", uint256(adjustedAnswer));
        console2.log("Adjusted answer as USD: $", uint256(adjustedAnswer) * 1e10);
        console2.log("VaultAgg updatedAt:", vaultAggUpdatedAt);
        console2.log("");
        console2.log("--- Manual Calculation ---");
        console2.log("rawAnswer * exchangeRate:", uint256(rawAnswer) * exchangeRate);
        console2.log("/ assetDecimalPrecision:", assetDecimalPrecision);
        console2.log("= expectedAnswer:", uint256(expectedAnswer));
        console2.log("Matches adjusted answer:", adjustedAnswer == expectedAnswer);
    }

    function test_priceGuardIsCappingVUSDPrice() public view {
        // 1. Get the raw price the VaultAggregator produces (before guard).
        //    Note: the VaultAggregator reads the underlying feed directly,
        //    bypassing the adaptor entirely. Any AUSD price guard on the
        //    adaptor does NOT apply here — only the vUSD price guard does.
        (, int256 rawAnswer,,,) = underlyingAgg.latestRoundData();
        int256 adjustedAnswer = vaultAgg.getAdjustedAnswer(rawAnswer);

        // Normalize to WAD (18 decimals) - same as _adjustPrice does.
        uint256 rawPriceWad = FixedPointMathLib.fullMulDiv(
            uint256(adjustedAnswer), WAD, 10 ** aggDecimals
        );

        // 2. Get the price guard config.
        IOracleAdaptor.PriceGuard memory pg = adaptor.getPriceGuard(vault, true);
        assertGt(pg.basePrice, 0, "price guard should be active");
        assertGt(pg.ips, 0, "should be dynamic mode");

        // 3. Compute the current guarded max/min.
        uint256 timePassed = block.timestamp - pg.timestampStart;
        uint256 scaleFactor = WAD + timePassed * pg.ips;
        uint256 guardedMax = FixedPointMathLib.fullMulDiv(
            pg.basePrice, scaleFactor, WAD
        );
        uint256 guardedMin = FixedPointMathLib.fullMulDiv(
            pg.minPrice, scaleFactor, WAD
        );

        console2.log("--- PriceGuard Config ---");
        console2.log("timestampStart:", pg.timestampStart);
        console2.log("ips (increase per second):", uint256(pg.ips));
        console2.log("basePrice:", uint256(pg.basePrice));
        console2.log("minPrice:", uint256(pg.minPrice));
        console2.log("Mode: dynamic (ips > 0)");
        console2.log("");
        console2.log("--- Dynamic Guard Calculation ---");
        console2.log("block.timestamp:", block.timestamp);
        console2.log("Time passed since start (s):", timePassed);
        console2.log("Time passed (hours):", timePassed / 3600);
        console2.log("Time passed (days):", timePassed / 86400);
        console2.log("Scale factor (WAD):", scaleFactor);
        console2.log("Guarded max (WAD):", guardedMax);
        console2.log("Guarded min (WAD):", guardedMin);
        console2.log("");
        console2.log("--- Price Comparison ---");
        console2.log("Raw uncapped price (WAD):", rawPriceWad);
        console2.log("Guarded max (WAD):       ", guardedMax);
        console2.log("Difference (WAD):        ", rawPriceWad - guardedMax);

        // 4. Confirm raw price exceeds the guarded max -> price IS being capped.
        assertGt(rawPriceWad, guardedMax, "raw price should exceed guarded max (i.e. capped)");

        // 5. Get the actual returned price from the adaptor.
        IOracleAdaptor.PricingResult memory result = adaptor.getPrice(vault, true, false);
        assertFalse(result.hadError, "getPrice should not error");
        assertTrue(result.inUSD, "should be priced in USD");

        // 6. Confirm the returned price equals the guarded max (capped).
        assertEq(result.price, guardedMax, "returned price should equal guarded max");

        // 7. Confirm the returned price is less than the raw uncapped price.
        assertLt(result.price, rawPriceWad, "returned price should be less than raw price");

        uint256 cappedBy = rawPriceWad - guardedMax;
        uint256 cappedBps = cappedBy * 10000 / rawPriceWad;
        console2.log("");
        console2.log("--- Result ---");
        console2.log("Adaptor returned price (WAD):", result.price);
        console2.log("Adaptor inUSD:", result.inUSD);
        console2.log("Adaptor hadError:", result.hadError);
        console2.log("Price IS capped: true");
        console2.log("Capped by (WAD):", cappedBy);
        console2.log("Capped by (bps):", cappedBps);
    }

    function test_priceGuardClampsInflatedVUSDVaultExchangeRate() public {
        _assertPriceGuardClampsInflatedVaultExchangeRate(VAULT_AGGREGATOR_AUSD_VUSD, adaptor);
    }

    function test_priceGuardClampsInflatedSAUSDVaultExchangeRateOnActiveRoute() public {
        IVaultAggregator agg = IVaultAggregator(VAULT_AGGREGATOR_AUSD_SAUSD);
        address vaultToken = agg.vault();

        address[] memory adaptors = oracleManager.getPricingAdaptors(vaultToken);
        assertEq(adaptors.length, 1, "sAUSD vault should have one active pricing adaptor");
        assertEq(adaptors[0], REDSTONE_CLASSIC_ADAPTOR, "sAUSD vault route should use Redstone");
        assertEq(oracleManager.cTokens(SAUSD_MARKET_TOKEN), vaultToken, "market token should price through vault");

        _assertPriceGuardClampsInflatedVaultExchangeRate(VAULT_AGGREGATOR_AUSD_SAUSD, redstoneAdaptor);
    }

    function test_priceGuardWillUncapAfterSufficientTime() public {
        // Get current raw price.
        (, int256 rawAnswer,,,) = underlyingAgg.latestRoundData();
        int256 adjustedAnswer = vaultAgg.getAdjustedAnswer(rawAnswer);
        uint256 rawPriceWad = FixedPointMathLib.fullMulDiv(
            uint256(adjustedAnswer), WAD, 10 ** aggDecimals
        );

        IOracleAdaptor.PriceGuard memory pg = adaptor.getPriceGuard(vault, true);

        // Calculate how much more time is needed for guardedMax >= rawPriceWad.
        // guardedMax = basePrice * (WAD + t * ips) / WAD >= rawPriceWad
        // t >= (rawPriceWad * WAD / basePrice - WAD) / ips
        uint256 neededTotalTime = (rawPriceWad * WAD / pg.basePrice - WAD) / pg.ips;
        uint256 currentTimePassed = block.timestamp - pg.timestampStart;

        assertGt(neededTotalTime, currentTimePassed, "should need more time to uncap");

        uint256 remainingTime = neededTotalTime - currentTimePassed + 1; // +1 for rounding

        // Current state (before warp).
        uint256 currentGuardedMax = FixedPointMathLib.fullMulDiv(
            pg.basePrice, (WAD + currentTimePassed * pg.ips), WAD
        );

        console2.log("--- Before Time Warp ---");
        console2.log("Current block.timestamp:", block.timestamp);
        console2.log("Current time passed (s):", currentTimePassed);
        console2.log("Current guarded max:", currentGuardedMax);
        console2.log("Raw price:", rawPriceWad);
        console2.log("Currently capped by:", rawPriceWad - currentGuardedMax);
        console2.log("");
        console2.log("--- Time Calculation ---");
        console2.log("Total time needed from start (s):", neededTotalTime);
        console2.log("Total time needed (days):", neededTotalTime / 86400);
        console2.log("Remaining time from now (s):", remainingTime);
        console2.log("Remaining time (hours):", remainingTime / 3600);
        console2.log("Remaining time (days):", remainingTime / 86400);

        // Warp forward past the needed time.
        skip(remainingTime);

        // After time warp, guard max should now be >= raw price.
        uint256 newTimePassed = block.timestamp - pg.timestampStart;
        uint256 newGuardedMax = FixedPointMathLib.fullMulDiv(
            pg.basePrice, (WAD + newTimePassed * pg.ips), WAD
        );

        assertGe(newGuardedMax, rawPriceWad, "guard max should now exceed raw price");

        console2.log("");
        console2.log("--- After Time Warp ---");
        console2.log("New block.timestamp:", block.timestamp);
        console2.log("New time passed (s):", newTimePassed);
        console2.log("New time passed (days):", newTimePassed / 86400);
        console2.log("New guarded max:", newGuardedMax);
        console2.log("Raw price:", rawPriceWad);
        console2.log("Headroom above raw:", newGuardedMax - rawPriceWad);
        console2.log("Price would no longer be capped: true");
        // Note: after skip, the heartbeat check may fail since the underlying
        // feed timestamp is stale. We verify the guard math independently.
    }

    function _assertPriceGuardClampsInflatedVaultExchangeRate(
        address aggregator,
        IOracleAdaptor pricingAdaptor
    ) internal {
        IVaultAggregator agg = IVaultAggregator(aggregator);
        address vaultToken = agg.vault();
        IOracleAdaptor.PriceGuard memory pg = pricingAdaptor.getPriceGuard(vaultToken, true);
        assertGt(pg.basePrice, 0, "price guard should be active");

        uint256 guardedMax = _guardedMax(pg);
        assertGt(guardedMax, 0, "guarded max should be positive");

        uint256 inflatedRawPrice = _mockVaultExchangeRateAboveGuard(agg, guardedMax);
        assertGt(inflatedRawPrice, guardedMax, "mocked vault rate should exceed guard max");

        IOracleAdaptor.PricingResult memory result = pricingAdaptor.getPrice(vaultToken, true, false);
        assertFalse(result.hadError, "guard clamp should not mark an error");
        assertTrue(result.inUSD, "vault token should be priced in USD");
        assertEq(result.price, guardedMax, "vault token price should clamp to guard max");
    }

    function _mockVaultExchangeRateAboveGuard(
        IVaultAggregator agg,
        uint256 guardedMax
    ) internal returns (uint256 inflatedRawPrice) {
        IChainlink feed = agg.underlyingAggregator();
        (, int256 rawAnswer,,,) = feed.latestRoundData();
        assertGt(rawAnswer, 0, "underlying feed should be positive");

        address vaultToken = agg.vault();
        uint256 vaultDecimalPrecision = 10 ** IERC20(vaultToken).decimals();
        uint8 aggregatorDecimals = agg.decimals();
        uint256 inflatedExchangeRate =
            FixedPointMathLib.fullMulDiv(
                FixedPointMathLib.fullMulDiv(guardedMax * 2, 10 ** aggregatorDecimals, WAD) + 1,
                10 ** IERC20(agg.asset()).decimals(),
                uint256(rawAnswer)
            ) + 1;

        vm.mockCall(
            vaultToken,
            abi.encodeWithSelector(IERC4626.convertToAssets.selector, vaultDecimalPrecision),
            abi.encode(inflatedExchangeRate)
        );

        int256 inflatedAnswer = agg.getAdjustedAnswer(rawAnswer);
        inflatedRawPrice =
            FixedPointMathLib.fullMulDiv(uint256(inflatedAnswer), WAD, 10 ** aggregatorDecimals);
    }

    function _guardedMax(IOracleAdaptor.PriceGuard memory pg) internal view returns (uint256) {
        if (pg.ips == 0) {
            return pg.basePrice;
        }

        uint256 timePassed = block.timestamp - pg.timestampStart;
        return FixedPointMathLib.fullMulDiv(
            pg.basePrice, WAD + timePassed * pg.ips, WAD
        );
    }
}
