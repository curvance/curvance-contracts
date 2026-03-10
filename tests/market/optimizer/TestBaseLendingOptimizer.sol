// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { SimpleCToken } from "contracts/market/token/SimpleCToken.sol";
import { DynamicIRM } from "contracts/market/DynamicIRM.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";
import { MockERC20 } from "tests/libraries/utils/mocks/MockERC20.sol";
import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";
import { LendingOptimizerHarness } from "./LendingOptimizerHarness.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { ICToken } from "contracts/interfaces/ICToken.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";


contract TestBaseLendingOptimizer is TestBaseMarketIsolated {

    LendingOptimizer optimizer;

    ICentralRegistry public liveCentralRegistry;

    address USDC_MONAD;

    address cUSDC_WMON_MARKET;
    address cUSDC_WBTC_MARKET;
    address cUSDC_WETH_MARKET;

    // Per-market infrastructure (populated by _deployMarket).
    mapping(address => address) internal _marketMgrs;
    mapping(address => address) internal _collaterals;
    mapping(address => address) internal _collCTokens;

    // Shared oracle infrastructure.
    OracleManager internal _oracleManager;
    ChainlinkAdaptor internal _chainlinkAdaptor;

    function setUp() public virtual override {
        // Warp to a realistic timestamp so MIN_HOLD_PERIOD checks pass.
        vm.warp(1779686867);

        // 1. Deploy mock USDC (6 decimals, matches live Monad USDC).
        MockERC20 mockUsdc = new MockERC20("USDC", "USDC", 6);
        USDC_MONAD = address(mockUsdc);

        // 2. Deploy CentralRegistry.
        //    dao=0, ec=0 → both default to msg.sender (test contract),
        //    giving test contract: hasDaoPermissions, hasElevatedPermissions, hasMarketPermissions.
        CentralRegistry cr = new CentralRegistry(
            address(0),
            address(0),
            1779686867,    // genesisEpoch (matches live)
            address(0),    // no sequencer
            USDC_MONAD     // feeToken
        );
        liveCentralRegistry = ICentralRegistry(address(cr));

        // 3. Deploy OracleManager + ChainlinkAdaptor.
        _oracleManager = new OracleManager(liveCentralRegistry);
        cr.setOracleManager(address(_oracleManager));
        _chainlinkAdaptor = new ChainlinkAdaptor(liveCentralRegistry);
        _oracleManager.addApprovedAdaptor(address(_chainlinkAdaptor));

        // 4. Register USDC price feed ($1.00).
        _registerPriceFeed(USDC_MONAD, 1e8);

        // 5. Deploy 3 markets with live IRM params.
        cUSDC_WMON_MARKET = _deployMarket(1200, 2000, 8500, 500, 200, 100000);
        cUSDC_WBTC_MARKET = _deployMarket(600, 2400, 8000, 1000, 100, 100000);
        cUSDC_WETH_MARKET = _deployMarket(600, 2400, 8000, 1000, 100, 100000);

        // 6. Create real debt positions so interest accrues over time.
        //    Each call: deposit lendAmount as liquidity, then borrow borrowAmount.
        _seedAndBorrow(cUSDC_WMON_MARKET, 500_000e6, 100_000e6);
        _seedAndBorrow(cUSDC_WBTC_MARKET, 500_000e6, 200_000e6);
        _seedAndBorrow(cUSDC_WETH_MARKET, 500_000e6, 150_000e6);
    }

    /// @dev Registers a Chainlink price feed for `asset` with the oracle infrastructure.
    function _registerPriceFeed(address asset, int256 price) internal {
        MockV3Aggregator feed = new MockV3Aggregator(8, price);
        _chainlinkAdaptor.addAsset(asset, true, address(feed), 0);
        _oracleManager.addAssetPricingAdaptor(
            asset, address(_chainlinkAdaptor), 0, 0, 0, 0
        );
    }

    /// @dev Deploys a full isolated market: MarketManager, IRM, BorrowableCToken,
    ///      collateral SimpleCToken, oracle feeds, and token configs.
    function _deployMarket(
        uint256 baseRatePerYear,
        uint256 vertexRatePerYear,
        uint256 vertexStart,
        uint256 adjustmentVelocity,
        uint256 decayPerAdjustment,
        uint256 vertexMultiplierMax
    ) internal returns (address) {
        CentralRegistry cr = CentralRegistry(address(liveCentralRegistry));

        // Deploy isolated MarketManager (matches live: MIN_LOAN_SIZE=10e18, not correlated).
        MarketManagerIsolated mm = new MarketManagerIsolated(
            liveCentralRegistry, 10e18, false
        );
        cr.addMarketManager(address(mm));

        // Deploy DynamicIRM with exact live params (all in BPS).
        DynamicIRM irm = new DynamicIRM(
            liveCentralRegistry,
            baseRatePerYear,
            vertexRatePerYear,
            vertexStart,
            adjustmentVelocity,
            decayPerAdjustment,
            vertexMultiplierMax
        );

        // Deploy BorrowableCToken.
        BorrowableCToken cToken = new BorrowableCToken(
            liveCentralRegistry, IERC20(USDC_MONAD), address(mm), address(irm)
        );
        irm.setLinkedToken(address(cToken));
        _oracleManager.addCTokenSupport(address(cToken));

        // Deploy collateral side, list tokens, configure risk params.
        {
            MockERC20 collateral = new MockERC20("COLL", "COLL", 18);
            _registerPriceFeed(address(collateral), 1e8); // $1.00 per token

            SimpleCToken collCToken = new SimpleCToken(
                liveCentralRegistry, IERC20(address(collateral)), address(mm)
            );
            _oracleManager.addCTokenSupport(address(collCToken));

            // Provide tokens for initializeDeposits (77777 = _BASE_UNDERLYING_RESERVE).
            deal(USDC_MONAD, address(this), 77777);
            IERC20(USDC_MONAD).approve(address(cToken), 77777);
            collateral.mint(address(this), 77777);
            IERC20(address(collateral)).approve(address(collCToken), 77777);

            // List token pair — this calls initializeDeposits on both cTokens.
            mm.listTokens(address(cToken), address(collCToken));

            // Configure token risk params for both sides.
            _configureToken(mm, address(collCToken), 7000, 1_000_000e18, 0);
            _configureToken(mm, address(cToken), 0, 0, 1_000_000e6);

            // Store references for borrowing helpers.
            _marketMgrs[address(cToken)] = address(mm);
            _collaterals[address(cToken)] = address(collateral);
            _collCTokens[address(cToken)] = address(collCToken);
        }

        return address(cToken);
    }

    /// @dev Sets token risk parameters on a MarketManager.
    function _configureToken(
        MarketManagerIsolated mm,
        address cToken,
        uint256 collRatio,
        uint256 collateralCap,
        uint256 debtCap
    ) internal {
        MarketManagerIsolated.TokenConfig memory cfg;
        cfg.cToken = cToken;
        cfg.collRatio = collRatio;
        cfg.collReqSoft = 4000;
        cfg.collReqHard = 3000;
        cfg.liqIncBase = 1000;
        cfg.liqIncHard = 1500;
        cfg.liqIncMin = 10;
        cfg.liqIncMax = 2000;
        cfg.closeFactorBase = 2000;
        cfg.closeFactorMin = 2000;
        cfg.closeFactorMax = 5000;
        cfg.collateralCap = collateralCap;
        cfg.debtCap = debtCap;
        mm.updateTokenConfig(cfg);
    }

    /// @dev Seeds a cToken with liquidity, then creates a borrower with real debt.
    ///      This ensures interest accrues when time passes.
    function _seedAndBorrow(
        address cToken,
        uint256 lendAmount,
        uint256 borrowAmount
    ) internal {
        // 1. Deposit USDC as a lender to provide liquidity.
        deal(USDC_MONAD, address(this), lendAmount);
        IERC20(USDC_MONAD).approve(cToken, lendAmount);
        IBorrowableCToken(cToken).deposit(lendAmount, address(this));

        // 2. Create a borrower with collateral.
        address borrower = address(
            uint160(uint256(keccak256(abi.encode("borrower", cToken))))
        );
        address collateral = _collaterals[cToken];
        address collCToken_ = _collCTokens[cToken];

        // 3x collateral in USD terms ($1/token, 18 decimals) for the borrow ($1/USDC, 6 decimals).
        uint256 collAmount = uint256(borrowAmount) * 1e12 * 3;

        deal(collateral, borrower, collAmount);
        vm.startPrank(borrower);
        IERC20(collateral).approve(collCToken_, collAmount);
        ICToken(collCToken_).depositAsCollateral(collAmount, borrower);
        vm.stopPrank();

        // 3. Warp past MIN_HOLD_PERIOD (1200s) so the borrower can borrow.
        vm.warp(block.timestamp + 1201);

        // 4. Borrow.
        vm.prank(borrower);
        IBorrowableCToken(cToken).borrow(borrowAmount, borrower);
    }

    /// @dev Calculates expected shares using the ERC4626 formula:
    ///      shares = assets * totalSupply / totalAssets
    /// @param assets The amount of assets to deposit
    /// @param totalAssetsBefore Total assets before the deposit
    /// @param totalSupplyBefore Total supply before the deposit
    /// @return expectedShares The expected shares to be minted
    function _calculateExpectedShares(
        uint256 assets,
        uint256 totalAssetsBefore,
        uint256 totalSupplyBefore
    ) internal pure returns (uint256 expectedShares) {
        if (totalSupplyBefore == 0 || totalAssetsBefore == 0) {
            // First deposit: 1:1 ratio.
            return assets;
        }
        // shares = assets * totalSupply / totalAssets (round down).
        expectedShares = (assets * totalSupplyBefore) / totalAssetsBefore;
    }

    /// @dev Verifies that shares minted match the previewDeposit invariant.
    /// @notice Uses previewDeposit() as the reference, which uses standard ERC4626 pricing.
    ///         Must be called AFTER accrueIfNeeded() to match deposit()'s internal state.
    /// @param assets The deposited assets
    /// @param sharesMinted The shares that were minted
    function _assertSharesMatchInvariant(
        uint256 assets,
        uint256 sharesMinted,
        uint256,
        uint256
    ) internal view {
        uint256 expectedShares = optimizer.previewDeposit(assets);

        // Allow for small difference due to cToken rounding in _depositToMarket.
        uint256 diff = sharesMinted > expectedShares
            ? sharesMinted - expectedShares
            : expectedShares - sharesMinted;

        require(diff <= 1, "Shares minted deviate from exchange rate invariant");
    }

    function _setUpOneMarket() internal {
        address[] memory approvedCTokens = new address[](1);
        approvedCTokens[0] = cUSDC_WMON_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](1);
        allocationCapsBps[0] = 10_000;

        optimizer = new LendingOptimizerHarness(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            1_000
        );

        uint256 initAssets = 77777;
        deal(USDC_MONAD, address(this), initAssets);
        IERC20(USDC_MONAD).approve(address(optimizer), initAssets);
        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );
        optimizer.initializeDeposits(cUSDC_WMON_MARKET);
    }

    function _setUpTwoMarkets() internal {
        address[] memory approvedCTokens = new address[](2);
        approvedCTokens[0] = cUSDC_WMON_MARKET;
        approvedCTokens[1] = cUSDC_WBTC_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](2);
        allocationCapsBps[0] = 6_000;
        allocationCapsBps[1] = 5_000;

        optimizer = new LendingOptimizerHarness(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            1_000
        );

        uint256 initAssets = 77777;
        deal(USDC_MONAD, address(this), initAssets);
        IERC20(USDC_MONAD).approve(address(optimizer), initAssets);
        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );
        optimizer.initializeDeposits(cUSDC_WMON_MARKET);
    }

    function _setUpThreeMarkets() internal {
        address[] memory approvedCTokens = new address[](3);
        approvedCTokens[0] = cUSDC_WMON_MARKET;
        approvedCTokens[1] = cUSDC_WBTC_MARKET;
        approvedCTokens[2] = cUSDC_WETH_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](3);
        allocationCapsBps[0] = 6_000;
        allocationCapsBps[1] = 5_000;
        allocationCapsBps[2] = 2_000;

        optimizer = new LendingOptimizerHarness(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            1_000
        );

        uint256 initAssets = 77777;
        deal(USDC_MONAD, address(this), initAssets);
        IERC20(USDC_MONAD).approve(address(optimizer), initAssets);
        // Mock market permissions.
        vm.mockCall(
            address(liveCentralRegistry),
            abi.encodeWithSelector(ICentralRegistry.hasMarketPermissions.selector, address(this)),
            abi.encode(true)
        );
        optimizer.initializeDeposits(cUSDC_WMON_MARKET);
    }

    function _depositToAllMarkets(uint256 amountPerMarket) internal {
        address[3] memory markets = [cUSDC_WMON_MARKET, cUSDC_WBTC_MARKET, cUSDC_WETH_MARKET];

        for (uint256 i = 0; i < 3; i++) {
            deal(USDC_MONAD, address(this), amountPerMarket);
            IERC20(USDC_MONAD).approve(address(optimizer), amountPerMarket);
            optimizer.deposit(amountPerMarket, address(this), markets[i]);
        }
    }

}
