// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { TestBaseLendingOptimizer } from "../TestBaseLendingOptimizer.sol";
import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IERC165 } from "contracts/interfaces/IERC165.sol";
import { IPluginDelegable } from "contracts/interfaces/IPluginDelegable.sol";
import { ERC4626 } from "contracts/libraries/external/ERC4626.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { WAD, BPS } from "contracts/libraries/ConstantsLib.sol";

contract TestLendingOptimizerDeposit is TestBaseLendingOptimizer {

    LendingOptimizer optimizer;

    function setUp() public override {
        super.setUp();

        address[] memory approvedCTokens = new address[](3);
        approvedCTokens[0] = cUSDC_WMON_MARKET;
        approvedCTokens[1] = cUSDC_WETH_MARKET;
        approvedCTokens[2] = cUSDC_WBTC_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](3);
        allocationCapsBps[0] = 5_000;
        allocationCapsBps[1] = 4_000;
        allocationCapsBps[2] = 1_000;

        optimizer = new LendingOptimizer(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            1_000
        );

        deal(USDC_MONAD, address(this), 77777, true);

        IERC20(USDC_MONAD).approve(address(optimizer), 77777);

        optimizer.initializeDeposits(0);
    }

    function testLendingOptimizerDeposit_success_targetMarket() public {

        vm.startPrank(user1);

        deal(USDC_MONAD, user1, 1000e6, true);

        IERC20(USDC_MONAD).approve(address(optimizer), 1000e6);

        optimizer.deposit(
            1000e6,
            user1,
            cUSDC_WMON_MARKET
        );
    }


}