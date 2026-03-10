// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { OptimizerZapper } from "contracts/plugins/market/OptimizerZapper.sol";
import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

contract TestOptimizerZapperMonad is TestBaseMarketIsolated {
    OptimizerZapper public optimizerZapper;
    LendingOptimizer public optimizer;

    // Monad addresses.
    address public constant WMON_ADDRESS = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;
    address public constant WBTC_ADDRESS_MONAD = 0x0555E30da8f98308EdB960aa94C0Db47230d2B9c;
    address public constant USDC_ADDRESS_MONAD = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603;

    // Monad oracle feeds.
    address public constant WBTC_USD_FEED_MONAD = 0x2D1Df1bD061AAc38C22407AD69d69bCC3C62edBD;
    address public constant USDC_USD_FEED_MONAD = 0xf5F15f188AbCB0d165D1Edb7f37F7d6fA2fCebec;

    BorrowableCToken public borrowableCWBTC;
    BorrowableCToken public borrowableCUSDCMonad;

    function setUp() public override {
        _fork("MON_NODE_URI_MONAD_MAINNET");

        _deployCentralRegistry();
        _deployCVE();
        _deployRewardManager();
        _deployVeCVE();
        _deployGaugeManager();
        _deployMarketManager();
        _deployOracleManager();

        // Deploy OptimizerZapper (WMON is native wrapper on Monad).
        optimizerZapper = new OptimizerZapper(
            ICentralRegistry(address(centralRegistry)),
            WMON_ADDRESS
        );

        // Oracle setup — single adaptor for both assets.
        ChainlinkAdaptor adaptor = new ChainlinkAdaptor(
            ICentralRegistry(address(centralRegistry))
        );
        oracleManager.addApprovedAdaptor(address(adaptor));

        adaptor.addAsset(WBTC_ADDRESS_MONAD, true, WBTC_USD_FEED_MONAD, 0);
        oracleManager.addAssetPricingAdaptor(
            WBTC_ADDRESS_MONAD,
            address(adaptor),
            100,
            50,
            100,
            50
        );

        adaptor.addAsset(USDC_ADDRESS_MONAD, true, USDC_USD_FEED_MONAD, 0);
        oracleManager.addAssetPricingAdaptor(
            USDC_ADDRESS_MONAD,
            address(adaptor),
            100,
            50,
            100,
            50
        );

        // Deploy cTokens — WBTC as collateral, USDC as borrowable.
        borrowableCWBTC = _deployBorrowableCToken(WBTC_ADDRESS_MONAD);
        oracleManager.addCTokenSupport(address(borrowableCWBTC));

        borrowableCUSDCMonad = _deployBorrowableCToken(USDC_ADDRESS_MONAD);
        oracleManager.addCTokenSupport(address(borrowableCUSDCMonad));

        // Prepare underlying tokens for listTokens — each cToken pulls
        // 77777 of its underlying via initializeDeposits(msg.sender).
        deal(WBTC_ADDRESS_MONAD, address(this), 77777);
        deal(USDC_ADDRESS_MONAD, address(this), 77777);
        IERC20(WBTC_ADDRESS_MONAD).approve(address(borrowableCWBTC), 77777);
        IERC20(USDC_ADDRESS_MONAD).approve(address(borrowableCUSDCMonad), 77777);

        // List the market pair and configure.
        marketManagerIsolated.listTokens(
            address(borrowableCWBTC),
            address(borrowableCUSDCMonad)
        );
        _setCTokenConfigBasic(
            address(borrowableCWBTC),
            1_000_000e18,
            0
        );
        _setCTokenConfigBasic(
            address(borrowableCUSDCMonad),
            1_000_000e18,
            1_000_000e18
        );

        // Deploy LendingOptimizer targeting USDC with borrowableCUSDCMonad.
        address[] memory cTokens = new address[](1);
        cTokens[0] = address(borrowableCUSDCMonad);
        uint256[] memory caps = new uint256[](1);
        caps[0] = 10000; // 100%

        optimizer = new LendingOptimizer(
            IERC20(USDC_ADDRESS_MONAD),
            ICentralRegistry(address(centralRegistry)),
            cTokens,
            caps,
            0
        );

        // Initialize the optimizer (pulls 77777 USDC via initializeDeposits).
        deal(USDC_ADDRESS_MONAD, address(this), 77777);
        IERC20(USDC_ADDRESS_MONAD).approve(address(optimizer), 77777);
        optimizer.initializeDeposits(address(borrowableCUSDCMonad));

        // Seed liquidity into borrowableCUSDCMonad.
        address liquidityProvider = makeAddr("liquidityProvider");
        deal(USDC_ADDRESS_MONAD, liquidityProvider, 10_000e6);
        vm.startPrank(liquidityProvider);
        IERC20(USDC_ADDRESS_MONAD).approve(address(borrowableCUSDCMonad), 10_000e6);
        borrowableCUSDCMonad.deposit(10_000e6, liquidityProvider);
        vm.stopPrank();
    }

    function test_OptimizerZapper_success_swapAndDeposit_NoSwap_USDC()
        public
    {
        uint256 amount = 1000e6;
        deal(USDC_ADDRESS_MONAD, user1, amount);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = USDC_ADDRESS_MONAD;
        swapAction.inputAmount = amount;
        swapAction.outputToken = USDC_ADDRESS_MONAD;

        vm.startPrank(user1);
        IERC20(USDC_ADDRESS_MONAD).approve(address(optimizerZapper), amount);

        uint256 shares = optimizerZapper.swapAndDeposit(
            address(optimizer),
            address(borrowableCUSDCMonad),
            false,
            swapAction,
            0,
            user1
        );
        vm.stopPrank();

        assertGt(shares, 0, "Should receive optimizer shares");
        assertEq(
            optimizer.balanceOf(user1),
            shares,
            "Returned shares should match user balance"
        );
        assertEq(
            IERC20(USDC_ADDRESS_MONAD).balanceOf(address(optimizerZapper)),
            0,
            "Zapper should not hold USDC"
        );
        assertEq(
            IERC20(USDC_ADDRESS_MONAD).balanceOf(user1),
            0,
            "User should have deposited all USDC"
        );
    }
}
