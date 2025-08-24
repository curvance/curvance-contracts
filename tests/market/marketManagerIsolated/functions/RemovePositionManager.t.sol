// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { SimplePositionManager } from "contracts/market/position-management/SimplePositionManager.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";

contract RemovePositionManagerTest is TestBaseMarketIsolated {
    SimplePositionManager public positionManager;

    function setUp() public override {
        super.setUp();

        centralRegistry.setExternalCalldataChecker(
            _UNISWAP_V2_ROUTER,
            address(new MockCalldataChecker(_UNISWAP_V2_ROUTER))
        );

        // Setup borrowable cDAI.
        {
            _prepareDAI(address(this), 200000e18);
            dai.approve(address(borrowableCDAI), 200000e18);
        }

        // Setup borrowable cUSDC.
        {
            _deployBorrowableCUSDC();
            oracleManager.addCTokenSupport(address(borrowableCUSDC));
            _prepareUSDC(address(this), 100e6);
            usdc.approve(address(borrowableCUSDC), 100e6);
        }

        positionManager = new SimplePositionManager(
            ICentralRegistry(address(centralRegistry)),
            address(marketManagerIsolated),
            _WETH_ADDRESS
        );

        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(borrowableCDAI));

         _setCTokenConfigBasic(address(borrowableCUSDC), 100_000e18, 100_000e18);
         _setCTokenConfigBasic(address(borrowableCDAI), 100_000e18, 100_000e18);
    }

    function test_removePositionManager_fail_whenUnauthorized() public {
        address unauthorizedAddress = makeAddr("unauthorizedAddress");

        vm.startPrank(unauthorizedAddress);

        vm.expectRevert(bytes4(keccak256("MarketManager__Unauthorized()")));
        marketManagerIsolated.removePositionManager(address(positionManager));

        vm.stopPrank();
    }

    function test_removePositionManager_fail_whenNotAdded() public {
        vm.expectRevert(bytes4(keccak256("MarketManager__InvalidParameter()")));
        marketManagerIsolated.removePositionManager(address(positionManager));
    }

    function test_removePositionManager_success() public {
        marketManagerIsolated.addPositionManager(address(positionManager));

        marketManagerIsolated.removePositionManager(address(positionManager));
        assertEq(marketManagerIsolated.isPositionManager(address(positionManager)), false);
    }
}
