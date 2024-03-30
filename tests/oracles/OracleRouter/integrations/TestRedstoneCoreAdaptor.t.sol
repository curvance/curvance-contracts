// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import { EthereumRedstoneCoreAdaptor } from "contracts/oracles/adaptors/redstone/EthereumRedstoneCoreAdaptor.sol";
import { MockEthereumRedstoneCoreAdaptor } from "contracts/mocks/MockEthereumRedstoneCoreAdaptor.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { OracleRouter } from "contracts/oracles/OracleRouter.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { TestBaseOracleRouter } from "../TestBaseOracleRouter.sol";

contract TestRedstoneCoreAdaptor is TestBaseOracleRouter {
    address private WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address private USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    MockEthereumRedstoneCoreAdaptor public adapter;

    function getRedstonePayload(
        // dataFeedId:value:decimals
        string memory priceFeed
    ) public returns (bytes memory) {
        string[] memory args = new string[](3);
        args[0] = "node";
        args[1] = "getRedstonePayload.js";
        args[2] = priceFeed;

        return vm.ffi(args);
    }

    function setUp() public override {
        _fork(18031848);

        _deployCentralRegistry();
        chainlinkAdaptor = new ChainlinkAdaptor(
            ICentralRegistry(address(centralRegistry))
        );

        oracleRouter = new OracleRouter(
            ICentralRegistry(address(centralRegistry))
        );
        centralRegistry.setOracleRouter(address(oracleRouter));

        adapter = new MockEthereumRedstoneCoreAdaptor(
            ICentralRegistry(address(centralRegistry))
        );
        adapter.addAsset(WBTC, true, 8, 12 hours);
        adapter.addAsset(WBTC, false, 18, 12 hours);

        oracleRouter.addApprovedAdaptor(address(chainlinkAdaptor));

        oracleRouter.addApprovedAdaptor(address(adapter));
    }

    function testReturnsCorrectPrice() public {
        bytes memory redstonePayload = getRedstonePayload("WBTC:60000:8");

        (
            bool isConfigured,
            bytes32 symbolHash,
            uint256 max,
            uint256 decimals,
            uint256 heartbeat
        ) = adapter.adaptorDataUSD(WBTC);
        assertEq(symbolHash, bytes32("WBTC"));
        bytes memory encodedFunction = abi.encodeWithSignature(
            "writePrice(address,bool)",
            WBTC,
            true
        );
        bytes memory encodedFunctionWithRedstonePayload = abi.encodePacked(
            encodedFunction,
            redstonePayload
        );

        // Securely getting oracle value
        (bool success, ) = address(adapter).call(
            encodedFunctionWithRedstonePayload
        );
        assertEq(success, true);

        oracleRouter.addAssetPriceFeed(WBTC, address(adapter));

        (uint256 price, uint256 errorCode) = oracleRouter.getPrice(
            WBTC,
            true,
            false
        );
        assertEq(errorCode, 0);
        assertEq(price, 60000e18);
    }
}
