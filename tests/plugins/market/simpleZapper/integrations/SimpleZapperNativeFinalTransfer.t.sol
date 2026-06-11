// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {SimpleZapper} from "contracts/plugins/market/SimpleZapper.sol";
import {BaseZapper} from "contracts/plugins/BaseZapper.sol";
import {SwapperLib} from "contracts/libraries/SwapperLib.sol";
import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";
import {IERC20} from "contracts/interfaces/IERC20.sol";
import {MockCalldataChecker} from "contracts/mocks/MockCalldataChecker.sol";

import {TestBaseMarketIsolated} from "tests/market/TestBaseMarketIsolated.sol";

contract NativeOutputSwapTarget {
    receive() external payable {}

    function swapToNative(
        address inputToken,
        uint256 inputAmount,
        uint256 nativeOut
    ) external {
        require(
            IERC20(inputToken)
                .transferFrom(msg.sender, address(this), inputAmount),
            "transferFrom failed"
        );

        (bool success,) = msg.sender.call{value: nativeOut}("");
        require(success, "native transfer failed");
    }
}

contract TestSimpleZapperNativeFinalTransfer is TestBaseMarketIsolated {
    uint256 internal constant INPUT_ASSETS = 10e6;
    uint256 internal constant NATIVE_OUT = 1 ether;

    SimpleZapper public simpleZapper;
    NativeOutputSwapTarget public nativeOutputTarget;

    function setUp() public override {
        super.setUp();

        oracleManager.addCTokenSupport(address(simpleCUSDC));

        simpleZapper = new SimpleZapper(
            ICentralRegistry(address(centralRegistry)), _WETH_ADDRESS
        );

        nativeOutputTarget = new NativeOutputSwapTarget();
        centralRegistry.setExternalCalldataChecker(
            address(nativeOutputTarget),
            address(new MockCalldataChecker(address(nativeOutputTarget)))
        );

        _prepareDAI(address(this), 200_000e18);
        dai.approve(address(borrowableCDAI), 200_000e18);

        _prepareUSDC(address(this), 100e6);
        usdc.approve(address(simpleCUSDC), 100e6);

        marketManagerIsolated.listTokens(
            address(simpleCUSDC), address(borrowableCDAI)
        );
        _setCTokenConfigHighValues(address(simpleCUSDC), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCDAI), 100_000e18, 100_000e18);
    }

    function test_redeemAndSwap_nativeOutputWrapsToWethForReceiverAndLeavesNoNativeResidue()
        public
    {
        _prepareUSDC(user1, INPUT_ASSETS);
        deal(address(nativeOutputTarget), NATIVE_OUT);

        vm.startPrank(user1);
        usdc.approve(address(simpleCUSDC), INPUT_ASSETS);
        uint256 shares = simpleCUSDC.deposit(INPUT_ASSETS, user1);
        simpleCUSDC.setDelegateApproval(address(simpleZapper), true);
        vm.stopPrank();

        BaseZapper.RedeemAction memory redeemAction = BaseZapper.RedeemAction({
            cToken: address(simpleCUSDC),
            shares: shares,
            forceRedeemCollateral: false
        });

        SwapperLib.Swap memory swapAction = SwapperLib.Swap({
            inputToken: _USDC_ADDRESS,
            inputAmount: INPUT_ASSETS,
            outputToken: _ETH_ADDRESS,
            target: address(nativeOutputTarget),
            slippage: 0.5e18,
            call: abi.encodeWithSelector(
                NativeOutputSwapTarget.swapToNative.selector,
                _USDC_ADDRESS,
                INPUT_ASSETS,
                NATIVE_OUT
            )
        });

        uint256 receiverNativeBefore = user2.balance;
        uint256 receiverWethBefore = weth.balanceOf(user2);

        vm.prank(user1);
        uint256 returnedOut =
            simpleZapper.redeemAndSwap(redeemAction, swapAction, user2);

        assertEq(returnedOut, NATIVE_OUT, "reported native output");
        assertEq(user2.balance, receiverNativeBefore, "receiver native delta");
        assertEq(
            weth.balanceOf(user2) - receiverWethBefore,
            NATIVE_OUT,
            "receiver wrapped-native delta"
        );
        assertEq(address(simpleZapper).balance, 0, "zapper native residue");
        assertEq(
            weth.balanceOf(address(simpleZapper)),
            0,
            "zapper wrapped-native residue"
        );
        assertEq(
            usdc.balanceOf(address(simpleZapper)), 0, "zapper USDC residue"
        );
    }
}
