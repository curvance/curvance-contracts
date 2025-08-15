// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @title Curvance Liquidation Manager.
/// @notice Triages and configures uniquely sequenced market liquidations.
/// @dev NOTE: Only use this as an abstract contract as no account or market
///            data is written here.
///
/// This contract manages Curvance's liquidation queue system, enabling efficient
/// capture of Optimal Extractable Value (OEV) while ensuring liquidations
/// always proceed in a timely manner.
///
/// Key features:
///  - Implements a multi-phase liquidation queue with configurable durations:
///    1. Priority phase (priority liquidators only): priorityDuration seconds
///    2. Regular phase (any liquidator): regularDuration seconds
///    3. End phase (queue reset period): endDuration seconds
///  
///  - Supports Atlas OEV integration allowing:
///    - Approved bundlers to bypass the queue system entirely
///    - Immediate execution of winning liquidation bids from auctions
///    - Fallback to normal queue-based liquidations when OEV fails
///
///  - Differentiates between two liquidation types:
///    - Token-specific liquidations (for individual collateral positions)
///    - Full account liquidations (for accounts with bad debt)
///  
///  - Uses a nonce system to:
///    - Uniquely identify each liquidation cycle for an account
///    - Prevent exploitation of old liquidation permissions
///    - Enable sequential liquidations of the same account
///  
///  - Provides granular control via:
///    - specificSequencingActive toggle to enable/disable the entire OEV system
///    - Configurable time windows for each liquidation phase
///    - Priority access mapping for liquidators who queued liquidations
///
/// The contract's functions coordinate with MarketManager to ensure
/// all liquidations are properly validated, sequenced, and executed
/// according to protocol rules.
/// 
abstract contract LiquidationManager {
    /// TYPES ///

    /// @title Liquidation Queue
    /// @notice Liquidation queue struct for a specific liquidation target when
    ///                     liquidation auction is disabled or passed.
    /// @param prioritStartLine The timestamp where liquidators with 
    ///                     priority access can start liquidation.
    /// @param regularStartLine The timestamp where any liquidator can 
    ///                     start liquidation.
    /// @param endLine The timestamp where the liquidation window ends.
    /// @param nonce The nonce uniquely identifies each liquidation event for 
    ///                     an account, preventing reuse of old liquidations 
    ///                     and ensuring correct sequencing in the liquidation
    ///                     queue.
    struct LiqQueue {
        uint64 priorityStartline;
        uint64 regularStartline;
        uint64 endLine;
        uint64 nonce;
    }

    /// STORAGE ///

    /// @notice Duration that a normal liquidation must wait for auction end.
    /// @dev 2 = 2 seconds.
    uint256 public regularDuration = 3;
    /// @notice Duration that a queued liquidation must wait for auction end.
    /// @dev 1 = 1 second.
    uint256 public priorityDuration = 1;
    /// @notice Duration that a new auction must wait after a prior auction
    ///         concluded.
    /// @dev 30 = 30 seconds.
    uint256 public endDuration = 30;

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

    event DurationUpdated(string durationType, uint256 newValue);

    /// ERRORS ///
    error LiquidationManager__InvalidLiquidator();

    /// CONSTRUCTOR ///
    constructor() {}

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
                block.timestamp + priorityDuration
            );
            liqQueue.regularStartline = uint64(
                block.timestamp + regularDuration
            );
            liqQueue.endLine = uint64(block.timestamp + endDuration);
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
        ] = block.timestamp + priorityDuration;

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
        if (_checkAtlasOevAllowed()) {
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

    /// @notice Updates regular duration.
    /// @dev NOTE: This function MUST be called inside an external or public
    ///            function triggered by a call from the Central Registry.
    function _setRegularDuration(uint256 _duration) internal {
        require(
            priorityDuration < _duration,
            "Regular duration must be greater than priority duration"
        );
        require(
            _duration < endDuration,
            "Regular duration must be less than end duration"
        );

        regularDuration = _duration;
        emit DurationUpdated("RegularDuration", _duration);
    }

    /// @notice Updates priority duration.
    /// @dev NOTE: This function MUST be called inside an external or public
    ///            function triggered by a call from the Central Registry.
    function _setPriorityDuration(uint256 _duration) internal {
        require(
            _duration < regularDuration,
            "Priority duration must be less than regular duration"
        );

        priorityDuration = _duration;
        emit DurationUpdated("PriorityDuration", _duration);
    }

    /// @notice Updates end duration.
    /// @dev NOTE: This function MUST be called inside an external or public
    ///            function triggered by a call from the Central Registry.
    function _setEndDuration(uint256 _duration) internal {
        require(
            regularDuration < _duration,
            "End duration must be greater than regular duration"
        );

        endDuration = _duration;
        emit DurationUpdated("EndDuration", _duration);
    }

    /// @notice Checks whether OEV is enabled or not.
    /// @dev MUST be overridden in `MarketManager`.
    /// @return Whether OEV is enabled.
    function _checkAtlasOevAllowed() internal view virtual returns (bool);
}
