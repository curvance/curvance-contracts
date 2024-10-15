//SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { UniversalBalance } from "contracts/architecture/UniversalBalance.sol";

import { PluginDelegable } from "contracts/libraries/PluginDelegable.sol";
import { WAD } from "contracts/libraries/Constants.sol";
import { ReentrancyGuard } from "contracts/libraries/external/ReentrancyGuard.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";

import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IWETH } from "contracts/interfaces/IWETH.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IOracleManager } from "contracts/interfaces/IOracleManager.sol";
import { IMToken } from "contracts/interfaces/market/IMToken.sol";
import { IGaugeManager } from "contracts/interfaces/IGaugeManager.sol";

/// @title Curvance Universal Balance for native gas token.
/// @notice A system for managing a Universal Balance within the Curvance
///         Protocol.
contract UniversalBalanceNative is UniversalBalance {

    receive() external payable {
        if (msg.sender != underlying) {
            IWETH(underlying).deposit{ value: msg.value };
            _deposit(msg.value, true);
        }
    }

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        address eToken,
        address underlying_
    ) UniversalBalance(centralRegistry_, eToken) {
        // Validate that eToken underlying and native wrapped token
        // contract match addresses.
        if (IMToken(eToken).underlying() != underlying_) {
            revert UniversalBalance__UnderlyingTokenMismatch();
        }
    }

    /// EXTERNAL FUNCTIONS ///

    function depositNative(bool isLent) external payable {
        IWETH(underlying).deposit{ value: msg.value }();
        _deposit(msg.value, isLent);
    }

    function withdrawAsNative(uint256 amount, bool isLent) external {
        amount = _withdraw(amount, isLent);
        IWETH(underlying).withdraw(amount);
        SafeTransferLib.safeTransferETH(msg.sender, amount);
    }

    /// @notice Used by Oracle Manager to fund a pull-based oracle update.
    /// @param user Which user is funding the oracle update from their universal
    ///             balance account.
    /// @param amount The amount of underlying token to be earmarked for
    ///               oracle update.
    function useBalanceForOracleUpdate(address user, uint256 amount) external {
        // Check for amount == 0 in oracle adaptor.
        if (
            !IOracleManager(centralRegistry.oracleManager()).isApprovedAdaptor(
                msg.sender
            )
        ) {
            revert UniversalBalance__Unauthorized();
        }

        UserBalance memory userBalance = userBalances[user];
        uint256 exchangeRate = linkedEToken.exchangeRateWithUpdate();
        uint256 pointerAmount;
        uint256 remainingAmount = amount;

        if (
            userBalance.sittingBalance +
                _mulDiv(userBalance.lentBalance, exchangeRate, WAD) <
            amount
        ) {
            revert UniversalBalance__InsufficientBalance();
        }

        if (userBalance.sittingBalance > 0) {
            pointerAmount = userBalance.sittingBalance < amount
                ? userBalance.sittingBalance
                : amount;
            // Reduce user sitting balance.
            userBalances[user].sittingBalance -= pointerAmount;
            remainingAmount -= pointerAmount;
        }

        // Check if lent balance needs to be utilized.
        // Will natively fail if utilization is at 100%.
        if (remainingAmount > 0) {
            pointerAmount = FixedPointMathLib.mulDivUp(
                remainingAmount,
                WAD,
                exchangeRate
            );
            // Reduce user lent balance.
            userBalances[user].lentBalance -= pointerAmount;

            pointerAmount = linkedEToken.redeem(pointerAmount);
            // Make sure enough was redeemed.
            if (pointerAmount < remainingAmount) {
                revert UniversalBalance__SlippageError();
            }
        }

        // Transfer the wrapped native tokens to the Oracle Adaptor for use
        // in updating oracle feed.
        SafeTransferLib.safeTransfer(underlying, msg.sender, amount);
    }
}
