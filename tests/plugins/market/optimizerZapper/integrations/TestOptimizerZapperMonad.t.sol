// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { OptimizerZapper } from "contracts/plugins/market/OptimizerZapper.sol";
import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { SimpleCToken } from "contracts/market/token/SimpleCToken.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

contract TestOptimizerZapperMonad is TestBaseMarketIsolated {
    OptimizerZapper public optimizerZapper;
    LendingOptimizer public optimizer;

    // Monad addresses.
    address public constant SHMON_ADDRESS = 0x1B68626dCa36c7fE922fD2d55E4f631d962dE19c;
    address public constant WMON_ADDRESS = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;
    address public constant _CHAINLINK_ETH_USD_MONAD = 0x1B1414782B859871781bA3E4B0979b9ca57A0A04;

    BorrowableCToken public borrowableCWMON;
    SimpleCToken public simpleCSHMON;

    function setUp() public override {
        _fork("MON_NODE_URI_MONAD_MAINNET");

        _deployCentralRegistry();
        _deployCVE();
        _deployRewardManager();
        _deployVeCVE();
        _deployGaugeManager();
        _deployMarketManager();
        _deployOracleManager();

        // Deploy OptimizerZapper.
        optimizerZapper = new OptimizerZapper(
            ICentralRegistry(address(centralRegistry)),
            WMON_ADDRESS
        );

        // Oracle setup for WMON.
        ChainlinkAdaptor adaptor = new ChainlinkAdaptor(
            ICentralRegistry(address(centralRegistry))
        );
        oracleManager.addApprovedAdaptor(address(adaptor));

        adaptor.addAsset(WMON_ADDRESS, true, _CHAINLINK_ETH_USD_MONAD, 0);
        oracleManager.addAssetPricingAdaptor(
            WMON_ADDRESS,
            address(adaptor),
            100,
            50,
            100,
            50
        );

        // Oracle setup for SHMON (using same price feed for simplicity).
        adaptor.addAsset(SHMON_ADDRESS, true, _CHAINLINK_ETH_USD_MONAD, 0);
        oracleManager.addAssetPricingAdaptor(
            SHMON_ADDRESS,
            address(adaptor),
            100,
            50,
            100,
            50
        );

        // Deploy collateral cToken for SHMON (needed for market listing pair).
        simpleCSHMON = new SimpleCToken(
            ICentralRegistry(address(centralRegistry)),
            IERC20(SHMON_ADDRESS),
            address(marketManagerIsolated)
        );
        oracleManager.addCTokenSupport(address(simpleCSHMON));

        // Deploy borrowable cToken for WMON.
        borrowableCWMON = _deployBorrowableCToken(WMON_ADDRESS);
        oracleManager.addCTokenSupport(address(borrowableCWMON));

        // List the market pair and configure.
        marketManagerIsolated.listTokens(
            address(simpleCSHMON),
            address(borrowableCWMON)
        );
        _setCTokenConfigBasic(address(simpleCSHMON), 1_000_000e18, 0);
        _setCTokenConfigBasic(
            address(borrowableCWMON),
            1_000_000e18,
            1_000_000e18
        );

        // Deploy LendingOptimizer targeting WMON with borrowableCWMON.
        address[] memory cTokens = new address[](1);
        cTokens[0] = address(borrowableCWMON);
        uint256[] memory caps = new uint256[](1);
        caps[0] = 10000; // 100%

        optimizer = new LendingOptimizer(
            IERC20(WMON_ADDRESS),
            ICentralRegistry(address(centralRegistry)),
            cTokens,
            caps,
            0
        );

        // Initialize the optimizer.
        deal(WMON_ADDRESS, address(this), 77777 ether);
        IERC20(WMON_ADDRESS).approve(address(optimizer), type(uint256).max);
        optimizer.initializeDeposits(0);
    }

    function test_OptimizerZapper_success_swapAndDeposit_NoSwap_NativeWrap()
        public
    {
        uint256 amount = 100 ether;
        vm.deal(user1, amount);

        uint256 initialEthBalance = user1.balance;

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.inputAmount = amount;

        vm.prank(user1);
        uint256 shares = optimizerZapper.swapAndDeposit{ value: amount }(
            address(optimizer),
            address(borrowableCWMON),
            true, // depositAsWrappedNative
            swapAction,
            0,
            user1
        );

        assertEq(
            user1.balance,
            initialEthBalance - amount,
            "User MON balance should decrease by input amount"
        );
        assertGt(shares, 0, "Should receive optimizer shares");
        assertEq(
            optimizer.balanceOf(user1),
            shares,
            "Returned shares should match user balance"
        );
        assertEq(
            IERC20(WMON_ADDRESS).balanceOf(address(optimizerZapper)),
            0,
            "Zapper should not hold WMON"
        );
        assertEq(
            address(optimizerZapper).balance,
            0,
            "Zapper should not hold native"
        );
    }
}
