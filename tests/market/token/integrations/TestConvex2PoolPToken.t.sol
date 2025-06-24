// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { Convex2PoolCToken, IERC20 } from "contracts/market/token/Convex2PoolCToken.sol";
import { IBooster } from "contracts/interfaces/external/convex/IBooster.sol";
import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";

import "tests/market/TestBaseMarketIsolated.sol";

contract TestConvex2PoolPToken is TestBaseMarketIsolated {
    address internal _CVX_ADDRESS = 0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B;
    address internal _CRV_ADDRESS = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    IERC20 public CONVEX_STETH_ETH_POOL =
        IERC20(0x21E27a5E5513D6e65C4f830167390997aA84843a);
    uint256 public CONVEX_STETH_ETH_POOL_ID = 177;
    address public CONVEX_STETH_ETH_REWARD =
        0x6B27D7BC63F1999D14fF9bA900069ee516669ee8;
    address public CONVEX_BOOSTER = 0xF403C135812408BFbE8713b5A23a04b3D48AAE31;
    address public SUSHI_ROUTER = 0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F;

    MockDataFeed public mockCRVFeed;
    MockDataFeed public mockCVXFeed;
    MockDataFeed public mockWethFeed;
    Convex2PoolCToken public cSTETH;

    /*
    LP token address	0x21E27a5E5513D6e65C4f830167390997aA84843a
    Deposit contract address	0xF403C135812408BFbE8713b5A23a04b3D48AAE31
    Rewards contract address	0x6B27D7BC63F1999D14fF9bA900069ee516669ee8
    Convex pool id	177
    Convex pool url	https://www.convexfinance.com/stake/ethereum/177
    */

    receive() external payable {}

    fallback() external payable {}

    function setUp() public override {
        super.setUp();

        centralRegistry.addHarvestPermissions(address(this));
        centralRegistry.setFeeManager(address(this));

        // start epoch
        vm.warp(gaugeManager.gaugeStartTime());
        _skipEpochDuration(1);
        vm.roll(block.number + 1000);

        cSTETH = new Convex2PoolCToken(
            ICentralRegistry(address(centralRegistry)),
            CONVEX_STETH_ETH_POOL,
            address(marketManagerIsolated),
            CONVEX_STETH_ETH_POOL_ID,
            CONVEX_STETH_ETH_REWARD,
            CONVEX_BOOSTER,
            1 days
        );

        address owner = address(this);
        deal(address(CONVEX_STETH_ETH_POOL), owner, 1 ether);
        CONVEX_STETH_ETH_POOL.approve(address(cSTETH), 1 ether);

        _prepareUSDC(address(this), 1 ether);
        usdc.approve(address(eUSDC), 1 ether);
        marketManagerIsolated.listTokens(address(cSTETH), address(eUSDC));

        centralRegistry.setExternalCalldataChecker(
            _UNISWAP_V2_ROUTER,
            address(new MockCalldataChecker(_UNISWAP_V2_ROUTER))
        );
        centralRegistry.setExternalCalldataChecker(
            SUSHI_ROUTER,
            address(new MockCalldataChecker(SUSHI_ROUTER))
        );

        mockCRVFeed = new MockDataFeed(
            0xCd627aA160A6fA45Eb793D19Ef54f5062F20f33f
        );
        mockCRVFeed.setMockUpdatedAt(block.timestamp);
        chainlinkAdaptor.addAsset(_CRV_ADDRESS, address(mockCRVFeed), 0, true);
        oracleManager.addAssetPriceFeed(
            _CRV_ADDRESS,
            address(chainlinkAdaptor)
        );

        mockCVXFeed = new MockDataFeed(
            0xd962fC30A72A84cE50161031391756Bf2876Af5D
        );
        mockCVXFeed.setMockUpdatedAt(block.timestamp);
        chainlinkAdaptor.addAsset(_CVX_ADDRESS, address(mockCVXFeed), 0, true);
        oracleManager.addAssetPriceFeed(
            _CVX_ADDRESS,
            address(chainlinkAdaptor)
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
        chainlinkAdaptor.addAsset(
            0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE,
            address(mockWethFeed),
            0,
            true
        );
        dualChainlinkAdaptor.addAsset(
            0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE,
            address(mockWethFeed),
            0,
            true
        );
    }

    function testConvexStethEthPool() public {
        uint256 assets = 100e18;
        deal(address(CONVEX_STETH_ETH_POOL), user1, assets);

        vm.prank(user1);
        CONVEX_STETH_ETH_POOL.approve(address(cSTETH), assets);

        vm.prank(user1);
        cSTETH.deposit(assets, user1);

        assertEq(
            cSTETH.totalAssets(),
            assets + 77777,
            "Total Assets should equal user deposit."
        );

        IBooster(CONVEX_BOOSTER).earmarkRewards(CONVEX_STETH_ETH_POOL_ID);

        // Advance time to earn CRV and CVX rewards
        vm.warp(block.timestamp + 10 days);

        mockCRVFeed.setMockUpdatedAt(block.timestamp);
        mockCVXFeed.setMockUpdatedAt(block.timestamp);
        mockWethFeed.setMockUpdatedAt(block.timestamp);

        // Mint some extra rewards for Vault.
        // deal(_CRV_ADDRESS, address(cSTETH), 100e18);
        // deal(_CVX_ADDRESS, address(cSTETH), 100e18);
        // deal(address(cSTETH), 1 ether);

        SwapperLib.Swap[] memory swaps = new SwapperLib.Swap[](2);
        uint256 crvAmount = 200 ether;
        swaps[0].slippage = 0.3e18;
        swaps[0].inputToken = _CRV_ADDRESS;
        swaps[0].inputAmount = crvAmount;
        swaps[0].outputToken = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
        swaps[0].target = _UNISWAP_V2_ROUTER;
        address[] memory path = new address[](2);
        path[0] = _CRV_ADDRESS;
        path[1] = _WETH_ADDRESS;
        swaps[0].call = abi.encodeWithSignature(
            "swapExactTokensForETH(uint256,uint256,address[],address,uint256)",
            crvAmount,
            0,
            path,
            address(cSTETH),
            block.timestamp
        );

        uint256 cvxAmount = 2 ether;
        swaps[1].slippage = 0.3e18;
        swaps[1].inputToken = _CVX_ADDRESS;
        swaps[1].inputAmount = cvxAmount;
        swaps[1].outputToken = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
        swaps[1].target = SUSHI_ROUTER;
        path[0] = _CVX_ADDRESS;
        path[1] = _WETH_ADDRESS;
        swaps[1].call = abi.encodeWithSignature(
            "swapExactTokensForETH(uint256,uint256,address[],address,uint256)",
            cvxAmount,
            0,
            path,
            address(cSTETH),
            block.timestamp
        );

        cSTETH.harvest(abi.encode(swaps, 1e8));

        assertEq(
            cSTETH.totalAssets(),
            assets + 77777,
            "Total Assets should equal user deposit."
        );

        vm.warp(block.timestamp + 8 days);

        // Mint some extra rewards for Vault.
        deal(_CRV_ADDRESS, address(cSTETH), 100e18);
        deal(_CVX_ADDRESS, address(cSTETH), 100e18);
        deal(address(cSTETH), 1 ether);
        cSTETH.harvest(abi.encode(new SwapperLib.Swap[](0), 1e8));
        vm.warp(block.timestamp + 7 days);

        uint256 totalAssets = cSTETH.totalAssets();

        assertGt(
            totalAssets,
            assets + 77777,
            "Total Assets should greater than original deposit."
        );

        uint256 balance = cSTETH.balanceOf(user1);

        vm.prank(user1);
        cSTETH.withdraw(balance, user1, user1);
    }
}
