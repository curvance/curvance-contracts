// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";

import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";

import { IERC20 } from "contracts/interfaces/IERC20.sol";

contract Faucet is Ownable {
    using Strings for uint256;

    /// Maximum faucet erc20 claim amount
    uint256 public maxClaim = 1000;
    mapping(address => uint256) public overrideMaxClaim;

    /// /// Maximum faucet sepETH claim amount
    uint256 public maxSepETHClaim = 0.1 ether;
    /// user => token => last claimed timestamp
    mapping(address => mapping(address => uint256)) public userLastClaimed;

    constructor() Ownable() {}

    function setMaxClaimAmounts(
        uint256 amountERC20,
        uint256 amountSepETH
    ) external onlyOwner {
        maxClaim = amountERC20;
        maxSepETHClaim = amountSepETH;
    }

    function claim(address user, address token, uint256 amount) external {
        _claim(user, token, amount);
    }

    function multiIsAvailable(
        address[] calldata tokens,
        uint256[] calldata amounts
    ) public view returns (bool[] memory availability) {
        availability = new bool[](tokens.length);
        for(uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            uint256 amount = amounts[i];
            IERC20 ercToken = IERC20(token);

            uint256 balance = ercToken.balanceOf(address(this));
            availability[i] = balance >= amount;
        }
    }

    function multiClaim(
        address user,
        address[] calldata tokens,
        uint256[] calldata amounts
    ) external {
        require(
            tokens.length == amounts.length,
            "Not enough tokens OR amounts provided"
        );

        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            uint256 amount = amounts[i];

            _claim(user, token, amount);
        }
    }

    function multiLastClaimed(
        address wallet,
        address[] calldata tokens
    ) public view returns (uint256[] memory) {
        uint256[] memory lastClaimed = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            lastClaimed[i] = userLastClaimed[wallet][tokens[i]];
        }
        return lastClaimed;
    }

    function _claim(address user, address token, uint256 amount) internal {
        uint256 tokenMaxClaim = _getMaxClaim(token);
        require(
            userLastClaimed[user][token] + 24 hours <= block.timestamp,
            "Wait 24 hours"
        );

        if (token == address(0)) {
            require(amount < maxSepETHClaim, "Excessive desired claim amount");
            require(address(this).balance >= amount, "Not enough ETH");
            SafeTransferLib.safeTransferETH(user, amount);
        } else {
            require(
                amount <= tokenMaxClaim,
                string.concat(
                    "Excessive desired claim amount, cannot claim more than: ",
                    tokenMaxClaim.toString()
                )
            );
            require(
                IERC20(token).balanceOf(address(this)) >= amount,
                "Not enough Token"
            );
            SafeTransferLib.safeTransfer(token, user, amount);
        }

        userLastClaimed[user][token] = block.timestamp;
    }

    function setMaxClaimAmounts(
        address token,
        uint256 amount
    ) external onlyOwner {
        overrideMaxClaim[token] = amount;
    }

    // By default users can claim 1000 of a specific token -- unless overriden by the owner
    function _getMaxClaim(address token) internal view returns (uint256) {
        uint256 decimal = IERC20(token).decimals();
        uint256 default_claim = maxClaim * (10 ** decimal);

        return
            overrideMaxClaim[token] == 0
                ? default_claim
                : overrideMaxClaim[token];
    }
}
