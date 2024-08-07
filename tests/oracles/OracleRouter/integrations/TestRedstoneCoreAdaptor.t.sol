// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { MockEthereumRedstoneCoreAdaptor } from "contracts/mocks/MockEthereumRedstoneCoreAdaptor.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { OracleRouter } from "contracts/oracles/OracleRouter.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { TestBaseOracleRouter } from "../TestBaseOracleRouter.sol";

contract TestRedstoneCoreAdaptor is TestBaseOracleRouter {
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
        _deployOracleRouter();

        chainlinkAdaptor = new ChainlinkAdaptor(
            ICentralRegistry(address(centralRegistry))
        );

        adapter = new MockEthereumRedstoneCoreAdaptor(
            ICentralRegistry(address(centralRegistry))
        );
        adapter.addAsset(_WBTC_ADDRESS, true, 8, 12 hours);
        adapter.addAsset(_WBTC_ADDRESS, false, 18, 12 hours);

        oracleRouter.addApprovedAdaptor(address(chainlinkAdaptor));

        oracleRouter.addApprovedAdaptor(address(adapter));
    }

    function testReturnsCorrectPrice() public {
        bytes memory redstonePayload = getRedstonePayload("WBTC:60000:8");

        (, bytes32 symbolHash, , , ) = adapter.adaptorDataUSD(_WBTC_ADDRESS);
        assertEq(symbolHash, bytes32("WBTC"));
        bytes memory encodedFunction = abi.encodeWithSignature(
            "writePrice(address,bool)",
            _WBTC_ADDRESS,
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

        oracleRouter.addAssetPriceFeed(_WBTC_ADDRESS, address(adapter));

        (uint256 price, uint256 errorCode) = oracleRouter.getPrice(
            _WBTC_ADDRESS,
            true,
            false
        );
        assertEq(errorCode, 0);
        assertEq(price, 60000e18);
    }
}
