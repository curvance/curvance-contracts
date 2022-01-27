// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./VestedEscrow.sol";

/**
 * @title Vesting Escrow Factory
 * @author Curvance
 * @notice Create Escrow Contracts
 * @dev Generate contract for eachseparate escrow
 */
contract VestedEscrowFactory is Ownable {
    /** @notice Emits escrow address */
    event EscrowCreated(address escrow);

    /**
     * @notice Factory creates escrow contract
     * @param _token Address of the ERC20 token being distributed
     * @param _startTime Timestamp at which the distribution starts
     * @param _endTime Timestamp at which everything should be vested
     * @param _stakeContract Contract to stake in when `claimAndStake` is called
     */
    function createEscrow(
        address _token,
        uint256 _startTime,
        uint256 _endTime,
        address _stakeContract
    ) external onlyOwner {
        VestedEscrow escrow = new VestedEscrow(_token, _startTime, _endTime, _stakeContract);
        emit EscrowCreated(address(escrow));
    }
}
