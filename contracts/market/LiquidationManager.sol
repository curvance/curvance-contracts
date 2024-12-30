// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

/// @title Curvance Liquidation Manager.
/// @notice Triages and configures uniquely sequenced market liquidations.
/// @dev NOTE: Only use this as an abstract contract as no account or market
///            data is written here.
abstract contract LiquidationManager {
    /// TYPES ///
    struct LiqQueue {
        uint64 priorityStartline;
        uint64 regularStartline;
        uint64 endLine;
        uint64 nonce;
    }

    /// CONSTANTS ///
    /// @notice Curvance DAO hub address.
    address public immutable centralRegistryAddress;
    /// @notice Duration that a normal liquidation must wait for auction end.
    /// @dev 2 = 2 seconds.
    uint256 public constant REGULAR_HOLD_DURATION = 2;
    /// @notice Duration that a queued liquidation must wait for auction end.
    /// @dev 1 = 1 second.
    uint256 public constant PRIORITY_HOLD_DURATION = 1;
    /// @notice Duration that a new auction must wait after a prior auction
    ///         concluded.
    /// @dev 30 = 30 seconds.
    uint256 public constant END_DURATION = 30;

    /// STORAGE ///

    // Indicates whether specific sequencing is active in the
    // liquidation system.
    bool public specificSequencingActive;

    mapping(bytes32 => LiqQueue) public regularQueue;
    mapping(bytes32 => uint256) public priorityAccess;

    /// EVENTS ///

    event SpecificSequencingStatusChanged(bool sequencingActive);

    event AccountLiquidationQueued(
        address indexed account,
        address indexed liquidator
    );

    event LiquidationQueued(
        address indexed account,
        address indexed liquidator,
        address indexed eToken
    );

    /// ERRORS ///
    error LiquidationManager__InvalidLiquidator();

    /// CONSTRUCTOR ///
    constructor(address _centralRegistryAddress) {
        centralRegistryAddress = _centralRegistryAddress;
    }

    /// INTERNAL FUNCTIONS ///

    // @notice Queues up `account` for future liquidation and puts the
    //         liquidator in the priority queue.
    // @dev This assumes _queueLiquidation is inside a function that handles
    //      the liquidation's validity.
    /// @param liquidator The account to execute the liquidation once queued.
    /// @param account The address of the account to be liquidated.
    /// @param tokenLiquidation Whether the liquidation is token
    ///                         specific (true) or a full account
    ///                         liquidation (false).
    function _queueLiquidation(
        address liquidator,
        address account,
        bool tokenLiquidation
    ) internal {
        //                                             eToken    Full Account.
        address liquidationTarget = tokenLiquidation ? msg.sender : address(0);
        LiqQueue memory liqQueue = regularQueue[
            keccak256(abi.encodePacked(account, liquidationTarget))
        ];

        // CASE: Previous liquidation window expired or this is account's
        //       first liquidation so increment the nonce of the account.
        if (liqQueue.endLine < block.timestamp || liqQueue.nonce == 0) {
            unchecked {
                ++liqQueue.nonce;
            }
            liqQueue.priorityStartline = uint64(
                block.timestamp + PRIORITY_HOLD_DURATION
            );
            liqQueue.regularStartline = uint64(
                block.timestamp + REGULAR_HOLD_DURATION
            );
            liqQueue.endLine = uint64(block.timestamp + END_DURATION);
            regularQueue[
                keccak256(abi.encodePacked(account, liquidationTarget))
            ] = liqQueue;
        }

        // Give the caller priority access at the current nonce
        priorityAccess[
            keccak256(
                abi.encodePacked(
                    account,
                    liquidator,
                    liqQueue.nonce,
                    liquidationTarget
                )
            )
        ] = block.timestamp + PRIORITY_HOLD_DURATION;

        // If the liquidation is token specific, make sure we emit the
        // LiquidationQueued event, otherwise emit AccountLiquidationQueued.
        if (tokenLiquidation) {
            emit LiquidationQueued(account, liquidator, msg.sender);
            return;
        }

        emit AccountLiquidationQueued(account, liquidator);
    }

    /// @notice Valides a liquidation currently in the process of execution.
    /// @param liquidator The account to execute the liquidation once queued.
    /// @param account The address of the account to be liquidated.
    /// @param tokenLiquidation Whether the liquidation is token
    ///                         specific (true) or a full account
    ///                         liquidation (false).
    function _validateLiquidation(
        address liquidator,
        address account,
        bool tokenLiquidation
    ) internal view {
        // CASE: OEV is turned off by owner so allow liquidation without
        //       queue validation.
        if (!specificSequencingActive) {
            return;
        }
        // CASE: Called from SolverOp within Atlas tx so allow liquidations
        //       without queue validation.
        if (ICentralRegistry(centralRegistryAddress).atlasOevAllowed()) {
            return;
        }

        // CASE: OEV is turned on but not an Atlas tx so validate the queue.
        address liquidationTarget = tokenLiquidation ? msg.sender : address(0);
        bytes32 queueKey = keccak256(
            abi.encodePacked(account, liquidationTarget)
        );
        LiqQueue memory liqQueue = regularQueue[queueKey];

        // CASE: Not eligible for liquidation yet or previous liquidation
        //       window has passed.
        if (liqQueue.nonce == 0 || liqQueue.endLine < block.timestamp) {
            revert LiquidationManager__InvalidLiquidator();
        }
        // CASE: Liquidation is neither available to anyone, nor does the
        //       liquidator have priority access.
        if (uint256(liqQueue.regularStartline) > block.timestamp) {
            uint256 priorityStartLine = priorityAccess[
                keccak256(
                    abi.encodePacked(
                        account,
                        liquidator,
                        liqQueue.nonce,
                        liquidationTarget
                    )
                )
            ];
            // The liqQueue.endLine < block.timestamp check earlier ensures
            // that verifying priorityStartLine != 0 also verifies that
            // priorityStartline > block.timestamp - END_DURATION
            if (
                priorityStartLine > block.timestamp || priorityStartLine == 0
            ) {
                revert LiquidationManager__InvalidLiquidator();
            }
        }
    }

    /// @notice Updates status of unique liquidation sequencing to
    ///         `sequencingActive`.
    /// @dev NOTE: This function MUST be called inside an external or public
    ///            function triggered by a call from the Central Registry.
    function _setSequencingStatus(bool sequencingActive) internal {
        specificSequencingActive = sequencingActive;

        emit SpecificSequencingStatusChanged(sequencingActive);
    }
}
