// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { ERC20 } from "contracts/libraries/external/ERC20.sol";

// Mock CVE for testing.
contract MockCve is ERC20 {
    string private _name;
    string private _symbol;

    constructor(string memory name_, string memory symbol_) {
        _name = name_;
        _symbol = symbol_;
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
