// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { Multicall } from "contracts/libraries/Multicall.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract BorrowableCTokenMulticallTest is TestBaseMarketIsolated {
    function setUp() public override {
        super.setUp();

        _prepareUSDC(address(this), _ONE + 77777);
        _prepareDAI(address(this), 10e18 + 77777);

        usdc.approve(address(borrowableCUSDC), _ONE + 77777);
        dai.approve(address(borrowableCDAI), 10e18 + 77777);

        marketManagerIsolated.listTokens(
            address(borrowableCDAI),
            address(borrowableCUSDC)
        );

        _setCTokenConfigBasic(address(borrowableCDAI), 100_000e18, 100_000e18);
        _setCTokenConfigBasic(address(borrowableCUSDC), 100_000e18, 100_000e6);

        borrowableCDAI.mint(_ONE, address(this));
    }

    function test_borrowableCTokenMulticall_fail_nonPriceCallCannotTargetExternalContract()
        public
    {
        Multicall.MulticallAction[] memory calls =
            new Multicall.MulticallAction[](1);

        calls[0] = Multicall.MulticallAction({
            target: address(usdc),
            isPriceUpdate: false,
            data: abi.encodeWithSelector(usdc.balanceOf.selector, user1)
        });

        vm.expectRevert(Multicall.Multicall__InvalidTarget.selector);
        borrowableCUSDC.multicall(calls);
    }

    function test_borrowableCTokenMulticall_fail_delegatedWithdrawStillChecksCollateral()
        public
    {
        _prepareUSDC(address(this), 2000e6);
        usdc.approve(address(borrowableCUSDC), 2000e6);
        borrowableCUSDC.deposit(2000e6, address(this));

        _prepareDAI(user1, 2000e18);

        vm.startPrank(user1);
        dai.approve(address(borrowableCDAI), 2000e18);
        borrowableCDAI.depositAsCollateral(2000e18, user1);
        borrowableCUSDC.borrow(1000e6, user1);
        vm.stopPrank();

        skip(20 minutes);

        Multicall.MulticallAction[] memory calls =
            new Multicall.MulticallAction[](1);

        calls[0] = Multicall.MulticallAction({
            target: address(borrowableCDAI),
            isPriceUpdate: false,
            data: abi.encodeWithSelector(
                borrowableCDAI.withdrawCollateral.selector,
                1900e18,
                user1,
                user1
            )
        });

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__InsufficientCollateral.selector
        );
        vm.prank(user1);
        borrowableCDAI.multicall(calls);
    }
}
