// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { RewardManager } from "contracts/architecture/RewardManager.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { SimpleCToken, IERC20 } from "contracts/market/token/SimpleCToken.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ClaimAction } from "contracts/interfaces/IRewardManager.sol";
import { IUniswapV2Router } from "contracts/interfaces/external/uniswap/IUniswapV2Router.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

import { TestBaseSimpleRewardZapper } from "../TestBaseSimpleRewardZapper.sol";
import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";

contract TestSimpleRewardZapper is TestBaseSimpleRewardZapper {

    SimpleCToken public simpleCWETH;

    function setUp() public override {
        super.setUp();

        centralRegistry.setExternalCalldataChecker(
            _UNISWAP_V2_ROUTER,
            address(new MockCalldataChecker(_UNISWAP_V2_ROUTER))
        );

        _prepareUSDC(address(rewardManager), 1e18);

        mockUsdcFeed = new MockDataFeed(_CHAINLINK_USDC_USD);
        chainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            true,
            address(mockUsdcFeed),
            0
        );
        dualChainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            true,
            address(mockUsdcFeed),
            0
        );
        mockWethFeed = new MockDataFeed(_CHAINLINK_ETH_USD);
        chainlinkAdaptor.addAsset(
            _WETH_ADDRESS,
            true,
            address(mockWethFeed),
            0
        );
        dualChainlinkAdaptor.addAsset(
            _WETH_ADDRESS,
            true,
            address(mockWethFeed),
            0
        );

        // start epoch
        vm.warp(gaugeManager.gaugeStartTime());
        _skipEpochDuration(1);
        vm.roll(block.number + 1000);

        mockUsdcFeed.setMockUpdatedAt(block.timestamp);
        mockWethFeed.setMockUpdatedAt(block.timestamp);

        address owner = address(this);

        // Setup borrowableCUSDC.
        {
            _deployBorrowableCUSDC();
            _prepareUSDC(owner, 200000e6);
            usdc.approve(address(borrowableCUSDC), 200000e6);
            // Add CToken support on Oracle Manager.
            oracleManager.addCTokenSupport(address(borrowableCUSDC));
        }

        // Setup simpleCWETH.
        {
            simpleCWETH = new SimpleCToken(
                ICentralRegistry(address(centralRegistry)),
                weth,
                address(marketManagerIsolated)
            );

            _prepareWETH(owner, 1 ether);
            weth.approve(address(simpleCWETH), 1 ether);
            // Add CToken support on Oracle Manager.
            oracleManager.addCTokenSupport(address(simpleCWETH));
        }

        // List tokens.
        marketManagerIsolated.listTokens(
            address(simpleCWETH),
            address(borrowableCUSDC)
        );

        _setCTokenConfigBasic(address(simpleCWETH), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 100_000e18, 100_000e6);

        provideEnoughLiquidityForLeverage();
    }

    function provideEnoughLiquidityForLeverage() internal {
        address liquidityProvider = makeAddr("Liquidity_provider");
        _prepareUSDC(liquidityProvider, 200000e6);
        _prepareWETH(liquidityProvider, 10 ether);
        // Mint borrowable cUSDC.
        vm.startPrank(liquidityProvider);
        usdc.approve(address(borrowableCUSDC), 200000e6);
        borrowableCUSDC.deposit(200000e6, liquidityProvider);
        // Mint cBALETH.
        weth.approve(address(simpleCWETH), 10 ether);
        simpleCWETH.mint(10 ether, liquidityProvider);
        vm.stopPrank();
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
            vm.prank(address(messagingHub));
            rewardManager.recordEpochRewards(1e6 * _ONE);
        }

        skip(veCVE.EPOCH_DURATION() + veCVE.RESTRICTION_DURATION() + 1);

        uint256 amount = 100e18;
        vm.startPrank(user1);
        _prepareCVE(user1, amount);
        cve.approve(address(veCVE), amount);
        veCVE.createLock(
            amount,
            false,
            ClaimAction(false, false, false, false),
            "",
            0
        );
        vm.stopPrank();

        vm.prank(address(centralRegistry.veCVE()));
        rewardManager.updateUserClaimIndex(user1, 1);

        uint256 rewards = amount /= 1e12;

        _prepareUSDC(address(rewardManager), rewards);

        address[] memory path = new address[](2);
        path[0] = _USDC_ADDRESS;
        path[1] = _WETH_ADDRESS;
        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.outputToken = _WETH_ADDRESS;
        swapAction.target = _UNISWAP_V2_ROUTER;
        swapAction.inputAmount = rewards;
        swapAction.call = abi.encodeWithSignature(
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
        simpleRewardZapper.claimAndSwap(swapAction, user1);

        assertEq(
            usdc.balanceOf(address(rewardManager)),
            baseRewardBalance - amountsOut[0]
        );
        assertEq(weth.balanceOf(user1), desiredTokenBalance + amountsOut[1]);
    }

    function testClaimSwapAndDeposit() public {
        simpleRewardZapper.addAuthorizedOutputToken(_WETH_ADDRESS);

        for (uint256 i = 0; i < 2; i++) {
            vm.prank(address(messagingHub));
            rewardManager.recordEpochRewards(1e6 * _ONE);
        }

        _skipEpochDuration(1);
        _skipRestrictionDuration();

        uint256 amount = 100e18;
        vm.startPrank(user1);
        _prepareCVE(user1, amount);
        cve.approve(address(veCVE), amount);
        veCVE.createLock(
            amount,
            false,
            ClaimAction(false, false, false, false),
            "",
            0
        );
        vm.stopPrank();

        vm.prank(address(centralRegistry.veCVE()));
        rewardManager.updateUserClaimIndex(user1, 1);

        uint256 rewards = amount /= 1e12;

        _prepareUSDC(address(rewardManager), rewards);

        address[] memory path = new address[](2);
        path[0] = _USDC_ADDRESS;
        path[1] = _WETH_ADDRESS;
        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.outputToken = _WETH_ADDRESS;
        swapAction.target = _UNISWAP_V2_ROUTER;
        swapAction.inputAmount = rewards;
        swapAction.call = abi.encodeWithSignature(
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
        uint256 desiredTokenBalance = simpleCWETH.balanceOf(user1);

        vm.prank(user1);
        rewardManager.setDelegateApproval(address(simpleRewardZapper), true);

        vm.prank(user1);
        simpleRewardZapper.claimSwapAndDeposit(
            address(simpleCWETH),
            swapAction,
            0,
            false,
            user1
        );

        assertEq(
            usdc.balanceOf(address(rewardManager)),
            baseRewardBalance - amountsOut[0]
        );
        assertEq(simpleCWETH.balanceOf(user1), desiredTokenBalance + amountsOut[1]);
    }

    function testClaimSwapAndRepay() public {
        // mint
        vm.startPrank(user1);
        _prepareWETH(user1, 1 ether);
        weth.approve(address(simpleCWETH), 1 ether);
        simpleCWETH.mint(1 ether, user1);
        simpleCWETH.postCollateral(1 ether);
        // borrow
        borrowableCUSDC.borrow(500e6, user1);
        vm.stopPrank();

        simpleRewardZapper.addAuthorizedOutputToken(_WETH_ADDRESS);

        for (uint256 i = 0; i < 2; i++) {
            vm.prank(address(messagingHub));
            rewardManager.recordEpochRewards(1e6 * _ONE);
        }

        _skipEpochDuration(1);
        _skipRestrictionDuration();

        uint256 amount = 100e18;
        vm.startPrank(user1);
        _prepareCVE(user1, amount);
        cve.approve(address(veCVE), amount);
        veCVE.createLock(
            amount,
            false,
            ClaimAction(false, false, false, false),
            "",
            0
        );
        vm.stopPrank();

        vm.prank(address(centralRegistry.veCVE()));
        rewardManager.updateUserClaimIndex(user1, 1);

        uint256 rewards = amount /= 1e12;

        _prepareUSDC(address(rewardManager), rewards);

        address[] memory path = new address[](2);
        path[0] = _USDC_ADDRESS;
        path[1] = _WETH_ADDRESS;
        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.outputToken = _WETH_ADDRESS;
        swapAction.target = _UNISWAP_V2_ROUTER;
        swapAction.inputAmount = rewards;
        swapAction.call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            rewards,
            0,
            path,
            address(simpleRewardZapper),
            block.timestamp
        );

        uint256 baseRewardBalance = usdc.balanceOf(address(rewardManager));
        uint256 desiredTokenBalance = borrowableCUSDC.debtBalance(user1);

        vm.prank(user1);
        rewardManager.setDelegateApproval(address(simpleRewardZapper), true);

        vm.prank(user1);
        simpleRewardZapper.claimSwapAndRepay(
            swapAction,
            address(borrowableCUSDC),
            100e6,
            user1
        );

        assertEq(
            usdc.balanceOf(address(rewardManager)),
            baseRewardBalance - 100e6
        );
        assertApproxEqAbs(
            borrowableCUSDC.debtBalance(user1),
            desiredTokenBalance - 100e6,
            10000
        );
    }
}
