// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import { TestBaseProtocolMessagingHub } from "../TestBaseProtocolMessagingHub.sol";
import { ProtocolMessagingHub } from "contracts/architecture/ProtocolMessagingHub.sol";
import { QueryTest } from "tests/utils/QueryTest.sol";
import { WormholeMock } from "tests/utils/WormholeMock.sol";
import { IWormhole } from "contracts/interfaces/external/wormhole/IWormhole.sol";

contract ExecuteEpochTest is TestBaseProtocolMessagingHub {
    uint8 public version = 0x01;
    uint16 public senderChainId = 0x0000;
    bytes public signature =
        hex"ff0c222dc9e3655ec38e212e9792bf1860356d1277462b6bf747db865caca6fc08e6317b64ee3245264e371146b1d315d38c867fe1f69614368dc4430bb560f200";
    uint8 public queryRequestVersion = 0x01;
    uint32 public queryRequestNonce = 0xdd9914c6;
    uint8 public numPerChainQueries = 0x01;
    uint8 public numPerChainResponses = 0x01;
    uint8 public sigGuardianIndex = 0;
    bytes public response;
    IWormhole.Signature[] public signatures;
    uint256 public constant DEVNET_GUARDIAN_PRIVATE_KEY =
        0xcfb12303a19cde580bb4dd771639b0d26bc68353645571a8cff516ab2ee113a0;

    function setUp() public override {
        _fork(19140000);

        WormholeMock wormholeMock = new WormholeMock();
        _WORMHOLE_CORE = address(wormholeMock);

        _init();

        centralRegistry.addChainSupport(
            address(this),
            address(protocolMessagingHub),
            address(cve),
            _USDC_ADDRESS,
            42161,
            1,
            1,
            23
        );
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = 42161;
        centralRegistry.updateForeignChainIds(chainIds);

        skip(cveLocker.EPOCH_DURATION() * 2);
    }

    function test_executeEpoch_fail_whenCurrentEpochIsEarlierThanNextEpochToDeliver()
        public
    {
        vm.warp(block.timestamp - cveLocker.EPOCH_DURATION() * 2);

        _prepareResponseAndSignatures(
            abi.encode(1e6),
            block.number,
            uint64(block.timestamp * 1000000),
            23,
            address(protocolMessagingHub),
            abi.encodeWithSignature("queryLockPoints()")
        );

        vm.expectRevert();
        protocolMessagingHub.executeEpoch(response, signatures, 250_000);
    }

    function test_executeEpoch_fail_whenResultIsNotNumber() public {
        _prepareResponseAndSignatures(
            abi.encode("wrong"),
            block.number,
            uint64(block.timestamp * 1000000),
            23,
            address(protocolMessagingHub),
            abi.encodeWithSignature("queryLockPoints()")
        );

        vm.expectRevert(
            ProtocolMessagingHub
                .ProtocolMessagingHub__InvalidParameter
                .selector
        );
        protocolMessagingHub.executeEpoch(response, signatures, 250_000);
    }

    function test_executeEpoch_fail_whenBlockTimeIsStale() public {
        _prepareResponseAndSignatures(
            abi.encode(1e6),
            block.number,
            uint64((block.timestamp - 1000) * 1000000),
            23,
            address(protocolMessagingHub),
            abi.encodeWithSignature("queryLockPoints()")
        );

        vm.expectRevert(bytes4(keccak256("StaleBlockTime()")));
        protocolMessagingHub.executeEpoch(response, signatures, 250_000);
    }

    function test_executeEpoch_fail_whenChainIdIsInvalid() public {
        _prepareResponseAndSignatures(
            abi.encode(1e6),
            block.number,
            uint64(block.timestamp * 1000000),
            24,
            address(protocolMessagingHub),
            abi.encodeWithSignature("queryLockPoints()")
        );

        vm.expectRevert(
            ProtocolMessagingHub
                .ProtocolMessagingHub__InvalidParameter
                .selector
        );
        protocolMessagingHub.executeEpoch(response, signatures, 250_000);
    }

    function test_executeEpoch_fail_whenToAddressIsInvalid() public {
        _prepareResponseAndSignatures(
            abi.encode(1e6),
            block.number,
            uint64(block.timestamp * 1000000),
            23,
            address(1),
            abi.encodeWithSignature("queryLockPoints()")
        );

        vm.expectRevert(bytes4(keccak256("InvalidContractAddress()")));
        protocolMessagingHub.executeEpoch(response, signatures, 250_000);
    }

    function test_executeEpoch_fail_whenCallDataIsInvalid() public {
        _prepareResponseAndSignatures(
            abi.encode(1e6),
            block.number,
            uint64(block.timestamp * 1000000),
            23,
            address(protocolMessagingHub),
            abi.encodeWithSignature("wrong()")
        );

        vm.expectRevert(bytes4(keccak256("InvalidFunctionSignature()")));
        protocolMessagingHub.executeEpoch(response, signatures, 250_000);
    }

    function test_executeEpoch_success() public {
        _prepareResponseAndSignatures(
            abi.encode(1e6),
            block.number,
            uint64(block.timestamp * 1000000),
            23,
            address(protocolMessagingHub),
            abi.encodeWithSignature("queryLockPoints()")
        );

        deal(address(protocolMessagingHub), _ONE);
        deal(_USDC_ADDRESS, address(feeAccumulator), 100e6);

        assertEq(usdc.balanceOf(address(protocolMessagingHub)), 0);
        assertEq(usdc.balanceOf(address(feeAccumulator)), 100e6);

        protocolMessagingHub.executeEpoch(response, signatures, 250_000);

        assertEq(usdc.balanceOf(address(protocolMessagingHub)), 0);
        assertEq(usdc.balanceOf(address(feeAccumulator)), 100e6 - 12.5e6);
    }

    function _prepareResponseAndSignatures(
        bytes memory result,
        uint256 blockNumber,
        uint64 timestamp,
        uint256 chainId,
        address to,
        bytes memory callData
    ) internal {
        bytes memory resultsBytes = QueryTest.buildEthCallResultBytes(result);
        bytes memory reponseBytes = QueryTest.buildEthCallResponseBytes(
            uint64(blockNumber),
            bytes32(blockhash(blockNumber)),
            timestamp,
            1,
            resultsBytes
        );
        bytes memory perChainResponses = QueryTest.buildPerChainResponseBytes(
            uint16(chainId),
            1,
            reponseBytes
        );

        bytes memory dataBytes = QueryTest.buildEthCallDataBytes(to, callData);
        bytes memory requestBytes = QueryTest.buildEthCallRequestBytes(
            abi.encode(blockNumber),
            1,
            dataBytes
        );
        bytes memory perChainQueries = QueryTest.buildPerChainRequestBytes(
            uint16(chainId),
            1,
            requestBytes
        );

        response = _concatenateQueryResponseBytesOffChain(
            version,
            senderChainId,
            signature,
            queryRequestVersion,
            queryRequestNonce,
            numPerChainQueries,
            perChainQueries,
            numPerChainResponses,
            perChainResponses
        );

        bytes32 responseDigest = protocolMessagingHub.getResponseDigest(
            response
        );
        (uint8 sigV, bytes32 sigR, bytes32 sigS) = vm.sign(
            DEVNET_GUARDIAN_PRIVATE_KEY,
            responseDigest
        );

        signatures.push(
            IWormhole.Signature({
                r: sigR,
                s: sigS,
                v: sigV,
                guardianIndex: sigGuardianIndex
            })
        );
    }

    function _concatenateQueryResponseBytesOffChain(
        uint8 _version,
        uint16 _senderChainId,
        bytes memory _signature,
        uint8 _queryRequestVersion,
        uint32 _queryRequestNonce,
        uint8 _numPerChainQueries,
        bytes memory _perChainQueries,
        uint8 _numPerChainResponses,
        bytes memory _perChainResponses
    ) internal pure returns (bytes memory) {
        bytes memory queryRequest = QueryTest.buildOffChainQueryRequestBytes(
            _queryRequestVersion,
            _queryRequestNonce,
            _numPerChainQueries,
            _perChainQueries
        );
        return
            QueryTest.buildQueryResponseBytes(
                _version,
                _senderChainId,
                _signature,
                queryRequest,
                _numPerChainResponses,
                _perChainResponses
            );
    }
}
