// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseFeeAccumulator } from "../TestBaseFeeAccumulator.sol";
import { FeeAccumulator } from "contracts/architecture/FeeAccumulator.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract FeeAccumulatorDeploymentTest is TestBaseFeeAccumulator {
    function test_feeAccumulatorDeployment_fail_whenCentralRegistryIsInvalid()
        public
    {
        vm.expectRevert(
            FeeAccumulator.FeeAccumulator__InvalidCentralRegistry.selector
        );
        new FeeAccumulator(ICentralRegistry(address(0)));
    }

    function test_feeAccumulatorDeployment_success() public {
        feeAccumulator = new FeeAccumulator(
            ICentralRegistry(address(centralRegistry))
        );

        assertEq(
            address(feeAccumulator.centralRegistry()),
            address(centralRegistry)
        );
        assertEq(
            address(feeAccumulator.getOracleRouter()),
            centralRegistry.oracleRouter()
        );
        assertEq(feeAccumulator.feeToken(), _USDC_ADDRESS);
        assertEq(
            feeAccumulator.vaultCompoundFee(),
            centralRegistry.protocolCompoundFee()
        );
        assertEq(
            feeAccumulator.vaultHarvestFee(),
            centralRegistry.protocolYieldFee() +
                centralRegistry.protocolCompoundFee()
        );
    }
}
