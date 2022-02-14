//SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./VotingEscrow.sol";

contract CveCVE is ERC20, Ownable {
    event Unwrap(address indexed _to, uint256 _amount);

    address public lockerAddress;

    constructor(address _lockerAddress) ERC20("Curvance CVE", "cveCVE") Ownable() {
        lockerAddress = _lockerAddress;
    }

    function mint(address _account, uint256 _amount) external {
        require(msg.sender == lockerAddress);
        _mint(_account, _amount);
    }

    function _afterTokenTransfer(
        address _from,
        address _to,
        uint256
    ) internal override {
        VotingEscrow(lockerAddress).updateReward(_from);
        VotingEscrow(lockerAddress).updateReward(_to);
    }

    function unwrap(uint256 _amount) public {
        _burn(msg.sender, _amount);
        VotingEscrow(lockerAddress).lock(msg.sender, _amount);

        emit Unwrap(msg.sender, _amount);
    }
}
