// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { ICToken } from "contracts/interfaces/ICToken.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";
import { WAD, BPS } from "contracts/libraries/ConstantsLib.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

// Todo: 
// add behavior for when totalSupply is 0
// Add storage pointers
// add helpers
// change variable names
// optimize logic
// reduce storage reads

contract LendingOptimizer {

    struct RebalanceAction {
        IBorrowableCToken cToken;
        uint256 assets;
        bool isDeposit;
    }

    struct RemoveAction {
        IBorrowableCToken cToken;
        uint256 reallocationAmount;
    }

    address public immutable underlying;
    ICentralRegistry public immutable centralRegistry;

    address[] public approvedCTokensList;
    mapping(address => uint256) public allocationCaps;
    uint256 public fee;

    uint256 public totalSupply;
    mapping(address => uint256) public balances;

    uint256 public exchangeRateHighWatermark;

    constructor(
        address _underlying,
        address _centralRegistry,
        address[] memory _approvedCTokens,
        uint256[] memory _allocationCapsBps,
        uint256 _feeBps
    )
    {
        if (_approvedCTokens.length > 6) {
            // revert
        }
        if(_approvedCTokens.length != _allocationCapsBps.length) {
            // revert
        }
        underlying = _underlying;
        centralRegistry = ICentralRegistry(_centralRegistry);
        fee = _feeBps;

        uint256 totalAllocation;
        
        for(uint256 i; i < _approvedCTokens.length; i++) {
            if(IBorrowableCToken(_approvedCTokens[i]).asset() != _underlying) 
            {
                // revert
            }
            if(centralRegistry.isMarketManager(
                (address(IBorrowableCToken(_approvedCTokens[i]).marketManager())))) 
            {
                // revert
            }
            // convert cap to WAD
            uint256 alloCapWAD = _allocationCapsBps[i] * 1e14;
            allocationCaps[_approvedCTokens[i]] = alloCapWAD;
            totalAllocation += alloCapWAD;
        }

        if (totalAllocation < WAD) {
            // revert
        }

        approvedCTokensList = _approvedCTokens;
        exchangeRateHighWatermark = WAD;
    }

    function deposit(
        uint256[] memory assetsAmts,
        address receiver
    ) external returns (uint256 shares) {
        if (assetsAmts.length != approvedCTokensList.length) {
            // revert
        }

        _accruePerformanceFee();

        // already updated in _accruePerformanceFee
        uint256 totalAssetsBefore = totalAssets();
        uint256 totalUserDeposit;

        // accrue on all borrowableCTokens
        // Sum optimizer total assets pre deposit
        // Sum user asset input
        uint256 mumCTokens = approvedCTokensList.length;
        for (uint256 i; i < mumCTokens; ++i) {
            if(assetsAmts[i] == 0) continue;
            totalUserDeposit += assetsAmts[i];
        }

        SafeTransferLib.safeTransferFrom(address(underlying), msg.sender, address(this), totalUserDeposit);

        for(uint256 i; i < mumCTokens; i++) {
            if (assetsAmts[i] == 0) continue;
            IBorrowableCToken cToken = IBorrowableCToken(approvedCTokensList[i]);
            // maybe approve max so we dont have to do this each time
            SafeTransferLib.safeApprove(underlying, address(cToken), assetsAmts[i]);
            cToken.deposit(assetsAmts[i], address(this));
        }

        shares = FixedPointMathLib.mulDiv(totalUserDeposit, totalSupply, totalAssetsBefore);

        _mint(receiver, shares);
    }

    function mint(uint256 shares, address receiver)
        public
        returns (uint256 assets)
    {
    }

    function withdraw(
        uint256[] memory assetsAmts,
        IBorrowableCToken[] memory cTokens,
        address receiver,
        address owner)
        public
        returns (uint256 shares)
    {

    }

    function redeem(uint256 shares, address receiver, address owner)
        public
        returns (uint256 assets)
    {
        return 0;
    }

    function rebalance(RebalanceAction[] memory actions) public {
        _hasHarvesterPermissions();

        if(actions.length != approvedCTokensList.length) {
            //revert
        }

        uint256[] memory assetsAmts = new uint256[](approvedCTokensList.length);
        uint256 ta;

        // validate + accrue + withdraw first
        for (uint256 i; i < approvedCTokensList.length; ++i) {
            if (allocationCaps[address(actions[i].cToken)] <= 0) {
                // revert
            }
            if(actions[i].cToken < actions[i-1].cToken) {
                // revert
            }
            actions[i].cToken.accrueIfNeeded();
            if (actions[i].assets == 0) {
                continue;
            }
            if(!actions[i].isDeposit) {
                actions[i].cToken.withdraw(actions[i].assets, address(this), address(this));
            }
        }

        // deposits second
        for (uint256 i; i < approvedCTokensList.length; ++i) {
            if (actions[i].assets == 0) {
                continue;
            }
            if(actions[i].isDeposit) {
                actions[i].cToken.deposit(actions[i].assets, address(this));
            }
        }

        ta = totalAssets();
        // uint256 totalAllocation;

        // check caps
        for (uint256 i; i < approvedCTokensList.length; ++i) {
            uint256 allocationCap = allocationCaps[address(approvedCTokensList[i])];
               uint256 currentAllocation = 
                FixedPointMathLib.mulDivUp(assetsAmts[i], WAD, ta);

            if (currentAllocation > allocationCap) {
                // revert
            }

            // totalAllocation += currentAllocation;
        }

        // if (totalAllocation < WAD) {
        //     // revert
        // }
    }

    function removeApprovedAsset(uint256 indexRemove, uint256 indexAdd) public {
        if (indexRemove == indexAdd) {
            // revert
        }
        _hasHarvesterPermissions();
        _accruePerformanceFee();

        // First redeem shares from cToken being removed
        // Then, add assets to a different cToken. 
        IBorrowableCToken cTokenToRemove = 
            IBorrowableCToken(approvedCTokensList[indexRemove]);

        address cTokenToAdd = approvedCTokensList[indexAdd];

        uint256 assetsRedeemed = cTokenToRemove.redeem(
            cTokenToRemove.balanceOf(address(this)),
            address(this),
            address(this)
        );

        SafeTransferLib.safeApprove(
            underlying,
            address(cTokenToAdd),
            assetsRedeemed
        );

        IBorrowableCToken(cTokenToAdd).deposit(
            assetsRedeemed,
            address(this)
        );

        // Update accounting to remove cToken from list
        uint256 cTokenListLength = approvedCTokensList.length;
        address cTokenToMove = approvedCTokensList[cTokenListLength - 1];
        approvedCTokensList[indexRemove] = cTokenToMove;
        approvedCTokensList[cTokenListLength - 1] = address(cTokenToRemove);
        approvedCTokensList.pop();

        delete allocationCaps[address(cTokenToRemove)];

        // Check new allocation ratios

        uint256 newCTokenListLength = cTokenListLength - 1;
        uint256 ta;
        uint256[] memory assetsPerCToken = new uint256[](newCTokenListLength);

        for (uint256 i; i < newCTokenListLength; i++) {
            address cTokenAddress = approvedCTokensList[i];
            IBorrowableCToken cToken = IBorrowableCToken(cTokenAddress);
            uint256 shareBalance = cToken.balanceOf(address(this));
            // No need to call accrueIfNeeded() here because _accruePerformanceFee()
            // already called exchangeRateUpdated(), which accrues all markets this tx.
            uint256 assets = cToken.convertToAssets(shareBalance);
            ta += assets;
            assetsPerCToken[i] = assets;
        }

        uint256 totalAllocationCaps;

        for (uint256 i; i < newCTokenListLength; i++) {
            uint256 allocation = FixedPointMathLib.mulDiv(
                assetsPerCToken[i],
                WAD,
                ta
            );
            uint256 allocationCap = allocationCaps[approvedCTokensList[i]];
            if (allocation > allocationCap) {
                // revert
            }
            totalAllocationCaps += allocationCap;
        }

        if (totalAllocationCaps < WAD) {
            // revert
        }
    }

    function addApprovedAssset(address newAsset, uint256 capBps) public {
        if(newAsset == address(0)) {
            // revert
        }
        if(allocationCaps[newAsset] > 0) {
            // revert
        }

        IBorrowableCToken cToken = IBorrowableCToken(newAsset);

        if(cToken.asset() != underlying) 
        {
            // revert
        }
        if(centralRegistry.isMarketManager(
            (address(cToken.marketManager())))) 
        {
            // revert
        }

        approvedCTokensList.push(newAsset);
        allocationCaps[newAsset] = capBps;

    }

    // update one cap at a time to reduce chances of human error
    function updateCap(address cToken, uint256 newCapBps) public {
        _hasHarvesterPermissions();

        if(allocationCaps[cToken] == 0) {
            // revert
        }
        if(newCapBps > BPS || newCapBps == 0) {
            // revert
        }

        allocationCaps[cToken] = (newCapBps * 1e14);

        uint256 totalCaps;

        uint256 cTokenListLength = approvedCTokensList.length;
        for(uint256 i; i < cTokenListLength; i++) {
            totalCaps += allocationCaps[approvedCTokensList[i]];
        }

        if(totalCaps < WAD) {
            // revert
        }

    }

    function exchangeRateUpdated() public returns (uint256) {
        uint256 ta;
        uint256 approvedCTokensListLength = approvedCTokensList.length;
        for (uint256 i; i < approvedCTokensListLength; i++) {
            address cToken = approvedCTokensList[i];
            IBorrowableCToken(cToken).accrueIfNeeded();
            ta += IBorrowableCToken(cToken).convertToAssets(IBorrowableCToken(cToken).balanceOf(address(this)));
        }

        return FixedPointMathLib.mulDiv(WAD, ta, totalSupply);
    }

    function exchangeRate() public view returns (uint256) {
        uint256 ta;
        uint256 approvedCTokensListLength = approvedCTokensList.length;
        for (uint256 i; i < approvedCTokensListLength; i++) {
            address cToken = approvedCTokensList[i];
            ta += IBorrowableCToken(cToken).convertToAssets(IBorrowableCToken(cToken).balanceOf(address(this)));
        }
        return FixedPointMathLib.mulDiv(WAD, ta, totalSupply);
    }

    function totalAssets() public view returns (uint256) {
        uint256 ta;
        uint256 approvedCTokensListLength = approvedCTokensList.length;
        for (uint256 i; i < approvedCTokensListLength; i++) {
            address cToken = approvedCTokensList[i];
            ta += IBorrowableCToken(cToken).convertToAssets(IBorrowableCToken(cToken).balanceOf(address(this)));
        }
        return ta;
    }

    function totalAssetsUpdated() public returns (uint256) {
        uint256 ta;
        uint256 approvedCTokensListLength = approvedCTokensList.length;
        for (uint256 i; i < approvedCTokensListLength; i++) {
            address cToken = approvedCTokensList[i];
            IBorrowableCToken(cToken).accrueIfNeeded();
            ta += IBorrowableCToken(cToken).convertToAssets(IBorrowableCToken(cToken).balanceOf(address(this)));
        }
        return ta;
    }

    function _mint(address to, uint256 shares) internal {
        totalSupply += shares;
        balances[to] += shares;
    }
    function _burn(address from, uint256 shares) internal {
        totalSupply -= shares;
        balances[from] -= shares;
    }

    function _accruePerformanceFee() internal {
        if (fee == 0) return;

        uint256 supply = totalSupply;
        uint256 currentRate = exchangeRateUpdated();
        uint256 highRate = exchangeRateHighWatermark;

        // If no exchange rate hasnt increased, return
        if (currentRate <= highRate) return;

        uint256 currentAssets = totalAssets();

        // Calculate assets at watermark
        uint256 highAssets = FixedPointMathLib.mulDiv(highRate, supply, WAD);

        uint256 profit = currentAssets - highAssets;

        // calculate fee from profit
        uint256 feeAssets = FixedPointMathLib.mulDivUp(profit, fee, WAD);

        if (feeAssets == 0) {
            // do something, return early or maybe update watermark
        }

        // calculate shares to mint
        uint256 feeShares = FixedPointMathLib.fullMulDivUp(
            feeAssets,
            supply,
            currentAssets - feeAssets
        );

        address dao = centralRegistry.daoAddress();
        _mint(dao, feeShares);

        // calculate new water mark exchange rate
        uint256 sAfter = supply + feeShares;
        uint256 rAfter = FixedPointMathLib.mulDiv(WAD, currentAssets, sAfter);

        exchangeRateHighWatermark = rAfter;

    }

    function _hasHarvesterPermissions() internal view returns (bool) {
        if(!centralRegistry.hasHarvestPermissions(msg.sender)) {
            // revert
        }
    }


}