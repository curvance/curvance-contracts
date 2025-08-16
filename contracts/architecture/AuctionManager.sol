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

contract AuctionManager is DAppControl {
    /// CONSTANTS ///

    uint256 public constant OEV_SHARE_SCALE = 10_000;
    uint256 public constant ATLAS_CLOSE_FACTOR = 5_000_000;
    ICentralRegistry public immutable CENTRAL_REGISTRY;

    /// STORAGE ///

    /// DAPP CONTROL CONFIG
    uint32 public solverGasLimit = 6_000_000;

    /// OEV ALLOCATION CONFIG
    // OEV shares are in hundredth of percent
    uint256 public oevShareBundler;
    uint256 public oevShareFastlane;

    address public oevAllocationDestinationFastlane;
    address public oevAllocationDestinationProtocol;

    /// VALIDATION OF AUCTIONEER/USER
    address public authorizedUserOpSigner;
    address public authorizedExecutionEnv;

    // ORACLE CONFIGURATIONS
    uint32 public whitelistedOraclesCount;
    mapping(address oracle => bool isWhitelisted) public oracleWhitelist;

    uint32 public allowedSelectorsCount;
    mapping(bytes4 selector => bool isAllowed) public allowedSelectors;

    /// EVENTS ///

    event CurvanceOevAllocated(
        address indexed bundler, uint256 totalOev, uint256 oevBundler, uint256 oevFastlane, uint256 oevProtocol
    );
    event OevShareBundlerSet(uint256 oldBundlerShare, uint256 newBundlerShare);
    event OevShareFastlaneSet(uint256 oldFastlaneShare, uint256 newFastlaneShare);
    event OevAllocationDestinationFastlaneSet(address oldFastlaneDestination, address newFastlaneDestination);
    event OevAllocationDestinationProtocolSet(address oldProtocolDestination, address newProtocolDestination);
    event SolverGasLimitSet(uint32 oldSolverGasLimit, uint32 newSolverGasLimit);
    event AuthorizedUserOpSignerSet(address oldAuthorizedUserOpSigner, address newAuthorizedUserOpSigner);
    event OracleWhitelistUpdated(address indexed oracle, bool isWhitelisted);
    event AllowedSelectorWhitelistUpdated(bytes4 indexed selector, bool isWhitelisted);

    /// ERRORS /// 

    // DAPP CONTROL/ATLAS VALIDATION ERRORS
    error OnlyGovernance();
    error InvalidUserOpFrom();
    error InvalidUserOpDapp();
    error InvalidExecutionEnv();

    // OEV ALLOCATION ERRORS
    error InvalidOevShare();
    error InvalidOevAllocationDestination();

    // ORACLE RELATED ERRORS
    error OnlyWhitelistedOracleAllowed();
    error OracleUpdateFailed();
    error InvalidSelector();

    // SOLVER ERRORS
    error MalformedSolverOperation();
    error InvalidMarketManager();

    /// CONSTRUCTOR /// 

    constructor(
        address atlas,
        ICentralRegistry centralRegistry_,
        uint256 oevShareBundler_,
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
                requirePreOps: true, // Hook where data feed update may be performed + auctioneer validation lives
                trackPreOpsReturnData: false,
                trackUserReturnData: false,
                delegateUser: false,
                requirePreSolver: true, // Hook where risk parameters are modified and market/collateral enforcement lives
                requirePostSolver: false,
                zeroSolvers: false, // Oracle updates can be made without solvers and no OEV
                reuseUserOp: true, // Copied from RedStone DappControl
                // Only allowed auctioneers are the ones whitelisted by the governance on `AtlasVerification` (addSignatory)
                userAuctioneer: false,
                solverAuctioneer: false,
                unknownAuctioneer: false,
                verifyCallChainHash: true,
                forwardReturnData: false,
                requireFulfillment: false, // Update oracle even if all solvers fail
                trustedOpHash: false,
                invertBidValue: false,
                exPostBids: false,
                multipleSuccessfulSolvers: true, // Allow multiple successful solvers
                checkMetacallGasLimit: false
            })
        )
    {
        CentralRegistryLib._isCentralRegistry(centralRegistry_);

        // Configure OEV allocation.
        if (oevShareBundler_ + oevShareFastlane_ > OEV_SHARE_SCALE) revert InvalidOevShare();
        if (oevAllocationDestinationFastlane_ == address(0)) revert InvalidOevAllocationDestination();
        if (oevAllocationDestinationProtocol_ == address(0)) revert InvalidOevAllocationDestination();
        oevShareBundler = oevShareBundler_;
        oevShareFastlane = oevShareFastlane_;
        oevAllocationDestinationFastlane = oevAllocationDestinationFastlane_;
        oevAllocationDestinationProtocol = oevAllocationDestinationProtocol_;

        // Set `CENTRAL_REGISTRY`.
        CENTRAL_REGISTRY = centralRegistry_;

        // Set Oracle related configurations.
        allowedSelectors[IRedstoneProxy.updateDataFeedsValues.selector] = true;
        allowedSelectors[IRedstoneProxy.updateDataFeedsValuesPartial.selector] = true;
        allowedSelectorsCount = 2;

        emit OevShareBundlerSet(0, oevShareBundler_);
        emit OevShareFastlaneSet(0, oevShareFastlane_);
        emit OevAllocationDestinationFastlaneSet(address(0), oevAllocationDestinationFastlane_);
        emit OevAllocationDestinationProtocolSet(address(0), oevAllocationDestinationProtocol_);
        emit AllowedSelectorWhitelistUpdated(IRedstoneProxy.updateDataFeedsValues.selector, true);
        emit AllowedSelectorWhitelistUpdated(IRedstoneProxy.updateDataFeedsValuesPartial.selector, true);
    }

    // ---------------------------------------------------- //
    //                   Custom Functions                   //
    // ---------------------------------------------------- //

    modifier onlyGov() {
        if (msg.sender != governance) revert OnlyGovernance();
        _;
    }

    /// SETTERS FOR OEV ALLOCATION CONFIG
    function setOevShareBundler(uint256 oevShareBundler_) external onlyGov {
        if (oevShareBundler_ + oevShareFastlane > OEV_SHARE_SCALE) revert InvalidOevShare();
        uint256 old = oevShareBundler;
        oevShareBundler = oevShareBundler_;
        emit OevShareBundlerSet(old, oevShareBundler_);
    }

    function setOevShareFastlane(uint256 oevShareFastlane_) external onlyGov {
        if (oevShareFastlane_ + oevShareBundler > OEV_SHARE_SCALE) revert InvalidOevShare();
        uint256 old = oevShareFastlane;
        oevShareFastlane = oevShareFastlane_;
        emit OevShareFastlaneSet(old, oevShareFastlane_);
    }

    function setOevAllocationDestinationFastlane(address oevAllocationDestinationFastlane_) external onlyGov {
        if (oevAllocationDestinationFastlane_ == address(0)) revert InvalidOevAllocationDestination();
        address old = oevAllocationDestinationFastlane;
        oevAllocationDestinationFastlane = oevAllocationDestinationFastlane_;
        emit OevAllocationDestinationFastlaneSet(old, oevAllocationDestinationFastlane_);
    }

    function setOevAllocationDestinationProtocol(address oevAllocationDestinationProtocol_) external onlyGov {
        if (oevAllocationDestinationProtocol_ == address(0)) revert InvalidOevAllocationDestination();
        address old = oevAllocationDestinationProtocol;
        oevAllocationDestinationProtocol = oevAllocationDestinationProtocol_;
        emit OevAllocationDestinationProtocolSet(old, oevAllocationDestinationProtocol_);
    }

    /// SETTER FOR DAPP CONTROL CONFIGURATION
    function setSolverGasLimit(uint32 solverGasLimit_) external onlyGov {
        uint32 old = solverGasLimit;
        solverGasLimit = solverGasLimit_;
        emit SolverGasLimitSet(old, solverGasLimit_);
    }

    /// SET AUCTIONEER/USER VALIDATION
    // NOTE: This function must be called immediately after deployment to initialize the authorizedExecutionEnv
    function setAuthorizedUserOpSigner(address authorizedUserOpSigner_) external onlyGov {
        address old = authorizedUserOpSigner;
        authorizedUserOpSigner = authorizedUserOpSigner_;
        _updateAuthorizedExecutionEnv(authorizedUserOpSigner_);
        emit AuthorizedUserOpSignerSet(old, authorizedUserOpSigner_);
    }

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

    // NOTE: Whitelisting is enforced only if the whitelist is not empty
    function verifyOracleWhitelist(address oracle) external view {
        if (whitelistedOraclesCount > 0 && !oracleWhitelist[oracle]) revert OnlyWhitelistedOracleAllowed();
    }

    function addOracleToWhitelist(address oracle) external onlyGov {
        if (!oracleWhitelist[oracle]) {
            oracleWhitelist[oracle] = true;
            whitelistedOraclesCount++;
            emit OracleWhitelistUpdated(oracle, true);
        }
    }

    function removeOracleFromWhitelist(address oracle) external onlyGov {
        if (oracleWhitelist[oracle]) {
            oracleWhitelist[oracle] = false;
            whitelistedOraclesCount--;
            emit OracleWhitelistUpdated(oracle, false);
        }
    }

    // NOTE: Whitelisting is enforced only if the whitelist is not empty
    function verifyAllowedSelector(bytes4 selector) external view {
        if (allowedSelectorsCount > 0 && !allowedSelectors[selector]) revert InvalidSelector();
    }

    function addAllowedSelector(bytes4 selector) external onlyGov {
        if (!allowedSelectors[selector]) {
            allowedSelectors[selector] = true;
            allowedSelectorsCount++;
            emit AllowedSelectorWhitelistUpdated(selector, true);
        }
    }

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
     * @param userOp The user operation to check
     * @return The user address
     * @dev This function is delegatcalled
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
     * @param solverOp The solver operation data.
     * @dev Called via delegatecall.
     */
    function _preSolverCall(SolverOperation calldata solverOp, bytes calldata) internal override {
        (uint256 newPenalty, address collateralBid, address marketBid) = _getBidParamsFromSolverOpData(solverOp.data);
        AuctionManager(CONTROL).preSolverSetup(marketBid, collateralBid, newPenalty);
    }

    /**
     * @notice Allocates the bid amount to the relevant parties
     * @param bidAmount The bid amount to be allocated
     * @dev This function is delegatecalled
     */
    function _allocateValueCall(bool, address, uint256 bidAmount, bytes calldata) internal virtual override {
        if (bidAmount == 0) return;

        (uint256 bundlerShare, uint256 fastlaneShare, address fastlaneDest, address protocolDest) =
            AuctionManager(CONTROL).getSharesAndDestinations();

        // Get the OEV share for the bundler and transfer it
        uint256 _oevShareBundler = bidAmount * bundlerShare / OEV_SHARE_SCALE;
        if (_oevShareBundler > 0) SafeTransferLib.safeTransferETH(_bundler(), _oevShareBundler);

        // Get the OEV share for Fastlane and transfer it
        uint256 _oevShareFastlane = bidAmount * fastlaneShare / OEV_SHARE_SCALE;
        if (_oevShareFastlane > 0) SafeTransferLib.safeTransferETH(fastlaneDest, _oevShareFastlane);

        // Transfer the rest
        uint256 _oevShareProtocol = bidAmount - _oevShareBundler - _oevShareFastlane;
        if (_oevShareProtocol > 0) SafeTransferLib.safeTransferETH(protocolDest, _oevShareProtocol);

        emit CurvanceOevAllocated(_bundler(), bidAmount, _oevShareBundler, _oevShareFastlane, _oevShareProtocol);
    }

    // ---------------------------------------------------- //
    //                    UserOp Function Option 1          //
    // ---------------------------------------------------- //

    /**
     * @notice Updates the oracle with the new values
     * @param oracle The oracle to update
     * @param callData The call data to update the oracle with
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
     * @notice Initiates the OEV auction
     * @dev Intentially empty, must be called in an atlas UserOperation,
     * @dev all checks are done in the _preOpsCall
     */
    // Only called when performing an auction without a data feed update
    function initiateOevAuction() external {
        if (msg.sender != authorizedExecutionEnv) revert InvalidExecutionEnv();
    }

    /// FUNCTIONS DELEGATE CALLED FROM EXECUTION ENVIRONMENT DURING PRE SOLVER HOOK

    function preSolverSetup(address marketManager, address cToken, uint256 newPenalty) external {
        if (msg.sender != authorizedExecutionEnv) revert InvalidExecutionEnv();
        if (!CENTRAL_REGISTRY.isMarketManager(marketManager)) revert InvalidMarketManager();

        // Set dynamic risk parameters.
        IMarketManager(marketManager).setLiquidationConfig(cToken, newPenalty, ATLAS_CLOSE_FACTOR);

        // Unlock cToken collateral liquidation.
        IMarketManager(marketManager).unlockAuctionCollateral(cToken);

        // Unlock `marketManager`.
        CENTRAL_REGISTRY.unlockAuctionForMarket(marketManager);
    }

    // ---------------------------------------------------- //
    //                  Internal Functions                  //
    // ---------------------------------------------------- //

    // Called whenever authorizedUserOpSigner is updated
    function _updateAuthorizedExecutionEnv(address newAuthedUserOpSigner) internal {
        (authorizedExecutionEnv,,) = IAtlas(ATLAS).getExecutionEnvironment(newAuthedUserOpSigner, address(this));
    }

    // ---------------------------------------------------- //
    //                    View Functions                    //
    // ---------------------------------------------------- //

    function getBidFormat(UserOperation calldata) public pure override returns (address bidToken) {
        return address(0); // ETH is bid token
    }

    function getBidValue(SolverOperation calldata solverOp) public pure override returns (uint256) {
        return solverOp.bidAmount;
    }

    function getSolverGasLimit() public view override returns (uint32) {
        return solverGasLimit;
    }

    function getSharesAndDestinations() external view returns (
        uint256, uint256, address, address
    ) {
        return (oevShareBundler, oevShareFastlane, oevAllocationDestinationFastlane, oevAllocationDestinationProtocol);
    }
}