// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { Bytes32Helper } from "contracts/libraries/Bytes32Helper.sol";

import { IRedstone } from "contracts/interfaces/external/redstone/IRedstone.sol";

contract MockRedstoneClassicAdaptor is IRedstone {
    uint256 public constant version = 0;

    uint8 public override decimals;
    int256 public latestAnswer;
    uint256 public latestTimestamp;
    uint256 public latestRound = 1;
    string public id;

    mapping(uint256 => int256) public getAnswer;
    mapping(uint256 => uint256) public getTimestamp;
    mapping(uint256 => uint256) private getStartedAt;

    constructor(
        uint8 _decimals,
        int256 _initialAnswer,
        string memory _id
    ) {
        decimals = _decimals;
        updateAnswer(_initialAnswer);
        id = _id;
    }

    function getDataFeedId() external view returns (bytes32) {
        Bytes32Helper.toBytes32(id);
    }

    function updateAnswer(int256 _answer) public virtual {
        latestAnswer = _answer;
        latestTimestamp = block.timestamp;
        getAnswer[latestRound] = _answer;
        getTimestamp[latestRound] = block.timestamp;
        getStartedAt[latestRound] = block.timestamp;
    }

    function updateRoundData(
        int256 _answer,
        uint256 _timestamp,
        uint256 _startedAt
    ) public virtual {
        latestAnswer = _answer;
        latestTimestamp = _timestamp;
        getAnswer[latestRound] = _answer;
        getTimestamp[latestRound] = _timestamp;
        getStartedAt[latestRound] = _startedAt;
    }

    function latestRoundData()
        external
        view
        override
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        return (
            uint80(latestRound),
            getAnswer[latestRound],
            getStartedAt[latestRound],
            getTimestamp[latestRound],
            uint80(latestRound)
        );
    }
}
