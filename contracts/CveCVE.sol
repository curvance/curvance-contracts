//SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./interfaces/IVotingEscrow.sol";

contract CveCVE is ERC20 {
    using SafeERC20 for IERC20;

    uint256 private constant MAX_SUPPLY = 420_000_069 * 1e18;

    address public locker;

    constructor(address _locker) ERC20("Curvance CVE", "cveCVE") {
        locker = _locker;
    }

    modifier onlyLocker() {
        require(msg.sender == locker, "!auth");
        _;
    }

    function mint(address _account, uint256 _amount) external onlyLocker {
        _mint(_account, _amount);
    }

    function burn(address _account, uint256 _amount) external onlyLocker {
        _burn(_account, _amount);
    }

    function _beforeTokenTransfer(
        address _from,
        address _to,
        uint256
    ) internal override {
        if (_from == address(0)) {
            IVotingEscrow(locker).updateReward(_from);
        }

        if (_to == address(0)) {
            IVotingEscrow(locker).updateReward(_to);
        }
    }
}
