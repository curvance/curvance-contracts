// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { ERC20 } from "contracts/libraries/external/ERC20.sol";

contract TestnetToken is ERC20 {
    string private _name;
    string private _symbol;
    uint8 private _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        _name = name_;
        _symbol = symbol_;
        _decimals = decimals_;
        _mint(
            0xBAaf22d2Bc4Ac001BBDDA7De73d3ae1bA71dfDDB,
            10000000000 * (10 ** decimals_)
        );
    }

    function mint(uint256 amount) public {
        require(msg.sender == 0xBAaf22d2Bc4Ac001BBDDA7De73d3ae1bA71dfDDB, "Only owner can mint");
        _mint(msg.sender, amount);
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }
}
