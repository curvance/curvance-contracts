// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseOracleManager } from "../TestBaseOracleManager.sol";
import { WstETHAggregator } from "contracts/oracles/adaptors/wrappedAggregators/WstETHAggregator.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { console2 } from "forge-std/console2.sol";

contract TestWstETHAdaptor is TestBaseOracleManager {
    address internal _WSTETH_ADDRESS =
        0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    WstETHAggregator public aggregator;

    function setUp() public override {
        _fork(18031848);
        console2.log("Forked to block 18031848");
        
        console2.log("Deployed DAO Timelock");
        _deployCentralRegistry();
        console2.log("Deployed Central Registry");
        _deployOracleManager();
        console2.log("Deployed Oracle Manager");

        aggregator = new WstETHAggregator(
            _WSTETH_ADDRESS,
            _STETH_ADDRESS,
            _CHAINLINK_ETH_USD
        );
        console2.log("Deployed WstETH Aggregator");
    }

    function testReturnsCorrectPrice() public {
        chainlinkAdaptor = new ChainlinkAdaptor(
            ICentralRegistry(address(centralRegistry))
        );
        chainlinkAdaptor.addAsset(_ETH_ADDRESS, _CHAINLINK_ETH_USD, 0, true);
        chainlinkAdaptor.addAsset(_STETH_ADDRESS, _CHAINLINK_ETH_USD, 0, true);
        chainlinkAdaptor.addAsset(
            _WSTETH_ADDRESS,
            address(aggregator),
            0,
            true
        );
        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));
        oracleManager.addAssetPriceFeed(
            _ETH_ADDRESS,
            address(chainlinkAdaptor)
        );
        oracleManager.addAssetPriceFeed(
            _STETH_ADDRESS,
            address(chainlinkAdaptor)
        );
        oracleManager.addAssetPriceFeed(
            _WSTETH_ADDRESS,
            address(chainlinkAdaptor)
        );

        (uint256 price, uint256 errorCode) = oracleManager.getPrice(
            _WSTETH_ADDRESS,
            true,
            false
        );
        assertEq(errorCode, 0);
        assertGt(price, 0);
    }
}
