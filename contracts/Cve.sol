// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "./interfaces/ICve.sol";

/**
 * @title Curvance Token
 * @author Convex Finance, Curvance
 * @notice CVE token contract
 * @dev Addresses with MINTER role are allowed to mint CVE until it reaches the maximum supply
 */
contract CurvanceToken is ERC20, AccessControl {
    // role bytes for minter
    bytes32 public constant MINTER_ROLE = keccak256("MINTER");

    // 4mil CVE maximum supply
    uint256 public maxSupply = 4_000_000 * 1e18;

    /**
     * @notice Initialize CVE token contract
     */
    constructor() ERC20("Curvance Token", "CVE") {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /**
     * @dev Used to mint tokens until `maxSupply` is reached, needs to be executed
     *       by addresses with the MINTER role
     * @param _to Address to send funds to
     * @param _amount Amount to send
     */
    function mint(address _to, uint256 _amount) external {
        require(totalSupply() + _amount <= maxSupply, "maxSupply reached");
        if (!hasRole(MINTER_ROLE, msg.sender)) {
            //dont error just return. if a shutdown happens, rewards on old system
            //can still be claimed, just wont mint cvx
            return;
        }
        _mint(_to, _amount);
    }

    /**
     * @dev Checks interfaces
     * @param interfaceId Interface ID to be checked for compatibility
     * @return true if `interfaceId` is compatible with contract, otherwise, false
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(ICve).interfaceId || super.supportsInterface(interfaceId);
    }
}
