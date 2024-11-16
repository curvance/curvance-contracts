// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

abstract contract LiquidationManager {
    /// TYPES ///
    struct LiqQueue {
        uint64 priorityStartline;
        uint64 regularStartline;
        uint64 endLine;
        uint64 nonce;
    }

    /// CONSTANTS ///

    uint256 public constant REGULAR_HOLD_DURATION = 2; // 2 secs
    uint256 public constant PRIORITY_HOLD_DURATION = 1; // 1 sec
    uint256 public constant END_DURATION = 30; // 60 secs

    /// STORAGE ///

    // Indicates whether specific sequencing is active in the
    // liquidation system.
    bool public specificSequencingActive;

    mapping(bytes32 => LiqQueue) public regularQueue;
    mapping(bytes32 => uint256) public priorityAccess;
    mapping(address => bool) public liquidationBundlers;

    /// EVENTS ///

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
    error LiquidationManager__OEVDisabled();

    /// CONSTRUCTOR ///
  
    constructor() {
        liquidationBundlers[tx.origin] = true;
    }

    /// EXTERNAL FUNCTIONS ///

    // On/Off switch for OEV auctions
    // TODO: Add a secure external function to add and remove liquidationBundler EOAs to the map
    function setOEV(bool changeOEV) external {
        if (!_checkLiquidationBundler()) {
            revert LiquidationManager__InvalidLiquidator();
        }
        specificSequencingActive = changeOEV;
    }

    function addBundler(address newBundler) external {
        if (!_checkLiquidationBundler()) {
            revert LiquidationManager__InvalidLiquidator();
        }
        liquidationBundlers[newBundler] = true;
    }

    /// INTERNAL FUNCTIONS ///

    // This function queues up an account for future liquidation and puts the liquidator in the priority queue.
    // NOTE: We assume this is inside funcs that also handle the liquidation validation
    function _queueLiquidation(
        address account,
        address liquidator,
        bool tokenLiquidation
    ) internal {
        //                                          eToken    Full Account.
        address liquidationTarget = tokenLiquidation ? msg.sender : address();
        LiqQueue memory liqQueue = regularQueue[
            keccak256(abi.encodePacked(account, liquidationTarget))
        ];
        // CASE: Previous liquidation window expired or this is account's first liquidation so increment the nonce of the account
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

        emit tokenLiquidation
            ? LiquidationQueued(account, liquidator, msg.sender)
            : AccountLiquidationQueued(account, liquidator);
    }

    // This function validates a liquidation that's in progress
    function _validateLiquidation(
        address liquidator,
        address account,
        bool tokenLiquidation
    ) internal {
        // Case: OEV is turned off by owner so allow liquidation without queue validation
        if (!specificSequencingActive) {
            return;
        }
        // Case: Being called from SolverOp within Atlas tx so allow any liquidations without queue validation
        if (_checkLiquidationBundler()) {
            return;
        }
        // Case: OEV is turned on but not an Atlas tx so validate the queue
        else {
            address liquidationTarget = tokenLiquidation ? msg.sender : address();
            bytes32 queueKey = keccak256(
                abi.encodePacked(account, liquidationTarget)
            );
            LiqQueue memory liqQueue = regularQueue[queueKey];

            // CASE: Not eligible for liquidation yet or previous liquidation window has passed
            if (liqQueue.nonce == 0 || liqQueue.endLine < block.timestamp) {
                // NOTE: If we haven't reached the priorityStartline then there's no way we're at regularStartline
                revert LiquidationManager__InvalidLiquidator();
            }
            // CASE: Liquidation is neither available to anyone, nor does the liquidator have priority access
            if (
                uint256(liqQueue.regularStartline) > block.timestamp &&
                priorityAccess[
                    keccak256(
                        abi.encodePacked(
                            account,
                            liquidator,
                            liqQueue.nonce,
                            liquidationTarget
                        )
                    )
                ] >
                block.timestamp
            ) {
                revert LiquidationManager__InvalidLiquidator();
            }
        }
    }

    function _checkLiquidationBundler() internal view returns (bool) {
        return liquidationBundlers[tx.origin];
    }
}
