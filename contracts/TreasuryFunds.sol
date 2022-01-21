// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title Treasury Funds
 *
 * @author Convex Finance, Curvance
 *
 * @notice Receive treasury funds, treasurer can withdraw and execute arbitrary external code
 *
 * @dev treasuryAdmin can assign treasurer roles, which are responsible for managing treasury's funds.
 *
 * @dev Multisig can be implemented by assigning an admin address, so it can add other addresses as treasurers.
 */
contract TreasuryFunds {
    using SafeERC20 for IERC20;
    using Address for address;

    address public treasuryAdmin;
    mapping(address => bool) public isTreasurer;

    /// @dev Emit when funds are withdrawn
    event WithdrawTo(IERC20 indexed asset, address indexed to, address indexed receiver, uint256 amount);

    /// @dev Emit when the admin role is changed
    event changedAdmin(address indexed from, address indexed to);

    /// @dev Emit when a new treasurer is nominated
    event newTreasurer(address indexed admin, address indexed nominee);

    /// @dev Emit when a treasurer is removed from the role
    event removeTreasurer(address indexed admin, address indexed treasurer);

    /// @dev Emit when a treasurer resigns
    event resignTreasurer(address indexed resignee);

    /// @dev Emit when making external calls
    event externalCall(address indexed treasurer, address indexed to, uint256 amount);

    /// @dev Only admins can execute functions with this modifier
    modifier adminOnly() {
        require(msg.sender == treasuryAdmin, "!treasuryAdmin");
        _;
    }

    /// @dev Only treasurers can execute functions with this modifier
    modifier treasurerOnly() {
        require(isTreasurer[msg.sender], "!treasurer");
        _;
    }

    /// @dev Zero address is disallowed
    modifier notZeroAddress(address _addr) {
        require(_addr != address(0), "Zero address");
        _;
    }

    /**
     * @dev Initialize contract
     *
     * @param _admin treasuryAdmin to be nominated
     */
    constructor(address _admin) notZeroAddress(_admin) {
        treasuryAdmin = _admin;
        isTreasurer[_admin] = true;
    }

    function resignAdminRoleTo(address _to) external adminOnly notZeroAddress(_to) {
        isTreasurer[msg.sender] = false;

        treasuryAdmin = _to;
        isTreasurer[_to] = true;

        emit changedAdmin(msg.sender, _to);
    }

    function nominateTreasurer(address _nominee) external adminOnly notZeroAddress(_nominee) {
        require(!isTreasurer[_nominee], "Already nominated");
        isTreasurer[_nominee] = true;

        emit newTreasurer(msg.sender, _nominee);
    }

    function revokeTreasurer(address _treasurer) external adminOnly {
        require(isTreasurer[_treasurer], "!treasurer");
        isTreasurer[_treasurer] = false;

        emit removeTreasurer(msg.sender, _treasurer);
    }

    function resignTreasury() external treasurerOnly {
        isTreasurer[msg.sender] = false;

        emit resignTreasurer(msg.sender);
    }

    /**
     * @dev Withdraw an amount of a given asset to a given address
     *
     * @param _asset The ERC20 compatible asset to be used
     * @param _amount Amount to be withdrawn
     * @param _to Address to send the funds
     */
    function withdrawTo(
        IERC20 _asset,
        uint256 _amount,
        address _to
    ) external treasurerOnly {
        _asset.safeTransfer(_to, _amount);

        emit WithdrawTo(_asset, msg.sender, _to, _amount);
    }

    /**
     * @dev Execute a low-level call to an address
     *
     * @param _to Address to execute the call
     * @param _value The amount of ethers to send
     * @param _data Call data
     */
    function execute(
        address _to,
        uint256 _value,
        bytes calldata _data
    ) external treasurerOnly {
        _to.functionCallWithValue(_data, _value);

        emit externalCall(msg.sender, _to, _value);
    }
}
