// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "./interfaces/ITreasuryFunds.sol";

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
contract TreasuryFunds is Ownable, AccessControl {
    using SafeERC20 for IERC20;
    using Address for address;

    /// @dev Treasurer role bytes
    bytes32 public constant TREASURER_ROLE = keccak256("TREASURER");

    /// @dev Emit when funds are withdrawn
    event WithdrawTo(IERC20 indexed asset, address indexed to, address indexed receiver, uint256 amount);

    /// @dev Emit when contract ownership is changed
    event OwnerChanged(address indexed from, address indexed to);

    /// @dev Emit when making external calls
    event ExternalCall(address indexed treasurer, address indexed to, uint256 amount, bytes data);

    /// @dev Only treasurers can execute functions with this modifier
    modifier onlyTreasurer() {
        require(isTreasurer(msg.sender), "!treasurer");
        _;
    }

    /// @dev Initialize TreasuryFunds contract
    constructor() {
        // Grant DEFAULT_ADMIN_ROLE for contract deployer and emit {RoleGranted}
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(TREASURER_ROLE, msg.sender);
    }

    /// @dev Disable grantRole
    function grantRole(bytes32 role, address account) public virtual override {
        // Access to disable warnings
        role;
        account;
    }

    /// @dev Disable revokeRole
    function revokeRole(bytes32 role, address account) public virtual override {
        // Access to disable warnings
        role;
        account;
    }

    /// @dev Disable renounceRole
    function renounceRole(bytes32 role, address account) public virtual override {
        // Access to disable warnings
        role;
        account;
    }

    /**
     * @dev Transfer contract ownership
     *
     * @param _newOwner New owner of the contract
     */
    function transferOwnership(address _newOwner) public virtual override {
        // Check if msg.sender is the owner and change contract ownership
        super.transferOwnership(_newOwner);

        // Transfer treasurer rights to new owner and emit {RoleGranted} and {RoleRevoked}
        _grantRole(TREASURER_ROLE, _newOwner);
        _revokeRole(TREASURER_ROLE, msg.sender);

        // Transfer ownership and emit {RoleGranted} and {RoleRevoked}
        _grantRole(DEFAULT_ADMIN_ROLE, _newOwner);
        _revokeRole(DEFAULT_ADMIN_ROLE, msg.sender);

        emit OwnerChanged(msg.sender, _newOwner);
    }

    /**
     * @dev Nominate a new treasurer, only executable by owner
     *
     * @param _nominee New treasurer to be nominated
     */
    function nominateTreasurer(address _nominee) external onlyOwner {
        // Reverts if `_nominee` is already a treasurer and emit {RoleGranted}
        _grantRole(TREASURER_ROLE, _nominee);
    }

    /**
     * @dev Remove treasurer from role, only executable by owner
     *
     * @param _treasurer Treasurer to be removed
     */
    function removeTreasurer(address _treasurer) external onlyOwner {
        // Reverts if `_treasurer` is not a treasurer and emit {RoleRevoked}
        _revokeRole(TREASURER_ROLE, _treasurer);
    }

    /// @dev Renounce treasurer role, must be a treasurer but not the contract admin
    function renounceTreasurerRole() external onlyTreasurer {
        require(owner() != msg.sender, "Admin cannot renounce treasurer role");
        // Reverts if `msg.sender` is not a treasurer and emit {RoleRevoked}
        _revokeRole(TREASURER_ROLE, msg.sender);
    }

    /**
     * @dev Check if address has treasurer rights
     *
     * @param _addr Address to be checked for treasurer rights
     * @return True, if `_addr` is a treasurer, false otherwise
     */
    function isTreasurer(address _addr) public view returns (bool) {
        return hasRole(TREASURER_ROLE, _addr);
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
    ) external onlyTreasurer {
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
    ) external onlyTreasurer {
        _to.functionCallWithValue(_data, _value);

        emit ExternalCall(msg.sender, _to, _value, _data);
    }

    /**
     * Check if interfaceId is supported by the contract
     *
     * @param _interfaceId The interfaceId to be checked
     * @return True, if the interface is supported, false otherwise
     */
    function supportsInterface(bytes4 _interfaceId) public view virtual override returns (bool) {
        return type(ITreasuryFunds).interfaceId == _interfaceId || super.supportsInterface(_interfaceId);
    }
}
