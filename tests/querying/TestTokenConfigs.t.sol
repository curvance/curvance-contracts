// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import "forge-std/console.sol";

contract TestTokenConfigs is TestBaseMarketIsolated {

    // ⋆⁺₊⋆☾⋆⁺₊⋆♡⋆⁺₊⋆☾⋆⁺₊⋆ FILL THESE IN ⋆⁺₊⋆☾⋆⁺₊⋆♡⋆⁺₊⋆☾⋆⁺₊⋆
    address MARKET_MANAGER_TO_TEST = 0xBc4cd7bbd8d38027A88838B88BA04561FA778C35;
    address CTOKEN_TO_TEST = 0xdB3e888c3b50771821226d30Ab6eC14eB5ba85bA;

    /// @dev Update these values to match the config you want to validate on-chain.
    function _tokenConfig()
        internal
        pure
        returns (MarketManagerIsolated.TokenConfig memory tokenConfig)
    {
        tokenConfig.collRatio = 4000;
        tokenConfig.collReqSoft = 1000;
        tokenConfig.collReqHard = 800;
        tokenConfig.liqIncBase = 600;
        tokenConfig.liqIncHard = 700;
        tokenConfig.liqIncMin = 600;
        tokenConfig.liqIncMax = 700;
        tokenConfig.closeFactorBase = 4000;
        tokenConfig.closeFactorMin = 4000;
        tokenConfig.closeFactorMax = 10_000;
        tokenConfig.collateralCap = 11500000000;
        tokenConfig.debtCap = 11500000000;
    }

    // ⋆⁺₊⋆☾⋆⁺₊⋆♡⋆⁺₊⋆☾⋆⁺₊⋆⋆⁺₊⋆☾⋆⁺₊⋆♡⋆⁺₊⋆☾⋆⁺₊⋆⋆⁺₊⋆☾⋆⁺₊⋆♡⋆⁺₊⋆☾⋆⁺₊⋆

    struct ExpectedConfig {
        uint256 collRatio;
        uint256 collReqSoft;
        uint256 collReqHard;
        uint256 liqIncBase;
        uint256 liqIncCurve;
        uint256 liqIncMin;
        uint256 liqIncMax;
        uint256 closeFactorBase;
        uint256 closeFactorCurve;
        uint256 closeFactorMin;
        uint256 closeFactorMax;
        uint256 collateralCap;
        uint256 debtCap;
    }

    function setUp() public override {
        super.setUp();

        _prepareUSDC(address(this), 77777);
        _prepareDAI(address(this), 77777);
        deal(address(LP_wstETH_24Dec2025), address(this), 77777);

        usdc.approve(address(borrowableCUSDC), 77777);
        dai.approve(address(borrowableCDAI), 77777);
    }

    /// @dev Applies config locally and reads back stored values into an
    ///      ExpectedConfig struct (captures internal transformations).
    function _applyAndReadConfig()
        internal
        returns (ExpectedConfig memory e)
    {
        marketManagerIsolated.listTokens(
            address(borrowableCUSDC),
            address(borrowableCDAI)
        );

        MarketManagerIsolated.TokenConfig memory config = _tokenConfig();
        config.cToken = address(borrowableCDAI);
        marketManagerIsolated.updateTokenConfig(config);

        (e.collRatio, e.collReqSoft, e.collReqHard) =
            marketManagerIsolated.collConfig(address(borrowableCDAI));

        _readLiqConfig(e, address(marketManagerIsolated), address(borrowableCDAI));

        e.collateralCap =
            marketManagerIsolated.collateralCaps(address(borrowableCDAI));
        e.debtCap =
            marketManagerIsolated.debtCaps(address(borrowableCDAI));
    }

    /// @dev Reads liquidationConfig into struct via staticcall + assembly
    ///      to avoid stack-too-deep from 8-tuple destructuring.
    ///      ExpectedConfig field layout (uint256 each, 0x20 bytes):
    ///        0x00 collRatio | 0x20 collReqSoft | 0x40 collReqHard
    ///        0x60 liqIncBase | 0x80 liqIncCurve | 0xa0 liqIncMin
    ///        0xc0 liqIncMax | 0xe0 closeFactorBase | 0x100 closeFactorCurve
    ///        0x120 closeFactorMin | 0x140 closeFactorMax
    ///        0x160 collateralCap | 0x180 debtCap
    function _readLiqConfig(
        ExpectedConfig memory e,
        address target,
        address cToken
    ) internal view {
        bytes4 selector = MarketManagerIsolated.liquidationConfig.selector;
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, selector)
            mstore(add(ptr, 0x04), cToken)

            if iszero(staticcall(gas(), target, ptr, 0x24, ptr, 0x100)) {
                revert(0, 0)
            }

            mstore(add(e, 0x60), mload(ptr))
            mstore(add(e, 0x80), mload(add(ptr, 0x20)))
            mstore(add(e, 0xa0), mload(add(ptr, 0x40)))
            mstore(add(e, 0xc0), mload(add(ptr, 0x60)))
            mstore(add(e, 0xe0), mload(add(ptr, 0x80)))
            mstore(add(e, 0x100), mload(add(ptr, 0xa0)))
            mstore(add(e, 0x120), mload(add(ptr, 0xc0)))
            mstore(add(e, 0x140), mload(add(ptr, 0xe0)))
        }
    }

    function _validateLiqConfig(
        ExpectedConfig memory e,
        address target
    ) internal {
        ExpectedConfig memory a = ExpectedConfig(0,0,0,0,0,0,0,0,0,0,0,0,0);
        _readLiqConfig(a, target, CTOKEN_TO_TEST);

        console.log("=== Liquidation Config ===");
        console.log("liqIncBase       expected:", e.liqIncBase);
        console.log("liqIncBase       actual:  ", a.liqIncBase);
        console.log("liqIncCurve      expected:", e.liqIncCurve);
        console.log("liqIncCurve      actual:  ", a.liqIncCurve);
        console.log("liqIncMin        expected:", e.liqIncMin);
        console.log("liqIncMin        actual:  ", a.liqIncMin);
        console.log("liqIncMax        expected:", e.liqIncMax);
        console.log("liqIncMax        actual:  ", a.liqIncMax);
        console.log("closeFactorBase  expected:", e.closeFactorBase);
        console.log("closeFactorBase  actual:  ", a.closeFactorBase);
        console.log("closeFactorCurve expected:", e.closeFactorCurve);
        console.log("closeFactorCurve actual:  ", a.closeFactorCurve);
        console.log("closeFactorMin   expected:", e.closeFactorMin);
        console.log("closeFactorMin   actual:  ", a.closeFactorMin);
        console.log("closeFactorMax   expected:", e.closeFactorMax);
        console.log("closeFactorMax   actual:  ", a.closeFactorMax);

        assertEq(a.liqIncBase, e.liqIncBase, "liqIncBase mismatch");
        assertEq(a.liqIncCurve, e.liqIncCurve, "liqIncCurve mismatch");
        assertEq(a.liqIncMin, e.liqIncMin, "liqIncMin mismatch");
        assertEq(a.liqIncMax, e.liqIncMax, "liqIncMax mismatch");
        assertEq(a.closeFactorBase, e.closeFactorBase, "closeFactorBase mismatch");
        assertEq(a.closeFactorCurve, e.closeFactorCurve, "closeFactorCurve mismatch");
        assertEq(a.closeFactorMin, e.closeFactorMin, "closeFactorMin mismatch");
        assertEq(a.closeFactorMax, e.closeFactorMax, "closeFactorMax mismatch");
    }

    /// @dev Sets up the token config locally and logs the stored values
    ///      (after internal transformations).
    function test_live_token() public {
        ExpectedConfig memory e = _applyAndReadConfig();

        console.log("=== Stored Collateral Config ===");
        console.log("collRatio:  ", e.collRatio);
        console.log("collReqSoft:", e.collReqSoft);
        console.log("collReqHard:", e.collReqHard);

        console.log("=== Stored Liquidation Config ===");
        console.log("liqIncBase:      ", e.liqIncBase);
        console.log("liqIncCurve:     ", e.liqIncCurve);
        console.log("liqIncMin:       ", e.liqIncMin);
        console.log("liqIncMax:       ", e.liqIncMax);
        console.log("closeFactorBase: ", e.closeFactorBase);
        console.log("closeFactorCurve:", e.closeFactorCurve);
        console.log("closeFactorMin:  ", e.closeFactorMin);
        console.log("closeFactorMax:  ", e.closeFactorMax);

        console.log("=== Stored Caps ===");
        console.log("collateralCap:", e.collateralCap);
        console.log("debtCap:      ", e.debtCap);
    }

    /// @dev Sets up token config locally, forks Monad mainnet, then asserts
    ///      on-chain values match the locally stored values.
    function test_validate_on_chain() public {
        ExpectedConfig memory e = _applyAndReadConfig();

        // Fork to Monad mainnet.
        vm.createSelectFork(vm.envString("MON_NODE_URI_MONAD_MAINNET"));

        MarketManagerIsolated liveManager =
            MarketManagerIsolated(MARKET_MANAGER_TO_TEST);

        assertTrue(
            liveManager.isListed(CTOKEN_TO_TEST),
            "token not listed on-chain"
        );

        // -- Collateral config --
        {
            (uint256 collRatio, uint256 collReqSoft, uint256 collReqHard) =
                liveManager.collConfig(CTOKEN_TO_TEST);

            console.log("=== Collateral Config ===");
            console.log("collRatio   expected:", e.collRatio);
            console.log("collRatio   actual:  ", collRatio);
            console.log("collReqSoft expected:", e.collReqSoft);
            console.log("collReqSoft actual:  ", collReqSoft);
            console.log("collReqHard expected:", e.collReqHard);
            console.log("collReqHard actual:  ", collReqHard);

            assertEq(collRatio, e.collRatio, "collRatio mismatch");
            assertEq(collReqSoft, e.collReqSoft, "collReqSoft mismatch");
            assertEq(collReqHard, e.collReqHard, "collReqHard mismatch");
        }

        // -- Liquidation config --
        _validateLiqConfig(e, MARKET_MANAGER_TO_TEST);

        // -- Caps --
        {
            uint256 collateralCap =
                liveManager.collateralCaps(CTOKEN_TO_TEST);
            uint256 debtCap = liveManager.debtCaps(CTOKEN_TO_TEST);

            console.log("=== Caps ===");
            console.log("collateralCap expected:", e.collateralCap);
            console.log("collateralCap actual:  ", collateralCap);
            console.log("debtCap       expected:", e.debtCap);
            console.log("debtCap       actual:  ", debtCap);

            assertEq(collateralCap, e.collateralCap, "collateralCap mismatch");
            assertEq(debtCap, e.debtCap, "debtCap mismatch");
        }
    }
}
