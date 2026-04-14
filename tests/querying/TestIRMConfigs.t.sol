// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { DynamicIRM } from "contracts/market/DynamicIRM.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import "forge-std/console.sol";

contract TestIRMConfigs is TestBaseMarketIsolated {

    // ⋆⁺₊⋆☾⋆⁺₊⋆♡⋆⁺₊⋆☾⋆⁺₊⋆ FILL THESE IN ⋆⁺₊⋆☾⋆⁺₊⋆♡⋆⁺₊⋆☾⋆⁺₊⋆
    address IRM_TO_TEST = 0x95B961B9aD06dB25831FcdA3c7A79b1EB7c3AFA8;

    /// @dev Update these to match the live IRM constructor args (all in BPS).
    function _irmConstructorArgs()
        internal
        pure
        returns (
            uint256 baseRatePerYear,
            uint256 vertexRatePerYear,
            uint256 vertexStart,
            uint256 adjustmentVelocity,
            uint256 decayPerAdjustment,
            uint256 vertexMultiplierMax
        )
    {
        baseRatePerYear = 250;       // 10%
        vertexRatePerYear = 750;     // 10%
        vertexStart = 9000;           // 50%
        adjustmentVelocity = 500;    // 10%
        decayPerAdjustment = 200;     // 1%
        vertexMultiplierMax = 100000; // 10x
    }
    // ⋆⁺₊⋆☾⋆⁺₊⋆♡⋆⁺₊⋆☾⋆⁺₊⋆⋆⁺₊⋆☾⋆⁺₊⋆♡⋆⁺₊⋆☾⋆⁺₊⋆⋆⁺₊⋆☾⋆⁺₊⋆♡⋆⁺₊⋆☾⋆⁺₊⋆

    /// @dev Memory struct for expected IRM values. Each field occupies a
    ///      full 0x20 slot in memory regardless of declared type.
    ///      Layout: 0x00 baseRatePerSecond | 0x20 vertexRatePerSecond
    ///              0x40 vertexStart | 0x60 increaseThresholdStart
    ///              0x80 decreaseThresholdEnd | 0xa0 adjustmentVelocity
    ///              0xc0 decayPerAdjustment | 0xe0 vertexMultiplierMax
    struct ExpectedIRM {
        uint256 baseRatePerSecond;
        uint256 vertexRatePerSecond;
        uint256 vertexStart;
        uint256 increaseThresholdStart;
        uint256 decreaseThresholdEnd;
        uint256 adjustmentVelocity;
        uint256 decayPerAdjustment;
        uint256 vertexMultiplierMax;
    }

    function setUp() public override {
        super.setUp();
    }

    /// @dev Reads ratesConfig() into struct via staticcall + assembly
    ///      to avoid stack-too-deep from 9-tuple destructuring.
    function _readRatesConfig(
        ExpectedIRM memory e,
        address target
    ) internal view {
        bytes4 selector = 0xf3129fac; // ratesConfig()
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, selector)

            // ratesConfig() takes no args, calldata = 4 bytes.
            // Return = 9 words (0x120), we read 8 (skip linkedToken).
            if iszero(staticcall(gas(), target, ptr, 0x04, ptr, 0x120)) {
                revert(0, 0)
            }

            mstore(add(e, 0x00), mload(ptr))
            mstore(add(e, 0x20), mload(add(ptr, 0x20)))
            mstore(add(e, 0x40), mload(add(ptr, 0x40)))
            mstore(add(e, 0x60), mload(add(ptr, 0x60)))
            mstore(add(e, 0x80), mload(add(ptr, 0x80)))
            mstore(add(e, 0xa0), mload(add(ptr, 0xa0)))
            mstore(add(e, 0xc0), mload(add(ptr, 0xc0)))
            mstore(add(e, 0xe0), mload(add(ptr, 0xe0)))
        }
    }

    /// @dev Deploys a local DynamicIRM with the constructor args and reads
    ///      back the stored ratesConfig (captures BPS->WAD transformations).
    function _deployAndReadConfig()
        internal
        returns (ExpectedIRM memory e)
    {
        (
            uint256 baseRatePerYear,
            uint256 vertexRatePerYear,
            uint256 vertexStart_,
            uint256 adjustmentVelocity_,
            uint256 decayPerAdjustment_,
            uint256 vertexMultiplierMax_
        ) = _irmConstructorArgs();

        DynamicIRM localIRM = new DynamicIRM(
            ICentralRegistry(address(centralRegistry)),
            baseRatePerYear,
            vertexRatePerYear,
            vertexStart_,
            adjustmentVelocity_,
            decayPerAdjustment_,
            vertexMultiplierMax_
        );

        _readRatesConfig(e, address(localIRM));
    }

    function _logIRM(string memory label, ExpectedIRM memory e) internal pure {
        console.log(label);
        console.log("baseRatePerSecond:     ", e.baseRatePerSecond);
        console.log("vertexRatePerSecond:   ", e.vertexRatePerSecond);
        console.log("vertexStart:           ", e.vertexStart);
        console.log("increaseThresholdStart:", e.increaseThresholdStart);
        console.log("decreaseThresholdEnd:  ", e.decreaseThresholdEnd);
        console.log("adjustmentVelocity:    ", e.adjustmentVelocity);
        console.log("decayPerAdjustment:    ", e.decayPerAdjustment);
        console.log("vertexMultiplierMax:   ", e.vertexMultiplierMax);
    }

    /// @dev Deploys locally and logs the stored ratesConfig values.
    function test_live_irm() public {
        ExpectedIRM memory e = _deployAndReadConfig();
        _logIRM("=== Stored IRM Config ===", e);
    }

    /// @dev Deploys locally, forks Monad mainnet, then asserts on-chain
    ///      IRM ratesConfig values match the locally deployed values.
    function test_validate_irm_on_chain() public {
        ExpectedIRM memory e = _deployAndReadConfig();

        // Fork to Monad mainnet.
        vm.createSelectFork(vm.envString("MON_NODE_URI_MONAD_MAINNET"));

        ExpectedIRM memory a = ExpectedIRM(0,0,0,0,0,0,0,0);
        _readRatesConfig(a, IRM_TO_TEST);

        console.log("=== IRM Config ===");
        console.log("baseRatePerSecond      expected:", e.baseRatePerSecond);
        console.log("baseRatePerSecond      actual:  ", a.baseRatePerSecond);
        console.log("vertexRatePerSecond    expected:", e.vertexRatePerSecond);
        console.log("vertexRatePerSecond    actual:  ", a.vertexRatePerSecond);
        console.log("vertexStart            expected:", e.vertexStart);
        console.log("vertexStart            actual:  ", a.vertexStart);
        console.log("increaseThresholdStart expected:", e.increaseThresholdStart);
        console.log("increaseThresholdStart actual:  ", a.increaseThresholdStart);
        console.log("decreaseThresholdEnd   expected:", e.decreaseThresholdEnd);
        console.log("decreaseThresholdEnd   actual:  ", a.decreaseThresholdEnd);
        console.log("adjustmentVelocity     expected:", e.adjustmentVelocity);
        console.log("adjustmentVelocity     actual:  ", a.adjustmentVelocity);
        console.log("decayPerAdjustment     expected:", e.decayPerAdjustment);
        console.log("decayPerAdjustment     actual:  ", a.decayPerAdjustment);
        console.log("vertexMultiplierMax    expected:", e.vertexMultiplierMax);
        console.log("vertexMultiplierMax    actual:  ", a.vertexMultiplierMax);

        assertEq(a.baseRatePerSecond, e.baseRatePerSecond, "baseRatePerSecond mismatch");
        assertEq(a.vertexRatePerSecond, e.vertexRatePerSecond, "vertexRatePerSecond mismatch");
        assertEq(a.vertexStart, e.vertexStart, "vertexStart mismatch");
        assertEq(a.increaseThresholdStart, e.increaseThresholdStart, "increaseThresholdStart mismatch");
        assertEq(a.decreaseThresholdEnd, e.decreaseThresholdEnd, "decreaseThresholdEnd mismatch");
        assertEq(a.adjustmentVelocity, e.adjustmentVelocity, "adjustmentVelocity mismatch");
        assertEq(a.decayPerAdjustment, e.decayPerAdjustment, "decayPerAdjustment mismatch");
        assertEq(a.vertexMultiplierMax, e.vertexMultiplierMax, "vertexMultiplierMax mismatch");
    }
}
