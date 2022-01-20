// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

//receive treasury funds. operator can withdraw
//allow execute so that certain funds could be staked etc
//allow treasury ownership to be transfered during the vesting stage
contract TreasuryFunds {
    using SafeERC20 for IERC20;
    using Address for address;

    address public treasuryAdmin;
    mapping(address => bool) public isTreasurer;

    /// @dev emit when
    event WithdrawTo(IERC20 indexed asset, address indexed to, address indexed receiver, uint256 amount);

    event changedAdmin(address indexed from, address indexed to);

    event newTreasurer(address indexed admin, address indexed nominee);

    event removeTreasurer(address indexed admin, address indexed treasurer);

    event resignTreasurer(address indexed resignee);

    event externalCall(address indexed treasurer, address indexed to, uint256 amount);

    modifier adminOnly() {
        require(msg.sender == treasuryAdmin, "!treasuryAdmin");
        _;
    }

    modifier treasurerOnly() {
        require(isTreasurer[msg.sender], "!treasurer");
        _;
    }

    constructor() {
        treasuryAdmin = msg.sender;
        isTreasurer[msg.sender] = true;
    }

    function resignAdminRoleTo(address _to) external adminOnly {
        isTreasurer[msg.sender] = false;

        treasuryAdmin = _to;
        isTreasurer[_to] = true;

        emit changedAdmin(msg.sender, _to);
    }

    function nominateTreasurer(address _nominee) external adminOnly {
        require(!isTreasurer[_nominee], "Already nominated");
        isTreasurer[_nominee] = true;

        emit newTreasurer(msg.sender, _nominee);
    }

    function revokeTreasurer(address _treasurer) external adminOnly {
        require(isTreasurer[_treasurer], "!treasurer");
        isTreasurer[_treasurer] = false;

        emit removeTreasurer(msg.sender, _treasurer);
    }

    function resignTreasury() external {
        require(isTreasurer[msg.sender], "!treasurer");
        isTreasurer[msg.sender] = false;

        resignTreasurer(msg.sender);
    }

    function withdrawTo(
        IERC20 _asset,
        uint256 _amount,
        address _to
    ) external treasurerOnly {
        _asset.safeTransfer(_to, _amount);

        emit WithdrawTo(_asset, msg.sender, _to, _amount);
    }

    function execute(
        address _to,
        uint256 _value,
        bytes calldata _data
    ) external treasurerOnly {
        _to.functionCallWithValue(_data, _value);

        emit externalCall(msg.sender, _to, _value);
    }

    function stake(
        IERC20 _asset,
        address _staker,
        uint256 _amount
    ) external treasurerOnly {
        require(_asset.balanceOf(this) >= _amount, "!funds");
        // ...
    }
}
