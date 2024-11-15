// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

abstract contract LiquidationManager {
    error InvalidLiquidator();
    error OEVDisabled();

    event AccountLiquidationQueued(
        address indexed account,
        address indexed liquidator
    );
    event BadDebtLiquidationQueued(
        address indexed account,
        address indexed liquidator,
        address indexed eToken
    );

    struct LiqQueue {
        uint64 priorityStartline;
        uint64 regularStartline;
        uint64 endLine;
        uint64 nonce;
    }

    uint256 public constant REGULAR_HOLD_DURATION = 2_000_000; // 2 secs
    uint256 public constant PRIORITY_HOLD_DURATION = 1_000_000; // 1 sec
    uint256 public constant END_DURATION = 60_000_000; // 60 secs

    // Allows owner to turn on/off OEV functionality
    bool public activeOEV = false;

    mapping(bytes32 => LiqQueue) public regularQueue;
    mapping(bytes32 => uint256) public priorityAccess;
    mapping(address => bool) public liquidationBundlers;

    constructor() {
        liquidationBundlers[tx.origin] = true;
    }

    // On/Off switch for OEV auctions
    // TODO: Add a secure external function to add and remove liquidationBundler EOAs to the map
    function setOEV(bool changeOEV) external {
        if (!_isValidOEV()) {
            revert InvalidLiquidator();
        }
        activeOEV = changeOEV;
    }

    function addBundler(address newBundler) external {
        if (!_isValidOEV()) {
            revert InvalidLiquidator();
        }
        liquidationBundlers[newBundler] = true;
    }

    // This function queues up an account for future liquidation and puts the liquidator in the priority queue.
    // NOTE: We assume this is inside funcs that also handle the liquidation validation
    function _queueLiquidation(
        address account,
        address liquidator,
        bool badDebtBool
    ) internal {
        //                                          eToken    Full Account
        address liquidationTarget = badDebtBool ? msg.sender : address();
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

        emit badDebtBool
            ? BadDebtLiquidationQueued(account, liquidator, msg.sender)
            : AccountLiquidationQueued(account, liquidator);
    }

    // This function validates a liquidation that's in progress
    function _validateLiquidation(
        address liquidator,
        address account,
        bool badDebtBool
    ) internal {
        // Case: OEV is turned off by owner so allow liquidation without queue validation
        if (!activeOEV) {
            return;
        }
        // Case: Being called from SolverOp within Atlas tx so allow any liquidations without queue validation
        if (_isValidOEV()) {
            return;
        }
        // Case: OEV is turned on but not an Atlas tx so validate the queue
        else {
            address liquidationTarget = badDebtBool ? msg.sender : address();
            bytes32 queueKey = keccak256(
                abi.encodePacked(account, liquidationTarget)
            );
            LiqQueue memory liqQueue = regularQueue[queueKey];
            // CASE: Not eligible for liquidation yet or previous liquidation window has passed
            if (liqQueue.nonce == 0 || liqQueue.endLine < block.timestamp) {
                revert InvalidLiquidator(); // NOTE: If we haven't reached the priorityStartline then there's no way we're at regularStartline
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
                revert InvalidLiquidator();
            }
        }
    }

    function _isValidOEV() internal view returns (bool isValidOEV) {
        isValidOEV = liquidationBundlers[tx.origin];
    }
}
