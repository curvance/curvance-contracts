// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { SimpleZapper } from "contracts/plugins/market/SimpleZapper.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

import { SimpleCToken } from "contracts/market/token/SimpleCToken.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";

import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

contract TestSimpleZapperMonad is TestBaseMarketIsolated {
    SimpleZapper public simpleZapper;

    // Monad addresses
    address public constant SHMON_ADDRESS = 0x1B68626dCa36c7fE922fD2d55E4f631d962dE19c;
    address public constant WMON_ADDRESS = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;
    address public constant _CHAINLINK_ETH_USD_MONAD = 0x1B1414782B859871781bA3E4B0979b9ca57A0A04;

    SimpleCToken public simpleCSHMON;
    BorrowableCToken public borrowableCWMON;

    function setUp() public override {

        _fork("MON_NODE_URI_MONAD_MAINNET");

        _deployCentralRegistry();
        _deployCVE();
        _deployRewardManager();
        _deployVeCVE();
        _deployGaugeManager();
        _deployMarketManager();
        _deployOracleManager();

        simpleZapper = new SimpleZapper(ICentralRegistry(address(centralRegistry)), WMON_ADDRESS);

        simpleCSHMON = new SimpleCToken(
            ICentralRegistry(address(centralRegistry)),
            IERC20(SHMON_ADDRESS),
            address(marketManagerIsolated)
        );

        ChainlinkAdaptor adaptor = new ChainlinkAdaptor(ICentralRegistry(address(centralRegistry)));
        oracleManager.addApprovedAdaptor(address(adaptor));

        adaptor.addAsset(SHMON_ADDRESS, true, _CHAINLINK_ETH_USD_MONAD, 0);
        oracleManager.addAssetPricingAdaptor(
            SHMON_ADDRESS, 
            address(adaptor), 
            100, 
            50,
            100,
            50
            );
        oracleManager.addCTokenSupport(address(simpleCSHMON));

        adaptor.addAsset(WMON_ADDRESS, true, _CHAINLINK_ETH_USD_MONAD, 0);
        oracleManager.addAssetPricingAdaptor(
            WMON_ADDRESS, 
            address(adaptor), 
            100, 
            50,
            100,
            50
            );

        borrowableCWMON = _deployBorrowableCToken(WMON_ADDRESS);
        oracleManager.addCTokenSupport(address(borrowableCWMON));

        deal(SHMON_ADDRESS, address(this), 77777 ether);
        IERC20(SHMON_ADDRESS).approve(address(simpleCSHMON), type(uint256).max);

        deal(WMON_ADDRESS, address(this), 77777 ether);
        IERC20(WMON_ADDRESS).approve(address(borrowableCWMON), type(uint256).max);

        marketManagerIsolated.listTokens(address(simpleCSHMON), address(borrowableCWMON));

        _setCTokenConfigBasic(address(simpleCSHMON), 1_000_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCWMON), 1_000_000e18, 1_000_000e18);
    }

    function test_SimpleZapper_success_swapAndDeposit_NoSwap_NativeWrap() public {

        uint256 amount = 100 ether;
        deal(user1, amount);

        uint256 expectedShares = borrowableCWMON.previewDeposit(amount);
        uint256 initialEthBalance = user1.balance;

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.inputAmount = amount;

        vm.prank(user1);
        uint256 returnedShares = simpleZapper.swapAndDeposit{ value: amount }(
            address(borrowableCWMON),
            true, // depositAsWrappedNative
            swapAction,
            0,
            false,
            user1
        );

        assertEq(user1.balance, initialEthBalance - amount, "User MON balance should decrease by input amount");
        assertEq(borrowableCWMON.balanceOf(user1), expectedShares, "User cToken balance should increase 1:1 in this test");
        assertEq(borrowableCWMON.balanceOf(user1), returnedShares, "Returned shares should match user balance");

        assertEq(IERC20(borrowableCWMON.asset()).balanceOf(address(borrowableCWMON)), expectedShares + 77777, "Vault balance should increase (includes base reserve)");
        assertEq(borrowableCWMON.totalAssets(), expectedShares + 77777, "totalAssets should increase");
        assertEq(IERC20(WMON_ADDRESS).balanceOf(address(simpleZapper)), 0, "Zapper should not hold WMON");
        assertEq(address(simpleZapper).balance, 0, "Zapper should not hold native");
    }
}


