// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { Convex2PoolCToken, IERC20 } from "contracts/market/collateral/Convex2PoolCToken.sol";
import { IBooster } from "contracts/interfaces/external/convex/IBooster.sol";
import { MockCallDataChecker } from "contracts/mocks/MockCallDataChecker.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";

import "tests/market/TestBaseMarket.sol";

contract TestAuraCToken is TestBaseMarket {
    IERC20 public constant BAL =
        IERC20(0xba100000625a3754423978a60c9317c58a424e3D);
    IERC20 public constant AURA =
        IERC20(0xC0c293ce456fF0ED870ADd98a0828Dd4d2903DBF);

    MockDataFeed public mockUsdcFeed;
    MockDataFeed public mockDaiFeed;
    MockDataFeed public mockWethFeed;
    MockDataFeed public mockRethFeed;
    MockDataFeed mockBALFeed;
    MockDataFeed mockAURAFeed;

    receive() external payable {}

    fallback() external payable {}

    function setUp() public override {
        _fork(20287400);

        _init();

        centralRegistry.addHarvester(address(this));
        centralRegistry.setFeeAccumulator(address(this));

        centralRegistry.setExternalCallDataChecker(
            _UNISWAP_V2_ROUTER,
            address(new MockCallDataChecker(_UNISWAP_V2_ROUTER))
        );

        // use mock pricing for testing
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
            true
        );

        mockBALFeed = new MockDataFeed(
            0xdF2917806E30300537aEB49A7663062F4d1F2b5F
        );
        mockBALFeed.setMockUpdatedAt(block.timestamp);
        chainlinkAdaptor.addAsset(address(BAL), address(mockBALFeed), 0, true);
        oracleRouter.addAssetPriceFeed(
            address(BAL),
            address(chainlinkAdaptor)
        );

        mockAURAFeed = new MockDataFeed(
            0xdF2917806E30300537aEB49A7663062F4d1F2b5F
        );
        mockAURAFeed.setMockUpdatedAt(block.timestamp);
        chainlinkAdaptor.addAsset(
            address(AURA),
            address(mockAURAFeed),
            0,
            true
        );
        oracleRouter.addAssetPriceFeed(
            address(AURA),
            address(chainlinkAdaptor)
        );

        gaugePool.start();
        vm.warp(gaugePool.startTime());
        vm.roll(block.number + 1000);

        mockUsdcFeed.setMockUpdatedAt(block.timestamp);
        mockDaiFeed.setMockUpdatedAt(block.timestamp);
        mockWethFeed.setMockUpdatedAt(block.timestamp);
        mockRethFeed.setMockUpdatedAt(block.timestamp);

        _prepareBALRETH(user1, _ONE);
        _prepareBALRETH(address(this), _ONE);

        SafeTransferLib.safeApprove(
            _BAL_WETH_RETH_ADDRESS,
            address(cBALRETH),
            _ONE
        );
        marketManager.listToken(address(cBALRETH));
    }

    function testHarvestAuraCToken() public {
        uint256 assets = 100e18;
        _prepareBALRETH(user1, assets);

        vm.prank(address(user1));
        balRETH.approve(address(cBALRETH), assets);

        vm.prank(address(user1));
        cBALRETH.deposit(assets, user1);

        assertEq(
            cBALRETH.totalAssets(),
            assets + 42069,
            "Total Assets should equal user deposit."
        );

        IBooster(_AURA_BOOSTER).earmarkRewards(109);

        // Advance time to earn BAL and AURA rewards
        vm.warp(block.timestamp + 10 days);

        mockUsdcFeed.setMockUpdatedAt(block.timestamp);
        mockDaiFeed.setMockUpdatedAt(block.timestamp);
        mockWethFeed.setMockUpdatedAt(block.timestamp);
        mockRethFeed.setMockUpdatedAt(block.timestamp);
        mockBALFeed.setMockUpdatedAt(block.timestamp);
        mockAURAFeed.setMockUpdatedAt(block.timestamp);

        // Mint some extra rewards for Vault.
        // deal(address(CRV), address(cSTETH), 100e18);
        // deal(address(CVX), address(cSTETH), 100e18);
        // deal(address(cSTETH), 1 ether);

        SwapperLib.Swap[] memory swaps = new SwapperLib.Swap[](1);
        uint256 balAmount = 100 ether;
        swaps[0].slippage = 0.3e18;
        swaps[0].inputToken = address(BAL);
        swaps[0].inputAmount = balAmount;
        swaps[0].outputToken = _WETH_ADDRESS;
        swaps[0].target = _UNISWAP_V2_ROUTER;
        address[] memory path = new address[](2);
        path[0] = address(BAL);
        path[1] = _WETH_ADDRESS;
        swaps[0].call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            balAmount,
            0,
            path,
            address(cBALRETH),
            block.timestamp
        );

        cBALRETH.harvest(abi.encode(swaps, 0));

        vm.warp(block.timestamp + 8 days);

        assertGt(
            cBALRETH.totalAssets(),
            assets + 42069,
            "Total Assets should equal user deposit."
        );

        vm.startPrank(address(user1));
        cBALRETH.withdraw(cBALRETH.balanceOf(user1), user1, user1);
        vm.stopPrank();
    }

    function testReQueryTokens() external {
        cBALRETH.reQueryTokens();

        assertEq(cBALRETH.rewardTokens().length, 3);
        assertEq(cBALRETH.underlyingTokens().length, 2);
    }
}
