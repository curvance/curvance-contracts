// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {StrategyCToken} from "contracts/market/token/StrategyCToken.sol";
import {MockToken} from "contracts/mocks/MockToken.sol";

import {
    SafeTransferLib
} from "contracts/libraries/external/SafeTransferLib.sol";

import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";
import {IERC20} from "contracts/interfaces/IERC20.sol";

interface IStrategyCallbackProbe {
    function observe() external;
}

contract StrategyRegistryStub {
    function supportsInterface(bytes4 interfaceId)
        external
        pure
        returns (bool)
    {
        return interfaceId != 0xffffffff;
    }

    function isMarketManager(address) external pure returns (bool) {
        return true;
    }

    function hasHarvestPermissions(address) external pure returns (bool) {
        return true;
    }
}

contract StrategyMarketManagerStub {
    function canMint(address) external pure {}
}

contract StrategyCallbackGauge {
    MockToken public immutable assetToken;
    IStrategyCallbackProbe public probe;

    constructor(MockToken assetToken_) {
        assetToken = assetToken_;
    }

    function setProbe(IStrategyCallbackProbe probe_) external {
        probe = probe_;
    }

    function deposit(uint256 assets) external {
        SafeTransferLib.safeTransferFrom(
            address(assetToken), msg.sender, address(this), assets
        );
        probe.observe();
    }

    function mintYield(address receiver, uint256 assets) external {
        assetToken.mint(assets);
        SafeTransferLib.safeTransfer(address(assetToken), receiver, assets);
    }
}

contract StrategyCTokenHarness is StrategyCToken {
    StrategyCallbackGauge public immutable gauge;

    constructor(
        ICentralRegistry centralRegistry_,
        IERC20 asset_,
        address marketManager_,
        StrategyCallbackGauge gauge_
    ) StrategyCToken(centralRegistry_, asset_, marketManager_, 1 days) {
        gauge = gauge_;
    }

    function seedAccounting(address owner, uint256 assets, uint256 shares)
        external
    {
        _totalAssets = assets;
        _mint(owner, shares);
        _setlastVestingClaim(uint40(block.timestamp));
        harvestingPaused = 1;
    }

    function harvest(bytes calldata data)
        external
        override
        nonReentrant
        returns (uint256 yield)
    {
        _canHarvest();
        _accrueIfNeeded();

        if (_checkVestingFinished(_vestingData)) {
            _updateVestingPeriodIfNeeded();
            yield = abi.decode(data, (uint256));

            // Models reward conversion completing before the final external
            // gauge call in the Velodrome/Aerodrome harvest implementations.
            gauge.mintYield(address(this), yield);
            _afterDeposit(yield, 0);

            // Production strategies install the new vest only after their
            // final callback-capable external call has returned.
            _setVestingData(yield);
            emit Harvest(yield);
        }
    }

    function _afterDeposit(uint256 assets, uint256) internal override {
        SafeTransferLib.safeApprove(asset(), address(gauge), assets);
        gauge.deposit(assets);
    }

    function _beforeWithdraw(uint256, uint256) internal pure override {}
}

contract StrategyReadOnlyCallbackProbe is IStrategyCallbackProbe {
    bytes4 internal constant _REENTRANCY_SELECTOR =
        bytes4(keccak256("Reentrancy()"));
    uint256 internal constant _COLLATERAL_SHARES = 100e18;

    StrategyCTokenHarness public immutable strategy;

    uint256 public callbackCount;
    uint256 public observedExchangeRate;
    uint256 public observedUpdatedExchangeRate;
    uint256 public observedPreviewAssets;
    uint256 public observedCollateralValue;
    uint256 public observedSupply;

    bool public totalAssetsSucceeded;
    bool public convertToAssetsSucceeded;
    bool public depositSucceeded;
    bool public redeemSucceeded;
    bool public transferSucceeded;

    bytes4 public totalAssetsError;
    bytes4 public convertToAssetsError;
    bytes4 public depositError;
    bytes4 public redeemError;
    bytes4 public transferError;

    constructor(StrategyCTokenHarness strategy_) {
        strategy = strategy_;
    }

    function observe() external {
        ++callbackCount;

        observedExchangeRate = strategy.exchangeRate();
        observedUpdatedExchangeRate = strategy.exchangeRateUpdated();
        observedPreviewAssets = strategy.previewRedeem(1e18);
        observedSupply = strategy.totalSupply();
        observedCollateralValue =
            (_COLLATERAL_SHARES * observedUpdatedExchangeRate) / 1e18;

        bytes memory result;
        (totalAssetsSucceeded, result) = address(strategy)
            .staticcall(abi.encodeWithSignature("totalAssets()"));
        totalAssetsError = _selector(result);

        (convertToAssetsSucceeded, result) = address(strategy)
            .staticcall(
                abi.encodeWithSignature("convertToAssets(uint256)", 1e18)
            );
        convertToAssetsError = _selector(result);

        (depositSucceeded, result) = address(strategy)
            .call(
                abi.encodeWithSignature(
                    "deposit(uint256,address)", 1, address(this)
                )
            );
        depositError = _selector(result);

        (redeemSucceeded, result) = address(strategy)
            .call(
                abi.encodeWithSignature(
                    "redeem(uint256,address,address)",
                    1,
                    address(this),
                    address(this)
                )
            );
        redeemError = _selector(result);

        (transferSucceeded, result) = address(strategy)
            .call(
                abi.encodeWithSignature(
                    "transfer(address,uint256)", address(0xBEEF), 1
                )
            );
        transferError = _selector(result);
    }

    function allGuardedCallsFailedWithReentrancy()
        external
        view
        returns (bool)
    {
        return !totalAssetsSucceeded && !convertToAssetsSucceeded
            && !depositSucceeded && !redeemSucceeded && !transferSucceeded
            && totalAssetsError == _REENTRANCY_SELECTOR
            && convertToAssetsError == _REENTRANCY_SELECTOR
            && depositError == _REENTRANCY_SELECTOR
            && redeemError == _REENTRANCY_SELECTOR
            && transferError == _REENTRANCY_SELECTOR;
    }

    function _selector(bytes memory revertData)
        internal
        pure
        returns (bytes4 result)
    {
        if (revertData.length >= 4) {
            assembly {
                result := mload(add(revertData, 0x20))
            }
        }
    }
}

contract StrategyCTokenReadOnlyReentrancyProofTest is Test {
    uint256 internal constant _BASE_ASSETS = 100e18;
    uint256 internal constant _BASE_SHARES = 100e18;
    uint256 internal constant _HARVEST_YIELD = 20e18;

    MockToken internal assetToken;
    StrategyCallbackGauge internal gauge;
    StrategyCTokenHarness internal strategy;
    StrategyReadOnlyCallbackProbe internal probe;

    function setUp() public {
        vm.warp(1_000_000);

        StrategyRegistryStub registry = new StrategyRegistryStub();
        StrategyMarketManagerStub marketManager =
            new StrategyMarketManagerStub();
        assetToken = new MockToken("Strategy LP", "sLP", 18);
        gauge = new StrategyCallbackGauge(assetToken);
        strategy = new StrategyCTokenHarness(
            ICentralRegistry(address(registry)),
            IERC20(address(assetToken)),
            address(marketManager),
            gauge
        );
        probe = new StrategyReadOnlyCallbackProbe(strategy);
        gauge.setProbe(probe);

        strategy.seedAccounting(address(this), _BASE_ASSETS, _BASE_SHARES);
        SafeTransferLib.safeTransfer(
            address(assetToken), address(gauge), _BASE_ASSETS
        );
    }

    function test_depositCallbackObservesInflatedRateBeforeShareMint() public {
        assetToken.approve(address(strategy), _BASE_ASSETS);

        uint256 shares = strategy.deposit(_BASE_ASSETS, address(this));

        assertEq(shares, _BASE_SHARES);
        assertEq(probe.callbackCount(), 1);
        assertEq(probe.observedSupply(), _BASE_SHARES);
        assertEq(probe.observedExchangeRate(), 2e18);
        assertEq(probe.observedUpdatedExchangeRate(), 2e18);
        assertEq(probe.observedPreviewAssets(), 2e18);
        assertEq(probe.observedCollateralValue(), 200e18);
        assertTrue(probe.allGuardedCallsFailedWithReentrancy());

        // The callback-visible inflation disappears only after the depositor's
        // shares are minted.
        assertEq(strategy.totalSupply(), 200e18);
        assertEq(strategy.totalAssets(), 200e18);
        assertEq(strategy.exchangeRate(), 1e18);
        assertEq(assetToken.balanceOf(address(gauge)), 200e18);
    }

    function test_harvestCallbackSeesOnlyFinalizedBaseline() public {
        strategy.harvest(abi.encode(_HARVEST_YIELD));

        assertEq(probe.callbackCount(), 1);
        assertEq(probe.observedSupply(), _BASE_SHARES);
        assertEq(probe.observedExchangeRate(), 1e18);
        assertEq(probe.observedUpdatedExchangeRate(), 1e18);
        assertEq(probe.observedPreviewAssets(), 1e18);
        assertEq(probe.observedCollateralValue(), _BASE_ASSETS);
        assertTrue(probe.allGuardedCallsFailedWithReentrancy());

        // Newly acquired yield is physically backed before the callback but
        // starts vesting only after the external call returns.
        assertEq(assetToken.balanceOf(address(gauge)), 120e18);
        assertEq(strategy.exchangeRate(), 1e18);

        vm.warp(block.timestamp + 1 days);
        assertApproxEqAbs(strategy.exchangeRate(), 1.2e18, 1);
        assertApproxEqAbs(strategy.totalAssets(), 120e18, 1);
    }

    function test_secondHarvestAccruesPriorVestBeforeCallback() public {
        strategy.harvest(abi.encode(_HARVEST_YIELD));
        vm.warp(block.timestamp + 1 days);

        strategy.harvest(abi.encode(10e18));

        // The completed prior vest is credited before the second callback;
        // the new yield is still excluded until that callback returns.
        assertEq(probe.callbackCount(), 2);
        assertApproxEqAbs(probe.observedExchangeRate(), 1.2e18, 1);
        assertApproxEqAbs(probe.observedUpdatedExchangeRate(), 1.2e18, 1);
        assertApproxEqAbs(probe.observedCollateralValue(), 120e18, 100);
        assertApproxEqAbs(strategy.exchangeRate(), 1.2e18, 1);

        vm.warp(block.timestamp + 1 days);
        assertApproxEqAbs(strategy.exchangeRate(), 1.3e18, 1);
        assertApproxEqAbs(strategy.totalAssets(), 130e18, 2);
        assertEq(assetToken.balanceOf(address(gauge)), 130e18);
    }
}
