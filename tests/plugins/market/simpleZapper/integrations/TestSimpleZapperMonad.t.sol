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
    address public constant SHMON_ADDRESS = 0x3a98250F98Dd388C211206983453837C8365BDc1;
    address public constant WMON_ADDRESS = 0x760AfE86e5de5fa0Ee542fc7B7B713e1c5425701;
    address public constant _CHAINLINK_ETH_USD_MONAD = 0x0c76859E85727683Eeba0C70Bc2e0F5781337818;

    SimpleCToken public simpleCSHMON;
    BorrowableCToken public borrowableCWMON;

    function setUp() public override {

        _fork("ETH_NODE_URI_MONAD");

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

        adaptor.addAsset(SHMON_ADDRESS, true, _CHAINLINK_ETH_USD_MONAD, 0, 100);
        oracleManager.addAssetPriceFeed(SHMON_ADDRESS, address(adaptor));
        oracleManager.addCTokenSupport(address(simpleCSHMON));

        adaptor.addAsset(WMON_ADDRESS, true, _CHAINLINK_ETH_USD_MONAD, 0, 100);
        oracleManager.addAssetPriceFeed(WMON_ADDRESS, address(adaptor));

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


