pragma solidity ^0.8.19;

import { TestBaseDynamicIRM } from "../TestBaseDynamicIRM.sol";
import { DynamicIRM } from "contracts/market/DynamicIRM.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

contract SetLinkedTokenTest is TestBaseDynamicIRM {
    event TokenLinked(address cTokenAddress);

    BorrowableCToken public cToken;

    function setUp() public override {
        super.setUp();

        IRM = new DynamicIRM(
            ICentralRegistry(address(centralRegistry)),
            1000, // baseRatePerYear
            1000, // vertexRatePerYear
            5000, // vertexUtilizationStart
            5000, // adjustmentVelocity
            100000000, // 1000x maximum vertex multiplier
            100 // decayRate
        );
        cToken = new BorrowableCToken(
            ICentralRegistry(address(centralRegistry)),
            IERC20(_USDC_ADDRESS),
            address(marketManagerIsolated),
            address(IRM)
        );
    }

    function test_setLinkedToken_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(1));

        vm.expectRevert(
            DynamicIRM
                .DynamicIRM__Unauthorized
                .selector
        );
        IRM.setLinkedToken(address(cToken));
    }

    function test_setLinkedToken_fail_whenBorrowableCTokenHasAlreadyLinked() public {
        IRM.setLinkedToken(address(cToken));

        vm.expectRevert(
            DynamicIRM
                .DynamicIRM__Unauthorized
                .selector
        );
        IRM.setLinkedToken(address(cToken));
    }

    function test_setLinkedToken_fail_whenBorrowableCTokenIsNotBorrowable() public {
        vm.expectRevert(
            DynamicIRM
                .DynamicIRM__InvalidToken
                .selector
        );
        IRM.setLinkedToken(address(strategyCBALRETH));
    }

    function test_setLinkedToken_fail_whenIRMMismatch() public {
        vm.expectRevert(
            DynamicIRM
                .DynamicIRM__InvalidToken
                .selector
        );
        IRM.setLinkedToken(address(borrowableCDAI));
    }

    function test_setLinkedToken_success() public {
        assertEq(IRM.linkedToken(), _ZERO_ADDRESS);

        vm.expectEmit(true, true, true, true);
        emit TokenLinked(address(cToken));

        IRM.setLinkedToken(address(cToken));

        assertEq(IRM.linkedToken(), address(cToken));
    }
}
