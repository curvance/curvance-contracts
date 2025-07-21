// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { Convex2PoolCToken, IERC20 } from "contracts/market/token/Convex2PoolCToken.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";
import { Curve2PoolLPAdaptor } from "contracts/oracles/adaptors/curve/Curve2PoolLPAdaptor.sol";
import { IBaseRewardPool } from "contracts/interfaces/external/convex/IBaseRewardPool.sol";
import "tests/market/TestBaseMarketIsolated.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract TestConvexLPCollateral is TestBaseMarketIsolated {
    event Repay(uint256 repayAmount, address payer, address borrower);

    address internal constant _STETH_ADDRESS =
        0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

    IERC20 public CONVEX_STETH_ETH_POOL =
        IERC20(0x21E27a5E5513D6e65C4f830167390997aA84843a);
    uint256 public CONVEX_STETH_ETH_POOL_ID = 177;
    address public CONVEX_STETH_ETH_REWARD =
        0x6B27D7BC63F1999D14fF9bA900069ee516669ee8;
    address public CONVEX_BOOSTER = 0xF403C135812408BFbE8713b5A23a04b3D48AAE31;

    Convex2PoolCToken cSTETH;
    MockV3Aggregator public chainlinkStethUsd;

    function setUp() public override {
        super.setUp();

        cSTETH = new Convex2PoolCToken(
            ICentralRegistry(address(centralRegistry)),
            CONVEX_STETH_ETH_POOL,
            address(marketManagerIsolated),
            CONVEX_STETH_ETH_POOL_ID,
            CONVEX_STETH_ETH_REWARD,
            CONVEX_BOOSTER,
            1 days
        );
    }

    function testBorrowWithConvexLPCollateral() public {
        chainlinkStethUsd = new MockV3Aggregator(8, 1500e8, 3000e12, 1000e6);
        chainlinkAdaptor.addAsset(
            _STETH_ADDRESS,
            address(chainlinkStethUsd),
            0,
            true
        );
        oracleManager.addAssetPriceFeed(
            _STETH_ADDRESS,
            address(chainlinkAdaptor)
        );
        Curve2PoolLPAdaptor crvAdaptor = new Curve2PoolLPAdaptor(
            ICentralRegistry(address(centralRegistry))
        );
        crvAdaptor.setReentrancyConfig(2, 50_000);

        Curve2PoolLPAdaptor.AdaptorData memory data;
        data.pool = address(CONVEX_STETH_ETH_POOL);
        data.underlying0 = _ETH_ADDRESS;
        data.underlying1 = _STETH_ADDRESS;
        data.divideRate0 = true;
        data.divideRate1 = true;
        data.isCorrelated = true;
        data.upperBound = 10200;
        data.lowerBound = 10000;
        crvAdaptor.addAsset(address(CONVEX_STETH_ETH_POOL), data);
        oracleManager.addApprovedAdaptor(address(crvAdaptor));
        oracleManager.addAssetPriceFeed(
            address(CONVEX_STETH_ETH_POOL),
            address(crvAdaptor)
        );
        oracleManager.addCTokenSupport(address(cSTETH));

        // Ensure STETH/USD, ETH/USD, and USDC/USD feeds are not stale
        skip(gaugeManager.gaugeStartTime() - block.timestamp);
        chainlinkStethUsd.updateRoundData(
            0,
            1500e8,
            block.timestamp,
            block.timestamp
        );
        chainlinkEthUsd.updateRoundData(
            0,
            1500e8,
            block.timestamp,
            block.timestamp
        );
        chainlinkUsdcUsd.updateRoundData(
            0,
            1e8,
            block.timestamp,
            block.timestamp
        );

        // Need funds for initial mint when listing market token
        deal(address(CONVEX_STETH_ETH_POOL), address(this), 1 ether);
        SafeTransferLib.safeApprove(
            address(CONVEX_STETH_ETH_POOL),
            address(cSTETH),
            1 ether
        );
        _prepareUSDC(address(this), 1 ether);
        SafeTransferLib.safeApprove(_USDC_ADDRESS, address(borrowableCUSDC), 1 ether);
        marketManagerIsolated.listTokens(address(cSTETH), address(borrowableCUSDC));

        _setCTokenConfigBasic(address(cSTETH), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 100_000e18, 100_000e6);

        // User mints cSTETH with cvxStethEth LP tokens and then uses the cSTETH as collateral to borrow 10,000 eUSDC
        _prepareUSDC(address(borrowableCUSDC), 100_000e6);
        deal(address(CONVEX_STETH_ETH_POOL), user1, 10_000e18);
        vm.startPrank(user1);
        CONVEX_STETH_ETH_POOL.approve(address(cSTETH), 1_000e18);

        IBaseRewardPool rewarder = IBaseRewardPool(CONVEX_STETH_ETH_REWARD);

        assertEq(
            rewarder.balanceOf(address(cSTETH)),
            77777,
            "Rewarder must have balance equal to the initial mint"
        );
        assertEq(rewarder.earned(address(cSTETH)), 0);

        cSTETH.deposit(1_000e18, user1);
        cSTETH.postCollateral(1_000e18 - 1);

        assertEq(
            rewarder.balanceOf(address(cSTETH)),
            1000000000000000077777,
            "Convex LP Tokens must be deposited into Rewarder"
        );
        assertEq(rewarder.earned(address(cSTETH)), 0);
        assertEq(cSTETH.balanceOf(user1), 1_000e18);

        borrowableCUSDC.borrow(10_000e6, user1);
        vm.stopPrank();

        assertEq(
            usdc.balanceOf(user1),
            10_000e6,
            "User must have borrowed 10,000 USDC"
        );
        assertEq(
            borrowableCUSDC.debtBalance(user1),
            10_000e6,
            "User must have a debt balance of 10,000 USDC"
        );
        assertEq(
            borrowableCUSDC.marketOutstandingDebt(),
            10_000e6,
            "There must be a total amount of 10,000 USDC borrowed"
        );
    }

    function testConvexLPCollateralRepayDebt() public {
        testBorrowWithConvexLPCollateral();
        uint256 prevBalance = usdc.balanceOf(address(borrowableCUSDC));
        // User1 needs more funds to be able to repay debt with interest
        usdc.transfer(user1, 1000e6);

        vm.startPrank(user1);
        usdc.approve(address(borrowableCUSDC), type(uint256).max);
        vm.expectRevert(
            MarketManagerIsolated.MarketManager__MinimumHoldPeriod.selector
        );
        borrowableCUSDC.repay(0);

        // Must hold for a minimum of 20 minutes before debt can be repaid
        skip(20 minutes);
        // Pay off full debt including interest
        borrowableCUSDC.accrueIfNeeded();
        uint256 debtWithInterest = borrowableCUSDC.debtBalance(user1);
        vm.expectEmit(true, true, true, true, address(borrowableCUSDC));
        emit Repay(debtWithInterest, user1, user1);
        borrowableCUSDC.repay(0);
        vm.stopPrank();

        assertEq(borrowableCUSDC.marketOutstandingDebt(), 0, "No borrows must be left");
        assertEq(
            borrowableCUSDC.debtBalance(user1),
            0,
            "User must have settled debt"
        );
        assertEq(
            usdc.balanceOf(address(borrowableCUSDC)),
            debtWithInterest + prevBalance,
            "EToken's balance must include repaid debt plus interest"
        );
    }

    function testConvexLPCollateralRedemption() public {
        testConvexLPCollateralRepayDebt();
        IERC20 cvxPool = CONVEX_STETH_ETH_POOL;
        assertEq(cvxPool.balanceOf(user1), 9_000e18);

        vm.startPrank(user1);

        skip(128 days);
        chainlinkStethUsd.updateRoundData(
            0,
            1500e8,
            block.timestamp,
            block.timestamp
        );
        chainlinkEthUsd.updateRoundData(
            0,
            1500e8,
            block.timestamp,
            block.timestamp
        );
        chainlinkUsdcUsd.updateRoundData(
            0,
            1e8,
            block.timestamp,
            block.timestamp
        );
        cSTETH.redeem(cSTETH.balanceOf(user1) - 1, user1, user1);
        vm.stopPrank();

        assertEq(cSTETH.balanceOf(user1), 1);
        assertEq(cvxPool.balanceOf(user1), 10_000e18 - 1);
    }
}
