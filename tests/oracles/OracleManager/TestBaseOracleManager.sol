// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";

import { console2 } from "forge-std/console2.sol";

contract TestBaseOracleManager is TestBaseMarketIsolated {
    MockDataFeed public sequencer;

    function setUp() public virtual override {
        _fork(18031848);
        
        _deployCentralRegistry();
        _deployDAOTimelock();
        _deployCVE();
        _deployRewardManager();
        _deployVeCVE();
        _deployOracleManager();
        _deployGaugeManager();
        _deployMarketManager();
        _deployBorrowableCUSDC();

        chainlinkAdaptor = chainlinkAdaptors[
            block.chainid
        ] = new ChainlinkAdaptor(ICentralRegistry(
            address(centralRegistry))
        );
        dualChainlinkAdaptor = dualChainlinkAdaptors[
            block.chainid
        ] = new ChainlinkAdaptor(ICentralRegistry(
            address(centralRegistry))
        );

        chainlinkAdaptor.addAsset(
            _ETH_ADDRESS,
            true,
            _CHAINLINK_ETH_USD,
            0
        );
        dualChainlinkAdaptor.addAsset(
            _ETH_ADDRESS,
            true,
            _CHAINLINK_ETH_USD,
            0
        );
        chainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            true,
            _CHAINLINK_USDC_USD,
            0
        );
        chainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            false,
            _CHAINLINK_USDC_ETH,
            0
        );
        dualChainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            true,
            _CHAINLINK_USDC_USD,
            0
        );
        dualChainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            false,
            _CHAINLINK_USDC_ETH,
            0
        );

        vm.warp(centralRegistry.genesisEpoch());
    }

    function _deployCentralRegistry() internal override {
        sequencer = new MockDataFeed(address(0));
        sequencer.setMockStartedAt(block.timestamp - 3601);

        centralRegistry = centralRegistries[
            block.chainid
        ] = new CentralRegistry(
            _ZERO_ADDRESS,
            _ZERO_ADDRESS,
            block.timestamp + 1,
            address(sequencer),
            _USDC_ADDRESS
        );
        centralRegistry.transferEmergencyCouncil(address(this));
        centralRegistry.setSlippageLimit(6000);
    }
}
