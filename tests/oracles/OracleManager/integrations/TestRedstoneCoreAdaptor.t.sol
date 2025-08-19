// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { RedstoneCoreAdaptor } from "contracts/oracles/adaptors/redstone/RedstoneCoreAdaptor.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

import { MockRedstoneCoreAdaptor } from "contracts/mocks/MockRedstoneCoreAdaptor.sol";
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

    function test_fail_AddAsset__InvalidHeartbeat() public {
        // Should revert when heartbeat > DEFAULT_HEARTBEAT.
        uint256 invalidHeartbeat = adaptor.DEFAULT_HEARTBEAT() + 1;
        
        vm.expectRevert(RedstoneCoreAdaptor.RedstoneCoreAdaptor__InvalidConfiguration.selector);
        adaptor.addAsset(
            _WBTC_ADDRESS,
            true,
            8,
            invalidHeartbeat
        );
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
            "writePrice(address,bool,uint48)",
            _WBTC_ADDRESS,
            true,
            uint48(block.timestamp * 1000)
        );
        bytes memory encodedFunctionWithRedstonePayload = abi.encodePacked(
            encodedFunction,
            redstonePayload
        );

        // Update price with new signers
        (bool success, ) = address(adaptor).call(
            encodedFunctionWithRedstonePayload
        );
        assertTrue(success, "We expect that writing the price was successful from the constructed payload and 3 signers");

        oracleManager.addAssetPriceFeed(_WBTC_ADDRESS, address(adaptor));

        // Verify price was updated correctly
        (uint256 price, uint256 errorCode) = oracleManager.getPrice(
            _WBTC_ADDRESS,
            true,
            false
        );
        assertEq(errorCode, 0, "Should have had no error code returned when pricing via redstone core adaptor");
        assertEq(price, 61000e18, "We expect to get the 61k price back from the payload we built");
    }

    function test_fail_RemoveOldSignerBelowSignerThreshold() public {
        adaptor.removeSigner(redstoneSigners[0], false);
        
        vm.expectRevert(
            RedstoneCoreAdaptor.RedstoneCoreAdaptor__InvalidConfiguration
                .selector
        );
        
        adaptor.removeSigner(redstoneSigners[1], false);
    }

    function test_fail_RemoveOldSignerAndFailToUpdatePriceWithOldSignersKeys()
        public
    {
        bytes32[] memory fewerRedstoneSignerKeys = new bytes32[](3);
        fewerRedstoneSignerKeys[
            0
        ] = 0x56938289786ae24fdb687a2a740e755d6ed7e72a1f82f8f9c3ed6eac5b38ba23;
        fewerRedstoneSignerKeys[
            1
        ] = 0x4022f8e215d01e76d90987d7f56a09513fe76f97add10db250215bdbfab3e9c1;
        fewerRedstoneSignerKeys[
            2
        ] = 0x00b2ff109fc6421974dff44f7e2f95a0ebbba51acb43b6975b77615c6cba12b2;

        bytes memory redstonePayload = getRedstonePayload(
            "WBTC:61000:8",
            fewerRedstoneSignerKeys
        );

        bytes memory encodedFunction = abi.encodeWithSignature(
            "writePrice(address,bool,uint48)",
            _WBTC_ADDRESS,
            true,
            uint48(block.timestamp * 1000)
        );
        bytes memory encodedFunctionWithRedstonePayload = abi.encodePacked(
            encodedFunction,
            redstonePayload
        );

        adaptor.removeSigner(redstoneSigners[0], false);

        (bool success, ) = address(adaptor).call(
            encodedFunctionWithRedstonePayload
        );
        assertFalse(success, "Writing Price should have failed since only 2 of 3 signers are approved");
    }

    function test_success_ReturnsCorrectPrice() public {
        bytes memory redstonePayload = getRedstonePayload(
            "WBTC:60000:8",
            redstoneSignerKeys
        );

        (, , , , bytes32 symbolHash) = adaptor.assetConfig(_WBTC_ADDRESS, true);
        assertEq(symbolHash, bytes32("WBTC"));
        
        bytes memory encodedFunction = abi.encodeWithSignature(
            "writePrice(address,bool,uint48)",
            _WBTC_ADDRESS,
            true,
            uint48(block.timestamp * 1000)
        );
        bytes memory encodedFunctionWithRedstonePayload = abi.encodePacked(
            encodedFunction,
            redstonePayload
        );

        // Securely getting oracle value
        (bool success, ) = address(adaptor).call(
            encodedFunctionWithRedstonePayload
        );
        assertTrue(success, "We expect that writing the price was successful from the constructed payload and 3 signers");
        
        oracleManager.addAssetPriceFeed(_WBTC_ADDRESS, address(adaptor));

        (uint256 price, uint256 errorCode) = oracleManager.getPrice(
            _WBTC_ADDRESS,
            true,
            false
        );
        assertEq(errorCode, 0, "Should have had no error code returned when pricing via redstone core adaptor");
        assertEq(price, 60000e18, "We expect to get the 60k price back from the payload we built");
    }

    function testZeroHeartBeatRequiresPriceUpdateInEverySecond() public {
        adaptor.addAsset(_WETH_ADDRESS, true, 8, 0);

        bytes memory redstonePayload = getRedstonePayload(
            "WETH:3000:8",
            redstoneSignerKeys
        );

        (, , , , bytes32 symbolHash) = adaptor.assetConfig(_WETH_ADDRESS, true);
        assertEq(symbolHash, bytes32("WETH"));

        bytes memory encodedFunction = abi.encodeWithSignature(
            "writePrice(address,bool,uint48)",
            _WETH_ADDRESS,
            true,
            uint48(block.timestamp * 1000)
        );
        bytes memory encodedFunctionWithRedstonePayload = abi.encodePacked(
            encodedFunction,
            redstonePayload
        );

        // Securely getting oracle value
        (bool success, ) = address(adaptor).call(
            encodedFunctionWithRedstonePayload
        );
        assertTrue(success, "We expect that writing the price was successful from the constructed payload and 3 signers");

        oracleManager.addAssetPriceFeed(_WETH_ADDRESS, address(adaptor));

        (uint256 price, uint256 errorCode) = oracleManager.getPrice(
            _WETH_ADDRESS,
            true,
            false
        );
        assertEq(errorCode, 0, "Should have had no error code returned when pricing via redstone core adaptor");
        assertEq(price, 3000e18, "We expect to get the 3k price back from the payload we built");

        vm.warp(block.timestamp + 1);
        (price, errorCode) = oracleManager.getPrice(
            _WETH_ADDRESS,
            true,
            false
        );

        assertNotEq(errorCode, 0, "We expect an error message returned since the price feed should be stale now");
    }
}
