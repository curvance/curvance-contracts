// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { MockRedstoneCoreAdaptor } from "contracts/mocks/MockRedstoneCoreAdaptor.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { TestBaseOracleManager } from "../TestBaseOracleManager.sol";

contract TestRedstoneCoreAdaptor is TestBaseOracleManager {
    MockRedstoneCoreAdaptor public adaptor;

    function getRedstonePayload(
        // dataFeedId:value:decimals
        string memory priceFeed,
        bytes32[] memory redstoneSignerKeys
    ) public returns (bytes memory) {
        uint256 privateKeysLength = redstoneSignerKeys.length;
        string[] memory args = new string[](4 + privateKeysLength);
        args[0] = "node";
        args[1] = "getRedstonePayload.js";
        args[2] = priceFeed;
        args[3] = vm.toString(privateKeysLength);
        for (uint256 i = 0; i < privateKeysLength; i++) {
            args[4 + i] = vm.toString(redstoneSignerKeys[i]);
        }

        return vm.ffi(args);
    }

    function setUp() public override {
        _fork(18031848);

        
        _deployCentralRegistry();
        _deployOracleManager();
        _setRedstoneSigners();

        chainlinkAdaptor = new ChainlinkAdaptor(
            ICentralRegistry(address(centralRegistry))
        );

        adaptor = new MockRedstoneCoreAdaptor(
            ICentralRegistry(address(centralRegistry)),
            redstoneSigners,
            3,
            "ETH"
        );
        adaptor.addAsset(_WBTC_ADDRESS, true, 8, 10 minutes);
        adaptor.addAsset(_WBTC_ADDRESS, false, 18, 10 minutes);

        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));

        oracleManager.addApprovedAdaptor(address(adaptor));
    }

    function testReturnsCorrectPrice() public {
        bytes memory redstonePayload = getRedstonePayload(
            "WBTC:60000:8",
            redstoneSignerKeys
        );

        (, bytes32 symbolHash, , , ) = adaptor.adaptorData(_WBTC_ADDRESS, true);
        assertEq(symbolHash, bytes32("WBTC"));
        
        bytes memory encodedFunction = abi.encodeWithSignature(
            "writePrice(address,bool,uint128)",
            _WBTC_ADDRESS,
            true,
            uint128(block.timestamp * 1000)
        );
        bytes memory encodedFunctionWithRedstonePayload = abi.encodePacked(
            encodedFunction,
            redstonePayload
        );

        // Securely getting oracle value
        (bool success, ) = address(adaptor).call(
            encodedFunctionWithRedstonePayload
        );
        assertTrue(success);
        
        oracleManager.addAssetPriceFeed(_WBTC_ADDRESS, address(adaptor));

        (uint256 price, uint256 errorCode) = oracleManager.getPrice(
            _WBTC_ADDRESS,
            true,
            false
        );
        assertEq(errorCode, 0);
        assertEq(price, 60000e18);
    }

    function testZeroHeartBeatRequiresPriceUpdateInEverySecond() public {
        adaptor.addAsset(_WETH_ADDRESS, true, 8, 0);

        bytes memory redstonePayload = getRedstonePayload(
            "WETH:3000:8",
            redstoneSignerKeys
        );

        (, bytes32 symbolHash, , , ) = adaptor.adaptorData(_WETH_ADDRESS, true);
        assertEq(symbolHash, bytes32("WETH"));
        bytes memory encodedFunction = abi.encodeWithSignature(
            "writePrice(address,bool,uint128)",
            _WETH_ADDRESS,
            true,
            uint128(block.timestamp * 1000)
        );
        bytes memory encodedFunctionWithRedstonePayload = abi.encodePacked(
            encodedFunction,
            redstonePayload
        );

        // Securely getting oracle value
        (bool success, ) = address(adaptor).call(
            encodedFunctionWithRedstonePayload
        );
        assertTrue(success);

        oracleManager.addAssetPriceFeed(_WETH_ADDRESS, address(adaptor));

        (uint256 price, uint256 errorCode) = oracleManager.getPrice(
            _WETH_ADDRESS,
            true,
            false
        );
        assertEq(errorCode, 0);
        assertEq(price, 3000e18);

        vm.warp(block.timestamp + 1);
        (price, errorCode) = oracleManager.getPrice(
            _WETH_ADDRESS,
            true,
            false
        );
        assertNotEq(errorCode, 0);
    }

    function testAddNewSignersUpdatePriceWithNewSigners() public {
        address[] memory newSigners = new address[](3);
        bytes32[] memory newSignerKeys = new bytes32[](3);

        // Private keys (randomly generated)
        newSignerKeys[
            0
        ] = 0x98fe1d834ed6a59e53f16b92d57f76bc764bc6179a97fb6d1c0f57e2c6498bc6;
        newSignerKeys[
            1
        ] = 0x2c5b761dbc30b7cf827b9d12d057550e8a07fe6da7dff5f2385562f6165a8748;
        newSignerKeys[
            2
        ] = 0x91198cc0ab98d7832d653bf079615e8849fcb17c4b55d2e858ef13df35295742;

        // Corresponding addresses (derived from private keys)
        newSigners[0] = 0x55dfD892609471ccf030E830F127F3fe0f485C60;
        newSigners[1] = 0xb8b84E31308a9B64bE64ee061Df99a0DaBfb6f4D;
        newSigners[2] = 0x017f6D0d1DC16cb59Fa374D2716bf5D2A83c2b08;

        // Add new signers to the adaptor
        adaptor.addSigner(newSigners[0], false);
        adaptor.addSigner(newSigners[1], false);
        adaptor.addSigner(newSigners[2], false);

        // Test price update with new signers
        bytes memory redstonePayload = getRedstonePayload(
            "WBTC:61000:8",
            newSignerKeys
        );

        bytes memory encodedFunction = abi.encodeWithSignature(
            "writePrice(address,bool,uint128)",
            _WBTC_ADDRESS,
            true,
            uint128(block.timestamp * 1000)
        );
        bytes memory encodedFunctionWithRedstonePayload = abi.encodePacked(
            encodedFunction,
            redstonePayload
        );

        // Update price with new signers
        (bool success, ) = address(adaptor).call(
            encodedFunctionWithRedstonePayload
        );
        assertTrue(success);

        oracleManager.addAssetPriceFeed(_WBTC_ADDRESS, address(adaptor));

        // Verify price was updated correctly
        (uint256 price, uint256 errorCode) = oracleManager.getPrice(
            _WBTC_ADDRESS,
            true,
            false
        );
        assertEq(errorCode, 0);
        assertEq(price, 61000e18);
    }

    function testRemoveOldSignerAndFailToUpdatePriceWithOldSignersKeys()
        public
    {
        testAddNewSignersUpdatePriceWithNewSigners();

        adaptor.removeSigner(redstoneSigners[0], false);

        bytes memory redstonePayload = getRedstonePayload(
            "WBTC:61000:8",
            redstoneSignerKeys
        );

        bytes memory encodedFunction = abi.encodeWithSignature(
            "writePrice(address,bool,uint128)",
            _WBTC_ADDRESS,
            true,
            uint128(block.timestamp * 1000)
        );
        bytes memory encodedFunctionWithRedstonePayload = abi.encodePacked(
            encodedFunction,
            redstonePayload
        );

        (bool success, ) = address(adaptor).call(
            encodedFunctionWithRedstonePayload
        );
        assertFalse(success);
    }
}
