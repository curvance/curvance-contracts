// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { ProtocolManagerDeployment } from "contracts/architecture/ProtocolManagerDeployment.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";

contract TestProtocolManagerDeployment is TestBaseMarketIsolated {
    address public constant WMON_ADDRESS =
        0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;

    uint256 constant BASE_UNDERLYING_RESERVE = 77777;

    ProtocolManagerDeployment public deploymentManager;

    BorrowableCToken public borrowableCUSDC_MONAD;
    BorrowableCToken public borrowableCWMON;

    /// @dev Sets up cTokens and oracles but does NOT list tokens.
    ///      Listing is the deployment manager's job.
    function setUp() public virtual override {
        _fork("MON_NODE_URI_MONAD_MAINNET");

        _initMainConstantVariables();

        _deployCentralRegistry();
        _deployCVE();
        _deployRewardManager();
        _deployVeCVE();
        _deployGaugeManager();
        _deployMarketManager();
        _deployOracleManager();

        borrowableCUSDC_MONAD = _deployBorrowableCToken(_USDC_ADDRESS);
        borrowableCWMON = _deployBorrowableCToken(WMON_ADDRESS);

        MockV3Aggregator chainlinkUSDC_USD = new MockV3Aggregator(8, 1e8);
        address chainlinkWMON_USD = 0xBcD78f76005B7515837af6b50c7C52BCf73822fb;

        ChainlinkAdaptor chainlinkAdaptor = new ChainlinkAdaptor(
            ICentralRegistry(address(centralRegistry))
        );

        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));

        chainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            true,
            address(chainlinkUSDC_USD),
            0
        );
        chainlinkAdaptor.addAsset(WMON_ADDRESS, true, chainlinkWMON_USD, 0);

        oracleManager.addAssetPricingAdaptor(
            _USDC_ADDRESS,
            address(chainlinkAdaptor),
            100,
            50,
            100,
            50
        );
        oracleManager.addAssetPricingAdaptor(
            WMON_ADDRESS,
            address(chainlinkAdaptor),
            100,
            50,
            100,
            50
        );

        oracleManager.addCTokenSupport(address(borrowableCUSDC_MONAD));
        oracleManager.addCTokenSupport(address(borrowableCWMON));

        // Deploy the deployment manager with address(this) as owner.
        deploymentManager = new ProtocolManagerDeployment(
            ICentralRegistry(address(centralRegistry)),
            address(this)
        );

        // Grant market permissions to the deployment manager.
        centralRegistry.addMarketPermissions(address(deploymentManager));
    }

    /// ==================== DEPLOYMENT SUCCESS ==================== ///

    function test_deployMarket_success() public {
        _deployMarketViaManager();

        // Verify tokens are listed.
        assertTrue(marketManagerIsolated.isListed(address(borrowableCWMON)));
        assertTrue(
            marketManagerIsolated.isListed(address(borrowableCUSDC_MONAD))
        );
    }

    function test_deployMarket_correctTokensListedArray() public {
        _deployMarketViaManager();

        address[] memory listed = marketManagerIsolated.queryTokensListed();
        assertEq(listed.length, 2);
        assertEq(listed[0], address(borrowableCWMON));
        assertEq(listed[1], address(borrowableCUSDC_MONAD));
    }

    function test_deployMarket_mintPausedBothTokens() public {
        _deployMarketViaManager();

        (bool mintPaused0, , ) = marketManagerIsolated.actionsPaused(
            address(borrowableCWMON)
        );
        assertTrue(mintPaused0, "token0 mint should be paused");

        (bool mintPaused1, , ) = marketManagerIsolated.actionsPaused(
            address(borrowableCUSDC_MONAD)
        );
        assertTrue(mintPaused1, "token1 mint should be paused");
    }

    function test_deployMarket_otherActionsNotPaused() public {
        _deployMarketViaManager();

        // Collateralization and borrow should NOT be paused.
        (, bool collPaused0, bool borrowPaused0) = marketManagerIsolated
            .actionsPaused(address(borrowableCWMON));
        assertFalse(
            collPaused0,
            "token0 collateralization should not be paused"
        );
        assertFalse(borrowPaused0, "token0 borrow should not be paused");

        (, bool collPaused1, bool borrowPaused1) = marketManagerIsolated
            .actionsPaused(address(borrowableCUSDC_MONAD));
        assertFalse(
            collPaused1,
            "token1 collateralization should not be paused"
        );
        assertFalse(borrowPaused1, "token1 borrow should not be paused");

        // Market-wide pauses should also be off.
        assertEq(marketManagerIsolated.liquidationPaused(), 1);
        assertEq(marketManagerIsolated.redeemPaused(), 1);
        assertEq(marketManagerIsolated.transferPaused(), 1);
    }

    function test_deployMarket_collateralCapsSet() public {
        _deployMarketViaManager();

        assertEq(
            marketManagerIsolated.collateralCaps(address(borrowableCWMON)),
            1_000_000e18
        );
        assertEq(
            marketManagerIsolated.collateralCaps(
                address(borrowableCUSDC_MONAD)
            ),
            0
        );
    }

    function test_deployMarket_debtCapsSet() public {
        _deployMarketViaManager();

        assertEq(marketManagerIsolated.debtCaps(address(borrowableCWMON)), 0);
        assertEq(
            marketManagerIsolated.debtCaps(address(borrowableCUSDC_MONAD)),
            1_000_000e6
        );
    }

    function test_deployMarket_collConfigSet() public {
        _deployMarketViaManager();

        (
            uint256 collRatio,
            uint256 collReqSoft,
            uint256 collReqHard
        ) = marketManagerIsolated.collConfig(address(borrowableCWMON));

        assertEq(collRatio, 7000, "collRatio mismatch");
        // collReqSoft is stored as premium above BPS (4000 + 10000).
        assertEq(collReqSoft, 14000, "collReqSoft mismatch");
        // collReqHard is stored as premium above BPS (3000 + 10000).
        assertEq(collReqHard, 13000, "collReqHard mismatch");
    }

    function test_deployMarket_liquidationConfigSet() public {
        _deployMarketViaManager();

        (
            uint256 liqIncBase,
            uint256 liqIncCurve,
            uint256 liqIncMin,
            uint256 liqIncMax,
            uint256 closeFactorBase,
            uint256 closeFactorCurve,
            uint256 closeFactorMin,
            uint256 closeFactorMax
        ) = marketManagerIsolated.liquidationConfig(address(borrowableCWMON));

        // liqIncBase stored as BPS + incentive (10000 + 1000).
        assertEq(liqIncBase, 11000, "liqIncBase mismatch");
        // liqIncCurve = liqIncHard - liqIncBase (1500 - 1000).
        assertEq(liqIncCurve, 500, "liqIncCurve mismatch");
        // liqIncMin stored as BPS + min (10000 + 10).
        assertEq(liqIncMin, 10010, "liqIncMin mismatch");
        // liqIncMax stored as BPS + max (10000 + 2000).
        assertEq(liqIncMax, 12000, "liqIncMax mismatch");
        assertEq(closeFactorBase, 2000, "closeFactorBase mismatch");
        // closeFactorCurve = BPS - closeFactorBase (10000 - 2000).
        assertEq(closeFactorCurve, 8000, "closeFactorCurve mismatch");
        assertEq(closeFactorMin, 2000, "closeFactorMin mismatch");
        assertEq(closeFactorMax, 5000, "closeFactorMax mismatch");
    }

    function test_deployMarket_underlyingConsumed() public {
        _fundAndApprove();

        assertEq(
            IERC20(_USDC_ADDRESS).balanceOf(address(this)),
            BASE_UNDERLYING_RESERVE
        );
        assertEq(
            IERC20(WMON_ADDRESS).balanceOf(address(this)),
            BASE_UNDERLYING_RESERVE
        );

        MarketManagerIsolated.TokenConfig
            memory config0 = _getBasicTokenConfig(
                address(borrowableCWMON),
                1_000_000e18,
                0
            );
        MarketManagerIsolated.TokenConfig
            memory config1 = _getBasicTokenConfig(
                address(borrowableCUSDC_MONAD),
                0,
                1_000_000e6
            );

        deploymentManager.deployMarket(
            address(marketManagerIsolated),
            address(borrowableCWMON),
            address(borrowableCUSDC_MONAD),
            config0,
            config1
        );

        // Caller should have zero underlying remaining.
        assertEq(IERC20(_USDC_ADDRESS).balanceOf(address(this)), 0);
        assertEq(IERC20(WMON_ADDRESS).balanceOf(address(this)), 0);

        // Deployment manager contract should also have zero.
        assertEq(
            IERC20(_USDC_ADDRESS).balanceOf(address(deploymentManager)),
            0
        );
        assertEq(
            IERC20(WMON_ADDRESS).balanceOf(address(deploymentManager)),
            0
        );
    }

    function test_deployMarket_noResidualApproval() public {
        _deployMarketViaManager();

        // The deployment manager should have zero residual approval
        // to the cTokens after initializeDeposits consumed them.
        assertEq(
            IERC20(_USDC_ADDRESS).allowance(
                address(deploymentManager),
                address(borrowableCUSDC_MONAD)
            ),
            0,
            "USDC residual approval"
        );
        assertEq(
            IERC20(WMON_ADDRESS).allowance(
                address(deploymentManager),
                address(borrowableCWMON)
            ),
            0,
            "WMON residual approval"
        );
    }

    /// ==================== INTEGRATION ==================== ///

    function test_deployMarket_mintRevertsWhenPaused() public {
        _deployMarketViaManager();

        // Fund a user and try to mint; should revert because mint is paused.
        address user = address(0xBEEF);
        deal(WMON_ADDRESS, user, 1e18);

        vm.startPrank(user);
        IERC20(WMON_ADDRESS).approve(address(borrowableCWMON), 1e18);

        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        borrowableCWMON.deposit(1e18, user);
        vm.stopPrank();
    }

    /// ==================== AUTHORIZATION ==================== ///

    function test_deployMarket_revertsUnauthorized() public {
        _fundAndApprove();

        MarketManagerIsolated.TokenConfig
            memory config0 = _getBasicTokenConfig(
                address(borrowableCWMON),
                1_000_000e18,
                0
            );
        MarketManagerIsolated.TokenConfig
            memory config1 = _getBasicTokenConfig(
                address(borrowableCUSDC_MONAD),
                0,
                1_000_000e6
            );

        address unauthorized = address(0xdead);
        vm.prank(unauthorized);
        vm.expectRevert(
            ProtocolManagerDeployment
                .ProtocolManagerDeployment__Unauthorized
                .selector
        );
        deploymentManager.deployMarket(
            address(marketManagerIsolated),
            address(borrowableCWMON),
            address(borrowableCUSDC_MONAD),
            config0,
            config1
        );
    }

    function test_deployMarket_revertsWithoutMarketPermissions() public {
        _fundAndApprove();

        // Remove market permissions from the deployment manager.
        centralRegistry.removeMarketPermissions(address(deploymentManager));

        MarketManagerIsolated.TokenConfig
            memory config0 = _getBasicTokenConfig(
                address(borrowableCWMON),
                1_000_000e18,
                0
            );
        MarketManagerIsolated.TokenConfig
            memory config1 = _getBasicTokenConfig(
                address(borrowableCUSDC_MONAD),
                0,
                1_000_000e6
            );

        // Should revert at listTokens → _checkMarketPermissions.
        vm.expectRevert(
            MarketManagerIsolated.MarketManager__Unauthorized.selector
        );
        deploymentManager.deployMarket(
            address(marketManagerIsolated),
            address(borrowableCWMON),
            address(borrowableCUSDC_MONAD),
            config0,
            config1
        );
    }

    function test_deployMarket_revertsUnregisteredMarketBeforeReservePull()
        public
    {
        _fundAndApprove();

        address unregisteredMarket = makeAddr("unregisteredMarket");

        MarketManagerIsolated.TokenConfig
            memory config0 = _getBasicTokenConfig(
                address(borrowableCWMON),
                1_000_000e18,
                0
            );
        MarketManagerIsolated.TokenConfig
            memory config1 = _getBasicTokenConfig(
                address(borrowableCUSDC_MONAD),
                0,
                1_000_000e6
            );

        vm.expectRevert(
            ProtocolManagerDeployment
                .ProtocolManagerDeployment__ParametersAreInvalid
                .selector
        );
        deploymentManager.deployMarket(
            unregisteredMarket,
            address(borrowableCWMON),
            address(borrowableCUSDC_MONAD),
            config0,
            config1
        );

        assertEq(
            IERC20(_USDC_ADDRESS).balanceOf(address(this)),
            BASE_UNDERLYING_RESERVE,
            "USDC should not be pulled"
        );
        assertEq(
            IERC20(WMON_ADDRESS).balanceOf(address(this)),
            BASE_UNDERLYING_RESERVE,
            "WMON should not be pulled"
        );
        assertEq(
            IERC20(_USDC_ADDRESS).allowance(
                address(deploymentManager),
                address(borrowableCUSDC_MONAD)
            ),
            0,
            "USDC cToken approval should not be set"
        );
        assertEq(
            IERC20(WMON_ADDRESS).allowance(
                address(deploymentManager),
                address(borrowableCWMON)
            ),
            0,
            "WMON cToken approval should not be set"
        );
    }

    /// ==================== PARAMETER VALIDATION ==================== ///

    function test_deployMarket_revertsParametersInvalid_config0Mismatch()
        public
    {
        _fundAndApprove();

        // config0 has wrong cToken address.
        MarketManagerIsolated.TokenConfig
            memory config0 = _getBasicTokenConfig(
                address(0xbeef),
                1_000_000e18,
                0
            );
        MarketManagerIsolated.TokenConfig
            memory config1 = _getBasicTokenConfig(
                address(borrowableCUSDC_MONAD),
                0,
                1_000_000e6
            );

        vm.expectRevert(
            ProtocolManagerDeployment
                .ProtocolManagerDeployment__ParametersAreInvalid
                .selector
        );
        deploymentManager.deployMarket(
            address(marketManagerIsolated),
            address(borrowableCWMON),
            address(borrowableCUSDC_MONAD),
            config0,
            config1
        );
    }

    function test_deployMarket_revertsParametersInvalid_config1Mismatch()
        public
    {
        _fundAndApprove();

        MarketManagerIsolated.TokenConfig
            memory config0 = _getBasicTokenConfig(
                address(borrowableCWMON),
                1_000_000e18,
                0
            );
        // config1 has wrong cToken address.
        MarketManagerIsolated.TokenConfig
            memory config1 = _getBasicTokenConfig(
                address(0xbeef),
                0,
                1_000_000e6
            );

        vm.expectRevert(
            ProtocolManagerDeployment
                .ProtocolManagerDeployment__ParametersAreInvalid
                .selector
        );
        deploymentManager.deployMarket(
            address(marketManagerIsolated),
            address(borrowableCWMON),
            address(borrowableCUSDC_MONAD),
            config0,
            config1
        );
    }

    function test_deployMarket_revertsTokensAlreadyListed() public {
        // Deploy once successfully.
        _deployMarketViaManager();

        // Try to deploy again — listTokens checks tokensListed.length != 0.
        _fundAndApprove();

        MarketManagerIsolated.TokenConfig
            memory config0 = _getBasicTokenConfig(
                address(borrowableCWMON),
                1_000_000e18,
                0
            );
        MarketManagerIsolated.TokenConfig
            memory config1 = _getBasicTokenConfig(
                address(borrowableCUSDC_MONAD),
                0,
                1_000_000e6
            );

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__InvalidParameter.selector
        );
        deploymentManager.deployMarket(
            address(marketManagerIsolated),
            address(borrowableCWMON),
            address(borrowableCUSDC_MONAD),
            config0,
            config1
        );
    }

    function test_deployMarket_revertsSameToken() public {
        _fundAndApprove();

        MarketManagerIsolated.TokenConfig
            memory config0 = _getBasicTokenConfig(
                address(borrowableCWMON),
                1_000_000e18,
                0
            );
        MarketManagerIsolated.TokenConfig
            memory config1 = _getBasicTokenConfig(
                address(borrowableCWMON),
                0,
                1_000_000e6
            );

        // When token0 == token1, underlying0 == underlying1. The second
        // safeTransferFrom fails because the first already consumed the
        // caller's entire balance of that underlying. Reverts before
        // reaching listTokens.
        vm.expectRevert();
        deploymentManager.deployMarket(
            address(marketManagerIsolated),
            address(borrowableCWMON),
            address(borrowableCWMON),
            config0,
            config1
        );
    }

    function test_deployMarket_revertsInsufficientBalance() public {
        // Approve but don't fund.
        IERC20(_USDC_ADDRESS).approve(
            address(deploymentManager),
            BASE_UNDERLYING_RESERVE
        );
        IERC20(WMON_ADDRESS).approve(
            address(deploymentManager),
            BASE_UNDERLYING_RESERVE
        );

        MarketManagerIsolated.TokenConfig
            memory config0 = _getBasicTokenConfig(
                address(borrowableCWMON),
                1_000_000e18,
                0
            );
        MarketManagerIsolated.TokenConfig
            memory config1 = _getBasicTokenConfig(
                address(borrowableCUSDC_MONAD),
                0,
                1_000_000e6
            );

        vm.expectRevert();
        deploymentManager.deployMarket(
            address(marketManagerIsolated),
            address(borrowableCWMON),
            address(borrowableCUSDC_MONAD),
            config0,
            config1
        );
    }

    function test_deployMarket_revertsInsufficientApproval() public {
        // Fund but only approve for the first token.
        deal(_USDC_ADDRESS, address(this), BASE_UNDERLYING_RESERVE);
        deal(WMON_ADDRESS, address(this), BASE_UNDERLYING_RESERVE);

        IERC20(WMON_ADDRESS).approve(
            address(deploymentManager),
            BASE_UNDERLYING_RESERVE
        );
        // Intentionally skip USDC approval.

        MarketManagerIsolated.TokenConfig
            memory config0 = _getBasicTokenConfig(
                address(borrowableCWMON),
                1_000_000e18,
                0
            );
        MarketManagerIsolated.TokenConfig
            memory config1 = _getBasicTokenConfig(
                address(borrowableCUSDC_MONAD),
                0,
                1_000_000e6
            );

        vm.expectRevert();
        deploymentManager.deployMarket(
            address(marketManagerIsolated),
            address(borrowableCWMON),
            address(borrowableCUSDC_MONAD),
            config0,
            config1
        );
    }

    /// ==================== CONSTRUCTOR ==================== ///

    function test_constructor_setsImmutables() public view {
        assertEq(
            address(deploymentManager.centralRegistry()),
            address(centralRegistry)
        );
        assertEq(deploymentManager.owner(), address(this));
        assertEq(deploymentManager.BASE_UNDERLYING_RESERVE(), 77777);
    }

    /// ==================== UNPAUSE MARKET ==================== ///

    function test_deployMarket_setsPendingUnpause() public {
        _deployMarketViaManager();

        assertTrue(
            deploymentManager.pendingUnpause(address(marketManagerIsolated)),
            "pendingUnpause should be true after deploy"
        );
    }

    function test_revokeUnpause_ownerClearsAllowance() public {
        _deployMarketViaManager();

        deploymentManager.revokeUnpause(address(marketManagerIsolated));

        assertFalse(
            deploymentManager.pendingUnpause(address(marketManagerIsolated)),
            "pendingUnpause should be revoked"
        );
    }

    function test_revokeUnpause_marketPermissionsClearsStaleAllowance()
        public
    {
        _deployMarketViaManager();

        address marketAdmin = address(0xCAFE);
        centralRegistry.addMarketPermissions(marketAdmin);

        vm.startPrank(marketAdmin);
        marketManagerIsolated.setMintPaused(address(borrowableCWMON), false);
        marketManagerIsolated.setMintPaused(
            address(borrowableCUSDC_MONAD),
            false
        );
        deploymentManager.revokeUnpause(address(marketManagerIsolated));
        vm.stopPrank();

        assertFalse(
            deploymentManager.pendingUnpause(address(marketManagerIsolated)),
            "pendingUnpause should be revoked by market permissions"
        );

        vm.expectRevert(
            ProtocolManagerDeployment
                .ProtocolManagerDeployment__NoPendingUnpause
                .selector
        );
        deploymentManager.unpauseMarket(address(marketManagerIsolated));
    }

    function test_revokeUnpause_revertsUnauthorized() public {
        _deployMarketViaManager();

        address unauthorized = address(0xdead);
        vm.prank(unauthorized);
        vm.expectRevert(
            ProtocolManagerDeployment
                .ProtocolManagerDeployment__Unauthorized
                .selector
        );
        deploymentManager.revokeUnpause(address(marketManagerIsolated));

        assertTrue(
            deploymentManager.pendingUnpause(address(marketManagerIsolated)),
            "pendingUnpause should remain after unauthorized revoke"
        );
    }

    function test_revokeUnpause_succeedsWithoutPendingAllowance() public {
        deploymentManager.revokeUnpause(address(marketManagerIsolated));

        assertFalse(
            deploymentManager.pendingUnpause(address(marketManagerIsolated)),
            "pendingUnpause should remain false"
        );
    }

    function test_unpauseMarket_success() public {
        _deployMarketViaManager();

        deploymentManager.unpauseMarket(address(marketManagerIsolated));

        // Both tokens should have mint unpaused.
        (bool mintPaused0, , ) = marketManagerIsolated.actionsPaused(
            address(borrowableCWMON)
        );
        assertFalse(mintPaused0, "token0 mint should be unpaused");

        (bool mintPaused1, , ) = marketManagerIsolated.actionsPaused(
            address(borrowableCUSDC_MONAD)
        );
        assertFalse(mintPaused1, "token1 mint should be unpaused");
    }

    function test_unpauseMarket_consumesAllowance() public {
        _deployMarketViaManager();

        assertTrue(
            deploymentManager.pendingUnpause(address(marketManagerIsolated))
        );

        deploymentManager.unpauseMarket(address(marketManagerIsolated));

        assertFalse(
            deploymentManager.pendingUnpause(address(marketManagerIsolated)),
            "pendingUnpause should be consumed"
        );
    }

    function test_unpauseMarket_revertsNoPendingUnpause() public {
        // No deployment happened — no allowance exists.
        vm.expectRevert(
            ProtocolManagerDeployment
                .ProtocolManagerDeployment__NoPendingUnpause
                .selector
        );
        deploymentManager.unpauseMarket(address(marketManagerIsolated));
    }

    function test_unpauseMarket_revertsDoubleUnpause() public {
        _deployMarketViaManager();

        // First unpause succeeds.
        deploymentManager.unpauseMarket(address(marketManagerIsolated));

        // Second unpause reverts — allowance already consumed.
        vm.expectRevert(
            ProtocolManagerDeployment
                .ProtocolManagerDeployment__NoPendingUnpause
                .selector
        );
        deploymentManager.unpauseMarket(address(marketManagerIsolated));
    }

    function test_unpauseMarket_revertsUnauthorized() public {
        _deployMarketViaManager();

        address unauthorized = address(0xdead);
        vm.prank(unauthorized);
        vm.expectRevert(
            ProtocolManagerDeployment
                .ProtocolManagerDeployment__Unauthorized
                .selector
        );
        deploymentManager.unpauseMarket(address(marketManagerIsolated));
    }

    function test_unpauseMarket_onlyAffectsMint() public {
        _deployMarketViaManager();

        // Manually pause collateralization and borrow too.
        marketManagerIsolated.setCollateralizationPaused(
            address(borrowableCWMON),
            true
        );
        marketManagerIsolated.setBorrowPaused(
            address(borrowableCUSDC_MONAD),
            true
        );

        // Unpause market — should only touch mint.
        deploymentManager.unpauseMarket(address(marketManagerIsolated));

        // Mint should be unpaused.
        (bool mintPaused, , ) = marketManagerIsolated.actionsPaused(
            address(borrowableCWMON)
        );
        assertFalse(mintPaused, "mint should be unpaused");

        // Collateralization and borrow should still be paused.
        (, bool collPaused, ) = marketManagerIsolated.actionsPaused(
            address(borrowableCWMON)
        );
        assertTrue(collPaused, "collateralization should still be paused");

        (, , bool borrowPaused) = marketManagerIsolated.actionsPaused(
            address(borrowableCUSDC_MONAD)
        );
        assertTrue(borrowPaused, "borrow should still be paused");

        // Market-wide pauses should be unaffected.
        assertEq(marketManagerIsolated.liquidationPaused(), 1);
        assertEq(marketManagerIsolated.redeemPaused(), 1);
        assertEq(marketManagerIsolated.transferPaused(), 1);
    }

    function test_unpauseMarket_depositsWorkAfterUnpause() public {
        _deployMarketViaManager();

        // Deposits should fail while paused.
        address user = address(0xBEEF);
        deal(WMON_ADDRESS, user, 1e18);

        vm.startPrank(user);
        IERC20(WMON_ADDRESS).approve(address(borrowableCWMON), 1e18);
        vm.expectRevert(MarketManagerIsolated.MarketManager__Paused.selector);
        borrowableCWMON.deposit(1e18, user);
        vm.stopPrank();

        // Unpause via one-time allowance.
        deploymentManager.unpauseMarket(address(marketManagerIsolated));

        // Deposits should now succeed.
        vm.startPrank(user);
        borrowableCWMON.deposit(1e18, user);
        vm.stopPrank();

        assertTrue(
            borrowableCWMON.balanceOf(user) > 0,
            "user should have shares after unpause"
        );
    }

    /// HELPER FUNCTIONS ///

    function _getBasicTokenConfig(
        address cToken,
        uint256 collateralCap,
        uint256 debtCap
    ) internal pure returns (MarketManagerIsolated.TokenConfig memory config) {
        config.cToken = cToken;
        config.collRatio = 7000;
        config.collReqSoft = 4000;
        config.collReqHard = 3000;
        config.liqIncBase = 1000;
        config.liqIncHard = 1500;
        config.liqIncMin = 10;
        config.liqIncMax = 2000;
        config.closeFactorBase = 2000;
        config.closeFactorMin = 2000;
        config.closeFactorMax = 5000;
        config.collateralCap = collateralCap;
        config.debtCap = debtCap;
    }

    function _fundAndApprove() internal {
        deal(_USDC_ADDRESS, address(this), BASE_UNDERLYING_RESERVE);
        deal(WMON_ADDRESS, address(this), BASE_UNDERLYING_RESERVE);

        IERC20(_USDC_ADDRESS).approve(
            address(deploymentManager),
            BASE_UNDERLYING_RESERVE
        );
        IERC20(WMON_ADDRESS).approve(
            address(deploymentManager),
            BASE_UNDERLYING_RESERVE
        );
    }

    function _deployMarketViaManager() internal {
        _fundAndApprove();

        MarketManagerIsolated.TokenConfig
            memory config0 = _getBasicTokenConfig(
                address(borrowableCWMON),
                1_000_000e18,
                0
            );
        MarketManagerIsolated.TokenConfig
            memory config1 = _getBasicTokenConfig(
                address(borrowableCUSDC_MONAD),
                0,
                1_000_000e6
            );

        deploymentManager.deployMarket(
            address(marketManagerIsolated),
            address(borrowableCWMON),
            address(borrowableCUSDC_MONAD),
            config0,
            config1
        );
    }
}
