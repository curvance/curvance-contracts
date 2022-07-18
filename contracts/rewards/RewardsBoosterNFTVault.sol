// SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC721} from "solmate/tokens/ERC721.sol";
import {IFlywheelBooster} from "fei-protocol/flywheel-v2/interfaces/IFlywheelBooster.sol";
import {MultiOwnable} from "./common/MultiOwnable.sol";
import {NFTVaultListener} from "./NFTVault.sol";

// Example contract that boosts a user's share of total rewards if they stake NFTs in a
// vault. The boost calculations are completely arbitrary and not intended to demonstrate anything
// regarding real-world tokenomics.
contract RewardsBoosterNFTVault is IFlywheelBooster, NFTVaultListener, TokenVaultListener, MultiOwnable {
    type Category is uint8;

    mapping(NFTVault => bool) public allowedVaults;
    mapping(NFTVault => mapping(ERC721 => mapping(Category => uint8))) public boostMultipliers;
    mapping(NFTVault => uint256) public boostedTotalSupplies;

    uint256 constant ONE_HUNDRED_PERCENT = 1000;

    function setVaultAllowed(NFTVault vault, bool allowed) public onlyOwners {
        if (allowed) {
            allowedVaults[vault] = true;
        } else {
            delete allowedVaults[vault];
        }
    }

    function setNFTMultiplier(NFTVault vault, ERC721 nft, Category category, uint8 multiplier) public onlyOwners {
        if (multiplier > 0) {
            boostMultipliers[vault].multipliers[nft][category] = multiplier;
        } else {
            delete boostMultipliers[vault][nft][category];
        }
    }

    error MustBeVault();

    function nftAdded(address user, ERC721 nft, uint256 tokenID) public {
        NFTVault vault = NFTVault(msg.sender);
        if (!allowedVaults[msg.sender]) revert MustBeVault();
        boostedTotalSupplies[vault] += (vault.balanceOf(user) * userMultiplier(user)) / ONE_HUNDRED_PERCENT;
    }

    function nftRemoved(address user, ERC721 nft, uint256 tokenID) public {
        NFTVault vault = NFTVault(msg.sender);
        if (!allowedVaults[msg.sender]) revert MustBeVault();
        boostedTotalSupplies[vault] -= (vault.balanceOf(user) * userMultiplier(user)) / ONE_HUNDRED_PERCENT;
    }

    function nftMultiplier(NFTVault vault, ERC721 nft, uint256 tokenID) public view returns (uint256 multiplier) {
        return boostMultipliers[vault][nft][category(vault, nft, tokenID)];
    }

    function userMultiplier(address user, NFTVault vault) public view returns (uint256 multiplier) {
        ERC721[] memory allowedNFTs = vault.allowedNFTs();
        for (uint8 i = 0; i < allowedNFTs.length; i++) {
            ERC721 nft = allowedNFTs[i];
            uint256[] memory userNFTs = vault.userNFTTokenIDs(user, nft);
            for (uint8 j = 0; j < userNFTs.length; j++) {
                uint256 tokenID = userNFTs[j];
                multiplier += nftMultiplier(vault, nft, tokenID);
            }
        }
        return multiplier;
    }

    // This function should be extensible/upgradable so that we can add new NFTs whose categories will be determined based on various NFT-specific metadata
    function category(NFTVault vault, ERC721 nft, uint256 tokenID) public view returns (Category) {
        // ...
        // e.g. `return curveWarriors.quality(tokenID)`
        // ...
    }

    // Implements `IFlywheelBooster`
    function boostedTotalSupply(NFTVault vault) external view returns (uint256) {
        return vault.totalSupply() + boostedTotalSupplies[vault];
    }

    // Implements `IFlywheelBooster`
    function boostedBalanceOf(NFTVault vault, address user) external view returns (uint256 balance) {
        return NFTVault(address(vault)).balanceOf(user) * (ONE_HUNDRED_PERCENT + userMultiplier(user, NFTVault(address(vault))));
    }
}

