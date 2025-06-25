pragma solidity ^0.8.19;

import { TestBaseDynamicInterestRateModel } from "../TestBaseDynamicInterestRateModel.sol";
import { DynamicInterestRateModel } from "contracts/market/DynamicInterestRateModel.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

contract SetLinkedTokenTest is TestBaseDynamicInterestRateModel {
    event TokenLinked(address eTokenAddress);

    BorrowableCToken public eToken;

    function setUp() public override {
        super.setUp();

        interestRateModel = new DynamicInterestRateModel(
            ICentralRegistry(address(centralRegistry)),
            1000, // baseRatePerYear
            1000, // vertexRatePerYear
            5000, // vertexUtilizationStart
            4 hours, // adjustmentRate
            5000, // adjustmentVelocity
            100000000, // 1000x maximum vertex multiplier
            100 // decayRate
        );
        eToken = new BorrowableCToken(
            ICentralRegistry(address(centralRegistry)),
            IERC20(_USDC_ADDRESS),
            address(marketManagerIsolated),
            address(interestRateModel)
        );
    }

    function test_setLinkedToken_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(1));

        vm.expectRevert(
            DynamicInterestRateModel
                .DynamicInterestRateModel__Unauthorized
                .selector
        );
        interestRateModel.setLinkedToken(address(eToken));
    }

    function test_setLinkedToken_fail_whenETokenHasAlreadyLinked() public {
        interestRateModel.setLinkedToken(address(eToken));

        vm.expectRevert(
            DynamicInterestRateModel
                .DynamicInterestRateModel__Unauthorized
                .selector
        );
        interestRateModel.setLinkedToken(address(eToken));
    }

    function test_setLinkedToken_fail_whenETokenIsPToken() public {
        vm.expectRevert(
            DynamicInterestRateModel
                .DynamicInterestRateModel__InvalidToken
                .selector
        );
        interestRateModel.setLinkedToken(address(pBALRETH));
    }

    function test_setLinkedToken_fail_whenInterestRateModelMismatch() public {
        vm.expectRevert(
            DynamicInterestRateModel
                .DynamicInterestRateModel__InvalidToken
                .selector
        );
        interestRateModel.setLinkedToken(address(eDAI));
    }

    function test_setLinkedToken_success() public {
        assertEq(interestRateModel.linkedToken(), _ZERO_ADDRESS);

        vm.expectEmit(true, true, true, true);
        emit TokenLinked(address(eToken));

        interestRateModel.setLinkedToken(address(eToken));

        assertEq(interestRateModel.linkedToken(), address(eToken));
    }
}
