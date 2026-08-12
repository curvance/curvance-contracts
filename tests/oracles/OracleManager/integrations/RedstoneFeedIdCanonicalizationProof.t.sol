// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {
    TestBaseOracleManager
} from "tests/oracles/OracleManager/TestBaseOracleManager.sol";
import {
    RedstoneClassicAdaptor
} from "contracts/oracles/adaptors/redstone/RedstoneClassicAdaptor.sol";
import {
    BaseOracleAdaptor
} from "contracts/oracles/adaptors/BaseOracleAdaptor.sol";
import {Bytes32Helper} from "contracts/libraries/Bytes32Helper.sol";
import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";
import {IRedstone} from "contracts/interfaces/external/redstone/IRedstone.sol";
import {
    MockRedstoneClassicFeed
} from "contracts/mocks/MockRedstoneClassicFeed.sol";

contract Bytes32HelperInspectionHarness {
    function inspectDirtyWord(bytes32 word, uint256 length)
        external
        pure
        returns (bytes32 rawWord, bytes32 canonical)
    {
        string memory value = new string(length);
        assembly {
            mstore(add(value, 32), word)
            rawWord := mload(add(value, 32))
        }
        canonical = Bytes32Helper.toBytes32(value);
    }

    function inspect(string memory value)
        external
        pure
        returns (bytes32 rawWord, bytes32 canonical)
    {
        assembly {
            rawWord := mload(add(value, 32))
        }
        canonical = Bytes32Helper.toBytes32(value);
    }
}

contract RedstoneFeedIdCanonicalizationProof is TestBaseOracleManager {
    address internal constant ASSET = address(0xBEEF);
    address internal constant OTHER_ASSET = address(0xCAFE);

    Bytes32HelperInspectionHarness internal helper;
    RedstoneClassicAdaptor internal redstone;
    MockRedstoneClassicFeed internal feed;

    function setUp() public override {
        super.setUp();

        helper = new Bytes32HelperInspectionHarness();
        redstone = new RedstoneClassicAdaptor(
            ICentralRegistry(address(centralRegistry))
        );
        feed = new MockRedstoneClassicFeed(8, 1e8, "GOOD");
    }

    function test_shortIdsMaskDirtyTrailingMemory() public view {
        for (uint256 length = 1; length < 32; ++length) {
            bytes32 seed = keccak256(abi.encodePacked(length));
            uint256 mask = type(uint256).max << ((32 - length) * 8);
            bytes32 expected = bytes32(uint256(seed) & mask);
            bytes32 dirtyWord = bytes32(uint256(expected) | ~mask);

            (bytes32 observedRaw, bytes32 canonical) =
                helper.inspectDirtyWord(dirtyWord, length);
            assertEq(observedRaw, dirtyWord);
            assertEq(canonical, expected);
        }

        (, bytes32 emptyCanonical) = helper.inspect("");
        assertEq(emptyCanonical, bytes32(0));
    }

    function test_fullLengthIsExactAndExcessiveLengthReverts() public {
        bytes32 fullLength =
            0x0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef;
        (, bytes32 canonical) =
            helper.inspect(string(abi.encodePacked(fullLength)));
        assertEq(canonical, fullLength);

        vm.expectRevert(Bytes32Helper.Bytes32Helper__ExcessiveLength.selector);
        helper.inspect(new string(33));
    }

    function test_classicAdmissionUsesCanonicalIdAndMismatchWritesNothing()
        public
    {
        bytes32 expected = bytes32("GOOD");
        uint256 mask = type(uint256).max << (28 * 8);
        bytes32 dirtyWord = bytes32(uint256(expected) | ~mask);
        bytes memory payload = abi.encodePacked(
            RedstoneClassicAdaptor.addAsset.selector,
            bytes32(uint256(uint160(ASSET))),
            bytes32(uint256(1)),
            bytes32(uint256(uint160(address(feed)))),
            bytes32(uint256(0)),
            bytes32(uint256(160)),
            bytes32(uint256(4)),
            dirtyWord
        );

        (bool success,) = address(redstone).call(payload);
        assertTrue(success);
        assertTrue(redstone.isSupportedAsset(ASSET));

        (bool isConfigured, IRedstone storedFeed,,) =
            redstone.assetConfig(ASSET, true);
        assertTrue(isConfigured);
        assertEq(address(storedFeed), address(feed));

        vm.expectRevert(
            BaseOracleAdaptor.BaseOracleAdaptor__InvalidConfig.selector
        );
        redstone.addAsset(OTHER_ASSET, true, address(feed), 0, "DIFFERENT");

        assertFalse(redstone.isSupportedAsset(OTHER_ASSET));
        (isConfigured, storedFeed,,) = redstone.assetConfig(OTHER_ASSET, true);
        assertFalse(isConfigured);
        assertEq(address(storedFeed), address(0));
    }
}
