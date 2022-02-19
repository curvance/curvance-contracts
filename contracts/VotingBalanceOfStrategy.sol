// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "./interfaces/IVoteEscrow.sol";
import "./interfaces/IVotingEligibility.sol";

/**
 * @title Vote Balances
 * @author Curvance & based on Convex VotingBalanceMax.sol, VotingEligibility.sol
 * @notice Verifies account eligibility & returns balance of votes
 * @dev Requires CveLocker address deployed prior to this
 */

contract SnapshotVotingStrategy {
    address public immutable locker;
    address public immutable eligibleList;

    constructor(address _locker, address _eligibility) {
        locker = _locker;
        eligibleList = _eligibility;
    }

    /**
     *   @notice Obtain vote balances of eligible accounts
     *   @param _account Voting account
     */
    function balanceOf(address _account) external view returns (uint256) {
        //check eligibility
        if (!IVotingEligibility(eligibleList).isEligible(_account)) {
            return 0;
        }

        // Call balanceOf from VoteEscrow account
        uint256 accountBalance = IVoteEscrow(locker).balanceOf(_account);

        return accountBalance;
    }

    /**
     *   @notice Returns balance of all eligible votes
     */
    function totalVotes() external view returns (uint256) {
        uint256 totalVoteBalance = IVoteEscrow(locker).lockedSupply();

        return totalVoteBalance;
    }
}
