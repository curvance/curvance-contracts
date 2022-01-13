// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "./MerkleAirdrop.sol";
import "@openzeppelin/contracts/utils/Address.sol";

contract MerkleAirdropFactory {
    using Address for address;

    address public airdrop;

    event Created(address indexed drop);

    function CreateMerkleAirdrop(
        address _token,
        uint256 _startTime,
        uint256 _endTime,
        bytes32 _merkleRoot
    ) external returns (address) {
        MerkleAirdrop drop = new MerkleAirdrop(msg.sender, _token, _startTime, _endTime, _merkleRoot);
        emit Created(address(drop));
        airdrop = address(drop);
        return address(drop);
    }
}
