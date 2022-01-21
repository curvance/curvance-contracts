// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "./interfaces/ICve.sol";

/**
 * @title Curvance Token
 * @author Convex Finance, Curvance
 * @notice CVE token contract
 * @dev Addresses with MINTER role are allowed to mint CVE until it reaches the maximum supply
 */
contract CurvanceToken is ERC20, Ownable, ERC165 {
    /// @dev Check if an address has the minter role
    mapping(address => bool) public isMinter;

    /// @dev 4mil CVE maximum supply
    uint256 public maxSupply = 4_000_000 * 1e18;

    /// @dev Emit when contract ownership is changed
    event ownerChanged(address indexed from, address indexed to);

    /// @dev Emit when new minter is nominated
    event newMinter(address indexed owner, address indexed nominee);

    /// @dev Emit when minter is removed from the role
    event removedMinter(address indexed owner, address indexed minter);

    /// @dev Emit when minter renounce
    event renouncedMinter(address indexed minter);

    /// @dev Emit when token is minted
    event mintToken(address indexed to, uint256 amount);

    /// @dev Only minters allowed
    modifier onlyMinter() {
        require(isMinter[msg.sender], "!minter");
        _;
    }

    /// @dev Address Zero not allowed
    modifier notAddressZero(address _addr) {
        require(_addr != address(0), "Zero address");
        _;
    }

    /// @dev Initialize CVE token contract
    constructor() ERC20("Curvance Token", "CVE") {
        isMinter[msg.sender] = true;
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
        isMinter[msg.sender] = false;
        isMinter[_newOwner] = true;

        emit ownerChanged(msg.sender, _newOwner);
    }

    /**
     * @dev Nominate a new minter, only executable by owner
     *
     * @param _nominee New minter to be nominated
     */
    function nominateMinter(address _nominee) external onlyOwner notAddressZero(_nominee) {
        require(!isMinter[_nominee], "Already minter");
        isMinter[_nominee] = true;

        emit newMinter(msg.sender, _nominee);
    }

    /**
     * @dev Remove minter from role, only executable by owner
     *
     * @param _minter Minter to be removed
     */
    function removeMinter(address _minter) external onlyOwner notAddressZero(_minter) {
        require(isMinter[_minter], "!minter");
        isMinter[_minter] = false;

        emit removedMinter(msg.sender, _minter);
    }

    /// @dev Renounce minter role, must be a minter
    function renounceMinterRole() external onlyMinter {
        isMinter[msg.sender] = false;

        emit renouncedMinter(msg.sender);
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

        emit mintToken(_to, _amount);
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
