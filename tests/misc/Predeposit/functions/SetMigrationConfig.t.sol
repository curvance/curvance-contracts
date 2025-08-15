// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBasePredeposit } from "../TestBasePredeposit.sol";
import { Predeposit } from "contracts/misc/Predeposit.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract SetMigrationConfigTest is TestBasePredeposit {
    function test_setMigrationConfig_fail_whenCallerIsNotManager() public {
        vm.expectRevert(
            Predeposit.Predeposit__Unauthorized.selector
        );
        predeposit.setMigrationConfig(_USDC_ADDRESS, address(borrowableCUSDC));
    }

    function test_setMigrationConfig_fail_whenTokenIsNotApproved() public {
        predeposit = new Predeposit(
            ICentralRegistry(address(centralRegistry)),
            manager,
            block.timestamp + 1 weeks
        );

        vm.prank(manager);

        vm.expectRevert(
            Predeposit.Predeposit__InvalidParameters.selector
        );
        predeposit.setMigrationConfig(_USDC_ADDRESS, address(borrowableCUSDC));
    }

    function test_setMigrationConfig_fail_whenUnderlyingIsNotPredepositToken()
        public
    {
        vm.prank(manager);

        vm.expectRevert(
            Predeposit.Predeposit__InvalidParameters.selector
        );
        predeposit.setMigrationConfig(_USDC_ADDRESS, address(borrowableCDAI));
    }

    function test_setMigrationConfig_fail_whenProtocolTokenIsNotListed()
        public
    {
        vm.prank(manager);

        vm.expectRevert(
            Predeposit.Predeposit__InvalidParameters.selector
        );
        predeposit.setMigrationConfig(_USDC_ADDRESS, address(borrowableCUSDC));
    }

    function test_setMigrationConfig_success() public {
        _prepareUSDC(address(this), 1000e6);
        _prepareBALRETH(address(this), 1000e18);

        usdc.approve(address(borrowableCUSDC), 1000e6);
        balRETH.approve(address(strategyCBALRETH), 1000e18);

        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCUSDC));

        (, address mTokenAddress) = predeposit.tokenData(
            _USDC_ADDRESS
        );

        assertEq(mTokenAddress, _ZERO_ADDRESS);

        vm.prank(manager);
        predeposit.setMigrationConfig(_USDC_ADDRESS, address(borrowableCUSDC));

        (, mTokenAddress) = predeposit.tokenData(_USDC_ADDRESS);

        assertEq(mTokenAddress, address(borrowableCUSDC));

        (, mTokenAddress) = predeposit.tokenData(
            _BAL_WETH_RETH_ADDRESS
        );

        assertEq(mTokenAddress, _ZERO_ADDRESS);

        address[] memory newPredepositTokens = new address[](1);
        newPredepositTokens[0] = _BAL_WETH_RETH_ADDRESS;

        vm.prank(manager);
        predeposit.addPredepositTokens(newPredepositTokens);

        vm.prank(manager);
        predeposit.setMigrationConfig(
            _BAL_WETH_RETH_ADDRESS,
            address(strategyCBALRETH)
        );

        (, mTokenAddress) = predeposit.tokenData(
            _BAL_WETH_RETH_ADDRESS
        );

        assertEq(mTokenAddress, address(strategyCBALRETH));
    }
}
