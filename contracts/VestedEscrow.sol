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

    struct Vester {
        // Escrow balance (balances are kept in .10e11 since an year in blockstamp is around 3e8)
        uint256 balance;

        // Withdrawal date
        uint256 lockTime;

        // Timekeeping constant
        uint256 initTime;
    }

    mapping(address => Vester) public Escrows;

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

    // ----- MAIN ----- //

    // Creates locked balance and records time
    function createEscrow(
        address payable vester,
        uint256 lockedTokensAmount,
        uint256 lockTimeInBlocks
        ) external nonReentrant onlyAdmin {
        
        lockedTokensAmount = lockedTokensAmount * 10e11;
        Escrows[vester] = Vester(lockedTokensAmount,lockTimeInBlocks,block.timestamp);
    }

    // Checks balance, calculates claim amount, and withdraws
    function claim(address payable vester) public nonReentrant {

        // Check if msg.sender is vester
        // Can omit vester arg if no need for delegated calls
        require(msgSender() == vester, "Not vesting user");        
        // Check for balance
        require(viewBalance(msgSender()) > 0, "No balance");

        // If past lock end date, unlock all remainin balance
        // Otherwise, transfer tokens unlocked up to date
        if (block.timestamp <= (viewInitTime(msgSender()) + viewLockTime(msgSender()))) {
            Escrows[msgSender()].balance = 0;

            // Transfer remaining locked CVE
            CVE.approve(address(this), viewBalance(vester));
            CVE.transferFrom(tokenVault, vester, viewBalance(vester));
        }
        else {
            (uint256 _withdrawAmount, uint256 _withdrawTime) = _calculateWithdraw(msgSender());

            // update balance, lock remaining, and init time
            Escrows[vester] = Vester(
                (viewBalance(msgSender())-_withdrawAmount),
                (viewLockTime(msgSender())-_withdrawTime),
                (viewInitTime(msgSender())-_withdrawTime)
                );
            
            // Trasnfer unlocked CVE balance
            CVE.approve(address(this), _withdrawAmount);
            CVE.transferFrom(tokenVault, msgSender(), _withdrawAmount);
        }
    }

    // Changing escrow balance
    function editbalance(address vester, uint256 newBalance) external onlyAdmin nonReentrant {
        Escrows[vester].balance = newBalance * 10e11;
    }

    // Changing escrow lock time
    function editLockTime(address vester, uint256 newLockTime) external onlyAdmin nonReentrant {
        Escrows[vester].lockTime = newLockTime;
    }

    // Changing x constant
    function editInitTime(address vester, uint256 newInitTime) external onlyAdmin nonReentrant {
        Escrows[vester].initTime = newInitTime;
    } 


    // ----- INTERNAL ----- //

    // Withdraw amount calculation
    function _calculateWithdraw(address vester) view internal returns (uint, uint) {

        // y = mx + b except the token emission is reversed in calculation for unsigned numbers
        uint256 m = viewBalance(vester) / viewLockTime(vester);    // slope
        uint256 x = block.timestamp - viewInitTime(vester);        // time passed
        uint256 y = m*x;                                           // balance to withdraw

        return (y, x);
    }


    // ----- VIEW FUNCTIONS ----- //

    function viewBalance(address vester) public view returns (uint256) {
        return Escrows[vester].balance;
    }

    function viewLockTime(address vester) public view returns (uint256) {
        return Escrows[vester].lockTime;
    }

    function viewInitTime(address vester) internal view returns (uint256) {
        return Escrows[vester].initTime;
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

    // onlyAdmin
    modifier onlyAdmin() {
        require(msgSender() == admin, "Not admin");
        _;
    }

}