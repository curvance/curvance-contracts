// SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {MultiOwnable} from "./common/MultiOwnable.sol";
import {Pausable} from "./common/Pausable.sol";

interface TokenVaultListener {
    function tokensDeposited(address user, ERC20 token, uint256 amount) external;
    function tokensRemoved(address user, ERC20 token, uint256 amount) external;
}

contract TokenVault is ERC4626, MultiOwnable, Pausable {
    TokenVaultListener public tokenVaultListener;

    constructor (ERC20 underlying, string memory name, string memory symbol, TokenVaultListener _tokenVaultListener)
        ERC4626(underlying, name, symbol)
    {
        tokenVaultListener = _tokenVaultListener;
    }

    function setTokenVaultListener(NFTVaultListener _tokenVaultListener) public onlyOwners {
        tokenVaultListener = _tokenVaultListener;
    }

    function deposit(uint256 assets, address receiver) public override(ERC4626) returns (uint256 shares) {
        shares = ERC4626.deposit(assets, receiver);

        if (address(tokenVaultListener) != address(0)) {
            tokenVaultListener.tokensDeposited(receiver, asset, shares);
        }
        return shares;
    }

    function mint(uint256 shares, address receiver) public override(ERC4626) returns (uint256 assets) {
        assets = ERC4626.mint(shares, receiver);

        if (address(tokenVaultListener) != address(0)) {
            tokenVaultListener.tokensDeposited(receiver, asset, shares);
        }
        return assets;
    }

    function withdraw(uint256 assets, address receiver, address owner) public override(ERC4626) returns (uint256 shares) {
        shares = ERC4626.withdraw(assets, receiver, owner);

        if (address(tokenVaultListener) != address(0)) {
            tokenVaultListener.tokensWithdrawn(owner, asset, shares);
        }
        return shares;
    }

    function redeem(uint256 shares, address receiver, address owner) public override(ERC4626) returns (uint256 assets) {
        assets = ERC4626.redeem(shares, receiver, owner);

        if (address(tokenVaultListener) != address(0)) {
            tokenVaultListener.tokensWithdrawn(owner, asset, shares);
        }
        return assets;
    }

    function beforeWithdraw(uint256 assets, uint256 shares) internal override(ERC4626) {}
    function afterDeposit(uint256 assets, uint256 shares) internal override(ERC4626) {}
}

