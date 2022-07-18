// SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC721} from "solmate/tokens/ERC721.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {EnumerableSet, AddressSet, UintSet} from "fei-protocol/flywheel-v2/lib/EnumerableSet.sol";
import {MultiOwnable} from "./common/MultiOwnable.sol";
import {Pausable} from "./common/Pausable.sol";

interface TokenVaultListener {
    function nftAdded(address user, ERC721 nft, uint256 tokenID) external;
    function nftRemoved(address user, ERC721 nft, uint256 tokenID) external;
}

contract TokenAndNFTVault is TokenVault, NFTVault, MultiOwnable, Pausable {
    constructor (
        ERC20 underlyingAsset,
        string memory name,
        string memory symbol,
        TokenVaultListener _tokenVaultListener,
        NFTVaultListener _nftVaultListener
    )
        TokenVault(underlyingAsset, name, symbol, _tokenVaultListener)
        NFTVault(_nftVaultListener)
    {
        listener = _listener;
    }


}

