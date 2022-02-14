// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
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

    /// @dev Emit when funds are withdrawn
    event WithdrawTo(IERC20 indexed asset, address indexed to, address indexed receiver, uint256 amount);

    /// @dev Emit when making external calls
    event ExternalCall(address indexed treasurer, address indexed to, uint256 amount, bytes data);

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
    ) external onlyOwner {
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
    ) external onlyOwner {
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
