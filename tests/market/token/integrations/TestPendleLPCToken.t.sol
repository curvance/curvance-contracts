// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IUniswapV3Router } from "contracts/interfaces/external/uniswap/IUniswapV3Router.sol";
import { IPendleRouter, ApproxParams, LimitOrderData } from "contracts/interfaces/external/pendle/IPendleRouter.sol";
import { PendleLPCToken, IERC20 } from "contracts/market/token/PendleLPCToken.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";

contract TestPendleLPCToken is TestBaseMarketIsolated {
    address internal _UNISWAP_V3_SWAP_ROUTER =
        0xE592427A0AEce92De3Edee1F18E0157C05861564;
    IPendleRouter internal _ROUTER =
        IPendleRouter(0x888888888889758F76e7103c6CbF23ABbF58F946);

    address internal _PT_STETH = 0x7758896b6AC966BbABcf143eFA963030f17D3EdF; // PT-stETH-26DEC24
    address internal _PENDLE = 0x808507121B80c02388fAd14726482e061B8da827;
    address internal _LP_STETH = 0xD0354D4e7bCf345fB117cabe41aCaDb724eccCa2; // PT-stETH-26DEC24/SY-stETH Market

    PendleLPCToken public pendleCTokenSTETH;
    MockV3Aggregator public chainlinkPendleUsd;

    receive() external payable {}

    fallback() external payable {}

    function setUp() public override {
        _fork(20287400);

        
        _deployCentralRegistry();
        _deployCVE();
        _deployRewardManager();
        _deployVeCVE();
        _deployGaugeManager();
        _deployOracleManager();
        _deployChainlinkAdaptors();
        _deployMarketManager();
        _deployBorrowableCDAI();

        chainlinkPendleUsd = new MockV3Aggregator(18, 3.6e18);
        chainlinkAdaptor.addAsset(
            _PENDLE,
            true,
            address(chainlinkPendleUsd),
            0
        );
        oracleManager.addAssetPriceFeed(_PENDLE, address(chainlinkAdaptor));

        centralRegistry.addHarvestPermissions(address(this));
        centralRegistry.setFeeManager(address(this));

        pendleCTokenSTETH = new PendleLPCToken(
            ICentralRegistry(address(centralRegistry)),
            IERC20(_LP_STETH),
            address(marketManagerIsolated),
            _ROUTER,
            1 days
        );

        centralRegistry.setExternalCalldataChecker(
            _UNISWAP_V3_SWAP_ROUTER,
            address(new MockCalldataChecker(_UNISWAP_V3_SWAP_ROUTER))
        );

        vm.warp(veCVE.nextEpochStartTime());
    }

    function testPendleStethLP() public {
        uint256 assets = 100e18;
        deal(_LP_STETH, user1, assets);
        deal(_LP_STETH, address(this), 77777);

        _prepareDAI(address(this), 77777);
        dai.approve(address(borrowableCDAI), 77777);

        IERC20(_LP_STETH).approve(address(pendleCTokenSTETH), 77777);
        marketManagerIsolated.listTokens(address(pendleCTokenSTETH), address(borrowableCDAI));

        vm.prank(user1);
        IERC20(_LP_STETH).approve(address(pendleCTokenSTETH), assets);

        vm.prank(user1);
        pendleCTokenSTETH.deposit(assets, user1);

        assertEq(
            pendleCTokenSTETH.totalAssets(),
            assets + 77777,
            "Total Assets should equal user deposit plus initial mint."
        );

        // Advance time to earn CRV and CVX rewards
        vm.warp(block.timestamp + 3 days);

        chainlinkPendleUsd.updateAnswer(3.6e18);
        chainlinkEthUsd.updateAnswer(3000e8);

        // Mint some extra rewards for Vault.
        deal(_PENDLE, address(pendleCTokenSTETH), 100e18);
        deal(address(pendleCTokenSTETH), 1e18);

        uint256 rewardAmount = (100e18 * 84) / 100; // 16% for protocol harvest fee;
        SwapperLib.Swap[] memory swaps = new SwapperLib.Swap[](1);
        swaps[0].inputToken = _PENDLE;
        swaps[0].inputAmount = rewardAmount;
        swaps[0].outputToken = _WETH_ADDRESS;
        swaps[0].target = _UNISWAP_V3_SWAP_ROUTER;
        swaps[0].slippage = 0.3e18;
        IUniswapV3Router.ExactInputSingleParams memory params;
        params.tokenIn = _PENDLE;
        params.tokenOut = _WETH_ADDRESS;
        params.fee = 3000;
        params.recipient = address(pendleCTokenSTETH);
        params.deadline = block.timestamp;
        params.amountIn = rewardAmount;
        params.amountOutMinimum = 0;
        params.sqrtPriceLimitX96 = 0;
        swaps[0].call = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector,
            params
        );

        ApproxParams memory approx;
        approx.guessMin = 1e10;
        approx.guessMax = 1e18;
        approx.guessOffchain = 0;
        approx.maxIteration = 200;
        approx.eps = 1e18;

        LimitOrderData memory limit;

        pendleCTokenSTETH.harvest(abi.encode(swaps, 1e8, approx, limit));

        vm.warp(block.timestamp + 8 days);

        chainlinkPendleUsd.updateAnswer(3.6e18);
        chainlinkEthUsd.updateAnswer(3000e8);

        uint256 totalAssets = pendleCTokenSTETH.totalAssets();
        assertGt(
            totalAssets,
            assets + 77777,
            "Total Assets should equal user deposit plus initial mint."
        );

        vm.prank(user1);
        pendleCTokenSTETH.withdraw(assets, user1, user1);
    }

    function testRevertWithInvalidSwapper() external {
        uint256 assets = 100e18;
        deal(_LP_STETH, user1, assets);
        deal(_LP_STETH, address(this), 77777);

        _prepareDAI(address(this), 77777);
        dai.approve(address(borrowableCDAI), 77777);

        IERC20(_LP_STETH).approve(address(pendleCTokenSTETH), 77777);
        marketManagerIsolated.listTokens(address(pendleCTokenSTETH), address(borrowableCDAI));

        vm.prank(user1);
        IERC20(_LP_STETH).approve(address(pendleCTokenSTETH), assets);

        vm.prank(user1);
        pendleCTokenSTETH.deposit(assets, user1);

        // Advance time to earn CRV and CVX rewards
        vm.warp(block.timestamp + 3 days);

        chainlinkPendleUsd.updateAnswer(3.6e18);
        chainlinkEthUsd.updateAnswer(3000e8);

        // Mint some extra rewards for Vault.
        deal(_PENDLE, address(pendleCTokenSTETH), 100e18);

        uint256 rewardAmount = (100e18 * 84) / 100; // 16% for protocol harvest fee;
        SwapperLib.Swap[] memory swaps = new SwapperLib.Swap[](1);
        swaps[0].inputToken = _PENDLE;
        swaps[0].inputAmount = rewardAmount;
        swaps[0].outputToken = _WETH_ADDRESS;
        swaps[0].target = address(0);

        ApproxParams memory approx;
        approx.guessMin = 1e10;
        approx.guessMax = 1e18;
        approx.guessOffchain = 0;
        approx.maxIteration = 200;
        approx.eps = 1e18;

        LimitOrderData memory limit;

        vm.expectRevert(SwapperLib.SwapperLib__UnknownCalldata.selector);
        pendleCTokenSTETH.harvest(abi.encode(swaps, 1e8, approx, limit));
    }

    function testReQueryTokens() external {
        pendleCTokenSTETH.reQueryTokens();

        assertEq(pendleCTokenSTETH.rewardTokens().length, 1);
        assertEq(pendleCTokenSTETH.underlyingTokens().length, 4);
    }
}
