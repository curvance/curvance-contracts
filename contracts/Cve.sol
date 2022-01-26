// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "./interfaces/ICve.sol";

/**
 * @title Curvance Token
 * @author Convex Finance, Curvance
 * @notice CVE token contract
 * @dev Addresses with MINTER role are allowed to mint CVE until it reaches the maximum supply
 */
contract CurvanceToken is ERC20, Ownable, AccessControl {
    /// @dev Minter role identifier
    bytes32 public constant MINTER_ROLE = keccak256("MINTER");

    /// @dev 4mil CVE maximum supply
    uint256 public maxSupply = 4_000_000 * 1e18;

    /// @dev Emit when contract ownership is changed
    event OwnerChanged(address indexed from, address indexed to);

    /// @dev Emit when token is minted
    event MintToken(address indexed to, uint256 amount);

    /// @dev Only minters allowed
    modifier onlyMinter() {
        require(hasRole(MINTER_ROLE, msg.sender), "!minter");
        _;
    }

    /// @dev Initialize CVE token contract
    constructor() ERC20("Curvance Token", "CVE") {
        // Grant DEFAULT_ADMIN_ROLE for contract deployer and emit {RoleGranted}
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /**
     * @dev Transfer contract ownership
     *
     * @param _newOwner New owner of the contract
     */
    function transferOwnership(address _newOwner) public virtual override {
        // Check if msg.sender is the owner and change contract ownership
        super.transferOwnership(_newOwner);

        // Transfer ownership and emit {RoleGranted} and {RoleRevoked}
        _revokeRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(DEFAULT_ADMIN_ROLE, _newOwner);
    }

    /// @dev Disable grantRole
    function grantRole(bytes32 role, address account) public virtual override {}

    /// @dev Disable revokeRole
    function revokeRole(bytes32 role, address account) public virtual override {}

    /// @dev Disable renounceRole
    function renounceRole(bytes32 role, address account) public virtual override {}

    /**
     * @dev Nominate a new minter, only executable by owner
     *
     * @param _nominee New minter to be nominated
     */
    function nominateMinter(address _nominee) external onlyOwner {
        // Reverts if `_nominee` is already a minter and emit {RoleGranted}
        _grantRole(MINTER_ROLE, _nominee);
    }

    /**
     * @dev Remove minter from role, only executable by owner
     *
     * @param _minter Minter to be removed
     */
    function removeMinter(address _minter) external onlyOwner {
        // Reverts if `_minter` is not a minter and emit {RoleRevoked}
        _revokeRole(MINTER_ROLE, _minter);
    }

    /// @dev Renounce minter role, must be a minter
    function renounceMinterRole() external onlyMinter {
        // Reverts if `msg.sender` is not a minter and emit {RoleRevoked}
        _revokeRole(MINTER_ROLE, msg.sender);
    }

    /**
     * @dev Used to mint tokens until `maxSupply` is reached, needs to be executed
     *       by addresses with the MINTER role
     * @param _to Address to send funds to
     * @param _amount Amount to send
     */
    function mint(address _to, uint256 _amount) external onlyMinter {
        require(totalSupply() + _amount <= maxSupply, "maxSupply reached");
        _mint(_to, _amount);

        emit MintToken(_to, _amount);
    }

    /**
     * @dev Checks interfaces
     * @param interfaceId Interface ID to be checked for compatibility
     * @return true if `interfaceId` is compatible with contract, otherwise, false
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return
            interfaceId == type(ICve).interfaceId ||
            interfaceId == type(IERC20).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
