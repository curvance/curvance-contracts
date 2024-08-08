// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";

contract TestBaseOracleRouter is TestBaseMarket {
    MockDataFeed public sequencer;

    function setUp() public virtual override {
        _fork(18031848);

        _deployCentralRegistry();
        _deployCVE();
        _deployRewardManager();
        _deployVeCVE();
        _deployOracleRouter();
        _deployGaugePool();
        _deployMarketManager();
        _deployDynamicInterestRateModel();
        _deployDUSDC();

        chainlinkAdaptor = chainlinkAdaptors[
            block.chainid
        ] = new ChainlinkAdaptor(ICentralRegistry(address(centralRegistry)));
        dualChainlinkAdaptor = dualChainlinkAdaptors[
            block.chainid
        ] = new ChainlinkAdaptor(ICentralRegistry(address(centralRegistry)));

        chainlinkAdaptor.addAsset(_ETH_ADDRESS, _CHAINLINK_ETH_USD, 0, true);
        dualChainlinkAdaptor.addAsset(
            _ETH_ADDRESS,
            _CHAINLINK_ETH_USD,
            0,
            true
        );
        chainlinkAdaptor.addAsset(_USDC_ADDRESS, _CHAINLINK_USDC_USD, 0, true);
        chainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            _CHAINLINK_USDC_ETH,
            0,
            false
        );
        dualChainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            _CHAINLINK_USDC_USD,
            0,
            true
        );
        dualChainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            _CHAINLINK_USDC_ETH,
            0,
            false
        );
    }

    function _deployCentralRegistry() internal override {
        sequencer = new MockDataFeed(address(0));
        sequencer.setMockStartedAt(block.timestamp - 3601);

        centralRegistry = centralRegistries[
            block.chainid
        ] = new CentralRegistry(
            _ZERO_ADDRESS,
            _ZERO_ADDRESS,
            _ZERO_ADDRESS,
            block.timestamp,
            address(sequencer),
            _USDC_ADDRESS
        );
        centralRegistry.transferEmergencyCouncil(address(this));
        centralRegistry.setSlippageLimit(6000);
    }
}
