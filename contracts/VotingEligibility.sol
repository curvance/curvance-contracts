// SPDX-License-Identifier: MIT
pragma solidity 0.8.9;

import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title Voting Eligibility
 * @author Curvance, based on ConvexVotingEligibility.sol
 * @notice Verifies account eligibility
 * @dev Deploy before SnapshotVotingStrategy
 */

contract VotingEligibility is Ownable {
    mapping(address => bool) public blockList;
    event AccountBlockUpdated(address indexed _account, bool _true);

    constructor() {}

    /**
     *   @notice Prevent a specific account access to voting rights
     *   @notice Enable blacklisting by setUseBlock to True
     *   @param _account Account to blacklist
     *   @param _block true = cannot vote, false = allowed to vote
     */
    function setAccountBlock(address _account, bool _block) external onlyOwner {
        blockList[_account] = _block;
        emit AccountBlockUpdated(_account, _block);
    }

    /**
     *   @notice Evaluates account voting eligibility
     *   @param _account Account attempting to vote
     */
    function isEligible(address _account) external view returns (bool) {
        if (blockList[_account] == true) {
            return false;
        }

        return true;
    }
}
