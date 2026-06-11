// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {SwapperLib} from "contracts/libraries/SwapperLib.sol";
import {ERC20} from "contracts/libraries/external/ERC20.sol";

import {CentralRegistry} from "contracts/architecture/CentralRegistry.sol";
import {OracleManager} from "contracts/oracles/OracleManager.sol";
import {
    ChainlinkAdaptor
} from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import {
    MarketManagerIsolated
} from "contracts/market/isolated/MarketManagerIsolated.sol";
import {DynamicIRM} from "contracts/market/DynamicIRM.sol";
import {
    BasePositionManager
} from "contracts/market/position-management/BasePositionManager.sol";
import {
    DualSidedVaultPositionManager
} from "contracts/market/position-management/DualSidedVaultPositionManager.sol";
import {SimpleCToken} from "contracts/market/token/SimpleCToken.sol";
import {BorrowableCToken} from "contracts/market/token/BorrowableCToken.sol";

import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";
import {IBorrowableCToken} from "contracts/interfaces/IBorrowableCToken.sol";
import {ICToken} from "contracts/interfaces/ICToken.sol";
import {IERC20} from "contracts/interfaces/IERC20.sol";

import {MockV3Aggregator} from "contracts/mocks/MockV3Aggregator.sol";

contract TestVaultPositionManagerReentrancy is Test {
    CentralRegistry public centralRegistry;
    OracleManager public oracleManager;
    ChainlinkAdaptor public chainlinkAdaptor;
    MarketManagerIsolated public marketManager;
    DualSidedVaultPositionManager public positionManager;
    ReentrantVault public vault;
    ReentrantAsset public underlying;
    ReentrantAsset public wrappedNative;
    SimpleCToken public cVault;
    BorrowableCToken public cUnderlying;

    address public user1 = makeAddr("user1");

    function setUp() public {
        vm.warp(1_700_000_000);

        underlying = new ReentrantAsset();
        wrappedNative = new ReentrantAsset();
        vault = new ReentrantVault(underlying);

        centralRegistry = new CentralRegistry(
            address(0),
            address(0),
            block.timestamp + 1,
            address(0),
            address(underlying)
        );
        oracleManager =
            new OracleManager(ICentralRegistry(address(centralRegistry)));
        chainlinkAdaptor =
            new ChainlinkAdaptor(ICentralRegistry(address(centralRegistry)));
        marketManager = new MarketManagerIsolated(
            ICentralRegistry(address(centralRegistry)), 10e18, false
        );

        centralRegistry.setOracleManager(address(oracleManager));
        centralRegistry.addMarketManager(address(marketManager));
        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));

        cVault = new SimpleCToken(
            ICentralRegistry(address(centralRegistry)),
            IERC20(address(vault)),
            address(marketManager)
        );
        DynamicIRM irm = new DynamicIRM(
            ICentralRegistry(address(centralRegistry)),
            1000,
            1000,
            5000,
            1000,
            100,
            100000
        );
        cUnderlying = new BorrowableCToken(
            ICentralRegistry(address(centralRegistry)),
            IERC20(address(underlying)),
            address(marketManager),
            address(irm)
        );
        irm.setLinkedToken(address(cUnderlying));

        MockV3Aggregator underlyingFeed = new MockV3Aggregator(8, 1e8);
        MockV3Aggregator vaultFeed = new MockV3Aggregator(8, 1e8);

        chainlinkAdaptor.addAsset(
            address(underlying), true, address(underlyingFeed), 0
        );
        chainlinkAdaptor.addAsset(address(vault), true, address(vaultFeed), 0);
        oracleManager.addAssetPricingAdaptor(
            address(underlying), address(chainlinkAdaptor), 100, 50, 100, 50
        );
        oracleManager.addAssetPricingAdaptor(
            address(vault), address(chainlinkAdaptor), 100, 50, 100, 50
        );
        oracleManager.addCTokenSupport(address(cVault));
        oracleManager.addCTokenSupport(address(cUnderlying));

        underlying.mintTo(address(this), 77777);
        vault.mintTo(address(this), 77777);
        underlying.approve(address(cUnderlying), 77777);
        vault.approve(address(cVault), 77777);

        marketManager.listTokens(address(cVault), address(cUnderlying));
        _setTokenConfig(address(cVault), 1_000_000e18, 0);
        _setTokenConfig(address(cUnderlying), 1_000_000e18, 1_000_000e18);

        positionManager = new DualSidedVaultPositionManager(
            ICentralRegistry(address(centralRegistry)),
            address(marketManager),
            address(wrappedNative)
        );
        marketManager.addPositionManager(address(positionManager));

        address liquidityProvider = makeAddr("liquidityProvider");
        underlying.mintTo(liquidityProvider, 1_000_000e18);
        vm.startPrank(liquidityProvider);
        underlying.approve(address(cUnderlying), type(uint256).max);
        cUnderlying.deposit(1_000_000e18, liquidityProvider);
        vm.stopPrank();
    }

    function test_vaultDepositCallbackCannotReenterPositionManager() public {
        uint256 initialVaultShares = 1_000e18;
        uint256 borrowAmount = 100e18;

        vault.mintTo(user1, initialVaultShares);
        vault.configureReentry(
            address(positionManager), ReentrantVault.ReentryMode.Leverage
        );

        DualSidedVaultPositionManager.LeverageAction memory action;
        action.borrowableCToken = IBorrowableCToken(address(cUnderlying));
        action.borrowAssets = borrowAmount;
        action.cToken = ICToken(address(cVault));

        vm.startPrank(user1);
        vault.approve(address(positionManager), type(uint256).max);
        positionManager.depositAndLeverage(initialVaultShares, action, 0.01e18);
        vm.stopPrank();

        assertTrue(vault.reentryAttempted(), "deposit reentry attempted");
        assertFalse(vault.reentrySucceeded(), "deposit reentry blocked");
        assertGt(cVault.collateralPosted(user1), initialVaultShares);
    }

    function test_vaultRedeemCallbackCannotReenterPositionManager() public {
        uint256 initialVaultShares = 1_000e18;
        uint256 borrowAmount = 100e18;

        vault.mintTo(user1, initialVaultShares);

        DualSidedVaultPositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken =
            IBorrowableCToken(address(cUnderlying));
        leverageAction.borrowAssets = borrowAmount;
        leverageAction.cToken = ICToken(address(cVault));

        vm.startPrank(user1);
        vault.approve(address(positionManager), type(uint256).max);
        positionManager.depositAndLeverage(
            initialVaultShares, leverageAction, 0.01e18
        );

        skip(20 minutes);

        vault.configureReentry(
            address(positionManager), ReentrantVault.ReentryMode.Deleverage
        );

        DualSidedVaultPositionManager.DeleverageAction memory deleverageAction;
        deleverageAction.cToken = ICToken(address(cVault));
        deleverageAction.collateralAssets = 10e18;
        deleverageAction.borrowableCToken =
            IBorrowableCToken(address(cUnderlying));
        deleverageAction.repayAssets = 1e18;

        uint256 debtBefore = cUnderlying.debtBalanceUpdated(user1);
        positionManager.deleverage(deleverageAction, 0.01e18);
        uint256 debtAfter = cUnderlying.debtBalanceUpdated(user1);
        vm.stopPrank();

        assertTrue(vault.reentryAttempted(), "redeem reentry attempted");
        assertFalse(vault.reentrySucceeded(), "redeem reentry blocked");
        assertLt(debtAfter, debtBefore, "deleverage should still repay debt");
    }

    function test_positionManagerCallbacksRejectDirectUnauthorizedCalls()
        public
    {
        DualSidedVaultPositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken =
            IBorrowableCToken(address(cUnderlying));
        leverageAction.borrowAssets = 1e18;
        leverageAction.cToken = ICToken(address(cVault));

        vm.expectRevert(
            BasePositionManager.BasePositionManager__Unauthorized.selector
        );
        positionManager.onBorrow(
            address(cUnderlying), 1e18, user1, leverageAction
        );

        DualSidedVaultPositionManager.DeleverageAction memory deleverageAction;
        deleverageAction.cToken = ICToken(address(cVault));
        deleverageAction.collateralAssets = 1e18;
        deleverageAction.borrowableCToken =
            IBorrowableCToken(address(cUnderlying));
        deleverageAction.swapActions = new SwapperLib.Swap[](0);

        vm.expectRevert(
            BasePositionManager.BasePositionManager__Unauthorized.selector
        );
        positionManager.onRedeem(
            address(cVault), 1e18, user1, deleverageAction
        );
    }

    function _setTokenConfig(
        address cToken,
        uint256 collateralCap,
        uint256 debtCap
    ) internal {
        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = cToken;
        tokenConfig.collRatio = 7000;
        tokenConfig.collReqSoft = 4000;
        tokenConfig.collReqHard = 3000;
        tokenConfig.liqIncBase = 1000;
        tokenConfig.liqIncHard = 1500;
        tokenConfig.liqIncMin = 10;
        tokenConfig.liqIncMax = 2000;
        tokenConfig.closeFactorBase = 2000;
        tokenConfig.closeFactorMin = 2000;
        tokenConfig.closeFactorMax = 5000;
        tokenConfig.collateralCap = collateralCap;
        tokenConfig.debtCap = debtCap;
        marketManager.updateTokenConfig(tokenConfig);
    }
}

contract ReentrantVault is ERC20 {
    enum ReentryMode {
        None,
        Leverage,
        Deleverage
    }

    ReentrantAsset public immutable underlying;
    address payable public reentryTarget;
    ReentryMode public reentryMode;
    bool public reentryAttempted;
    bool public reentrySucceeded;

    constructor(ReentrantAsset underlying_) {
        underlying = underlying_;
    }

    function name() public pure override returns (string memory) {
        return "Reentrant Vault";
    }

    function symbol() public pure override returns (string memory) {
        return "rvTOKEN";
    }

    function decimals() public pure override returns (uint8) {
        return 18;
    }

    function asset() external view returns (IERC20) {
        return IERC20(address(underlying));
    }

    function configureReentry(address reentryTarget_, ReentryMode reentryMode_)
        external
    {
        reentryTarget = payable(reentryTarget_);
        reentryMode = reentryMode_;
        reentryAttempted = false;
        reentrySucceeded = false;
    }

    function deposit(uint256 assets, address receiver)
        external
        returns (uint256 shares)
    {
        underlying.transferFrom(msg.sender, address(this), assets);
        _attemptReentry();
        shares = assets;
        _mint(receiver, shares);
    }

    function redeem(uint256 shares, address receiver, address owner)
        external
        returns (uint256 assets)
    {
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        _burn(owner, shares);
        _attemptReentry();
        assets = shares;
        underlying.mintTo(receiver, assets);
    }

    function previewDeposit(uint256 assets)
        external
        pure
        returns (uint256 shares)
    {
        shares = assets;
    }

    function previewRedeem(uint256 shares)
        external
        pure
        returns (uint256 assets)
    {
        assets = shares;
    }

    function mintTo(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function _attemptReentry() internal {
        if (reentryTarget == address(0) || reentryMode == ReentryMode.None) {
            return;
        }

        reentryAttempted = true;

        if (reentryMode == ReentryMode.Leverage) {
            DualSidedVaultPositionManager.LeverageAction memory action;
            try DualSidedVaultPositionManager(reentryTarget)
                .leverage(action, 0) {
                reentrySucceeded = true;
            } catch {}
        } else {
            DualSidedVaultPositionManager.DeleverageAction memory action;
            try DualSidedVaultPositionManager(reentryTarget)
                .deleverage(action, 0) {
                reentrySucceeded = true;
            } catch {}
        }
    }
}

contract ReentrantAsset is ERC20 {
    function name() public pure override returns (string memory) {
        return "Reentrant Asset";
    }

    function symbol() public pure override returns (string memory) {
        return "rASSET";
    }

    function decimals() public pure override returns (uint8) {
        return 18;
    }

    function mintTo(address account, uint256 amount) external {
        _mint(account, amount);
    }
}
