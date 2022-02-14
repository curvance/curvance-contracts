// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract ERC20Mock is ERC20 {
    uint256 public maxSupply = 1_000 * 1e18;

    constructor() ERC20("ERC20 Mock", "MOCK") {
        _mint(_msgSender(), maxSupply);
    }

    function dummy() public payable {}
}
