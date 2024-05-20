//SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { Delegable } from "contracts/libraries/Delegable.sol";
import { WAD } from "contracts/libraries/Constants.sol";
import { ReentrancyGuard } from "contracts/libraries/ReentrancyGuard.sol";
import { ERC165Checker } from "contracts/libraries/external/ERC165Checker.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";
import { FixedPointMathLib } from "contracts/libraries/FixedPointMathLib.sol";

import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IWETH } from "contracts/interfaces/IWETH.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IOracleRouter } from "contracts/interfaces/IOracleRouter.sol";
import { IMToken } from "contracts/interfaces/market/IMToken.sol";
import { IGaugePool } from "contracts/interfaces/IGaugePool.sol";

/// @title Curvance Universal Balance.
/// @notice A system for managing a Universal Balance within the Curvance Protocol.
contract UniversalBalance is Delegable, ReentrancyGuard {
    /// TYPES ///

    struct UserBalance {
        uint256 sittingBalance;
        uint256 lentBalance;
    }
    /// CONSTANTS ///

    /// @notice The address of the dToken linked to this contract.
    IMToken public immutable linkedDToken;

    /// @notice The address of WETH on this chain.
    address public immutable WETH;
    /// @dev `bytes4(keccak256(bytes("UniversalBalance__InvalidParameter()")))`.
    uint256 internal constant _INVALID_PARAMETER_SELECTOR = 0xc75f2a32;

    /// STORAGE ///

    /// @notice The next epoch index to claim for a user.
    /// @dev User => User's balance sitting and lent out.
    mapping(address => UserBalance) public userBalances;

    /// EVENTS ///

    /// @dev Emitted during a deposit call.
    event Deposit(
        address indexed by,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    /// @dev Emitted during a withdraw call.
    event Withdraw(
        address indexed by,
        address indexed to,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    /// ERRORS ///

    error UniversalBalance__InvalidCentralRegistry();
    error UniversalBalance__InsufficientBalance();
    error UniversalBalance__InvalidParameter();
    error UniversalBalance__Unauthorized();
    error UniversalBalance__SlippageError();

    receive() external payable {
        IWETH(WETH).deposit{ value: msg.value };
        _deposit(msg.value, true);
    }

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry centralRegistry_,
        address dToken,
        address WETH_
    ) Delegable(centralRegistry_) {
        if (
            !ERC165Checker.supportsInterface(
                address(centralRegistry_),
                type(ICentralRegistry).interfaceId
            )
        ) {
            revert UniversalBalance__InvalidCentralRegistry();
        }

        if (IMToken(dToken).isCToken()) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        linkedDToken = IMToken(dToken);
        WETH = WETH_;

        IERC20(WETH_).approve(dToken, type(uint256).max);
    }

    /// EXTERNAL FUNCTIONS ///

    function depositETH(bool isLent) external payable {
        IWETH(WETH).deposit{ value: msg.value }();
        _deposit(msg.value, isLent);
    }

    function depositWETH(uint256 amount, bool isLent) external {
        SafeTransferLib.safeTransferFrom(
            WETH,
            msg.sender,
            address(this),
            amount
        );
        _deposit(amount, isLent);
    }

    function withdrawAsETH(uint256 amount, bool isLent) external {
        amount = _withdraw(amount, isLent);
        SafeTransferLib.forceSafeTransferETH(msg.sender, amount);
    }

    function withdrawAsWETH(uint256 amount, bool isLent) external {
        amount = _withdraw(amount, isLent);
        SafeTransferLib.safeTransfer(WETH, msg.sender, amount);
    }

    function useBalanceForOracleUpdate(address user, uint256 amount) external {
        // Check for amount == 0 in oracle adaptor.
        if (
            !IOracleRouter(centralRegistry.oracleRouter()).isApprovedAdaptor(
                msg.sender
            )
        ) {
            revert UniversalBalance__Unauthorized();
        }

        UserBalance memory userBalance = userBalances[user];
        uint256 exchangeRate = linkedDToken.exchangeRateWithUpdate();
        uint256 pointerAmount;
        uint256 remainingAmount;

        if (
            userBalance.sittingBalance +
                _mulDiv(userBalance.lentBalance, WAD, exchangeRate) <=
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
            remainingAmount = amount - pointerAmount;
        }

        // Check if lent balance needs to be utilized.
        // Will natively fail if utilization is at 100%.
        if (remainingAmount > 0) {
            pointerAmount = _mulDiv(remainingAmount, WAD, exchangeRate);
            // Reduce user lent balance.
            userBalances[user].lentBalance -= pointerAmount;

            pointerAmount = linkedDToken.redeem(pointerAmount);
            // Make sure enough was redeemed.
            if (pointerAmount < remainingAmount) {
                revert UniversalBalance__SlippageError();
            }
        }

        // Transfer the WETH to Oracle Adaptor for use in updating oracle feed.
        SafeTransferLib.safeTransfer(WETH, msg.sender, amount);
    }

    /// @notice Claims pending gauge rewards from lent balance to the DAO.
    /// @dev This is allowed to be permissionless as there is no potential
    ///      to steal funds.
    function claimForDAO() external {
        IGaugePool gaugePool = linkedDToken.marketManager().gaugePool();
        address[] memory rewardTokens = gaugePool.getRewardTokens();

        uint256 numRewardTokens = rewardTokens.length;
        uint256[] memory previousBalances = new uint256[](numRewardTokens);

        for (uint256 i = 0; i < numRewardTokens; ++i) {
            previousBalances[i] = IERC20(rewardTokens[i]).balanceOf(
                address(this)
            );
        }

        gaugePool.claim(address(linkedDToken));
        address daoAddress = centralRegistry.daoAddress();

        // If the contract received rewards in a reward token, transfer them to the DAO.
        // We do a two step process in case a reward token matches a universal balance token.
        for (uint256 i = 0; i < numRewardTokens; ++i) {
            previousBalances[i] =
                IERC20(rewardTokens[i]).balanceOf(address(this)) -
                previousBalances[i];
            if (previousBalances[i] > 0) {
                SafeTransferLib.safeTransfer(
                    rewardTokens[i],
                    daoAddress,
                    previousBalances[i]
                );
            }
        }
    }

    /// INTERNAL FUNCTIONS ///

    function _deposit(uint256 amount, bool isLent) internal {
        if (isLent) {
            // Will natively fail if amount == 0 on gaugePool call.
            // Records balance in tokens (shares).
            uint256 tokensReceived = linkedDToken.mint(amount);
            userBalances[msg.sender].lentBalance += tokensReceived;
            emit Deposit(msg.sender, msg.sender, amount, tokensReceived);
            return;
        }

        if (amount == 0) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        userBalances[msg.sender].sittingBalance += amount;
        emit Deposit(msg.sender, msg.sender, amount, amount);
    }

    function _withdraw(
        uint256 amount,
        bool isLent
    ) internal returns (uint256) {
        if (isLent) {
            uint256 exchangeRate = linkedDToken.exchangeRateWithUpdate();
            // Will natively fail if amount == 0 on gaugePool call.
            // Records balance in tokens (shares).
            uint256 tokensToRedeem = _mulDiv(amount, WAD, exchangeRate);
            userBalances[msg.sender].lentBalance -= tokensToRedeem;

            uint256 tokensReceived = linkedDToken.redeem(tokensToRedeem);
            emit Withdraw(
                msg.sender,
                msg.sender,
                msg.sender,
                amount,
                tokensToRedeem
            );
            return tokensReceived;
        }

        if (amount == 0) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        userBalances[msg.sender].sittingBalance -= amount;
        emit Withdraw(msg.sender, msg.sender, msg.sender, amount, amount);
        return amount;
    }

    /// @dev Returns `floor(x * y / d)`.
    /// Reverts if `x * y` overflows, or `d` is zero.
    function _mulDiv(
        uint256 x,
        uint256 y,
        uint256 d
    ) internal pure returns (uint256) {
        return FixedPointMathLib.mulDiv(x, y, d);
    }

    /// @dev Internal helper for reverting efficiently.
    function _revert(uint256 s) internal pure {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x00, s)
            revert(0x1c, 0x04)
        }
    }
}
