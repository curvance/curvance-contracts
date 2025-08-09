// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseFeeManager } from "../TestBaseFeeManager.sol";
import { FeeManager } from "contracts/architecture/FeeManager.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract MigrateFeeManagerTest is TestBaseFeeManager {
    function test_migrateFeeManager_fail_whenNewFeeManagerIsNotRegistered()
        public
    {
        vm.expectRevert(
            FeeManager.FeeManager__NewFeeManagerIsNotChanged.selector
        );
        feeManager.migrateFeeManager();
    }

    function test_migrateFeeManager_success() public {
        address[] memory rewardTokens = new address[](2);
        rewardTokens[0] = _DAI_ADDRESS;
        rewardTokens[1] = _BAL_WETH_RETH_ADDRESS;

        feeManager.addRewardTokens(rewardTokens);

        _prepareUSDC(address(feeManager), _ONE);
        _prepareDAI(address(feeManager), _ONE);
        _prepareBALRETH(address(feeManager), _ONE);

        uint256[] memory rewardTokenBalances = feeManager
            .getRewardTokenBalances();

        for (uint256 i = 0; i < rewardTokenBalances.length; i++) {
            assertEq(rewardTokenBalances[i], _ONE);
        }

        uint256 feeTokenBalance = usdc.balanceOf(address(feeManager));

        FeeManager newFeeManager = new FeeManager(
            ICentralRegistry(address(centralRegistry))
        );
        centralRegistry.setFeeManager(address(newFeeManager));

        feeManager.migrateFeeManager();

        assertEq(dai.balanceOf(address(feeManager)), 0);
        assertEq(dai.balanceOf(address(newFeeManager)), _ONE);
        assertEq(balRETH.balanceOf(address(feeManager)), 0);
        assertEq(balRETH.balanceOf(address(newFeeManager)), _ONE);
        assertEq(usdc.balanceOf(address(feeManager)), 0);
        assertEq(usdc.balanceOf(address(newFeeManager)), feeTokenBalance);
    }
}
