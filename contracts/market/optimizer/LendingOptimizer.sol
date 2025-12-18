// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { ICToken } from "contracts/interfaces/ICToken.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";
import { WAD, BPS } from "contracts/libraries/ConstantsLib.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract LendingOptimizer {

    struct RebalanceAction {
        IBorrowableCToken cToken;
        uint256 assets;
        bool isDeposit;
    }

    IERC20 public immutable underlying;
    ICentralRegistry public immutable centralRegistry;

    address[] public approvedCTokensList;
    mapping(address => uint256) public allocationCaps;
    uint256 public fee;

    uint256 public totalSupply;
    mapping(address => uint256) public balances;

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
        underlying = IERC20(_underlying);
        centralRegistry = ICentralRegistry(_centralRegistry);
        fee = _feeBps;

        uint256 totalAllocation;
        
        for(uint256 i; i < _approvedCTokens.length; i++) {
            if(address(IBorrowableCToken(_approvedCTokens[i])) != _underlying) {
                // revert
            }
            // convert cap to WAD
            uint256 alloCapWAD = _allocationCapsBps[i] * 1e14;
            allocationCaps[_approvedCTokens[i]] = alloCapWAD;
        }

        if (totalAllocation != WAD) {
            // revert
        }

        approvedCTokensList = _approvedCTokens;
    }

    function deposit(
        uint256[] memory assetsAmts,
        address receiver
    ) external returns (uint256 shares) {
        if (assetsAmts.length != approvedCTokensList.length) {
            // revert
        }

        address[] memory approvedCTokensList_ = approvedCTokensList;
        uint256 totalAssetsBefore;
        uint256 assetsAddedBeforeFee;
        uint256 assetsAddedAfterFee;
        uint256[] memory assetsAddedPerMarket = new uint256[](approvedCTokensList_.length);
        uint256 totalFee;

        // accrue on all borrowableCTokens
        // Sum optimizer total assets pre deposit
        // Sum user asset input
        // Get fee per market on user deposit
        // Store how much to actually deposit per market (with fee taken).
        // Sum net total assets to deposit (with fee taken).
        for (uint256 i; i < approvedCTokensList_.length; ++i) {
            IBorrowableCToken cToken = IBorrowableCToken(approvedCTokensList_[i]);

            cToken.accrueIfNeeded();

            uint256 balBefore = cToken.balanceOf(address(this));
            totalAssetsBefore += cToken.convertToAssets(balBefore);
                if(assetsAmts[i] > 0) { // maybe add minimum so fee doesnt round to 0
                    assetsAddedBeforeFee += assetsAmts[i];
                    uint256 feeAmount = _getFee(assetsAmts[i]);
                    totalFee += feeAmount;
                    uint256 assetsToDeposit = assetsAmts[i] - feeAmount;
                    assetsAddedPerMarket[i] = assetsToDeposit;
                    assetsAddedAfterFee += assetsToDeposit;
                }
        }

        SafeTransferLib.safeTransferFrom(address(underlying), msg.sender, address(this), assetsAddedBeforeFee);
        SafeTransferLib.safeTransfer(address(underlying), centralRegistry.daoAddress(), totalFee);

        for(uint256 i; i < approvedCTokensList_.length; i++) {
            if (assetsAddedPerMarket[i] == 0) continue;
            IBorrowableCToken cToken = IBorrowableCToken(approvedCTokensList_[i]);
            // maybe approve max so we dont have to do this each time
            SafeTransferLib.safeApprove(address(underlying), address(cToken), assetsAddedPerMarket[i]);
            cToken.deposit(assetsAddedPerMarket[i], address(this));
        }

        shares = FixedPointMathLib.mulDiv(assetsAddedAfterFee, totalSupply, totalAssetsBefore);

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

    function _getFee(uint256 assets) internal returns (uint256 feeAmount) {
        if (fee == 0) {
            return assets;
        }
        feeAmount = FixedPointMathLib.mulDivUp(assets, fee, WAD);
    }

    function _mint(address to, uint256 shares) internal {
        totalSupply += shares;
        balances[to] += shares;
    }
    function _burn(address from, uint256 shares) internal {
        totalSupply -= shares;
        balances[from] -= shares;
    }

    function _hasHarvesterPermissions() internal view returns (bool) {
        if(!centralRegistry.hasHarvestPermissions(msg.sender)) {
            // revert
        }
    }
}