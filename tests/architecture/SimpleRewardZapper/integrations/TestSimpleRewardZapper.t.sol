// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import { TestBaseSimpleRewardZapper } from "../TestBaseSimpleRewardZapper.sol";

import { RewardManager } from "contracts/architecture/RewardManager.sol";
import { SimpleRewardZapper } from "contracts/architecture/utils/SimpleRewardZapper.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { SimplePToken, IERC20 } from "contracts/market/token/SimplePToken.sol";
import { IMToken } from "contracts/interfaces/market/IMToken.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { RewardsData } from "contracts/interfaces/IRewardManager.sol";
import { IUniswapV2Router } from "contracts/interfaces/external/uniswap/IUniswapV2Router.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract User {}

contract TestSimpleRewardZapper is TestBaseSimpleRewardZapper {
    MockDataFeed public mockUsdcFeed;
    MockDataFeed public mockWethFeed;

    SimplePToken public cWETH;

    function setUp() public override {
        super.setUp();

        centralRegistry.setExternalCalldataChecker(
            _UNISWAP_V2_ROUTER,
            address(new MockCalldataChecker(_UNISWAP_V2_ROUTER))
        );

        deal(_USDC_ADDRESS, address(rewardManager), 1e18);

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

        // start epoch
        vm.warp(gaugeManager.startTime());
        vm.roll(block.number + 1000);

        mockUsdcFeed.setMockUpdatedAt(block.timestamp);
        mockWethFeed.setMockUpdatedAt(block.timestamp);

        address owner = address(this);

        // deploy eUSDC
        {
            _deployEUSDC();
            // support market
            _prepareUSDC(owner, 200000e6);
            usdc.approve(address(eUSDC), 200000e6);
            marketManager.listToken(address(eUSDC));
            // add MToken support on oracle manager
            oracleManager.addMTokenSupport(address(eUSDC));
            address[] memory markets = new address[](1);
            markets[0] = address(eUSDC);
            // vm.prank(user1);
            // marketManager.enterMarkets(markets);
            // vm.prank(user2);
            // marketManager.enterMarkets(markets);
        }

        // deploy cWETH
        {
            // deploy aura position vault
            cWETH = new SimplePToken(
                ICentralRegistry(address(centralRegistry)),
                weth,
                address(marketManager)
            );

            // support market
            deal(_WETH_ADDRESS, owner, 1 ether);
            weth.approve(address(cWETH), 1 ether);
            marketManager.listToken(address(cWETH));
            // add MToken support on oracle manager
            oracleManager.addMTokenSupport(address(cWETH));
            // set position token configuration
            marketManager.updatePositionToken(
                IMToken(address(cWETH)),
                7000,
                4000, // liquidate at 71%
                3000,
                200, // 2% liq incentive
                400,
                0,
                1000
            );

            address[] memory mTokens = new address[](1);
            mTokens[0] = address(cWETH);
            uint256[] memory caps = new uint256[](1);
            caps[0] = 100 ether;
            marketManager.setPTokenCollateralCaps(mTokens, caps);

            // address[] memory markets = new address[](1);
            // markets[0] = address(cWETH);
            // vm.prank(user1);
            // marketManager.enterMarkets(markets);
            // vm.prank(user2);
            // marketManager.enterMarkets(markets);
        }

        provideEnoughLiquidityForLeverage();
    }

    function provideEnoughLiquidityForLeverage() internal {
        address liquidityProvider = address(new User());
        _prepareUSDC(liquidityProvider, 200000e6);
        deal(_WETH_ADDRESS, liquidityProvider, 10 ether);
        // mint eUSDC
        vm.startPrank(liquidityProvider);
        usdc.approve(address(eUSDC), 200000e6);
        eUSDC.mint(200000e6);
        // mint cBALETH
        weth.approve(address(cWETH), 10 ether);
        cWETH.mint(10 ether, liquidityProvider);
        vm.stopPrank();
    }

    function testAuthorizedMarketManager() public {
        assertEq(
            simpleRewardZapper.authorizedMarketManager(address(marketManager)),
            0
        );

        simpleRewardZapper.addAuthorizedMarketManager(address(marketManager));

        assertEq(
            simpleRewardZapper.authorizedMarketManager(address(marketManager)),
            2
        );

        simpleRewardZapper.removeAuthorizedMarketManager(
            address(marketManager)
        );

        assertEq(
            simpleRewardZapper.authorizedMarketManager(address(marketManager)),
            1
        );
    }

    function testAuthorizedRewardToken() public {
        assertEq(simpleRewardZapper.authorizedOutputToken(_WETH_ADDRESS), 0);

        simpleRewardZapper.addAuthorizedOutputToken(_WETH_ADDRESS);

        assertEq(simpleRewardZapper.authorizedOutputToken(_WETH_ADDRESS), 2);

        simpleRewardZapper.removeAuthorizedOutputToken(_WETH_ADDRESS);

        assertEq(simpleRewardZapper.authorizedOutputToken(_WETH_ADDRESS), 1);
    }

    function testClaimAndSwap() public {
        simpleRewardZapper.addAuthorizedOutputToken(_WETH_ADDRESS);

        for (uint256 i = 0; i < 2; i++) {
            vm.prank(centralRegistry.messagingHub());
            rewardManager.recordEpochRewards(1e6 * _ONE);
        }

        skip(veCVE.epochDuration() + veCVE.RESTRICTION_DURATION() + 1);

        uint256 amount = 100e18;
        vm.startPrank(user1);
        deal(address(cve), user1, amount);
        cve.approve(address(veCVE), amount);
        veCVE.createLock(
            amount,
            false,
            RewardsData(false, false, false, false),
            "0x",
            0
        );
        vm.stopPrank();

        vm.prank(address(rewardManager.veCVE()));
        rewardManager.updateUserClaimIndex(user1, 1);

        uint256 rewards = amount /= 1e12;

        deal(_USDC_ADDRESS, address(rewardManager), rewards);

        address[] memory path = new address[](2);
        path[0] = _USDC_ADDRESS;
        path[1] = _WETH_ADDRESS;
        SwapperLib.Swap memory swapData;
        swapData.inputToken = _USDC_ADDRESS;
        swapData.outputToken = _WETH_ADDRESS;
        swapData.target = _UNISWAP_V2_ROUTER;
        swapData.inputAmount = rewards;
        swapData.call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            rewards,
            0,
            path,
            address(simpleRewardZapper),
            block.timestamp
        );

        uint256[] memory amountsOut = IUniswapV2Router(_UNISWAP_V2_ROUTER)
            .getAmountsOut(rewards, path);
        uint256 baseRewardBalance = usdc.balanceOf(address(rewardManager));
        uint256 desiredTokenBalance = weth.balanceOf(user1);

        vm.prank(user1);
        rewardManager.setDelegateApproval(address(simpleRewardZapper), true);

        vm.prank(user1);
        simpleRewardZapper.claimAndSwap(swapData, user1);

        assertEq(
            usdc.balanceOf(address(rewardManager)),
            baseRewardBalance - amountsOut[0]
        );
        assertEq(weth.balanceOf(user1), desiredTokenBalance + amountsOut[1]);
    }

    function testClaimSwapAndDeposit() public {
        simpleRewardZapper.addAuthorizedOutputToken(_WETH_ADDRESS);
        simpleRewardZapper.addAuthorizedMarketManager(address(marketManager));

        for (uint256 i = 0; i < 2; i++) {
            vm.prank(centralRegistry.messagingHub());
            rewardManager.recordEpochRewards(1e6 * _ONE);
        }

        skip(veCVE.epochDuration() + veCVE.RESTRICTION_DURATION() + 1);

        uint256 amount = 100e18;
        vm.startPrank(user1);
        deal(address(cve), user1, amount);
        cve.approve(address(veCVE), amount);
        veCVE.createLock(
            amount,
            false,
            RewardsData(false, false, false, false),
            "0x",
            0
        );
        vm.stopPrank();

        vm.prank(address(rewardManager.veCVE()));
        rewardManager.updateUserClaimIndex(user1, 1);

        uint256 rewards = amount /= 1e12;

        deal(_USDC_ADDRESS, address(rewardManager), rewards);

        address[] memory path = new address[](2);
        path[0] = _USDC_ADDRESS;
        path[1] = _WETH_ADDRESS;
        SwapperLib.Swap memory swapData;
        swapData.inputToken = _USDC_ADDRESS;
        swapData.outputToken = _WETH_ADDRESS;
        swapData.target = _UNISWAP_V2_ROUTER;
        swapData.inputAmount = rewards;
        swapData.call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            rewards,
            0,
            path,
            address(simpleRewardZapper),
            block.timestamp
        );

        uint256[] memory amountsOut = IUniswapV2Router(_UNISWAP_V2_ROUTER)
            .getAmountsOut(rewards, path);
        uint256 baseRewardBalance = usdc.balanceOf(address(rewardManager));
        uint256 desiredTokenBalance = cWETH.balanceOf(user1);

        vm.prank(user1);
        rewardManager.setDelegateApproval(address(simpleRewardZapper), true);

        vm.prank(user1);
        simpleRewardZapper.claimSwapAndDeposit(
            swapData,
            address(marketManager),
            address(cWETH),
            false,
            user1
        );

        assertEq(
            usdc.balanceOf(address(rewardManager)),
            baseRewardBalance - amountsOut[0]
        );
        assertEq(cWETH.balanceOf(user1), desiredTokenBalance + amountsOut[1]);
    }

    function testClaimSwapAndRepay() public {
        // mint
        vm.startPrank(user1);
        deal(_WETH_ADDRESS, user1, 1 ether);
        weth.approve(address(cWETH), 1 ether);
        cWETH.mint(1 ether, user1);
        marketManager.postCollateral(user1, address(cWETH), 1 ether);
        // borrow
        eUSDC.borrow(500e6);
        vm.stopPrank();

        simpleRewardZapper.addAuthorizedOutputToken(_WETH_ADDRESS);
        simpleRewardZapper.addAuthorizedMarketManager(address(marketManager));

        for (uint256 i = 0; i < 2; i++) {
            vm.prank(centralRegistry.messagingHub());
            rewardManager.recordEpochRewards(1e6 * _ONE);
        }

        skip(veCVE.epochDuration() + veCVE.RESTRICTION_DURATION() + 1);

        uint256 amount = 100e18;
        vm.startPrank(user1);
        deal(address(cve), user1, amount);
        cve.approve(address(veCVE), amount);
        veCVE.createLock(
            amount,
            false,
            RewardsData(false, false, false, false),
            "0x",
            0
        );
        vm.stopPrank();

        vm.prank(address(rewardManager.veCVE()));
        rewardManager.updateUserClaimIndex(user1, 1);

        uint256 rewards = amount /= 1e12;

        deal(_USDC_ADDRESS, address(rewardManager), rewards);

        address[] memory path = new address[](2);
        path[0] = _USDC_ADDRESS;
        path[1] = _WETH_ADDRESS;
        SwapperLib.Swap memory swapData;
        swapData.inputToken = _USDC_ADDRESS;
        swapData.outputToken = _WETH_ADDRESS;
        swapData.target = _UNISWAP_V2_ROUTER;
        swapData.inputAmount = rewards;
        swapData.call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            rewards,
            0,
            path,
            address(simpleRewardZapper),
            block.timestamp
        );

        uint256 baseRewardBalance = usdc.balanceOf(address(rewardManager));
        uint256 desiredTokenBalance = eUSDC.debtBalanceCached(user1);

        vm.prank(user1);
        rewardManager.setDelegateApproval(address(simpleRewardZapper), true);

        vm.prank(user1);
        simpleRewardZapper.claimSwapAndRepay(
            swapData,
            address(marketManager),
            address(eUSDC),
            100e6,
            user1
        );

        assertEq(
            usdc.balanceOf(address(rewardManager)),
            baseRewardBalance - 100e6
        );
        assertApproxEqAbs(
            eUSDC.debtBalanceCached(user1),
            desiredTokenBalance - 100e6,
            10000
        );
    }
}
