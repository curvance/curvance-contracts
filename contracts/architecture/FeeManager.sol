// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { CentralRegistryLib } from "contracts/libraries/CentralRegistryLib.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { WAD } from "contracts/libraries/ConstantsLib.sol";

import { ReentrancyGuard } from "contracts/libraries/external/ReentrancyGuard.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";

import { IOracleManager } from "contracts/interfaces/IOracleManager.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

/// @title Curvance Fee Manager.
/// @notice A system for managing fee collected through Curvance DAO
///         operations within Curvance Protocol.
/// @dev The Fee Manager acts as a unified hub for collecting and
///      transforming fees collected and their preparation for delivery
///      to Curvance DAO users. Currently, fees can be swapped via offchain
///      solver integrations such as 1Inch. An alternative model of
///      permissionless dutch auctions such as the work seen by Uniswap/Euler
///      could be used. However, A/B testing may provide greater insight into
///      the superior model.
///
///      Fees can be marked for OTC which will allow the Curvance DAO to
///      purchase them, at fair market value. The Fee Manager also works
///      in collaboration with the Messaging Hub to manage system
///      information and fees. Epoch fee distributions are distributed once a
///      single chain has recorded fees accumulated and tokens locked across
///      all supported chains inside the Curvance Protocol system.
///
///      These fees are distributed pro-rata based on the under of locked
///      veCVE tokens on each chain, see "RewardManager.sol" for more information
///      on this.
///
///      Native gas tokens are stored inside the contract to pay for all
///      crosschain actions. Locked token data actions are intended to be
///      moved over to Wormhole's CCQ prior to mainnet deployment.
///      At this time, payload/MessageType configuration + encoding/decoding
///      are not production ready.
///
contract FeeManager is ReentrancyGuard {
    /// TYPES ///

    /// @title Reward Token Data
    /// @notice Manages and tracks reward tokens, including their eligibility
    ///         for DAO OTC transactions.
    /// @param isRewardToken Whether an address is the reward token or not.
    ///                      2 = yes; 0 or 1 = no.
    /// @param forOTC Whether a token should be held back for DAO OTC or not.
    ///               2 = yes; 0 or 1 = no.
    struct RewardToken {
        uint256 isRewardToken;
        uint256 forOTC;
    }

    /// CONSTANTS ///

    /// @notice Curvance DAO hub.
    ICentralRegistry public immutable centralRegistry;

    /// STORAGE ///

    /// @notice Used for offchain bots to check what tokens to swap.
    /// @dev    We store token data semi redundantly to save gas.
    ///         on daily operations and to help with offchain bot structure.
    address[] public rewardTokens;

    /// @notice Token Address => RewardToken data.
    mapping(address => RewardToken) public rewardTokenInfo;

    /// ERRORS ///

    error FeeManager__Unauthorized();
    error FeeManager__SwapActionsAndTokenLengthMismatch(
        uint256 numSwapActions,
        uint256 numTokens
    );
    error FeeManager__SwapActionsInputTokenIsNotCurrentToken(
        uint256 index,
        address inputToken,
        address currentToken
    );
    error FeeManager__SwapActionsOutputTokenIsNotFeeToken(
        uint256 index,
        address inputToken,
        address currentToken
    );
    error FeeManager__SwapActionsCurrentTokenIsNotRewardToken(
        uint256 index,
        address currentToken
    );
    error FeeManager__TokenIsNotEarmarked();
    error FeeManager__ConfigurationError();
    error FeeManager__NewFeeManagerIsNotChanged();
    error FeeManager__TokenLengthIsZero();
    error FeeManager__RemovalTokenIsNotRewardToken();
    error FeeManager__RemovalTokenDoesNotExist();
    error FeeManager__OTCExecutionTermsFailed();

    /// CONSTRUCTOR ///

    constructor(ICentralRegistry centralRegistry_) {
        CentralRegistryLib._isCentralRegistry(centralRegistry_);
        centralRegistry = centralRegistry_;
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Allows the contract to receive native gas tokens for
    ///         cross-chain operations and fee collection.
    receive() external payable {}

    /// @notice Performs multiple token swaps in a single transaction, converting
    ///      the provided tokens to fee token on behalf of Curvance DAO.
    /// @param data Encoded swap data containing the details of each swap.
    /// @param tokens An array of token addresses corresponding to
    ///               the swap data, specifying the tokens to be swapped.
    function multiSwap(
        bytes calldata data,
        address[] calldata tokens
    ) external nonReentrant {
        if (!centralRegistry.hasHarvestPermissions(msg.sender)) {
            revert FeeManager__Unauthorized();
        }

        SwapperLib.Swap[] memory swapActions = abi.decode(
            data,
            (SwapperLib.Swap[])
        );

        uint256 numTokens = swapActions.length;
        if (numTokens != tokens.length) {
            revert FeeManager__SwapActionsAndTokenLengthMismatch(
                numTokens,
                tokens.length
            );
        }
        address currentToken;

        for (uint256 i; i < numTokens; ++i) {
            currentToken = tokens[i];
            // Check that Curvance DAO has not earmarked this token for OTC.
            if (rewardTokenInfo[currentToken].forOTC == 2) {
                continue;
            }

            if (rewardTokenInfo[currentToken].isRewardToken != 2) {
                revert FeeManager__SwapActionsCurrentTokenIsNotRewardToken(
                    i,
                    currentToken
                );
            }

            if (swapActions[i].inputToken != currentToken) {
                revert FeeManager__SwapActionsInputTokenIsNotCurrentToken(
                    i,
                    swapActions[i].inputToken,
                    currentToken
                );
            }

            if (swapActions[i].outputToken != _getFeeToken()) {
                revert FeeManager__SwapActionsOutputTokenIsNotFeeToken(
                    i,
                    swapActions[i].outputToken,
                    _getFeeToken()
                );
            }

            // Swap from token to output token (fee token).
            // Note: Because this is called from permissioned offchain
            //       operators we know we will not have a malicious actor on
            //       swap routing. We route liquidity to 1Inch with tight
            //       slippage requirement, meaning we do not need to
            //       separately check for slippage here.
            SwapperLib._swapSafe(centralRegistry, swapActions[i]);
        }
    }

    /// @notice Performs an (OTC) operation for a specific token,
    ///         transferring the token to the DAO in exchange for fee token.
    /// @dev The function validates that the token is earmarked for OTC and
    ///      calculates the amount of fee token required based on the
    ///      current prices.
    /// @param tokenToOTC Address of the token to be OTC purchased by the DAO.
    /// @param amountToOTC Amount of the token to be OTC purchased by the DAO.
    /// @param expectedFeeTokens The amount of `feeToken` expected to be paid
    ///                          for the desired OTC transaction.
    /// @param slippageLimit The % limit premium on top of `expectedFeeTokens`
    ///                      allowed as part of the OTC transaction,
    ///                      in exchange for `amountToOTC` of `tokenToOTC`.
    ///                      represented in `WAD`, aka 1e18.
    /// @param deadline The time by which the OTC transaction must be executed
    ///                 before it is no longer valid, in unix time.
    function executeOTC(
        address tokenToOTC,
        uint256 amountToOTC,
        uint256 expectedFeeTokens,
        uint256 slippageLimit,
        uint256 deadline
    ) external nonReentrant {
        _checkDaoPermissions();

        // Validate `tokenToOTC` is currently earmarked for OTC trades.
        if (rewardTokenInfo[tokenToOTC].forOTC < 2) {
            revert FeeManager__TokenIsNotEarmarked();
        }

        // Validate that the OTC order is not stale.
        if (deadline < block.timestamp) {
            revert FeeManager__OTCExecutionTermsFailed();
        }

        // Cache router to save gas.
        IOracleManager oracleManager = IOracleManager(
            centralRegistry.oracleManager()
        );

        address feeToken = _getFeeToken();

        (uint256 OTCTokenPrice, uint256 errorCodeSwap) = oracleManager
            .getPrice(tokenToOTC, true, true);
        (uint256 feeTokenPrice, uint256 errorCodeFeeToken) = oracleManager
            .getPrice(feeToken, true, true);

        // Validate we have fresh, functional prices.
        if (errorCodeFeeToken == 2 || errorCodeSwap == 2) {
            revert FeeManager__ConfigurationError();
        }

        address daoAddress = centralRegistry.daoAddress();
        // Oracle Manager always returns in 1e18 (WAD) format,
        // so we only need to worry about token decimal differences here.
        uint256 feeTokenRequiredForOTC = (
            ((OTCTokenPrice *
                amountToOTC *
                10 ** IERC20(feeToken).decimals()) / feeTokenPrice)
        ) / 10 ** IERC20(tokenToOTC).decimals();

        // Check if Curvance DAO is paying more than anticipated.
        if (expectedFeeTokens < feeTokenRequiredForOTC) {
            uint256 slippage = ((feeTokenRequiredForOTC - expectedFeeTokens) *
                WAD) / expectedFeeTokens;

            if (slippage > slippageLimit) {
                revert FeeManager__OTCExecutionTermsFailed();
            }
        }

        SafeTransferLib.safeTransferFrom(
            feeToken,
            msg.sender,
            address(this),
            feeTokenRequiredForOTC
        );

        // Give DAO the OTC'd tokens.
        SafeTransferLib.safeTransfer(tokenToOTC, daoAddress, amountToOTC);
    }

    /// @notice Pulls fees and sends them to the DAO, used pending governance
    ///         proposals.
    /// @dev Only callable by DAO permissioned operators.
    /// @param amount The amount of `feeToken` to transfer.
    /// @return The amount of transferred fee tokens to the DAO address.
    function pullFeesAsDAO(uint256 amount) external returns (uint256) {
        _checkDaoPermissions();

        address feeToken = _getFeeToken();

        uint256 feeTokens = IERC20(feeToken).balanceOf(address(this));

        // If the amount desired is greater than what is available,
        // move all fees.
        feeTokens = amount > feeTokens ? feeTokens : amount;

        // If there are no fees collected, revert.
        if (feeTokens == 0) {
            revert FeeManager__ConfigurationError();
        }

        // Transfer desired fees to DAO address.
        SafeTransferLib.safeTransfer(
            feeToken,
            centralRegistry.daoAddress(),
            feeTokens
        );

        return feeTokens;
    }

    /// @notice Sends collected fee tokens ex compounding bot stipend to the
    ///         Messaging Hub.
    /// @dev Only callable by the Messaging Hub. Does not fail if fees
    ///      collected equal 0.
    /// @param amount The amount of token to transfer.
    /// @return The amount of transferred fee tokens to the Messaging Hub.
    function pullFees(uint256 amount) external returns (uint256) {
        address messagingHub = centralRegistry.messagingHub();

        if (msg.sender != messagingHub) {
            revert FeeManager__Unauthorized();
        }

        address feeToken = _getFeeToken();
        uint256 feeTokens = IERC20(feeToken).balanceOf(address(this));

        // If the amount desired is greater than what is available,
        // move all fees.
        feeTokens = amount > feeTokens ? feeTokens : amount;

        // If there are no fees collected, can just return.
        if (feeTokens == 0) {
            return 0;
        }

        uint256 compoundingFee = (feeTokens * vaultCompoundFee()) /
            vaultHarvestFee();

        // Move compounding fee accumulated to central registry to be used
        // for offchain harvester bots.
        if (compoundingFee > 0) {
            SafeTransferLib.safeTransfer(
                feeToken,
                centralRegistry.daoAddress(),
                compoundingFee
            );
        }

        feeTokens -= compoundingFee;

        if (feeTokens > 0) {
            // Move remaining fees on this chain to Messaging Hub to distribute.
            SafeTransferLib.safeTransfer(feeToken, messagingHub, feeTokens);
        }

        return feeTokens;
    }

    /// @notice Sends all left over fees to new fee manager.
    /// @dev This does not need to be permissioned as it pulls data
    ///      directly from the Central Registry meaning a malicious actor
    ///      cannot abuse this.
    function migrateFeeManager() external {
        address newFeeManager = centralRegistry.feeManager();
        if (newFeeManager == address(this)) {
            revert FeeManager__NewFeeManagerIsNotChanged();
        }

        address[] memory currentRewardTokens = rewardTokens;
        uint256 numTokens = currentRewardTokens.length;
        uint256 tokenBalance;

        // Send remaining fee tokens to new fee manager, if any.
        for (uint256 i; i < numTokens; ++i) {
            tokenBalance = IERC20(currentRewardTokens[i]).balanceOf(
                address(this)
            );

            if (tokenBalance > 0) {
                SafeTransferLib.safeTransfer(
                    currentRewardTokens[i],
                    newFeeManager,
                    tokenBalance
                );
            }   
        }

        address feeToken = _getFeeToken();
        tokenBalance = IERC20(feeToken).balanceOf(address(this));

        // Send remaining fee token to new fee manager, if any.
        if (tokenBalance > 0) {
            SafeTransferLib.safeTransfer(
                feeToken,
                newFeeManager,
                tokenBalance
            );
        }
    }

    /// @notice Set status on whether a token should be earmarked to OTC.
    /// @param state 2 = earmarked; 0 or 1 = not earmarked.
    function setEarmarked(address token, bool state) external {
        _checkDaoPermissions();

        rewardTokenInfo[token].forOTC = state ? 2 : 1;
    }

    /// @notice Adds multiple reward tokens to the contract for offchain bots
    ///         to read.
    /// @dev Does not fail on duplicate token, merely skips it and continues.
    /// @param newTokens Array of token addresses to be added as reward
    ///                  tokens.
    function addRewardTokens(address[] calldata newTokens) external {
        _checkDaoPermissions();

        uint256 numTokens = newTokens.length;
        if (numTokens == 0) {
            revert FeeManager__TokenLengthIsZero();
        }

        for (uint256 i; i < numTokens; ++i) {
            // If we already support the token just skip it.
            if (rewardTokenInfo[newTokens[i]].isRewardToken == 2) {
                continue;
            }

            // Add reward token data to both rewardTokenInfo
            // and rewardTokenData.
            _addRewardToken(newTokens[i]);
        }
    }

    /// @notice Removes a reward token from the contract data that offchain
    ///         bots read.
    /// @dev Will revert on unsupported token address.
    /// @param rewardTokenToRemove The address of the token to be removed.
    function removeRewardToken(address rewardTokenToRemove) external {
        _checkDaoPermissions();

        RewardToken storage tokenToRemove = rewardTokenInfo[
            rewardTokenToRemove
        ];
        if (tokenToRemove.isRewardToken != 2) {
            revert FeeManager__RemovalTokenIsNotRewardToken();
        }

        address[] memory currentTokens = rewardTokens;
        uint256 numTokens = currentTokens.length;
        uint256 tokenIndex = numTokens;

        for (uint256 i; i < numTokens; ++i) {
            if (currentTokens[i] == rewardTokenToRemove) {
                // We found the token so break out of the loop.
                tokenIndex = i;
                break;
            }
        }

        // Subtract 1 from numTokens so we properly have the end index.
        if (tokenIndex == numTokens--) {
            // We were unable to find the token in the array,
            // so something is wrong and we need to revert.
            revert FeeManager__RemovalTokenDoesNotExist();
        }

        // Copy last item in list to location of item to be removed.
        address[] storage currentList = rewardTokens;
        // Copy the last token index slot to tokenIndex.
        currentList[tokenIndex] = currentList[numTokens];
        // Remove the last element.
        currentList.pop();

        // Now delete the reward token support flag from mapping.
        tokenToRemove.isRewardToken = 1;
    }

    /// @notice Retrieves the balances of all reward tokens currently held by
    ///         the Fee Manager.
    /// @dev Used by bots and governance; cost scales with token count.
    /// @return tokenBalances An array of uint256 values,
    ///         representing the current balances of each reward token.
    function getRewardTokenBalances()
        external
        view
        returns (uint256[] memory)
    {
        address[] memory currentTokens = rewardTokens;
        uint256 numTokens = currentTokens.length;
        uint256[] memory tokenBalances = new uint256[](numTokens);

        for (uint256 i; i < numTokens; ++i) {
            tokenBalances[i] = IERC20(currentTokens[i]).balanceOf(
                address(this)
            );
        }

        return tokenBalances;
    }

    /// PUBLIC FUNCTIONS ///

    /// @notice Fetches the current Oracle Manager from the central registry.
    /// @return Current OracleManager interface address.
    function getOracleManager() public view returns (IOracleManager) {
        return IOracleManager(centralRegistry.oracleManager());
    }

    /// @notice Vault compound fee represented in basis point form (100 = 1%).
    /// @dev Returns the vaults current amount of yield used
    ///      for compounding rewards.
    /// @return The vault's current compound fee.
    function vaultCompoundFee() public view returns (uint256) {
        return centralRegistry.protocolCompoundFee();
    }

    /// @notice Vault harvest fee represented in basis point form (100 = 1%).
    /// @dev Returns the vaults current protocol fee for yield generated
    ///      inside the Curvance Protocol. This is equal to
    ///      Protocol Compounding Fee + Protocol Yield Fee.
    /// @return The vault's current harvest fee.
    function vaultHarvestFee() public view returns (uint256) {
        return centralRegistry.protocolHarvestFee();
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Returns the current fee token address.
    function _getFeeToken() internal view returns (address) {
        return centralRegistry.feeToken();
    }

    /// @notice Adds `newToken` to `rewardTokens` array and
    ///         rewardTokenInfo mapping so offchain bots knows a new token
    ///         has been added.
    function _addRewardToken(address newToken) internal {
        rewardTokens.push() = newToken;
        // Configure for isRewardToken = true and forOTC = false,
        // if the DAO wants to accumulate reward tokens it will need to be
        // passed by protocol governance.
        rewardTokenInfo[newToken] = RewardToken({
            isRewardToken: 2,
            forOTC: 1
        });
    }

    /// @dev Checks whether the caller has sufficient permissioning.
    function _checkDaoPermissions() internal view {
        if (!centralRegistry.hasDaoPermissions(msg.sender)) {
            revert FeeManager__Unauthorized();
        }
    }
}
