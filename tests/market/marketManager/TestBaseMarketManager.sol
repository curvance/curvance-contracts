// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";

contract TestBaseMarketManager is TestBaseMarket {
    MockDataFeed public mockWethFeed;
    MockDataFeed public mockRethFeed;

    function setUp() public virtual override {
        super.setUp();

        _prepareUSDC(address(this), _ONE);
        _prepareDAI(address(this), _ONE);
        _prepareBALRETH(address(this), _ONE);

        oracleManager.addMTokenSupport(address(eDAI));

        SafeTransferLib.safeApprove(_USDC_ADDRESS, address(eUSDC), _ONE);
        SafeTransferLib.safeApprove(_DAI_ADDRESS, address(eDAI), _ONE);
        SafeTransferLib.safeApprove(
            _BAL_WETH_RETH_ADDRESS,
            address(pBALRETH),
            _ONE
        );

        mockWethFeed = new MockDataFeed(_CHAINLINK_ETH_USD);
        chainlinkAdaptor.addAsset(
            _WETH_ADDRESS,
            address(mockWethFeed),
            0,
            true
        );
        dualChainlinkAdaptor.addAsset(
            _WETH_ADDRESS,
            address(mockWethFeed),
            0,
            true
        );
        mockRethFeed = new MockDataFeed(_CHAINLINK_ETH_USD);
        chainlinkAdaptor.addAsset(
            _RETH_ADDRESS,
            address(mockRethFeed),
            0,
            true
        );
        dualChainlinkAdaptor.addAsset(
            _RETH_ADDRESS,
            address(mockRethFeed),
            0,
            true
        );
    }
}
