// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;
import { IMToken } from "contracts/interfaces/IMToken.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import "tests/market/TestBaseMarket.sol";

contract TestLiquidationSequencing is TestBaseMarket {
    address public owner;

    MockDataFeed public mockDaiFeed;
    MockDataFeed public mockWethFeed;
    MockDataFeed public mockRethFeed;

    receive() external payable {}

    fallback() external payable {}

    bytes4 public constant INVALID_LIQUIDATOR_ERROR =
        bytes4(keccak256("LiquidationManager__InvalidLiquidator()"));

    function setUp() public override {
        super.setUp();

        owner = address(this);

        // use mock pricing for testing
        mockDaiFeed = new MockDataFeed(_CHAINLINK_DAI_USD);
        chainlinkAdaptor.addAsset(_DAI_ADDRESS, address(mockDaiFeed), 0, true);
        dualChainlinkAdaptor.addAsset(
            _DAI_ADDRESS,
            address(mockDaiFeed),
            0,
            true
        );
        mockWethFeed = new MockDataFeed(_CHAINLINK_ETH_USD);
        chainlinkAdaptor.addAsset(
            _WETH_ADDRESS,
            address(mockWethFeed),
            0,
            true
        );
        dualChainlinkAdaptor.addAsset(
            _WETH_ADDRESS,
            address(mockWethFeed),
            0,
            true
        );
        mockRethFeed = new MockDataFeed(_CHAINLINK_RETH_ETH);
        chainlinkAdaptor.addAsset(
            _RETH_ADDRESS,
            address(mockRethFeed),
            0,
            false
        );
        dualChainlinkAdaptor.addAsset(
            _RETH_ADDRESS,
            address(mockRethFeed),
            0,
            false
        );

        // start epoch
        vm.warp(gaugeManager.startTime());
        vm.roll(block.number + 1000);

        mockDaiFeed.setMockUpdatedAt(block.timestamp);
        mockWethFeed.setMockUpdatedAt(block.timestamp);
        mockRethFeed.setMockUpdatedAt(block.timestamp);

        (, int256 ethPrice, , , ) = mockWethFeed.latestRoundData();
        chainlinkEthUsd.updateAnswer(ethPrice);

        // deploy eDAI
        {
            _prepareDAI(owner, 200000e18);
            dai.approve(address(eDAI), 200000e18);
            marketManager.listToken(address(eDAI));
            // add MToken support on oracle manager
            oracleManager.addMTokenSupport(address(eDAI));
        }

        // deploy PBALRETH
        {
            // support market
            _prepareBALRETH(owner, 1 ether);
            balRETH.approve(address(pBALRETH), 1 ether);
            marketManager.listToken(address(pBALRETH));
            // set collateral factor
            marketManager.updatePositionToken(
                IMToken(address(pBALRETH)),
                7000,
                4000,
                3000,
                200,
                400,
                10,
                1000
            );
            address[] memory tokens = new address[](1);
            tokens[0] = address(pBALRETH);
            uint256[] memory caps = new uint256[](1);
            caps[0] = 100_000e18;
            marketManager.setPTokenCollateralCaps(tokens, caps);
        }

        // provide enough liquidity
        provideEnoughLiquidityForLeverage();
    }

    function provideEnoughLiquidityForLeverage() internal {
        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareDAI(liquidityProvider, 200000e18);
        _prepareBALRETH(liquidityProvider, 10 ether);
        // mint eDAI
        vm.startPrank(liquidityProvider);
        dai.approve(address(eDAI), 200000 ether);
        eDAI.mint(200000 ether);
        // mint cBALETH
        balRETH.approve(address(pBALRETH), 10 ether);
        pBALRETH.deposit(10 ether, liquidityProvider);
        vm.stopPrank();
    }

    function testSecondLiquidationWithSameNonceSucceedsAfterPriorityDuration()
        public
    {
        // First let's verify that atlas OEV is not allowed
        assertEq(centralRegistry.atlasOevAllowed(), false);
        _prepareBALRETH(user1, 1 ether);

        // Setup the borrower position
        vm.startPrank(user1);
        balRETH.approve(address(pBALRETH), 1 ether);
        pBALRETH.deposit(1 ether, user1);
        marketManager.postCollateral(user1, address(pBALRETH), 1 ether - 1);
        eDAI.borrow(1000 ether);
        vm.stopPrank();

        // Skip min hold period
        skip(20 minutes);

        // Make position liquidatable by adjusting DAI price
        mockDaiFeed.setMockAnswer(200000000);

        // Prepare user2 as liquidator
        _prepareDAI(user2, 500 ether);

        // Enable sequencing
        vm.prank(address(centralRegistry));
        marketManager.setSequencingStatus(true);

        // User2's queues liquidation
        vm.startPrank(user2, user2);
        eDAI.queueLiquidation(user1, IMToken(address(pBALRETH)));
        vm.stopPrank();

        // test multiple different liquidators queuing in same block
        vm.startPrank(user3, user3);
        eDAI.queueLiquidation(user1, IMToken(address(pBALRETH)));
        vm.stopPrank();

        // Skip priority duration
        skip(1 seconds);

        // User2's liquidation should succeed because they have priority access
        vm.startPrank(user2, user2);
        dai.approve(address(eDAI), 250 ether);
        eDAI.liquidateExact(user1, 250 ether, IMToken(address(pBALRETH)));
        vm.stopPrank();

        // Verify liquidation succeeded by checking balances
        assertApproxEqRel(eDAI.debtBalanceCached(user1), 750 ether, 0.01e18);

        // Make position liquidatable by adjusting DAI price
        mockDaiFeed.setMockAnswer(300000000);

        // User2's liquidation should succeed again because this second liquidation is still within the same nonce/end duration
        vm.startPrank(user2, user2);
        dai.approve(address(eDAI), 250 ether);
        eDAI.liquidateExact(user1, 250 ether, IMToken(address(pBALRETH)));
        vm.stopPrank();

        // Verify liquidation succeeded again by checking balances
        assertApproxEqRel(eDAI.debtBalanceCached(user1), 500 ether, 0.01e18);
    }

    function testSecondLiquidationWithSameNonceForDifferentNonQueuingLiquidator()
        public
    {
        // First let's verify that atlas OEV is not allowed
        assertEq(centralRegistry.atlasOevAllowed(), false);
        _prepareBALRETH(user1, 1 ether);

        // Setup the borrower position
        vm.startPrank(user1);
        balRETH.approve(address(pBALRETH), 1 ether);
        pBALRETH.deposit(1 ether, user1);
        marketManager.postCollateral(user1, address(pBALRETH), 1 ether - 1);
        eDAI.borrow(1000 ether);
        vm.stopPrank();

        // Skip min hold period
        skip(20 minutes);

        // Make position liquidatable by adjusting DAI price
        mockDaiFeed.setMockAnswer(200000000);

        // Prepare user2 as liquidator
        _prepareDAI(user2, 250 ether);

        // Prepare user3 as liquidator
        _prepareDAI(user3, 250 ether);

        // Enable sequencing
        vm.prank(address(centralRegistry));
        marketManager.setSequencingStatus(true);

        // User2's queues liquidation
        vm.startPrank(user2, user2);
        eDAI.queueLiquidation(user1, IMToken(address(pBALRETH)));
        vm.stopPrank();

        // test multiple different liquidators queuing in same block
        vm.startPrank(user4, user4);
        eDAI.queueLiquidation(user1, IMToken(address(pBALRETH)));
        vm.stopPrank();

        // Skip priority duration
        skip(1 seconds);

        // User2's liquidation should succeed because they have priority access
        vm.startPrank(user2, user2);
        dai.approve(address(eDAI), 250 ether);
        eDAI.liquidateExact(user1, 250 ether, IMToken(address(pBALRETH)));
        vm.stopPrank();

        // Verify liquidation succeeded by checking balances
        assertApproxEqRel(eDAI.debtBalanceCached(user1), 750 ether, 0.01e18);

        // Make position liquidatable by adjusting DAI price
        mockDaiFeed.setMockAnswer(300000000);

        // User3's liquidation should fail because it is before regular duration and they have not queued
        vm.startPrank(user3, user3);
        dai.approve(address(eDAI), 250 ether);
        vm.expectRevert(INVALID_LIQUIDATOR_ERROR);
        eDAI.liquidateExact(user1, 250 ether, IMToken(address(pBALRETH)));

        // Skip to regular duration
        skip(1 seconds);

        // User3's liquidation should succeed because it is past regular duration
        vm.startPrank(user3, user3);
        dai.approve(address(eDAI), 250 ether);
        eDAI.liquidateExact(user1, 250 ether, IMToken(address(pBALRETH)));
        vm.stopPrank();

        // Verify liquidation succeeded again by checking balances
        assertApproxEqRel(eDAI.debtBalanceCached(user1), 500 ether, 0.01e18);
    }

    function testSecondLiquidationWithSameNonceFailsAfterEndDurationForDifferentNonQueuingLiquidator()
        public
    {
        // First let's verify that atlas OEV is not allowed
        assertEq(centralRegistry.atlasOevAllowed(), false);
        _prepareBALRETH(user1, 1 ether);

        // Setup the borrower position
        vm.startPrank(user1);
        balRETH.approve(address(pBALRETH), 1 ether);
        pBALRETH.deposit(1 ether, user1);
        marketManager.postCollateral(user1, address(pBALRETH), 1 ether - 1);
        eDAI.borrow(1000 ether);
        vm.stopPrank();

        // Skip min hold period
        skip(20 minutes);

        // Make position liquidatable by adjusting DAI price
        mockDaiFeed.setMockAnswer(200000000);

        // Prepare user2 as liquidator
        _prepareDAI(user2, 250 ether);

        // Prepare user3 as liquidator
        _prepareDAI(user3, 250 ether);

        // Enable sequencing
        vm.prank(address(centralRegistry));
        marketManager.setSequencingStatus(true);

        // User2's queues liquidation
        vm.startPrank(user2, user2);
        eDAI.queueLiquidation(user1, IMToken(address(pBALRETH)));
        vm.stopPrank();

        // Skip priority duration
        skip(1 seconds);

        // test multiple different liquidators queuing over multiple block
        vm.startPrank(user4, user4);
        eDAI.queueLiquidation(user1, IMToken(address(pBALRETH)));
        vm.stopPrank();

        // User2's liquidation should succeed because they have priority access
        vm.startPrank(user2, user2);
        dai.approve(address(eDAI), 250 ether);
        eDAI.liquidateExact(user1, 250 ether, IMToken(address(pBALRETH)));
        vm.stopPrank();

        // Verify liquidation succeeded by checking balances
        assertApproxEqRel(eDAI.debtBalanceCached(user1), 750 ether, 0.01e18);

        // Skip to after end duration
        skip(30 seconds);

        // Make position liquidatable by adjusting DAI price
        mockDaiFeed.setMockAnswer(300000000);

        // User3's liquidation should fail because it is after end duration
        vm.startPrank(user3, user3);
        dai.approve(address(eDAI), 250 ether);
        vm.expectRevert(INVALID_LIQUIDATOR_ERROR);
        eDAI.liquidateExact(user1, 250 ether, IMToken(address(pBALRETH)));
        vm.stopPrank();
    }

    function testSecondLiquidationSucceedsForSameLiquidatorAfterIncrementingNonceAfterPriorityDuration()
        public
    {
        // First let's verify that atlas OEV is not allowed
        assertEq(centralRegistry.atlasOevAllowed(), false);
        _prepareBALRETH(user1, 1 ether);

        // Setup the borrower position
        vm.startPrank(user1);
        balRETH.approve(address(pBALRETH), 1 ether);
        pBALRETH.deposit(1 ether, user1);
        marketManager.postCollateral(user1, address(pBALRETH), 1 ether - 1);
        eDAI.borrow(1000 ether);
        vm.stopPrank();

        // Skip min hold period
        skip(20 minutes);

        // Make position liquidatable by adjusting DAI price
        mockDaiFeed.setMockAnswer(200000000);

        // Prepare user2 as liquidator
        _prepareDAI(user2, 500 ether);

        // Enable sequencing
        vm.prank(address(centralRegistry));
        marketManager.setSequencingStatus(true);

        // User2's queues liquidation
        vm.startPrank(user2, user2);
        eDAI.queueLiquidation(user1, IMToken(address(pBALRETH)));
        vm.stopPrank();

        // Skip priority duration
        skip(1 seconds);

        // test multiple different liquidators queuing over multiple block
        vm.startPrank(user4, user4);
        eDAI.queueLiquidation(user1, IMToken(address(pBALRETH)));
        vm.stopPrank();

        // User2's liquidation should succeed because they have priority access
        vm.startPrank(user2, user2);
        dai.approve(address(eDAI), 250 ether);
        eDAI.liquidateExact(user1, 250 ether, IMToken(address(pBALRETH)));
        vm.stopPrank();

        // Verify liquidation succeeded by checking balances
        assertApproxEqRel(eDAI.debtBalanceCached(user1), 750 ether, 0.01e18);

        // Skip to after end duration so nonce must be incremented
        skip(30 seconds);

        // Make position liquidatable by adjusting DAI price
        mockDaiFeed.setMockAnswer(300000000);

        // User2's liquidation should fail because they didnt re queue after end duration
        vm.startPrank(user2, user2);
        dai.approve(address(eDAI), 250 ether);
        vm.expectRevert(INVALID_LIQUIDATOR_ERROR);
        eDAI.liquidateExact(user1, 250 ether, IMToken(address(pBALRETH)));

        // User2's queues liquidation and increments nonce
        eDAI.queueLiquidation(user1, IMToken(address(pBALRETH)));
        vm.stopPrank();

        // Skip priority duration for second nonce
        skip(1 seconds);

        // test multiple different liquidators queuing over multiple block
        vm.startPrank(user4, user4);
        eDAI.queueLiquidation(user1, IMToken(address(pBALRETH)));
        vm.stopPrank();

        vm.startPrank(user2, user2);
        // User2's liquidation should succeed because it is after priority duration for new nonce
        dai.approve(address(eDAI), 250 ether);
        eDAI.liquidateExact(user1, 250 ether, IMToken(address(pBALRETH)));
        vm.stopPrank();

        // Verify liquidation succeeded again by checking balances
        assertApproxEqRel(eDAI.debtBalanceCached(user1), 500 ether, 0.01e18);
    }

    function testSecondLiquidationSucceedsForSameLiquidatorAfterIncrementingNonceAfterRegularDuration()
        public
    {
        // First let's verify that atlas OEV is not allowed
        assertEq(centralRegistry.atlasOevAllowed(), false);
        _prepareBALRETH(user1, 1 ether);

        // Setup the borrower position
        vm.startPrank(user1);
        balRETH.approve(address(pBALRETH), 1 ether);
        pBALRETH.deposit(1 ether, user1);
        marketManager.postCollateral(user1, address(pBALRETH), 1 ether - 1);
        eDAI.borrow(1000 ether);
        vm.stopPrank();

        // Skip min hold period
        skip(20 minutes);

        // Make position liquidatable by adjusting DAI price
        mockDaiFeed.setMockAnswer(200000000);

        // Prepare user2 as liquidator
        _prepareDAI(user2, 500 ether);

        // Enable sequencing
        vm.prank(address(centralRegistry));
        marketManager.setSequencingStatus(true);

        // User2's queues liquidation
        vm.startPrank(user2, user2);
        eDAI.queueLiquidation(user1, IMToken(address(pBALRETH)));
        vm.stopPrank();

        // Skip priority duration
        skip(1 seconds);

        // User2's liquidation should succeed because they have priority access
        vm.startPrank(user2, user2);
        dai.approve(address(eDAI), 250 ether);
        eDAI.liquidateExact(user1, 250 ether, IMToken(address(pBALRETH)));
        vm.stopPrank();

        // Verify liquidation succeeded by checking balances
        assertApproxEqRel(eDAI.debtBalanceCached(user1), 750 ether, 0.01e18);

        // Skip to after end duration so nonce must be incremented
        skip(30 seconds);

        // Make position liquidatable by adjusting DAI price
        mockDaiFeed.setMockAnswer(300000000);

        vm.startPrank(user3, user3);
        // User3 queues liquidation and increments nonce
        eDAI.queueLiquidation(user1, IMToken(address(pBALRETH)));
        vm.stopPrank();

        // Skip priority duration for second nonce
        skip(1 seconds);

        vm.startPrank(user2, user2);
        // User2's liquidation should fail because it is before regular duration for new nonce
        dai.approve(address(eDAI), 250 ether);
        vm.expectRevert(INVALID_LIQUIDATOR_ERROR);
        eDAI.liquidateExact(user1, 250 ether, IMToken(address(pBALRETH)));
        vm.stopPrank();

        // Skip regular duration for second nonce
        skip(1 seconds);

        // test multiple different liquidators queuing over multiple block
        vm.startPrank(user4, user4);
        eDAI.queueLiquidation(user1, IMToken(address(pBALRETH)));
        vm.stopPrank();

        vm.startPrank(user2, user2);
        // User2's liquidation should succeed because it is after regular duration for new nonce
        dai.approve(address(eDAI), 250 ether);
        eDAI.liquidateExact(user1, 250 ether, IMToken(address(pBALRETH)));
        vm.stopPrank();

        // Verify liquidation succeeded again by checking balances
        assertApproxEqRel(eDAI.debtBalanceCached(user1), 500 ether, 0.01e18);
    }

    function testSecondLiquidationFailsForSameLiquidatorAfterIncrementingNonceAfterSecondEndDuration()
        public
    {
        // First let's verify that atlas OEV is not allowed
        assertEq(centralRegistry.atlasOevAllowed(), false);
        _prepareBALRETH(user1, 1 ether);

        // Setup the borrower position
        vm.startPrank(user1);
        balRETH.approve(address(pBALRETH), 1 ether);
        pBALRETH.deposit(1 ether, user1);
        marketManager.postCollateral(user1, address(pBALRETH), 1 ether - 1);
        eDAI.borrow(1000 ether);
        vm.stopPrank();

        // Skip min hold period
        skip(20 minutes);

        // Make position liquidatable by adjusting DAI price
        mockDaiFeed.setMockAnswer(200000000);

        // Prepare user2 as liquidator
        _prepareDAI(user2, 500 ether);

        // Enable sequencing
        vm.prank(address(centralRegistry));
        marketManager.setSequencingStatus(true);

        // User2's queues liquidation
        vm.startPrank(user2, user2);
        eDAI.queueLiquidation(user1, IMToken(address(pBALRETH)));
        vm.stopPrank();

        // test multiple different liquidators queuing over same block
        vm.startPrank(user4, user4);
        eDAI.queueLiquidation(user1, IMToken(address(pBALRETH)));
        vm.stopPrank();

        // Skip priority duration
        skip(1 seconds);

        // User2's liquidation should succeed because they have priority access
        vm.startPrank(user2, user2);
        dai.approve(address(eDAI), 250 ether);
        eDAI.liquidateExact(user1, 250 ether, IMToken(address(pBALRETH)));
        vm.stopPrank();

        // Verify liquidation succeeded by checking balances
        assertApproxEqRel(eDAI.debtBalanceCached(user1), 750 ether, 0.01e18);

        // Skip to after end duration
        skip(30 seconds);

        // Make position liquidatable by adjusting DAI price
        mockDaiFeed.setMockAnswer(300000000);

        // User2's queues liquidation and increments nonce
        vm.startPrank(user2, user2);
        eDAI.queueLiquidation(user1, IMToken(address(pBALRETH)));
        vm.stopPrank();

        // Skip to second after second end duration
        skip(31 seconds);

        // User2's liquidation should fail because it is after end duration for new nonce
        vm.startPrank(user2, user2);
        dai.approve(address(eDAI), 250 ether);
        vm.expectRevert(INVALID_LIQUIDATOR_ERROR);
        eDAI.liquidateExact(user1, 250 ether, IMToken(address(pBALRETH)));
        vm.stopPrank();
    }

    function testSecondLiquidationSucceedsForDifferentLiquidatorAfterIncrementingNonceAfterPriorityDuration()
        public
    {
        // First let's verify that atlas OEV is not allowed
        assertEq(centralRegistry.atlasOevAllowed(), false);
        _prepareBALRETH(user1, 1 ether);

        // Setup the borrower position
        vm.startPrank(user1);
        balRETH.approve(address(pBALRETH), 1 ether);
        pBALRETH.deposit(1 ether, user1);
        marketManager.postCollateral(user1, address(pBALRETH), 1 ether - 1);
        eDAI.borrow(1000 ether);
        vm.stopPrank();

        // Skip min hold period
        skip(20 minutes);

        // Make position liquidatable by adjusting DAI price
        mockDaiFeed.setMockAnswer(200000000);

        // Prepare user2 as liquidator
        _prepareDAI(user2, 500 ether);

        // Prepare user3 as liquidator
        _prepareDAI(user3, 250 ether);

        // Enable sequencing
        vm.prank(address(centralRegistry));
        marketManager.setSequencingStatus(true);

        // User2's queues liquidation
        vm.startPrank(user2, user2);
        eDAI.queueLiquidation(user1, IMToken(address(pBALRETH)));
        vm.stopPrank();

        // Skip priority duration
        skip(1 seconds);

        // User2's liquidation should succeed because they have priority access
        vm.startPrank(user2, user2);
        dai.approve(address(eDAI), 250 ether);
        eDAI.liquidateExact(user1, 250 ether, IMToken(address(pBALRETH)));
        vm.stopPrank();

        // Verify liquidation succeeded by checking balances
        assertApproxEqRel(eDAI.debtBalanceCached(user1), 750 ether, 0.01e18);

        // Skip to after end duration so nonce must be incremented
        skip(30 seconds);

        // Make position liquidatable by adjusting DAI price
        mockDaiFeed.setMockAnswer(300000000);

        // User3's liquidation should fail because they didnt re queue after end duration
        vm.startPrank(user3, user3);
        dai.approve(address(eDAI), 250 ether);
        vm.expectRevert(INVALID_LIQUIDATOR_ERROR);
        eDAI.liquidateExact(user1, 250 ether, IMToken(address(pBALRETH)));

        // User3 queues liquidation and increments nonce
        eDAI.queueLiquidation(user1, IMToken(address(pBALRETH)));
        vm.stopPrank();

        // Skip priority duration for second nonce
        skip(1 seconds);

        // test multiple different liquidators queuing over multiple blocks
        vm.startPrank(user4, user4);
        eDAI.queueLiquidation(user1, IMToken(address(pBALRETH)));
        vm.stopPrank();

        vm.startPrank(user3, user3);
        // User3's liquidation should succeed because it is after priority duration for new nonce
        dai.approve(address(eDAI), 250 ether);
        eDAI.liquidateExact(user1, 250 ether, IMToken(address(pBALRETH)));
        vm.stopPrank();

        // Verify liquidation succeeded again by checking balances
        assertApproxEqRel(eDAI.debtBalanceCached(user1), 500 ether, 0.01e18);
    }

    function testSecondLiquidationSucceedsForDifferentLiquidatorAfterIncrementingNonceAfterRegularDuration()
        public
    {
        // First let's verify that atlas OEV is not allowed
        assertEq(centralRegistry.atlasOevAllowed(), false);
        _prepareBALRETH(user1, 1 ether);

        // Setup the borrower position
        vm.startPrank(user1);
        balRETH.approve(address(pBALRETH), 1 ether);
        pBALRETH.deposit(1 ether, user1);
        marketManager.postCollateral(user1, address(pBALRETH), 1 ether - 1);
        eDAI.borrow(1000 ether);
        vm.stopPrank();

        // Skip min hold period
        skip(20 minutes);

        // Make position liquidatable by adjusting DAI price
        mockDaiFeed.setMockAnswer(200000000);

        // Prepare user2 as liquidator
        _prepareDAI(user2, 500 ether);

        // Prepare user3 as liquidator
        _prepareDAI(user3, 250 ether);

        // Enable sequencing
        vm.prank(address(centralRegistry));
        marketManager.setSequencingStatus(true);

        // User2's queues liquidation
        vm.startPrank(user2, user2);
        eDAI.queueLiquidation(user1, IMToken(address(pBALRETH)));
        vm.stopPrank();

        // Skip priority duration
        skip(1 seconds);

        // User2's liquidation should succeed because they have priority access
        vm.startPrank(user2, user2);
        dai.approve(address(eDAI), 250 ether);
        eDAI.liquidateExact(user1, 250 ether, IMToken(address(pBALRETH)));
        vm.stopPrank();

        // Verify liquidation succeeded by checking balances
        assertApproxEqRel(eDAI.debtBalanceCached(user1), 750 ether, 0.01e18);

        // Skip to after end duration so nonce must be incremented
        skip(30 seconds);

        // Make position liquidatable by adjusting DAI price
        mockDaiFeed.setMockAnswer(300000000);

        vm.startPrank(user2, user2);
        // User2 queues liquidation and increments nonce
        eDAI.queueLiquidation(user1, IMToken(address(pBALRETH)));
        vm.stopPrank();

        // Skip priority duration for second nonce
        skip(1 seconds);

        // User3's liquidation should fail because it is before regular duration
        vm.startPrank(user3, user3);
        dai.approve(address(eDAI), 250 ether);
        vm.expectRevert(INVALID_LIQUIDATOR_ERROR);
        eDAI.liquidateExact(user1, 250 ether, IMToken(address(pBALRETH)));
        vm.stopPrank();

        // Skip regular duration for second nonce
        skip(1 seconds);

        // test multiple different liquidators queuing over multiple blocks
        vm.startPrank(user4, user4);
        eDAI.queueLiquidation(user1, IMToken(address(pBALRETH)));
        vm.stopPrank();

        vm.startPrank(user3, user3);
        // User3's liquidation should succeed because it is after priority duration for new nonce
        dai.approve(address(eDAI), 250 ether);
        eDAI.liquidateExact(user1, 250 ether, IMToken(address(pBALRETH)));
        vm.stopPrank();

        // Verify liquidation succeeded again by checking balances
        assertApproxEqRel(eDAI.debtBalanceCached(user1), 500 ether, 0.01e18);
    }

    function testSecondLiquidationFailsForDifferentLiquidatorAfterIncrementingNonceAfterSecondEndDuration()
        public
    {
        // First let's verify that atlas OEV is not allowed
        assertEq(centralRegistry.atlasOevAllowed(), false);
        _prepareBALRETH(user1, 1 ether);

        // Setup the borrower position
        vm.startPrank(user1);
        balRETH.approve(address(pBALRETH), 1 ether);
        pBALRETH.deposit(1 ether, user1);
        marketManager.postCollateral(user1, address(pBALRETH), 1 ether - 1);
        eDAI.borrow(1000 ether);
        vm.stopPrank();

        // Skip min hold period
        skip(20 minutes);

        // Make position liquidatable by adjusting DAI price
        mockDaiFeed.setMockAnswer(200000000);

        // Prepare user2 as liquidator
        _prepareDAI(user2, 500 ether);

        // Prepare user3 as liquidator
        _prepareDAI(user3, 250 ether);

        // Enable sequencing
        vm.prank(address(centralRegistry));
        marketManager.setSequencingStatus(true);

        // User2's queues liquidation
        vm.startPrank(user2, user2);
        eDAI.queueLiquidation(user1, IMToken(address(pBALRETH)));
        vm.stopPrank();

        // Skip priority duration
        skip(1 seconds);

        // User2's liquidation should succeed because they have priority access
        vm.startPrank(user2, user2);
        dai.approve(address(eDAI), 250 ether);
        eDAI.liquidateExact(user1, 250 ether, IMToken(address(pBALRETH)));
        vm.stopPrank();

        // Verify liquidation succeeded by checking balances
        assertApproxEqRel(eDAI.debtBalanceCached(user1), 750 ether, 0.01e18);

        // Skip to after end duration
        skip(30 seconds);

        // Make position liquidatable by adjusting DAI price
        mockDaiFeed.setMockAnswer(300000000);

        // User3 queues liquidation and increments nonce
        vm.startPrank(user3, user3);
        eDAI.queueLiquidation(user1, IMToken(address(pBALRETH)));

        // Skip to second after second end duration
        skip(31 seconds);

        // User3's liquidation should fail because it is after end duration for new nonce
        dai.approve(address(eDAI), 250 ether);
        vm.expectRevert(INVALID_LIQUIDATOR_ERROR);
        eDAI.liquidateExact(user1, 250 ether, IMToken(address(pBALRETH)));
        vm.stopPrank();
    }
}
