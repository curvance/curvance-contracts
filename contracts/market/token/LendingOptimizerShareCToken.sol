// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BorrowableCToken, ICentralRegistry, IERC20} from "contracts/market/token/BorrowableCToken.sol";

import {ERC165Checker} from "contracts/libraries/external/ERC165Checker.sol";
import {ILendingOptimizer} from "contracts/interfaces/ILendingOptimizer.sol";
import {IPositionManager} from "contracts/interfaces/IPositionManager.sol";

/// @title Curvance Lending Optimizer Share CToken.
/// @notice CToken wrapper for LendingOptimizer vault shares.
/// @dev This wrapper intentionally accrues the wrapped optimizer anywhere the
///      base cToken lifecycle already requires fresh accounting: deposits,
///      redeems, transfer checks, snapshots, and exchange-rate updates.
contract LendingOptimizerShareCToken is BorrowableCToken {
    /// ERRORS ///

    error LendingOptimizerShareCToken__InvalidOptimizer();
    error LendingOptimizerShareCToken__BorrowDisabled();

    /// CONSTRUCTOR ///

    /// @param cr The address of the Protocol Central Registry.
    /// @param optimizer The LendingOptimizer share token to list.
    /// @param mm The MarketManager which manages this cToken.
    /// @param IRM The interest rate model for inherited borrowable accounting.
    constructor(ICentralRegistry cr, ILendingOptimizer optimizer, address mm, address IRM)
        BorrowableCToken(cr, IERC20(address(optimizer)), mm, IRM)
    {
        if (
            !ERC165Checker.supportsInterface(address(optimizer), type(ILendingOptimizer).interfaceId)
                || address(optimizer.centralRegistry()) != address(cr)
                || optimizer.asset() == address(0) || optimizer.numApprovedMarkets() == 0
        ) {
            revert LendingOptimizerShareCToken__InvalidOptimizer();
        }
    }

    /// PUBLIC FUNCTIONS ///

    /// @notice Optimizer share wrapper markets cannot issue debt.
    function borrow(uint256, address) external pure override {
        revert LendingOptimizerShareCToken__BorrowDisabled();
    }

    /// @notice Optimizer share wrapper markets cannot issue delegated debt.
    function borrowFor(uint256, address, address) external pure override {
        revert LendingOptimizerShareCToken__BorrowDisabled();
    }

    /// @notice Optimizer share wrapper markets cannot issue position-manager debt.
    function borrowForPositionManager(uint256, address, IPositionManager.LeverageAction memory) external pure override {
        revert LendingOptimizerShareCToken__BorrowDisabled();
    }

    /// @notice Optimizer share wrapper markets cannot flashloan optimizer shares.
    function flashLoan(uint256, bytes calldata) external pure override {
        revert LendingOptimizerShareCToken__BorrowDisabled();
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Accrues the wrapped LendingOptimizer before cToken accounting.
    function _accrueIfNeeded() internal override {
        ILendingOptimizer(address(_asset)).accrueIfNeeded();
        super._accrueIfNeeded();
    }
}
