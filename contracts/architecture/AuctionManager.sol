//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { DAppControl } from "@atlas/contracts/dapp/DAppControl.sol";
import { CallConfig } from "@atlas/contracts/types/ConfigTypes.sol";
import { UserOperation } from "@atlas/contracts/types/UserOperation.sol";
import { SolverOperation } from "@atlas/contracts/types/SolverOperation.sol";
import { IAtlas } from "@atlas/contracts/interfaces/IAtlas.sol";

import { CentralRegistryLib } from "contracts/libraries/CentralRegistryLib.sol";

import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IRedstoneProxy } from "contracts/interfaces/external/redstone/IRedstoneProxy.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";

/**
 * @title AuctionManager
 * @author Fastlane Labs
 * @notice Manages auctions for liquidations, and transient risk parameter updates in the Curvance protocol
 * @dev Uses the Atlas framework for handling of auction execution and solver ordering, applies risk parameter 
 * updates using Atlas preSolver hook, handles OEV distribution between relevant parties.
 * 
 * This contract is an Atlas DApp control, an app-specific Atlas module for liquidations auctions on Curvance;
 * enabling Curvance to implement application-specific ordering rules for liquidations using dynamic risk parameters.
 * The DappControl also functions as a whitelisted data feed updater for RedStone oracles in order to ensure seamless
 * priority access to liquidations. 
 */
contract AuctionManager is DAppControl {
    /// CONSTANTS ///

    /// @notice Scaling factor for OEV share calculations (100% = 10,000)
    uint256 public constant OEV_SHARE_SCALE = 10_000;
    
    /// @notice Close factor used for Atlas liquidations (20% = 2,000,000)
    uint256 public constant ATLAS_CLOSE_FACTOR = 2_000_000;
    
    /// @notice Immutable reference to Curvance central registry
    ICentralRegistry public immutable CENTRAL_REGISTRY;

    /// STORAGE ///

    /// DAPP CONTROL CONFIG
    /// @notice Maximum gas limit allowed for each solver operation.
    uint32 public solverGasLimit = 6_000_000;

    /// OEV ALLOCATION CONFIG
    /// @notice Share of OEV allocated to Fastlane (in basis points, where 10000 = 100%)
    uint256 public oevShareFastlane;

    /// @notice Address where Fastlane's OEV share is sent
    address public oevAllocationDestinationFastlane;
    
    /// @notice Address where Curvance OEV share is sent
    address public oevAllocationDestinationProtocol;

    /// ACCUMULATED OEV TRACKING
    /// @notice Total accumulated OEV waiting to be distributed
    uint256 public totalAccumulatedOEV;
    
    /// @notice Accumulated OEV allocated to Fastlane
    uint256 public accumulatedOEVFastlane;
    
    /// @notice Accumulated OEV allocated to the protocol
    uint256 public accumulatedOEVProtocol;

    /// VALIDATION OF AUCTIONEER/USER
    /// @notice Address authorized to sign Atlas user operations, held by Fastlane Labs
    address public authorizedUserOpSigner;
    
    /// @notice Authorized execution environment contract for Atlas operations
    address public authorizedExecutionEnv;

    // ORACLE CONFIGURATIONS
    /// @notice Number of whitelisted oracle addresses
    uint32 public whitelistedOraclesCount;
    
    /// @notice Mapping of oracle addresses to their whitelist status
    mapping(address oracle => bool isWhitelisted) public oracleWhitelist;

    /// @notice Number of allowed function selectors for oracle updates
    uint32 public allowedSelectorsCount;
    
    /// @notice Mapping of function selectors to their allowed status
    mapping(bytes4 selector => bool isAllowed) public allowedSelectors;

    /// EVENTS ///

    /**
     * @notice Emitted when OEV is distributed
     * @param totalOev Total OEV amount captured
     * @param oevFastlane Amount allocated to Fastlane
     * @param oevProtocol Amount allocated to the protocol
     */
    event CurvanceOevAllocated(
        uint256 totalOev, uint256 oevFastlane, uint256 oevProtocol
    );
    
    
    /**
     * @notice Emitted when Fastlane's OEV share is updated
     * @param oldFastlaneShare Previous Fastlane share percentage
     * @param newFastlaneShare New Fastlane share percentage
     */
    event OevShareFastlaneSet(uint256 oldFastlaneShare, uint256 newFastlaneShare);
    
    /**
     * @notice Emitted when Fastlane's allocation destination is updated
     * @param oldFastlaneDestination Previous destination address
     * @param newFastlaneDestination New destination address
     */
    event OevAllocationDestinationFastlaneSet(address oldFastlaneDestination, address newFastlaneDestination);
    
    /**
     * @notice Emitted when protocol's allocation destination is updated
     * @param oldProtocolDestination Previous destination address
     * @param newProtocolDestination New destination address
     */
    event OevAllocationDestinationProtocolSet(address oldProtocolDestination, address newProtocolDestination);
    
    /**
     * @notice Emitted when the solver gas limit is updated
     * @param oldSolverGasLimit Previous gas limit
     * @param newSolverGasLimit New gas limit
     */
    event SolverGasLimitSet(uint32 oldSolverGasLimit, uint32 newSolverGasLimit);
    
    /**
     * @notice Emitted when the authorized user operation signer is updated
     * @param oldAuthorizedUserOpSigner Previous authorized signer
     * @param newAuthorizedUserOpSigner New authorized signer
     */
    event AuthorizedUserOpSignerSet(address oldAuthorizedUserOpSigner, address newAuthorizedUserOpSigner);
    
    /**
     * @notice Emitted when an oracle's whitelist status is updated
     * @param oracle Address of the oracle
     * @param isWhitelisted New whitelist status
     */
    event OracleWhitelistUpdated(address indexed oracle, bool isWhitelisted);
    
    /**
     * @notice Emitted when a function selector's allowed status is updated
     * @param selector Function selector being updated
     * @param isWhitelisted New allowed status
     */
    event AllowedSelectorWhitelistUpdated(bytes4 indexed selector, bool isWhitelisted);
    
    /**
     * @notice Emitted when accumulated OEV is distributed
     * @param oevFastlane Amount distributed to Fastlane
     * @param oevProtocol Amount distributed to the protocol
     * @param fastlaneDestination Address where Fastlane's OEV was sent
     * @param protocolDestination Address where protocol's OEV was sent
     */
    event AccumulatedOEVDistributed(
        uint256 oevFastlane, 
        uint256 oevProtocol, 
        address fastlaneDestination, 
        address protocolDestination
    );

    /// ERRORS /// 

    // DAPP CONTROL/ATLAS VALIDATION ERRORS
    /// @notice Thrown when a non-governance address attempts a governance action
    error OnlyGovernance();
    
    /// @notice Thrown when user operation is signed from an unauthorized address
    error InvalidUserOpFrom();
    
    /// @notice Thrown when user operation targets incorrect DAppControl
    error InvalidUserOpDapp();
    
    /// @notice Thrown when execution environment calling a hook is invalid. 
    error InvalidExecutionEnv();

    // OEV ALLOCATION ERRORS
    /// @notice Thrown when OEV shares exceed 100%
    error InvalidOevShare();
    
    /// @notice Thrown when OEV allocation destination is zero address
    error InvalidOevAllocationDestination();

    // ORACLE RELATED ERRORS
    /// @notice Thrown when non-whitelisted oracle is used
    error OnlyWhitelistedOracleAllowed();
    
    /// @notice Thrown when oracle update call fails
    error OracleUpdateFailed();
    
    /// @notice Thrown when using non-allowed function selector
    error InvalidSelector();

    // SOLVER ERRORS
    /// @notice Thrown when solver operation data is malformed
    error MalformedSolverOperation();
    
    /// @notice Thrown when market manager is not registered
    error InvalidMarketManager();

    /// CONSTRUCTOR /// 

    /**
     * @notice Initializes the AuctionManager with Atlas, central registry, and OEV allocation configurations.
     * @param atlas Address of the Atlas contract
     * @param centralRegistry_ Address of the Curvance central registry
     * @param oevShareFastlane_ Initial OEV share for Fastlane (in basis points)
     * @param oevAllocationDestinationFastlane_ Address to receive Fastlane's OEV share
     * @param oevAllocationDestinationProtocol_ Address to receive protocol's OEV share
     * @dev oevShareFastlane_ must not exceed OEV_SHARE_SCALE (10,000)
     * @dev Configures Atlas CallConfig with the following key settings:
     * - requirePreOps: true - Enables pre-operation hook for oracle updates and auctioneer validation
     * - requirePreSolver: true - Enables pre-solver hook for dynamic risk parameter updates and collateral unlocking
     * - zeroSolvers: false - Allows oracle updates without solvers (no OEV capture)
     * - userAuctioneer: false - Restricts auctioneers to those whitelisted via AtlasVerification
     * - requireFulfillment: false - Ensures oracle updates proceed even if all solvers fail
     * - multipleSuccessfulSolvers: true - Enables app-specific ordering rules for parallel solver execution
     */
    constructor(
        address atlas,
        ICentralRegistry centralRegistry_,
        uint256 oevShareFastlane_,
        address oevAllocationDestinationFastlane_,
        address oevAllocationDestinationProtocol_
    )
        DAppControl(
            atlas,
            msg.sender,
            CallConfig({
                userNoncesSequential: false,
                dappNoncesSequential: false,
                requirePreOps: true,
                trackPreOpsReturnData: false,
                trackUserReturnData: false,
                delegateUser: false,
                requirePreSolver: true,
                requirePostSolver: false,
                zeroSolvers: false,
                reuseUserOp: true,
                userAuctioneer: false,
                solverAuctioneer: false,
                unknownAuctioneer: false,
                verifyCallChainHash: true,
                forwardReturnData: false,
                requireFulfillment: false,
                trustedOpHash: false,
                invertBidValue: false,
                exPostBids: false,
                multipleSuccessfulSolvers: true,
                checkMetacallGasLimit: false
            })
        )
    {
        CentralRegistryLib._isCentralRegistry(centralRegistry_);

        // Configure OEV allocation.
        if (oevShareFastlane_ > OEV_SHARE_SCALE) revert InvalidOevShare();
        if (oevAllocationDestinationFastlane_ == address(0)) revert InvalidOevAllocationDestination();
        if (oevAllocationDestinationProtocol_ == address(0)) revert InvalidOevAllocationDestination();
        oevShareFastlane = oevShareFastlane_;
        oevAllocationDestinationFastlane = oevAllocationDestinationFastlane_;
        oevAllocationDestinationProtocol = oevAllocationDestinationProtocol_;

        // Set `CENTRAL_REGISTRY`.
        CENTRAL_REGISTRY = centralRegistry_;

        // Set Oracle related configurations.
        allowedSelectors[IRedstoneProxy.updateDataFeedsValues.selector] = true;
        allowedSelectors[IRedstoneProxy.updateDataFeedsValuesPartial.selector] = true;
        allowedSelectorsCount = 2;

        emit OevShareFastlaneSet(0, oevShareFastlane_);
        emit OevAllocationDestinationFastlaneSet(address(0), oevAllocationDestinationFastlane_);
        emit OevAllocationDestinationProtocolSet(address(0), oevAllocationDestinationProtocol_);
        emit AllowedSelectorWhitelistUpdated(IRedstoneProxy.updateDataFeedsValues.selector, true);
        emit AllowedSelectorWhitelistUpdated(IRedstoneProxy.updateDataFeedsValuesPartial.selector, true);
    }

    // ---------------------------------------------------- //
    //                   Custom Functions                   //
    // ---------------------------------------------------- //

    /**
     * @notice Restricts function access to governance address only
     */
    modifier onlyGov() {
        if (msg.sender != governance) revert OnlyGovernance();
        _;
    }

    /// SETTERS FOR OEV ALLOCATION CONFIG
    
    /**
     * @notice Updates Fastlane's share of OEV
     * @param oevShareFastlane_ New Fastlane share in basis points (max 10,000)
     * @dev Cannot exceed OEV_SHARE_SCALE
     */
    function setOevShareFastlane(uint256 oevShareFastlane_) external onlyGov {
        if (oevShareFastlane_ > OEV_SHARE_SCALE) revert InvalidOevShare();
        uint256 old = oevShareFastlane;
        oevShareFastlane = oevShareFastlane_;
        emit OevShareFastlaneSet(old, oevShareFastlane_);
    }

    /**
     * @notice Updates the destination address for Fastlane's OEV share
     * @param oevAllocationDestinationFastlane_ New destination address for Fastlane OEV
     * @dev Cannot be set to zero address
     */
    function setOevAllocationDestinationFastlane(address oevAllocationDestinationFastlane_) external onlyGov {
        if (oevAllocationDestinationFastlane_ == address(0)) revert InvalidOevAllocationDestination();
        address old = oevAllocationDestinationFastlane;
        oevAllocationDestinationFastlane = oevAllocationDestinationFastlane_;
        emit OevAllocationDestinationFastlaneSet(old, oevAllocationDestinationFastlane_);
    }

    /**
     * @notice Updates the destination address for protocol's OEV share
     * @param oevAllocationDestinationProtocol_ New destination address for protocol OEV
     * @dev Cannot be set to zero address
     */
    function setOevAllocationDestinationProtocol(address oevAllocationDestinationProtocol_) external onlyGov {
        if (oevAllocationDestinationProtocol_ == address(0)) revert InvalidOevAllocationDestination();
        address old = oevAllocationDestinationProtocol;
        oevAllocationDestinationProtocol = oevAllocationDestinationProtocol_;
        emit OevAllocationDestinationProtocolSet(old, oevAllocationDestinationProtocol_);
    }

    /**
     * @notice Distributes accumulated OEV to Fastlane and protocol destinations
     * @dev Only callable by governance
     * @dev Transfers all accumulated OEV to configured destinations and resets counters
     */
    function distributeAccumulatedOEV() external onlyGov {
        uint256 fastlaneAmount = accumulatedOEVFastlane;
        uint256 protocolAmount = accumulatedOEVProtocol;
        
        // Transfer accumulated OEV to destinations
        if (fastlaneAmount > 0) {
            SafeTransferLib.safeTransferETH(oevAllocationDestinationFastlane, fastlaneAmount);
        }
        if (protocolAmount > 0) {
            SafeTransferLib.safeTransferETH(oevAllocationDestinationProtocol, protocolAmount);
        }

        // Reset accumulated amounts
        totalAccumulatedOEV = 0;
        accumulatedOEVFastlane = 0;
        accumulatedOEVProtocol = 0;
        
        emit AccumulatedOEVDistributed(
            fastlaneAmount, 
            protocolAmount, 
            oevAllocationDestinationFastlane, 
            oevAllocationDestinationProtocol
        );
    }

    /// SETTER FOR DAPP CONTROL CONFIGURATION
    
    /**
     * @notice Updates the gas limit for each solver operation
     * @param solverGasLimit_ New gas limit for solvers
     */
    function setSolverGasLimit(uint32 solverGasLimit_) external onlyGov {
        uint32 old = solverGasLimit;
        solverGasLimit = solverGasLimit_;
        emit SolverGasLimitSet(old, solverGasLimit_);
    }

    /// SET AUCTIONEER/USER VALIDATION
    
    /**
     * @notice Sets the authorized signer for user operations
     * @param authorizedUserOpSigner_ Address authorized to sign user operations
     * @dev This function must be called immediately after deployment to initialize the authorizedExecutionEnv
     */
    function setAuthorizedUserOpSigner(address authorizedUserOpSigner_) external onlyGov {
        address old = authorizedUserOpSigner;
        authorizedUserOpSigner = authorizedUserOpSigner_;
        _updateAuthorizedExecutionEnv(authorizedUserOpSigner_);
        emit AuthorizedUserOpSignerSet(old, authorizedUserOpSigner_);
    }

    /**
     * @notice Extracts bid parameters from solver operation data
     * @param solverOpData Raw solver operation data
     * @return penaltyBid The liquidation penalty bid amount
     * @return collateralBid Address of the collateral token being bid on
     * @return marketBid Address of the market where liquidation occurs
     * @dev Expects the last 96 bytes of solverOpData to contain bid information
     */
    function _getBidParamsFromSolverOpData(bytes calldata solverOpData)
        internal
        pure
        returns (uint256 penaltyBid, address collateralBid, address marketBid)
    {
        if (solverOpData.length < 96) revert MalformedSolverOperation();

        // Isolate the bid data - the last 96 bytes of the solverOpData
        bytes memory bidData = solverOpData[solverOpData.length - 96:];

        // Decode the tail bid data into (penaltyBid, collateralBid, marketBid)
        (penaltyBid, collateralBid, marketBid) = abi.decode(bidData, (uint256, address, address));
    }

    // ---------------------------------------------------- //
    //               Oracle Related Functions               //
    // ---------------------------------------------------- //

    /**
     * @notice Verifies if an oracle is whitelisted
     * @param oracle Address of the oracle to verify
     * @dev Whitelisting is enforced only if the whitelist is not empty
     */
    function verifyOracleWhitelist(address oracle) external view {
        if (whitelistedOraclesCount > 0 && !oracleWhitelist[oracle]) revert OnlyWhitelistedOracleAllowed();
    }

    /**
     * @notice Adds an oracle to the whitelist
     * @param oracle Address of the oracle to whitelist
     * @dev Only callable by governance
     */
    function addOracleToWhitelist(address oracle) external onlyGov {
        if (!oracleWhitelist[oracle]) {
            oracleWhitelist[oracle] = true;
            whitelistedOraclesCount++;
            emit OracleWhitelistUpdated(oracle, true);
        }
    }

    /**
     * @notice Removes an oracle from the whitelist
     * @param oracle Address of the oracle to remove
     * @dev Only callable by governance
     */
    function removeOracleFromWhitelist(address oracle) external onlyGov {
        if (oracleWhitelist[oracle]) {
            oracleWhitelist[oracle] = false;
            whitelistedOraclesCount--;
            emit OracleWhitelistUpdated(oracle, false);
        }
    }

    /**
     * @notice Verifies if a function selector is allowed for oracle updates
     * @param selector Function selector to verify
     * @dev Whitelisting is enforced only if the whitelist is not empty
     */
    function verifyAllowedSelector(bytes4 selector) external view {
        if (allowedSelectorsCount > 0 && !allowedSelectors[selector]) revert InvalidSelector();
    }

    /**
     * @notice Adds a function selector to the allowed list
     * @param selector Function selector to allow
     * @dev Only callable by governance
     */
    function addAllowedSelector(bytes4 selector) external onlyGov {
        if (!allowedSelectors[selector]) {
            allowedSelectors[selector] = true;
            allowedSelectorsCount++;
            emit AllowedSelectorWhitelistUpdated(selector, true);
        }
    }

    /**
     * @notice Removes a function selector from the allowed list
     * @param selector Function selector to remove
     * @dev Only callable by governance
     */
    function removeAllowedSelector(bytes4 selector) external onlyGov {
        if (allowedSelectors[selector]) {
            allowedSelectors[selector] = false;
            allowedSelectorsCount--;
            emit AllowedSelectorWhitelistUpdated(selector, false);
        }
    }

    // ---------------------------------------------------- //
    //                  Atlas Hook Overrides                //
    // ---------------------------------------------------- //

    /**
     * @notice Pre-operation hook called before user operations are executed
     * @param userOp The user operation to validate and process
     * @return Empty bytes as return data
     * @dev This function is delegatecalled from the Atlas execution environment
     * @dev Validates the user operation and optionally triggers oracle updates
     */
    function _preOpsCall(UserOperation calldata userOp) internal override returns (bytes memory) {
        // The userOp dapp must be this control
        if (userOp.dapp != CONTROL) revert InvalidUserOpDapp();
        // The user must be the authorized user op signer
        if (userOp.from != AuctionManager(CONTROL).authorizedUserOpSigner()) revert InvalidUserOpFrom();

        // If the userOp contains a RedStone feed update perform it
        if (bytes4(userOp.data) == bytes4(AuctionManager.update.selector)) {
            (address _oracle, bytes memory _updateCallData) = abi.decode(userOp.data[4:], (address, bytes));

            // The called oracle must be whitelisted
            AuctionManager(CONTROL).verifyOracleWhitelist(_oracle);

            // The update call data must be a valid function call
            AuctionManager(CONTROL).verifyAllowedSelector(bytes4(_updateCallData));
        }

        // Else if UserOp does not contain a RedStone update, continue as no-op UserOp
        // This case is for liquidations triggered by interest accrual, not the oracle

        // Return empty bytes
        return "";
    }

    /**
     * @notice Pre-solver hook called before each solver operations is executed
     * @param solverOp The solver operation containing bid parameters
     * @dev Called via delegatecall from the Atlas execution environment
     * @dev Extracts bid parameters, unlocks relevant market and collateral, and updates risk parameters
     */
    function _preSolverCall(SolverOperation calldata solverOp, bytes calldata) internal override {
        (uint256 newPenalty, address collateralBid, address marketBid) = _getBidParamsFromSolverOpData(solverOp.data);
        AuctionManager(CONTROL).preSolverSetup(marketBid, collateralBid, newPenalty);
    }

    /**
     * @notice Accumulates OEV for later distribution according to configured shares
     * @param bidAmount The total OEV amount to accumulate
     * @dev This function is delegatecalled from the Atlas execution environment
     * @dev Accumulates ETH internally to be distributed later by governance
     */
    function _allocateValueCall(bool, address, uint256 bidAmount, bytes calldata) internal virtual override {
        if (bidAmount == 0) return;

        // Since this is delegatecalled, we need to call back to the control contract
        // to update storage variables
        AuctionManager(CONTROL).accumulateOEV(bidAmount);
    }

    // ---------------------------------------------------- //
    //                    UserOp Function Option 1          //
    // ---------------------------------------------------- //

    /**
     * @notice Updates oracle price feeds with new values
     * @param oracle Address of the oracle contract to update
     * @param callData Encoded function call to execute on the oracle
     * @dev Only callable by the authorized execution environment
     * @dev Oracle and selector validation occurs in _preOpsCall
     */
    function update(address oracle, bytes calldata callData) external {
        if (msg.sender != authorizedExecutionEnv) revert InvalidExecutionEnv();

        // Parameters have already been validated in _preOpsCall
        (bool success,) = oracle.call(callData);
        if (!success) revert OracleUpdateFailed();
    }

    // ---------------------------------------------------- //
    //                    UserOp Function Option 2          //
    // ---------------------------------------------------- //
    /**
     * @notice Initiates an OEV auction without updating oracle feeds
     * @dev Intentionally empty
     * @dev Used for liquidations triggered by interest accrual rather than price changes
     * @dev Only callable by the authorized execution environment
     */
    function initiateOevAuction() external {
        if (msg.sender != authorizedExecutionEnv) revert InvalidExecutionEnv();
    }

    /// FUNCTIONS DELEGATE CALLED FROM EXECUTION ENVIRONMENT DURING PRE SOLVER HOOK

    /**
     * @notice Configures market parameters for liquidation during pre-solver hook
     * @param marketManager Address of the market manager contract
     * @param cToken Address of the collateral token to be liquidated
     * @param newPenalty New liquidation penalty to apply
     * @dev Only callable by the authorized execution environment
     * @dev Sets dynamic risk parameters and unlocks collateral for liquidation
     */
    function preSolverSetup(address marketManager, address cToken, uint256 newPenalty) external {
        if (msg.sender != authorizedExecutionEnv) revert InvalidExecutionEnv();
        if (!CENTRAL_REGISTRY.isMarketManager(marketManager)) revert InvalidMarketManager();

        // Set dynamic risk parameters and unlock `cToken` collateral for auction-based liquidation.
        IMarketManager(marketManager).setTransientLiquidationConfig(cToken, newPenalty, ATLAS_CLOSE_FACTOR);

        // Unlock `marketManager`.
        CENTRAL_REGISTRY.unlockAuctionForMarket(marketManager);
    }

    /**
     * @notice Accumulates OEV internally for later distribution
     * @param bidAmount The total OEV amount to accumulate
     * @dev Only callable by the authorized execution environment
     * @dev Calculates shares and updates accumulation balances
     */
    function accumulateOEV(uint256 bidAmount) external {
        if (msg.sender != authorizedExecutionEnv) revert InvalidExecutionEnv();
        
        // Calculate OEV shares
        uint256 _oevShareFastlane = bidAmount * oevShareFastlane / OEV_SHARE_SCALE;
        uint256 _oevShareProtocol = bidAmount - _oevShareFastlane;
        
        // Update accumulated balances
        totalAccumulatedOEV += bidAmount;
        accumulatedOEVFastlane += _oevShareFastlane;
        accumulatedOEVProtocol += _oevShareProtocol;
        
        // Emit the proper event with calculated shares
        emit CurvanceOevAllocated(bidAmount, _oevShareFastlane, _oevShareProtocol);
    }

    // ---------------------------------------------------- //
    //                  Internal Functions                  //
    // ---------------------------------------------------- //

    /**
     * @notice Updates the authorized execution environment based on the user operation signer
     * @param newAuthedUserOpSigner Address of the new authorized user operation signer
     * @dev Called internally whenever authorizedUserOpSigner is updated
     * @dev Retrieves the execution environment from Atlas for the given signer
     */
    function _updateAuthorizedExecutionEnv(address newAuthedUserOpSigner) internal {
        (authorizedExecutionEnv,,) = IAtlas(ATLAS).getExecutionEnvironment(newAuthedUserOpSigner, address(this));
    }

    // ---------------------------------------------------- //
    //                    View Functions                    //
    // ---------------------------------------------------- //

    /**
     * @notice Returns the token used for bidding in auctions
     * @return bidToken Address of the bid token (address(0) for ETH)
     * @dev Override from DAppControl - always returns ETH as the bid token
     */
    function getBidFormat(UserOperation calldata) public pure override returns (address bidToken) {
        return address(0); // ETH is bid token
    }

    /**
     * @notice Extracts the bid value from a solver operation
     * @param solverOp The solver operation containing the bid
     * @return The bid amount in ETH
     * @dev Override from DAppControl - returns the solver's bid amount
     */
    function getBidValue(SolverOperation calldata solverOp) public pure override returns (uint256) {
        return solverOp.bidAmount;
    }

    /**
     * @notice Returns the configured gas limit for solver operations
     * @return The maximum gas limit allowed for solvers
     * @dev Override from DAppControl
     */
    function getSolverGasLimit() public view override returns (uint32) {
        return solverGasLimit;
    }

    /**
     * @notice Returns the current OEV share configuration and destination addresses
     * @return oevShareFastlane Fastlane's share of OEV (in basis points)
     * @return oevAllocationDestinationFastlane Address receiving Fastlane's OEV
     * @return oevAllocationDestinationProtocol Address receiving protocol's OEV
     */
    function getSharesAndDestinations() external view returns (
        uint256, address, address
    ) {
        return (oevShareFastlane, oevAllocationDestinationFastlane, oevAllocationDestinationProtocol);
    }

    /**
     * @notice Returns the current accumulated OEV balances
     * @return total Total accumulated OEV waiting to be distributed
     * @return fastlane Accumulated OEV allocated to Fastlane
     * @return protocol Accumulated OEV allocated to the protocol
     */
    function getAccumulatedOEV() external view returns (
        uint256 total,
        uint256 fastlane,
        uint256 protocol
    ) {
        return (totalAccumulatedOEV, accumulatedOEVFastlane, accumulatedOEVProtocol);
    }
}