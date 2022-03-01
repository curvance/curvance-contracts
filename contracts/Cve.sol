// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "./interfaces/ICve.sol";

/**
 * @title Curvance Token
 * @author Curvance
 * @notice CVE token contract
 * @dev Owner address of the contract is able to mint tokens, could be a multisig contract
 */
contract CurvanceToken is ERC20("Curvance Token", "CVE"), ERC165, Ownable {
    /// @dev CVE maximum supply
    uint256 public constant MAX_SUPPLY = 420_000_069 * 1e18;

    /// @dev Emit when token is minted
    event MintToken(address indexed to, uint256 amount);

    /**
     * @dev Used to mint tokens until `MAX_SUPPLY` is reached, needs to be executed
     *       by addresses with the MINTER role
     * @param _to Address to send funds to
     * @param _amount Amount to send
     */
    function mint(address _to, uint256 _amount) external onlyOwner {
        require(totalSupply() + _amount <= MAX_SUPPLY, "MAX_SUPPLY reached");
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
