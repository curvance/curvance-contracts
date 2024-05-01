// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { QueryTest } from "tests/utils/QueryTest.sol";
import { IWormhole } from "contracts/interfaces/external/wormhole/IWormhole.sol";

contract TestBaseProtocolMessagingHub is TestBaseMarket {
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

    function setUp() public virtual override {
        _fork(19140000);

        _init();
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
