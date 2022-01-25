// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";
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
contract TreasuryFunds is Ownable, ERC165 {
    using SafeERC20 for IERC20;
    using Address for address;

    address public treasuryAdmin;
    mapping(address => bool) public isTreasurer;

    /// @dev Emit when funds are withdrawn
    event WithdrawTo(IERC20 indexed asset, address indexed to, address indexed receiver, uint256 amount);

    /// @dev Emit when contract ownership is changed
    event ownerChanged(address indexed from, address indexed to);

    /// @dev Emit when a new treasurer is nominated
    event newTreasurer(address indexed admin, address indexed nominee);

    /// @dev Emit when a treasurer is removed from the role
    event removedTreasurer(address indexed admin, address indexed treasurer);

    /// @dev Emit when a treasurer renounces
    event renouncedTreasurer(address indexed resignee);

    /// @dev Emit when making external calls
    event externalCall(address indexed treasurer, address indexed to, uint256 amount, bytes data);

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
    constructor(address _admin) {
        isTreasurer[_admin] = true;
    }

    /**
     * @dev Transfer contract ownership
     *
     * @param _newOwner New owner of the contract
     */
    function transferOwnership(address _newOwner) public virtual override {
        // check if msg.sender is the owner and change contract ownership
        super.transferOwnership(_newOwner);

        // also transfer minter role
        isTreasurer[msg.sender] = false;
        isTreasurer[_newOwner] = true;

        emit ownerChanged(msg.sender, _newOwner);
    }

    /**
     * @dev Nominate a new treasurer, only executable by owner
     *
     * @param _nominee New treasurer to be nominated
     */
    function nominateTreasurer(address _nominee) external onlyOwner notZeroAddress(_nominee) {
        require(!isTreasurer[_nominee], "Already nominated");
        isTreasurer[_nominee] = true;

        emit newTreasurer(msg.sender, _nominee);
    }

    /**
     * @dev Remove treasurer from role, only executable by owner
     *
     * @param _treasurer Treasurer to be removed
     */
    function removeTreasurer(address _treasurer) external onlyOwner {
        require(isTreasurer[_treasurer], "!treasurer");
        isTreasurer[_treasurer] = false;

        emit removedTreasurer(msg.sender, _treasurer);
    }

    /// @dev Renounce minter role, must be a minter
    function renounceTreasurerRole() external treasurerOnly {
        isTreasurer[msg.sender] = false;

        emit renouncedTreasurer(msg.sender);
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

        emit externalCall(msg.sender, _to, _value, _data);
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
