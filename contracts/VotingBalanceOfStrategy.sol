// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import "./interfaces/IVoteEscrow.sol";
import "./interfaces/IVotingEligibility.sol";

/**
 * @title Vote Balances
 * @author Curvance & based on Convex VotingBalanceMax.sol, VotingEligibility.sol
 * @notice Verifies account eligibility & returns balance of votes
 * @dev Requires CveLocker address deployed prior to this
 */

contract SnapshotVotingStrategy {

    address public constant locker = address(***INSERT ADDRESS OF VOTE_ESCROW.SOL HERE***);
    address public constant eligibleList = address(***INSERT ADDRESS OF VOTING_ELIGIBILITY.SOL HERE***)


    /**
    *   @notice Obtain vote balances of eligible accounts
    *   @param _account Voting account
    *   @param returns Pending vote balances
    */
    function balanceOf(address _account) external view returns(uint256){

        //check eligibility
        if(!IVotingEligibility(eligiblelist).isEligible(_account)){
            return 0;
        }

        // Call balanceOf from VoteEscrow account
        uint256 public memory accountBalance = IVoteEscrow(locker).balanceOf(_account);
        
        return accountBalance;
    }

    /**
    *   @notice Obtain balance of all eligible votes
    *   @param returns Total vote count
    */
    function totalVotes() view external returns(uint256){

        uint256 public memory totalVoteBalance = IVoteEscrow(locker).lockedSupply();
        
        return totalVoteBalance;
    }
}