// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./MerkleAirdrop.sol";

interface IMerkleAirdrop {
    function rescueToken(address _token, address _recipient) external;

    function setClaimEndTimestamp(uint256 _endTime) external;

    function init(
        address _token,
        uint256 _startTime,
        uint256 _endTime,
        bytes32 _merkleRoot
    ) external;
}

contract MerkleAirdropManager is Ownable {
    address public airdropImplementation;

    mapping(address => bool) public instances;

    event Cloned(address instance);

    constructor(address _airdropImplementation) {
        airdropImplementation = _airdropImplementation;
    }

    /**
     * @dev rescue any token sent by mistake to the airdrop contract
     * @param _instance address of airdrop contract
     * @param _token address of token to rescue
     * @param _recipient address to receive token
     */
    function rescueToken(
        address _instance,
        address _token,
        address _recipient
    ) external onlyOwner {
        require(instances[_instance], "!instance");
        IMerkleAirdrop(_instance).rescueToken(_token, _recipient);
    }

    /**
     * @dev rescue any token sent by mistake
     * @param _instance address of airdrop contract
     * @param _endTime time to end airdrop claim
     */
    function setClaimEndTimestamp(address _instance, uint256 _endTime) external onlyOwner {
        require(instances[_instance], "!instance");
        IMerkleAirdrop(_instance).setClaimEndTimestamp(_endTime);
    }

    /**
     * @dev rescue any token sent by mistake
     * @param _token address of airdrop token
     * @param _startTime time to start airdrop claim
     * @param _endTime time to end airdrop claim
     * @param _merkleRoot troot of merkle tree implementation
     */
    function cloneAndInit(
        address _token,
        uint256 _startTime,
        uint256 _endTime,
        bytes32 _merkleRoot
    ) external onlyOwner returns (address) {
        address instance = Clones.clone(airdropImplementation);
        IMerkleAirdrop(instance).init(_token, _startTime, _endTime, _merkleRoot);
        instances[instance] = true;
        emit Cloned(instance);
        return instance;
    }
}
