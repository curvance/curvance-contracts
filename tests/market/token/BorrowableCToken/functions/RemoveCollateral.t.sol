// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseBorrowableCToken } from "../TestBaseBorrowableCToken.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract RemoveCollateralTest is TestBaseBorrowableCToken {
    event CollateralUpdated(uint256 shares, bool increased, address account);


    function setUp() public override {
        _fork(18031848);

        _init();

        mockUsdcFeed = new MockDataFeed(_CHAINLINK_USDC_USD);
        chainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            address(mockUsdcFeed),
            0,
            true
        );
        dualChainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            address(mockUsdcFeed),
            0,
            true
        );
        mockDaiFeed = new MockDataFeed(_CHAINLINK_DAI_USD);
        chainlinkAdaptor.addAsset(
            _DAI_ADDRESS,
            address(mockDaiFeed),
            0,
            true
        );
        dualChainlinkAdaptor.addAsset(
            _DAI_ADDRESS,
            address(mockDaiFeed),
            0,
            true
        );

        vm.warp(gaugeManager.gaugeStartTime());
        vm.roll(block.number + 1000);

        mockUsdcFeed.setMockUpdatedAt(block.timestamp);
        mockDaiFeed.setMockUpdatedAt(block.timestamp);

        

        _prepareUSDC(address(this), _ONE + 77777);
        _prepareDAI(address(this), 10e18 + 77777);
        
        usdc.approve(address(borrowableCUSDC), _ONE + 77777);
        dai.approve(address(borrowableCDAI), 10e18 + 77777);

        marketManagerIsolated.listTokens(address(borrowableCDAI), address(borrowableCUSDC));

        _setCTokenConfigBasic(address(borrowableCDAI), 100_000e18, 100_000e18);
        _setCTokenConfigBasic(address(borrowableCUSDC), 100_000e18, 100_000e6);

        borrowableCDAI.mint(_ONE, address(this));

        _prepareDAI(user1, _ONE + _ONE);

        vm.startPrank(user1);
        dai.approve(address(borrowableCDAI), _ONE + _ONE);
        borrowableCDAI.depositAsCollateral(_ONE + _ONE, user1);
        vm.stopPrank();
    }

    function test_borrowableCTokenRemoveCollateral_fail_whenZeroAmount() public {
        vm.expectRevert(BaseCToken.BaseCToken__ZeroAmount.selector);
        _removeBorrowableCDAICollateral(0);
    }

    function test_borrowableCTokenRemoveCollateral_fail_whenCooldownActive() public {
        vm.expectRevert(
            MarketManagerIsolated.MarketManager__MinimumHoldPeriod.selector
        );

        _removeBorrowableCDAICollateral(_ONE);
    }

    function test_borrowableCTokenRemoveCollateral_fail_whenCollateralAmountExceedsCTokens() public {
        vm.expectRevert(
            BaseCToken.BaseCToken__InsufficientLiquidity.selector
        );

        _removeBorrowableCDAICollateral(10e18);
    }

    function test_borrowableCTokenRemoveCollateral_fail_whenCollateralIsRequired() public {
        _prepareUSDC(address(this), _ONE + _ONE);
        usdc.approve(address(borrowableCUSDC), _ONE + _ONE);
        borrowableCUSDC.deposit(_ONE, address(this));

        _prepareDAI(user1, 500e18);

        vm.startPrank(user1);
        dai.approve(address(borrowableCDAI), 500e18);
        borrowableCDAI.depositAsCollateral(500e18, user1);
        
        borrowableCUSDC.borrow(200e6, user1);
        vm.stopPrank();

        skip(20 minutes);

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__InsufficientCollateral.selector
        );

        _removeBorrowableCDAICollateral(400e18);
    }

    function test_borrowableCTokenRemoveCollateral_success() public {
        uint256 balanceBefore = borrowableCDAI.balanceOf(user1);
        uint256 userCollateral = borrowableCDAI.collateralPosted(user1);
        uint256 totalCollateral = borrowableCDAI.marketCollateralPosted();
        uint256 collateralRemoved = _ONE;

        skip(20 minutes);

        vm.expectEmit(true, true, true, true, address(borrowableCDAI));
        emit CollateralUpdated(collateralRemoved, false, user1);

        _removeBorrowableCDAICollateral(collateralRemoved);

        // Balance should not have changed.
        assertEq(borrowableCDAI.balanceOf(user1), balanceBefore);

        // User collateral should go up by `collateralRemoved`.
        assertEq(borrowableCDAI.collateralPosted(user1), userCollateral - collateralRemoved);

        // Market collateral should go up by `collateralRemoved`.
        assertEq(borrowableCDAI.marketCollateralPosted(), totalCollateral - collateralRemoved);
    }

    function _removeBorrowableCDAICollateral(uint256 shares) internal {
        vm.startPrank(user1);
        borrowableCDAI.removeCollateral(shares);
        vm.stopPrank();
    }

}
