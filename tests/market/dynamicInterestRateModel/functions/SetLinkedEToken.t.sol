pragma solidity ^0.8.19;

import { TestBaseDynamicInterestRateModel } from "../TestBaseDynamicInterestRateModel.sol";
import { DynamicInterestRateModel } from "contracts/market/DynamicInterestRateModel.sol";
import { EToken } from "contracts/market/token/EToken.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract SetLinkedETokenTest is TestBaseDynamicInterestRateModel {
    event EarnTokenLinked(address eTokenAddress);

    EToken public eToken;

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
        eToken = new EToken(
            ICentralRegistry(address(centralRegistry)),
            _USDC_ADDRESS,
            address(marketManager),
            address(interestRateModel)
        );
    }

    function test_setLinkedEToken_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(1));

        vm.expectRevert(
            DynamicInterestRateModel
                .DynamicInterestRateModel__Unauthorized
                .selector
        );
        interestRateModel.setLinkedEToken(address(eToken));
    }

    function test_setLinkedEToken_fail_whenETokenHasAlreadyLinked() public {
        interestRateModel.setLinkedEToken(address(eToken));

        vm.expectRevert(
            DynamicInterestRateModel
                .DynamicInterestRateModel__Unauthorized
                .selector
        );
        interestRateModel.setLinkedEToken(address(eToken));
    }

    function test_setLinkedEToken_fail_whenETokenIsPToken() public {
        vm.expectRevert(
            DynamicInterestRateModel
                .DynamicInterestRateModel__InvalidToken
                .selector
        );
        interestRateModel.setLinkedEToken(address(pBALRETH));
    }

    function test_setLinkedEToken_fail_whenInterestRateModelMismatch() public {
        vm.expectRevert(
            DynamicInterestRateModel
                .DynamicInterestRateModel__InvalidToken
                .selector
        );
        interestRateModel.setLinkedEToken(address(eDAI));
    }

    function test_setLinkedEToken_success() public {
        assertEq(interestRateModel.linkedEToken(), _ZERO_ADDRESS);

        vm.expectEmit(true, true, true, true);
        emit EarnTokenLinked(address(eToken));

        interestRateModel.setLinkedEToken(address(eToken));

        assertEq(interestRateModel.linkedEToken(), address(eToken));
    }
}
