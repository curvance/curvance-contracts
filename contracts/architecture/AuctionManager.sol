//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { DAppControl } from "@atlas/contracts/dapp/DAppControl.sol";
import { CallConfig } from "@atlas/contracts/types/ConfigTypes.sol";
import { UserOperation } from "@atlas/contracts/types/UserOperation.sol";
import { SolverOperation } from "@atlas/contracts/types/SolverOperation.sol";
import { IAtlas } from "@atlas/contracts/interfaces/IAtlas.sol";

import { CentralRegistryLib } from "contracts/libraries/CentralRegistryLib.sol";
import { BPS } from "contracts/libraries/ConstantsLib.sol";

import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IRedstoneProxy } from "contracts/interfaces/external/redstone/IRedstoneProxy.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";

/// @title AuctionManager
/// @author Fastlane Labs
/// @author Curvance Protocol
/// @notice Manages auction-based liquidations, and transient risk parameter
///         updates in the Curvance protocol. This contract is a modified
///         Atlas DApp control, an app-specific Atlas module for liquidations
///         auctions on Curvance; enabling Curvance to implement
///         application-specific ordering rules for liquidations using dynamic
///         risk parameters. The DappControl also functions as a whitelisted
///         data feed updater for RedStone oracles in order to ensure seamless
///         priority access to liquidations. 
/// @dev Uses the Atlas framework for handling of auction execution and solver
///      ordering, applies risk parameter updates using Atlas preSolver hook,
///      handles OEV distribution between relevant parties.
///
contract AuctionManager is DAppControl {
    /// CONSTANTS ///

    /// @notice Immutable reference to Curvance Central Registry.
    ICentralRegistry public immutable CENTRAL_REGISTRY;

    /// STORAGE ///

    /// @notice Liquidation close factor used for Auction-based liquidations,
    ///         in BPS.
    /// @dev 2000 = 20%.
    uint256 public atlasCloseFactor;

    /// REVENUE INFORMATION

    /// @notice Accumulated revenue for both Fastlane Labs and Curvance
    ///         Protocol.
    uint208 public accumulatedRevenue;

    /// @notice Share of revenue allocated to Fastlane Labs, in BPS.
    uint16 public fastlaneSplitBPS;

    /// SOLVER CONFIG 

    /// @notice Maximum gas limit allowed for each solver operation.
    uint32 public solverGasLimit = 6_000_000;

    /// @notice Address where Fastlane Labs' revenue share is sent.
    address public fastlaneRevenueDestination;
    
    /// @notice Address where Curvance Protocol's revenue share is sent.
    address public curvanceRevenueDestination;

    /// AUTHORIZATION VALIDATION (AUCTIONEER/USER)

    /// @notice Address authorized to sign Atlas user operations,
    ///         held by Fastlane Labs.
    address public authorizedUserOpSigner;
    
    /// @notice Authorized execution environment contract for Atlas
    ///         operations.
    address public authorizedExecutionEnv;

    /// @notice Number of whitelisted oracle addresses.
    uint32 public whitelistedOraclesCount;

    /// @notice Number of allowed function selectors for oracle updates.
    uint32 public allowedSelectorsCount;

    /// @notice Mapping of oracle addresses to their whitelist status.
    /// @dev Oracle Address => Whitelisting status.
    mapping(address oracle => bool isWhitelisted) public oracleWhitelist;
    
    /// @notice Mapping of function selectors to their allowed status.
    /// @dev Function Selector => Allowed status.
    mapping(bytes4 selector => bool isAllowed) public allowedSelectors;

    /// EVENTS ///

    /// @notice Emitted when revenue is received.
    /// @param newRevenue New revenue received.
    event RevenueAllocated(uint256 newRevenue);

    /// @notice Emitted when accumulated auction revenue is distributed.
    /// @param fastlaneRevenue Revenue amount distributed to Fastlane Labs.
    /// @param curvanceRevenue Revenue amount distributed to the Curvance
    ///                        Protocol.
    /// @param fastlaneDestination Address where Fastlane Labs' revenue was
    ///                            sent.
    /// @param curvanceDestination Address where Curvance Protocol's revenue
    ///                            was sent.
    event RevenueDistributed(
        uint256 fastlaneRevenue, 
        uint256 curvanceRevenue, 
        address fastlaneDestination, 
        address curvanceDestination
    );

    /// @notice Emitted when Fastlane's revenue share is updated.
    /// @param oldFastlaneShare Previous Fastlane share, in `BPS`.
    /// @param newFastlaneShare New Fastlane share, in `BPS`.
    event RevenueShareSet(
        uint256 oldFastlaneShare,
        uint256 newFastlaneShare,
        uint256 oldCurvanceShare,
        uint256 newCurvanceShare
    );

    /// @notice Emitted when Fastlane's allocation destination is updated.
    /// @param oldFastlaneDestination Previous destination address.
    /// @param newFastlaneDestination New destination address.
    event FastlaneRevenueDestinationSet(address oldFastlaneDestination, address newFastlaneDestination);

    /// @notice Emitted when protocol's allocation destination is updated.
    /// @param oldProtocolDestination Previous destination address.
    /// @param newProtocolDestination New destination address.
    event CurvanceRevenueDestinationSet(address oldProtocolDestination, address newProtocolDestination);

    /// @notice Emitted when the solver gas limit is updated.
    /// @param oldSolverGasLimit The revious solver gas limit.
    /// @param newSolverGasLimit The new solver gas limit.
    event SolverGasLimitSet(uint32 oldSolverGasLimit, uint32 newSolverGasLimit);

    /// @notice Emitted when the Atlas close factor is updated.
    /// @param oldCloseFactor Previous close factor, in BPS.
    /// @param newCloseFactor New close factor, in BPS.
    event AtlasCloseFactorSet(uint256 oldCloseFactor, uint256 newCloseFactor);

    /// @notice Emitted when the authorized user operation signer is updated.
    /// @param oldAuthorizedUserOpSigner Previous authorized signer.
    /// @param newAuthorizedUserOpSigner New authorized signer.
    event AuthorizedUserOpSignerSet(address oldAuthorizedUserOpSigner, address newAuthorizedUserOpSigner);

    /// @notice Emitted when an oracle's whitelist status is updated.
    /// @param oracle Address of the oracle.
    /// @param isWhitelisted New whitelist status.
    event OracleWhitelistUpdated(address indexed oracle, bool isWhitelisted);

    /// @notice Emitted when a function selector's whitelisting status is updated.
    /// @param selector Function selector having whitelist status updated.
    /// @param isWhitelisted Whether `selector` is whitelisted or not after update.
    event AllowedSelectorWhitelistUpdated(bytes4 indexed selector, bool isWhitelisted);

    /// ERRORS /// 

    /// @notice Thrown when execution environment calling a hook is invalid.
    error AuctionManager__OnlyExecutionEnv();

    /// @notice Thrown when a non-governor address attempts a permissioned
    ///         action.
    error AuctionManager__OnlyGovernor();
    
    /// @notice Thrown when user operation is signed from an unauthorized
    ///         address.
    error AuctionManager__InvalidUserOpFrom();
    
    /// @notice Thrown when user operation targets incorrect DAppControl.
    error AuctionManager__InvalidUserOpDapp();
    
    // OEV ALLOCATION ERRORS

    /// @notice Thrown when revenue shares exceed 100%.
    error AuctionManager__InvalidRevenueConfig();
    
    /// @notice Thrown when revenue allocation destination is zero address.
    error AuctionManager__InvalidDestination();

    /// @notice Thrown when close factor is invalid (zero or exceeds 100%).
    error AuctionManager__InvalidCloseFactor();

    // ORACLE RELATED ERRORS

    /// @notice Thrown when non-whitelisted oracle is used.
    error AuctionManager__InvalidOracle();
    
    /// @notice Thrown when oracle update call fails.
    error AuctionManager__OracleUpdateFailed();
    
    /// @notice Thrown when using non-allowed function selector.
    error AuctionManager__InvalidSelector();

    // SOLVER ERRORS

    /// @notice Thrown when solver operation data is malformed.
    error AuctionManager__MalformedSolverOperation();
    
    /// @notice Thrown when Market Manager is not registered.
    error AuctionManager__InvalidMarketManager();

    /// CONSTRUCTOR /// 

    /// @notice Initializes the AuctionManager with Atlas, Central Registry,
    ///         and revenue allocation configurations.
    /// @dev Configures Atlas CallConfig with the following key settings:
    /// - requirePreOps: true - Enables pre-operation hook for oracle updates
    ///                         and auctioneer validation.
    /// - requirePreSolver: true - Enables pre-solver hook for dynamic risk
    ///                            parameter updates and collateral unlocking.
    /// - zeroSolvers: false - Allows oracle updates without solvers
    ///                        (no OEV capture).
    /// - userAuctioneer: false - Restricts auctioneers to those whitelisted
    ///                           via AtlasVerification.
    /// - requireFulfillment: false - Ensures oracle updates proceed even if
    ///                               all solvers fail.
    /// - multipleSuccessfulSolvers: true - Enables app-specific ordering
    ///                                     rules for parallel solver
    ///                                     execution.
    /// @param atlas Address of the Atlas contract.
    /// @param centralRegistry_ Address of the Curvance Central Registry.
    /// @param fastlaneSplitBPS_ Initial revenue share for Fastlane Labs,
    ///                          in `BPS`.
    /// @dev Must NOT exceed `BPS`.
    /// @param fastlaneDestination_ Address to receive Fastlane Labs' revenue
    ///                             share.
    /// @param curvanceDestination_ Address to receive Curvance Protocol's
    ///                             revenue share.
    /// @param atlasCloseFactor_ Initial close factor for auction-based
    ///                         liquidations, in BPS.
    constructor(
        address atlas,
        ICentralRegistry centralRegistry_,
        uint256 fastlaneSplitBPS_,
        address fastlaneDestination_,
        address curvanceDestination_,
        uint256 atlasCloseFactor_
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

        // Configure revenue allocation.
        if (fastlaneSplitBPS_ > BPS) revert AuctionManager__InvalidRevenueConfig();
        if (fastlaneDestination_ == address(0)) revert AuctionManager__InvalidDestination();
        if (curvanceDestination_ == address(0)) revert AuctionManager__InvalidDestination();
        if (atlasCloseFactor_ == 0 || atlasCloseFactor_ > BPS) revert AuctionManager__InvalidCloseFactor();
        fastlaneSplitBPS = uint16(fastlaneSplitBPS_);
        fastlaneRevenueDestination = fastlaneDestination_;
        curvanceRevenueDestination = curvanceDestination_;
        atlasCloseFactor = atlasCloseFactor_;

        // Set `CENTRAL_REGISTRY`.
        CENTRAL_REGISTRY = centralRegistry_;

        // Set Oracle related configurations.
        allowedSelectors[IRedstoneProxy.updateDataFeedsValues.selector] = true;
        allowedSelectors[IRedstoneProxy.updateDataFeedsValuesPartial.selector] = true;
        allowedSelectorsCount = 2;

        emit RevenueShareSet(0, fastlaneSplitBPS_, 0, BPS - fastlaneSplitBPS_);
        emit FastlaneRevenueDestinationSet(address(0), fastlaneDestination_);
        emit CurvanceRevenueDestinationSet(address(0), curvanceDestination_);
        emit AllowedSelectorWhitelistUpdated(IRedstoneProxy.updateDataFeedsValues.selector, true);
        emit AllowedSelectorWhitelistUpdated(IRedstoneProxy.updateDataFeedsValuesPartial.selector, true);
    }

    /// EXTERNAL FUNCTIONS ///

    /// REVENUE RELATED FUNCTIONS

    /// @notice Updates Fastlane Labs' share of auction revenue.
    /// @dev `fastlaneSplitBPS_` cannot exceed `BPS`.
    /// @param fastlaneSplitBPS_ New Fastlane Labs revenue split, in `BPS`.
    function setFastlaneSplit(uint256 fastlaneSplitBPS_) external {
        _checkIsGovernor();

        if (fastlaneSplitBPS_ > BPS) revert AuctionManager__InvalidRevenueConfig();
        uint256 old = fastlaneSplitBPS;

        // Distribute accumulated revenue with `old` Fastlane Labs fee split.
        _distributeRevenue();

        fastlaneSplitBPS = uint16(fastlaneSplitBPS_);
        emit RevenueShareSet(old, fastlaneSplitBPS_, BPS - old, BPS - fastlaneSplitBPS_);
    }

    /// @notice Updates the destination address for Fastlane Labs' revenue
    ///         split.
    /// @dev `fastlaneDestination_` cannot be set to zero address.
    /// @param fastlaneDestination_ New destination address for Fastlane
    ///                             Labs' revenue split.
    function setFastlaneDestination(address fastlaneDestination_) external {
        _checkIsGovernor();

        if (fastlaneDestination_ == address(0)) revert AuctionManager__InvalidDestination();
        address old = fastlaneRevenueDestination;
        fastlaneRevenueDestination = fastlaneDestination_;
        emit FastlaneRevenueDestinationSet(old, fastlaneDestination_);
    }

    /// @notice Updates the destination address for Curvance Protocol's
    ///         revenue split.
    /// @dev `curvanceDestination_` cannot be set to zero address.
    /// @param curvanceDestination_ New destination address for Curvance
    ///                             Protocol's revenue split.
    function setCurvanceDestination(address curvanceDestination_) external {
        _checkIsGovernor();
        
        if (curvanceDestination_ == address(0)) revert AuctionManager__InvalidDestination();
        address old = curvanceRevenueDestination;
        curvanceRevenueDestination = curvanceDestination_;
        emit CurvanceRevenueDestinationSet(old, curvanceDestination_);
    }

    /// @notice Distributes accumulated revenue to Fastlane Labs and Curvance
    ///         Protocol and zeros out `accumulatedRevenue`.
    /// @dev Only callable by governor.
    function distributeRevenue() external {
        _checkIsGovernor();
        _distributeRevenue();
    }

    /// SETTER FOR SOLVER CONFIGURATION

    /// @notice Updates the gas limit for each solver operation.
    /// @param solverGasLimit_ New gas limit for solvers.
    function setSolverGasLimit(uint32 solverGasLimit_) external {
        _checkIsGovernor();
        
        uint32 old = solverGasLimit;
        solverGasLimit = solverGasLimit_;
        emit SolverGasLimitSet(old, solverGasLimit_);
    }

    /// @notice Updates the close factor used for auction-based liquidations.
    /// @dev Close factor must be greater than 0 and not exceed 100% (BPS).
    /// @param atlasCloseFactor_ New close factor, in BPS.
    function setAtlasCloseFactor(uint256 atlasCloseFactor_) external {
        _checkIsGovernor();
        
        if (atlasCloseFactor_ == 0 || atlasCloseFactor_ > BPS) revert AuctionManager__InvalidCloseFactor();
        uint256 old = atlasCloseFactor;
        atlasCloseFactor = atlasCloseFactor_;
        emit AtlasCloseFactorSet(old, atlasCloseFactor_);
    }

    /// @notice Sets the authorized signer for user operations.
    /// @dev This function must be called immediately after deployment to
    ///      initialize the authorizedExecutionEnv.
    /// @param authorizedUserOpSigner_ Address authorized to sign user
    ///                                operations.
    function setAuthorizedUserOpSigner(address authorizedUserOpSigner_) external {
        _checkIsGovernor();
        
        address old = authorizedUserOpSigner;
        authorizedUserOpSigner = authorizedUserOpSigner_;
        _updateAuthorizedExecutionEnv(authorizedUserOpSigner_);
        emit AuthorizedUserOpSignerSet(old, authorizedUserOpSigner_);
    }

    // ---------------------------------------------------- //
    //                    UserOp Function Option 1          //
    // ---------------------------------------------------- //

    /// @notice Updates oracle price feeds with new values.
    /// @dev Only callable by the authorized execution environment.
    ///      Oracle and selector validation occurs in _preOpsCall.
    /// @param oracle Address of the oracle contract to update.
    /// @param callData Encoded function call to execute on the oracle.
    function update(address oracle, bytes calldata callData) external {
        _checkAuthorizedExecutionEnv();

        // Parameters have already been validated in _preOpsCall
        (bool success,) = oracle.call(callData);
        if (!success) revert AuctionManager__OracleUpdateFailed();
    }

    // ---------------------------------------------------- //
    //                    UserOp Function Option 2          //
    // ---------------------------------------------------- //

    /// @notice Initiates an auction without updating oracle feeds.
    /// @dev Only callable by the authorized execution environment.
    ///      Intentionally empty, used for liquidations triggered by interest
    ///      accrual rather than price changes, meaning we can skip oracle
    ///      update.
    function initiateAuction() external {
        _checkAuthorizedExecutionEnv();
    }

    /// FUNCTIONS DELEGATE CALLED FROM EXECUTION ENVIRONMENT DURING PRE SOLVER HOOK

    /// @notice Configures market parameters for liquidation during pre-solver hook.
    /// @dev Only callable by the authorized execution environment.
    ///      Sets dynamic risk parameters and unlocks collateral for liquidation.
    /// @param marketManager Address of the market manager to liquidate inside.
    /// @param cToken Address of the collateral token to be liquidated.
    /// @param newPenalty New liquidation penalty to apply.
    function preSolverSetup(address marketManager, address cToken, uint256 newPenalty) external {
        _checkAuthorizedExecutionEnv();
        if (!CENTRAL_REGISTRY.isMarketManager(marketManager)) revert AuctionManager__InvalidMarketManager();

        // Set dynamic risk parameters and unlock `cToken` collateral for auction-based liquidation.
        IMarketManager(marketManager).setTransientLiquidationConfig(cToken, newPenalty, atlasCloseFactor);

        // Unlock `marketManager`.
        CENTRAL_REGISTRY.unlockAuctionForMarket(marketManager);
    }

    /// @notice Accumulates revenue internally for later distribution.
    /// @dev Only callable by the authorized execution environment.
    /// @param bidAmount The total revenue to accumulate, in native gas token.
    function accumulateRevenue(uint256 bidAmount) external {
        _checkAuthorizedExecutionEnv();

        uint256 pendingRevenue = accumulatedRevenue;
        if (pendingRevenue + bidAmount > type(uint208).max) {
            _distributeRevenue();
            pendingRevenue = 0;
        }

        accumulatedRevenue = uint208(pendingRevenue + bidAmount);

        // Emit that new revenue was allocated from an auction-based
        // liquidation.
        emit RevenueAllocated(bidAmount);
    }

    // ---------------------------------------------------- //
    //            Whitelisted-Related Functions             //
    // ---------------------------------------------------- //

    /// @notice Adds an oracle to the whitelist.
    /// @dev Only callable by governor.
    /// @param oracle Address of the oracle to whitelist.
    function addOracleToWhitelist(address oracle) external {
        _checkIsGovernor();
        
        if (!oracleWhitelist[oracle]) {
            oracleWhitelist[oracle] = true;
            whitelistedOraclesCount++;
            emit OracleWhitelistUpdated(oracle, true);
        }
    }

    /// @notice Removes an oracle from the whitelist.
    /// @dev Only callable by governor.
    /// @param oracle Address of the oracle to remove.
    function removeOracleFromWhitelist(address oracle) external {
        _checkIsGovernor();
        
        if (oracleWhitelist[oracle]) {
            delete oracleWhitelist[oracle];
            whitelistedOraclesCount--;
            emit OracleWhitelistUpdated(oracle, false);
        }
    }

    /// @notice Verifies if an oracle is whitelisted.
    /// @dev Whitelisting is enforced only if the whitelist is not empty.
    /// @param oracle Address of the oracle to verify.
    function verifyOracleWhitelist(address oracle) external view {
        if (whitelistedOraclesCount > 0 && !oracleWhitelist[oracle]) revert AuctionManager__InvalidOracle();
    }

    /// @notice Adds a function selector to `allowedSelectors`.
    /// @dev Only callable by governor.
    /// @param selector Function selector to allow.
    function addAllowedSelector(bytes4 selector) external {
        _checkIsGovernor();
        
        if (!allowedSelectors[selector]) {
            allowedSelectors[selector] = true;
            allowedSelectorsCount++;
            emit AllowedSelectorWhitelistUpdated(selector, true);
        }
    }

    /// @notice Removes a function selector from `allowedSelectors`.
    /// @dev Only callable by governor.
    /// @param selector The function selector to remove.
    function removeAllowedSelector(bytes4 selector) external {
        _checkIsGovernor();
        
        if (allowedSelectors[selector]) {
            delete allowedSelectors[selector];
            allowedSelectorsCount--;
            emit AllowedSelectorWhitelistUpdated(selector, false);
        }
    }

    /// @notice Verifies if a function selector is allowed for oracle updates.
    /// @dev Whitelisting is enforced only if the whitelist is not empty.
    /// @param selector Function selector to verify.
    function verifyAllowedSelector(bytes4 selector) external view {
        if (allowedSelectorsCount > 0 && !allowedSelectors[selector]) revert AuctionManager__InvalidSelector();
    }

    /// @notice Returns the current revenue share configuration and
    ///         destination addresses.
    /// @return Fastlane Labs share of auction revenue, in `BPS`.
    /// @return Address receiving Fastlane Labs' revenue.
    /// @return Curvance Protocol share of auction revenue, in `BPS`.
    /// @return Address receiving Curvance Protocol's revenue.
    function getRevenueSharesAndDestinations() external view returns (
        uint256, address, uint256, address
    ) {
        return (fastlaneSplitBPS, fastlaneRevenueDestination, BPS - fastlaneSplitBPS, curvanceRevenueDestination);
    }

    /// @notice Returns the current accumulated revenue balances.
    /// @return fastlane Accumulated revenue allocated to Fastlane Labs.
    /// @return curvance Accumulated revenue allocated to Curvance Protocol.
    function getAccumulatedRevenue() external view returns (
        uint256 fastlane,
        uint256 curvance
    ) {
        fastlane = (accumulatedRevenue * fastlaneSplitBPS) / BPS;
        curvance = accumulatedRevenue - fastlane;
    }

    /// PUBLIC FUNCTIONS ///

    /// @notice Returns the token used for bidding in auctions.
    /// @dev Overridden from `DAppControl`, always returns native gas token
    ///      as the bid token.
    /// @return bidToken Address of the bid token, address(0) for native gas
    ///                  token.
    function getBidFormat(
        UserOperation calldata
    ) public pure override returns (address bidToken) {
        bidToken = address(0); // Native gas token is bid token.
    }

    /// @notice Extracts the bid value from a solver operation.
    /// @dev Overridden from `DAppControl`, returns the solver's bid amount.
    /// @return The bid amount in native gas token.
    function getBidValue(
        SolverOperation calldata solverOp
    ) public pure override returns (uint256) {
        return solverOp.bidAmount;
    }

    /// @notice Returns the configured gas limit for solver operations.
    /// @dev Overridden from `DAppControl`.
    /// @return The maximum gas limit allowed for solvers.
    function getSolverGasLimit() public view override returns (uint32) {
        return solverGasLimit;
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Extracts bid parameters from solver operation data.
    /// @dev Expects the last 96 bytes of solverOpData to contain bid
    ///      information.
    /// @param solverOpData Raw solver operation data.
    /// @return penaltyBid The liquidation penalty bid amount.
    /// @return collateralBid Address of the collateral token being bid on.
    /// @return market Address of the market where liquidation occurs.
    function _getBidParamsFromSolverOpData(
        bytes calldata solverOpData
    ) internal pure returns (
        uint256 penaltyBid,
        address collateralBid,
        address market
    ) {
        if (solverOpData.length < 96) revert AuctionManager__MalformedSolverOperation();

        // Isolate the bid data - the last 96 bytes of the solverOpData, then
        // decode the tail bid data into (penaltyBid, collateralBid, market)
        (penaltyBid, collateralBid, market) =
            abi.decode(solverOpData[solverOpData.length - 96:], (uint256, address, address));
    }

    // ---------------------------------------------------- //
    //                  Atlas Hook Overrides                //
    // ---------------------------------------------------- //

    /// @notice Pre-operation hook called before user operations are executed,
    ///         validates the user operation and optionally triggers oracle
    ///         updates.
    /// @dev This function is delegateCalled from the authorized execution
    ///      environment.
    /// @param userOp The user operation to validate and process.
    /// @return Empty bytes as return data.
    function _preOpsCall(
        UserOperation calldata userOp
    ) internal override returns (bytes memory) {
        // The userOp dapp must be `CONTROL` contract.
        if (userOp.dapp != CONTROL) revert AuctionManager__InvalidUserOpDapp();
        // The user must be the authorized user op signer.
        if (userOp.from != AuctionManager(CONTROL).authorizedUserOpSigner()) revert AuctionManager__InvalidUserOpFrom();

        // If the userOp contains a RedStone feed update perform it.
        if (bytes4(userOp.data) == bytes4(AuctionManager.update.selector)) {
            (address _oracle, bytes memory _updateCallData) =
                abi.decode(userOp.data[4:], (address, bytes));

            // The called oracle must be whitelisted.
            AuctionManager(CONTROL).verifyOracleWhitelist(_oracle);

            // The update call data must be a valid function call.
            AuctionManager(CONTROL).verifyAllowedSelector(bytes4(_updateCallData));
        }

        // Else if UserOp does not contain a RedStone update, continue as no-op UserOp
        // This case is for liquidations triggered by interest accrual, not the oracle.

        // Return empty bytes.
        return "";
    }

    /// @notice Pre-solver hook called before each solver operations is
    ///         executed. Extracts bid parameters, unlocks relevant market and
    ///         collateral, and updates risk parameters.
    /// @dev This function is delegateCalled from the Atlas execution
    ///      environment.
    /// @param solverOp The solver operation containing bid parameters. 
    function _preSolverCall(
        SolverOperation calldata solverOp,
        bytes calldata
    ) internal override {
        (uint256 newPenalty, address collateralBid, address market) =
            _getBidParamsFromSolverOpData(solverOp.data);
        AuctionManager(CONTROL).preSolverSetup(market, collateralBid, newPenalty);
    }

    /// @notice Accumulates revenue in native gas tokens for later
    ///         distribution according to configured revenue split.
    /// @dev This function is delegateCalled from the Atlas execution
    ///      environment.
    /// @param bidAmount The total revenue to accumulate.
    function _allocateValueCall(
        bool,
        address,
        uint256 bidAmount,
        bytes calldata
    ) internal virtual override {
        if (bidAmount == 0) return;

        // Since this is delegateCalled, we need to call back to the `CONTROL`
        // contract to update storage variables
        AuctionManager(CONTROL).accumulateRevenue(bidAmount);
    }

    /// @notice Updates the authorized execution environment based on the user
    ///         operation signer.
    /// @dev Called internally whenever authorizedUserOpSigner is updated.
    ///      Retrieves the execution environment from Atlas for the given
    ///      signer.
    /// @param newAuthedUserOpSigner Address of the new authorized user
    ///                              operation signer.
    function _updateAuthorizedExecutionEnv(address newAuthedUserOpSigner) internal {
        (authorizedExecutionEnv, , ) = IAtlas(ATLAS)
            .getExecutionEnvironment(newAuthedUserOpSigner, address(this));
    }

    /// @notice Distributes accumulated revenue to Fastlane Labs and Curvance
    ///         Protocol and zeros out `accumulatedRevenue`.
    function _distributeRevenue() internal {
        // Cached accumulated revenue value, in native gas tokens.
        uint256 revenue = accumulatedRevenue;
        if (revenue == 0) {
            return;
        }

        uint256 fastlaneSplit = (revenue * fastlaneSplitBPS) / BPS;
        uint256 curvanceSplit = revenue - fastlaneSplit;
        
        // Transfer accumulated OEV to destinations
        if (fastlaneSplit > 0) {
            SafeTransferLib.safeTransferETH(fastlaneRevenueDestination, fastlaneSplit);
        }
        if (curvanceSplit > 0) {
            SafeTransferLib.safeTransferETH(curvanceRevenueDestination, curvanceSplit);
        }

        // Reset accumulated auction revenue values.
        delete accumulatedRevenue;

        emit RevenueDistributed(
            fastlaneSplit, 
            curvanceSplit, 
            fastlaneRevenueDestination, 
            curvanceRevenueDestination
        );
    }

    /// @notice Validates whether the caller is `authorizedExecutionEnv`.
    function _checkAuthorizedExecutionEnv() internal view {
        if (msg.sender != authorizedExecutionEnv) revert AuctionManager__OnlyExecutionEnv();
    }

    /// @notice Validates whether the caller is `governance`.
    function _checkIsGovernor() internal view {
        if (msg.sender != governance) revert AuctionManager__OnlyGovernor();
    }
}