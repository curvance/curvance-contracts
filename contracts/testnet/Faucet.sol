// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

// solhint-disable max-line-length
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
// solhint-enable max-line-length

contract Faucet is Ownable {
    struct FaucetToken {
        address tokenAddress;
        uint256 maxClaimAmount;
    }

    FaucetToken[] public faucetTokens;
    mapping(address => mapping(address => uint256)) public userLastClaimed;

    constructor(
        address[] memory tokens, 
        uint256[] memory claimAmounts
    ) Ownable() {
        for (uint256 i = 0; i < tokens.length; i++) {
            _addFaucetToken(tokens[i], claimAmounts[i]);
        }
    }

    function claim(address token) external {
        _claim(token);
    }

    function multiClaim(address[] calldata tokens) external {
        for (uint256 i = 0; i < tokens.length; i++) {
            _claim(tokens[i]);
        }
    }

    function multiLastClaimed(
        address account,
        address[] calldata tokens
    ) public view returns (uint256[] memory) {
        uint256[] memory lastClaimed = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            lastClaimed[i] = userLastClaimed[account][tokens[i]];
        }
        return lastClaimed;
    }
    
    function addFaucetToken(
        address tokenAddress, 
        uint256 maxClaimAmount
    ) external onlyOwner {
        _addFaucetToken(tokenAddress, maxClaimAmount);
    }

    function modifyFaucetTokenAmount(
        address tokenAddress,
        uint256 newMaxClaimAmount
    ) external onlyOwner {
        for (uint256 i = 0; i < faucetTokens.length; i++) {
            if (faucetTokens[i].tokenAddress == tokenAddress) {
                faucetTokens[i].maxClaimAmount = newMaxClaimAmount;
                return;
            }
        }
        require(false, "Invalid token address");
    }

    function removeFaucetToken(address tokenAddress) external onlyOwner {
        FaucetToken[] memory newFaucetTokens = 
            new FaucetToken[](faucetTokens.length - 1);
        bool found = false;
        for(uint256 i; i < faucetTokens.length; i++) {
            if(faucetTokens[i].tokenAddress == tokenAddress) {
                found = true;
                continue;
            }
            newFaucetTokens[i] = faucetTokens[i];
        }
        require(found, "Invalid token address");
        
        delete faucetTokens;
        for(uint256 i; i < newFaucetTokens.length; i++) {
            faucetTokens.push(newFaucetTokens[i]);
        }
    }

    function _addFaucetToken(
        address tokenAddress, 
        uint256 maxClaimAmount
    ) internal {
        faucetTokens.push(FaucetToken(tokenAddress, maxClaimAmount));
    }
    
    function _getFaucetToken(
        address token
    ) internal view returns (FaucetToken memory) {
        for(uint256 i; i < faucetTokens.length; i++) {
            if(faucetTokens[i].tokenAddress == token) {
                return faucetTokens[i];
            }
        }

        revert("Token not found");
    }

    function _claim(address token) internal {
        require(
            userLastClaimed[msg.sender][token] + 24 hours < block.timestamp,
            "Claim cooldown active (24 hours)"
        );
        FaucetToken memory faucetToken = _getFaucetToken(token);

        IERC20 erc20Token = IERC20(token);
        require(
            erc20Token.balanceOf(address(this)) >= faucetToken.maxClaimAmount,
            "Insufficient balance in faucet"
        );
        SafeTransferLib.safeTransfer(
            token, msg.sender,
            faucetToken.maxClaimAmount
        );
        
        userLastClaimed[msg.sender][token] = block.timestamp;
    }
}