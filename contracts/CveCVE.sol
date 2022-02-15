//SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./VotingEscrow.sol";

// TODO: one thing that might be useful is to make this access control
// and retain ownership if in future, minters (apart from voting escrow) will be added
contract CveCVE is ERC20 {
    address public locker;

    // emitted when a user unwraps cveCVE for CVE at 1:1 ratio
    event Unwrap(address indexed to, uint256 amount);

    modifier onlyLocker() {
        require(msg.sender == locker, "!auth");
        _;
    }

    constructor(address _locker) ERC20("Curvance CVE", "cveCVE") {
        locker = _locker;
    }

    /**
     * @notice mint cveCVE
     * @param _account address of user to credit with tokens
     * @param _amount amount of cveCVE tokens to unwrap
     */
    function mint(address _account, uint256 _amount) external onlyLocker {
        _mint(_account, _amount);
    }

    /**
     * @dev Hook that is called after any transfer of tokens. This includes
     * minting and burning.
     * @param _from address from which tokens are transferred
     * @param _to address to which tokens are transferred
     * @param _amount amount of tokens transferred
     */
    function _afterTokenTransfer(
        address _from,
        address _to,
        uint256 _amount
    ) internal override {
        {
            _amount;
        }
        // otherwise same update will be made twice. save some gas
        if (_from != address(0)) {
            VotingEscrow(locker).updateReward(_from);
        }
        if (_to != address(0)) {
            VotingEscrow(locker).updateReward(_to);
        }
    }

    /**
     * @notice unwrap cveCVE for CVE at 1:1 ratio
     * @param _amount amount of cveCVE tokens to unwrap
     */
    function unwrap(uint256 _amount) external {
        require(_amount > 0, "amount must be greater than 0");
        _burn(msg.sender, _amount);

        VotingEscrow(locker).lockFor(msg.sender, _amount);

        emit Unwrap(msg.sender, _amount);
    }
}
