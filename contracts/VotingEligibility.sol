// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title Voting Eligibility
 * @author Curvance, based on ConvexVotingEligibility.sol
 * @notice Verifies account eligibility
 * @dev Deploy before SnapshotVotingStrategy
 */

contract VotingEligibility is Ownable {

    mapping(address => bool) public blockList;

    event AddBlocked(address indexed _account, bool _state);


    constructor() public {}


    /**
    *   @notice Prevent a specific account access to voting rights
    *   @notice Enable blacklisting by setUseBlock to True
    *   @param _account Account to blacklist
    *   @param _block Boolean; True == blacklisted, False == not blacklisted
    */
    function setAccountBlock(address _account, bool _block) external onlyOwner{
        blockList[_account] = _block;
        emit AddBlocked(_account, _block);
    }

    /**
    *   @notice Evaluates account voting eligibility
    *   @param _account Account attempting to vote
    *   @param _allowed Boolean; True == blacklisted, False == not blacklisted
    */
    function isEligible(address _account) external view returns(bool){

        if(blockList[_account]){
            return false;
        }

        return true;
    }
}