// SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC721} from "solmate/tokens/ERC721.sol";
import {EnumerableSet, AddressSet, UintSet} from "fei-protocol/flywheel-v2/lib/EnumerableSet.sol";
import {MultiOwnable} from "./common/MultiOwnable.sol";
import {Pausable} from "./common/Pausable.sol";

interface NFTVaultListener {
    function nftAdded(address user, ERC721 nft, uint256 tokenID) external;
    function nftRemoved(address user, ERC721 nft, uint256 tokenID) external;
}

contract NFTVault is MultiOwnable, Pausable {
    NFTVaultListener public nftVaultListener;
    AddressSet private _allowedNFTs;
    mapping(address => mapping(ERC721 => UintSet[])) private _userNFTTokenIDs;

    constructor (NFTVaultListener _nftVaultListener) {
        nftVaultListener = _nftVaultListener;
    }

    function setNFTVaultListener(NFTVaultListener _nftVaultListener) public onlyOwners {
        nftVaultListener = _nftVaultListener;
    }

    function allowNFT(ERC721 nft) public onlyOwners {
        _allowedNFTs.add(address(nft));
    }

    function disallowNFT(ERC721 nft) public onlyOwners {
        _allowedNFTs.remove(address(nft));
    }

    error NFTNotAllowed(address user, ERC721 nft);
    error NFTDoesNotExist(address user, ERC721 nft, uint256 tokenID);

    function depositNFT(ERC721 nft, uint256 tokenID) public whenNotPaused {
        if (!_allowedNFTs.contains(address(nft))) revert NFTNotAllowed(msg.sender, nft);

        _userNFTTokenIDs[msg.sender][nft].add(tokenID);
        nft.transferFrom(msg.sender, address(this), tokenID);

        if (address(nftVaultListener) != address(0)) {
            nftVaultListener.nftAdded(msg.sender, nft, tokenID);
        }
    }

    function withdrawNFT(ERC721 nft, uint256 tokenID) public whenNotPaused {
        if (!_userNFTTokenIDs[msg.sender][nft].contains(tokenID)) revert NFTDoesNotExist(user, nft, tokenID);

        _userNFTTokenIDs[msg.sender][nft].remove(tokenID);
        if (_userNFTTokenIDs[msg.sender][nft].length() == 0) {
            delete _userNFTTokenIDs[msg.sender][nft];
        }
        nft.transfer(msg.sender, address(this), tokenID);

        if (address(nftVaultListener) != address(0)) {
            nftVaultListener.nftRemoved(msg.sender, nft, tokenID);
        }
    }

    function allowedNFTs() public view returns (address[] memory) {
        return _allowedNFTs.values();
    }

    function userNFTTokenIDs(address user, ERC721 nft) public view returns (uint256[] memory) {
        return _userNFTTokenIDs[user][nft].values();
    }
}

