// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { ICToken } from "contracts/interfaces/ICToken.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IChainlink } from "contracts/interfaces/external/chainlink/IChainlink.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";


contract TestBaseLendingOptimizer is TestBaseMarketIsolated {

    ICentralRegistry public liveCentralRegistry = ICentralRegistry(0x1310f352f1389969Ece6741671c4B919523912fF);

    // USDC address on Monad
    address constant USDC_MONAD = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603;

    address cUSDC_WMON_MARKET = 0x8EE9FC28B8Da872c38A496e9dDB9700bb7261774;
    address cUSDC_WBTC_MARKET = 0x7C9d4f1695C6282Da5e5509Aa51fC9fb417C6f1d;
    address cUSDC_WETH_MARKET = 0x21aDBb60a5fB909e7F1fB48aACC4569615CD97b5;

    function setUp() public virtual override {
        vm.createSelectFork(vm.envString("MON_NODE_URI_MONAD_MAINNET"));
    }

}