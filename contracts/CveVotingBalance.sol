// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;
pragma experimental ABIEncoderV2;


import "./interfaces/ILockedCvx.sol";
import "./interfaces/IVotingEligibility.sol";
import '@openzeppelin/contracts/math/SafeMath.sol';

/**
 * @title Vote Balances
 * @author Curvance & based on Convex VotingBalanceMax.sol, VotingEligibility.sol
 * @notice Verifies account eligibility & returns balance of votes
 * @dev Requires CveLocker address deployed prior to this
 */

contract CveVotingBalance{

    // 
    address public constant locker = cveLocker;
    uint256 public constant rewardsDuration = 86400 * 7;
    uint256 public constant lockDuration = rewardsDuration * 17;

    mapping(address => bool) public blockList;
    mapping(address => bool) public allowedList;

    /** 
    *   @notice Allows for using either/or whitelisting or blacklisting of accounts
    *   @param useBlock by default is enabled
    *   @param useAllow by default is disabled
    */
    bool public useBlock = true;
    bool public useAllow = false;

    event changeBlock(address indexed _account, bool _state);
    event changeAllow(address indexed _account, bool _state);

    constructor(address _cveLocker, address _eligiblelist) public {
        locker = _cveLocker;
        eligiblelist = _eligiblelist;
    }

        ////////////////////////////////////////////////
        //            Account Eligibility             //
        ////////////////////////////////////////////////

    /**
    *   @dev Change the use of blacklist
    *   @param _b Boolean True/False
    */
    function setUseBlock(bool _b) external onlyOwner{
        useBlock = _b;
    }

    /**
    *   @dev Change the use of whitelist
    *   @param _a Boolean True/False
    */
    function setUseAllow(bool _a) external onlyOwner{
        useAllow = _a;
    }

    /**
    *   @notice Prevent a specific account access to voting rights
    *   @notice Enable blacklisting by setUseBlock to True
    *   @param _account Account to blacklist
    *   @param _block Boolean; True == blacklisted, False == not blacklisted
    */
    function setAccountBlock(address _account, bool _block) external onlyOwner{
        blockList[_account] = _block;
        emit changeBlock(_account, _block);
    }

    /**
    *   @notice Grant a specific account access to voting rights
    *   @notice Enable whitelisting by setUseAllow to True
    *   @param _account Account to whitelist
    *   @param _allowed Boolean; True == blacklisted, False == not blacklisted
    */
    function setAccountAllow(address _account, bool _allowed) external onlyOwner{
        allowedList[_account] = _allowed;
        emit changeAllow(_account, _allowed);
    }

    /**
    *   @notice Evaluates account voting eligibility
    *   @param _account Account attempting to vote
    *   @param _allowed Boolean; True == blacklisted, False == not blacklisted
    */
    function isEligible(address _account) external view returns(bool){

        if(useBlock){
            if(blockList[_account]){
                return false;
            }
        }

        /** @TODO Decide whether the `.isContract` functionality is necessary. 
        *   @dev Used to verify that the whitelisted account isn't: 
        *       - an externally-owned account
        *       - a contract in construction
        *       - an address where a contract will be created
        *       - an address where a contract lived, but was destroyed
        *   Reference: https://github.com/OpenZeppelin/openzeppelin-contracts/blob/release-v4.5/contracts/utils/Address.sol
        *   @notice ADJUSTED: `if(Address.isContract(_account) && !allowedList[_account]){`
        *       * Rationale: we expect to have gnosis contracts vote/count votes allocated to CveCVE.sol (delegated to multisig)
        */
        if(useAllow){
            if(!allowedList[_account]){
                return false;
            }
        }

        return true;
    }


        ////////////////////////////////////////////////
        //            Obtain Vote Balances            //
        ////////////////////////////////////////////////

    /**
    *   @notice Obtain vote balances of eligible accounts
    *   @param _account Voting account
    */
    function balanceOf(address _account) external view returns(uint256){

        //check eligibility
        if(!isEligible(_account)){
            return 0;
        }

        //compute to find previous epoch
        uint256 currentEpoch = block.timestamp.div(rewardsDuration).mul(rewardsDuration);
        uint256 epochindex = ILockedCvx(locker).epochCount() - 1;
        (, uint32 _enddate) = ILockedCvx(locker).epochs(epochindex);
        if(_enddate >= currentEpoch){
            //if end date is already the current epoch,  minus 1 to get the previous
            epochindex -= 1;
        }
        //get balances of current and previous
        uint256 balanceAtPrev = ILockedCvx(locker).balanceAtEpochOf(epochindex, _account);
        uint256 currentBalance = ILockedCvx(locker).balanceOf(_account);

        //return greater balance
        return max(balanceAtPrev, currentBalance);
    }

    /**
    *   @notice Obtain vote balances of eligible accounts
    *   @param _account Voting account
    *   @param returns Pending vote balances
    */
    function pendingBalanceOf(address _account) external view returns(uint256){

        //check eligibility
        if(!isEligible(_account)){
            return 0;
        }

        //determine when current epoch would end
        uint256 currentEpochUnlock = block.timestamp.div(rewardsDuration).mul(rewardsDuration).add(lockDuration);

        //grab account lock list
        (,,,ILockedCvx.LockedBalance[] memory balances) = ILockedCvx(locker).lockedBalances(_account);
        
        //if most recent lock is current epoch, then lock amount is pending balance
        uint256 pending;
        if(balances[balances.length-1].unlockTime == currentEpochUnlock){
            pending = balances[balances.length-1].boosted;
        }

        return pending;
    }

    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a >= b ? a : b;
    }

    function totalSupply() view external returns(uint256){
        return ILockedCvx(locker).totalSupply();
    }
}