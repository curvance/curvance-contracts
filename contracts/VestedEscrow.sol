// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Vested Escrows
/// @author Curvance
/// @notice Maintains vested escrow balances, time locks, and withdraws
/// @dev ask Mai for code assessment

contract VestedEscrow {


    // Admin
    address private admin;

    // Vested Token
    IERC20 private CVE;

    // Token vault
    address tokenVault;

    // Escrow balance
    mapping(address => uint) public balances;

    // Withdrawal date
    mapping(address => uint) public lockTime;

    // Timekeeping constant
    mapping(address => uint) public initTime;

    // HELPERS
    uint8 private lockStatus = 1;

    constructor(
        address _admin,
        IERC20 _CVE,
        address _tokenVault
    ) {
        admin == _admin;
        CVE == _CVE;
        tokenVault == _tokenVault;
    }

    // Deposits tokens and creates escrow balance
    function createEscrow(
        address payable vester,
        uint lockedTokensAmount,
        uint lockTimeInBlocks
        ) external nonReentrant onlyAdmin {

        // Set escrow balance
        balances[vester] = lockedTokensAmount;

        // Set lock time
        lockTime[vester] = lockTimeInBlocks;

        // Set init time constant
        initTime[vester] = block.timestamp;
    }

    // Checks balance, calculates claim amount, and withdraws
    function claim(address payable vester) public nonReentrant {

        require(msgSender() == vester, "Not vesting user");        
        // Check for balance
        require(viewBalance(msgSender()) > 0, "No balance");

        // If past lock end date, unlock all remainin balance
        // Otherwise, transfer tokens unlocked up to date
        if (block.timestamp <= (viewInitTime(msgSender()) + viewLockTime(msgSender()))) {
            CVE.transferFrom(tokenVault, vester, viewBalance(vester));
        } else {
            (uint _withdrawAmount, uint _withdrawTime) = _calculateWithdraw(msgSender());

            // update balance, lock remaining, and init time
            _editbalance(msgSender(), (viewBalance(msgSender())-_withdrawAmount));
            _editLockTime(msgSender(), (viewLockTime(msgSender())-_withdrawTime));
            _editInitTime(msgSender(), (viewInitTime(msgSender())-_withdrawTime));

            CVE.transferFrom(tokenVault, msgSender(), _withdrawAmount);
        }
    }

    // Changing escrow balance
    function editbalance(address vester, uint newBalance) external onlyAdmin {
        _editbalance(vester, newBalance);
    }

    // Changing escrow lock time
    function editLockTime(address vester, uint newLockTime) external onlyAdmin {
        _editLockTime(vester, newLockTime);
    }

    // Changing x constant
    function editInitTime(address vester, uint newInitTime) external onlyAdmin {
        _editInitTime(vester, newInitTime);
    } 


    // ----- INTERNAL ----- //

    // Withdraw amount calculation
    function _calculateWithdraw(address vester) view internal returns (uint, uint) {

        // y = mx + b except the token emission is reversed in calculation for unsigned numbers
        uint m = viewBalance(vester) / viewLockTime(vester);    // slope
        uint x = block.timestamp - viewInitTime(vester);        // time passed
        uint y = m*x;                                           // balance to withdraw

        return (y, x);
    }

    // Changing escrow balance
    function _editbalance(address vester, uint newBalance) internal {
        balances[vester] = newBalance;
    }

    // Changing escrow lock time
    function _editLockTime(address vester, uint newLockTime) internal {
        lockTime[vester] = newLockTime;
    }

    // Changing x constant
    function _editInitTime(address vester, uint newInitTime) internal {
        initTime[vester] = newInitTime;
    } 


    // ----- VIEW FUNCTIONS ----- //

    function viewBalance(address vester) public view returns (uint) {
        return balances[vester];
    }

    function viewLockTime(address vester) public view returns (uint) {
        return lockTime[vester];
    }

    function viewInitTime(address vester) internal view returns (uint) {
        return initTime[vester];
    }


    // ----- HELPERS ----- //

    // msg.sender -> msgSender()
    function msgSender() public view returns (address) {
        return address(msg.sender);
    }

    // no reentrancy
    modifier nonReentrant() {
        require(lockStatus == 1, "Reentrancy Attempt");
        lockStatus == 2;
        _;
        lockStatus == 1;
    }

    modifier onlyAdmin() {
        require(msgSender() == admin, "Not admin");
        _;
    }

}