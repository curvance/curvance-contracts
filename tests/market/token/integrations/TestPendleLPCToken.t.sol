// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {SwapperLib} from "contracts/libraries/SwapperLib.sol";
import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";
import {
    IUniswapV3Router
} from "contracts/interfaces/external/uniswap/IUniswapV3Router.sol";
import {
    IPendleRouter,
    ApproxParams,
    LimitOrderData
} from "contracts/interfaces/external/pendle/IPendleRouter.sol";
import {IPMarket} from "contracts/interfaces/external/pendle/IPMarket.sol";
import {
    PendleLPCToken,
    IERC20
} from "contracts/market/token/PendleLPCToken.sol";
import {StrategyCToken} from "contracts/market/token/StrategyCToken.sol";

import {TestBaseMarketIsolated} from "tests/market/TestBaseMarketIsolated.sol";
import {MockCalldataChecker} from "contracts/mocks/MockCalldataChecker.sol";
import {MockV3Aggregator} from "contracts/mocks/MockV3Aggregator.sol";

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
            _PENDLE, true, address(chainlinkPendleUsd), 0
        );
        oracleManager.addAssetPricingAdaptor(
            _PENDLE, address(chainlinkAdaptor), 100, 50, 100, 50
        );

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
        marketManagerIsolated.listTokens(
            address(pendleCTokenSTETH), address(borrowableCDAI)
        );

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
        swaps[0].slippage = 0.2e18;
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
            IUniswapV3Router.exactInputSingle.selector, params
        );

        ApproxParams memory approx;
        approx.guessMin = 1e10;
        approx.guessMax = 1e18;
        approx.guessOffchain = 0;
        approx.maxIteration = 200;
        approx.eps = 1e18;

        LimitOrderData memory limit;

        uint256 lpBalanceBeforeHarvest =
            IERC20(_LP_STETH).balanceOf(address(pendleCTokenSTETH));
        uint256 totalAssetsBeforeHarvest = pendleCTokenSTETH.totalAssets();

        uint256 yield =
            pendleCTokenSTETH.harvest(abi.encode(swaps, 1e8, approx, limit));
        uint256 lpBalanceAfterHarvest =
            IERC20(_LP_STETH).balanceOf(address(pendleCTokenSTETH));

        assertEq(
            yield,
            lpBalanceAfterHarvest - lpBalanceBeforeHarvest,
            "Harvest yield should be backed by new LP received."
        );
        assertEq(
            pendleCTokenSTETH.totalAssets(),
            totalAssetsBeforeHarvest,
            "Harvest yield should vest before increasing total assets."
        );

        vm.warp(block.timestamp + 8 days);

        chainlinkPendleUsd.updateAnswer(3.6e18);
        chainlinkEthUsd.updateAnswer(3000e8);

        uint256 totalAssets = pendleCTokenSTETH.totalAssets();
        assertApproxEqAbs(
            totalAssets,
            totalAssetsBeforeHarvest + yield,
            1,
            "Vested total assets should match credited harvest yield."
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
        marketManagerIsolated.listTokens(
            address(pendleCTokenSTETH), address(borrowableCDAI)
        );

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

    /// @notice Post-expiry harvest must NOT revert. It should claim accrued
    ///         rewards and route them to `daoAddress`. Without this branch,
    ///         `addLiquiditySingleSy` reverts post-expiry and rewards
    ///         become unrecoverable from the cToken. Path stays UNPAUSED:
    ///         Pendle SY-side rewards can keep accruing post-expiry, so
    ///         repeated harvests must remain callable to sweep them.
    function testHarvestPostExpiry_routesRewardsToDao() public {
        uint256 assets = 100e18;
        deal(_LP_STETH, user1, assets);
        deal(_LP_STETH, address(this), 77777);

        _prepareDAI(address(this), 77777);
        dai.approve(address(borrowableCDAI), 77777);

        IERC20(_LP_STETH).approve(address(pendleCTokenSTETH), 77777);
        marketManagerIsolated.listTokens(
            address(pendleCTokenSTETH), address(borrowableCDAI)
        );

        vm.prank(user1);
        IERC20(_LP_STETH).approve(address(pendleCTokenSTETH), assets);

        vm.prank(user1);
        pendleCTokenSTETH.deposit(assets, user1);

        // Warp to after the Pendle market expiry timestamp.
        uint256 marketExpiry = IPMarket(_LP_STETH).expiry();
        vm.warp(marketExpiry + 1);
        assertTrue(
            IPMarket(_LP_STETH).isExpired(),
            "expected market to report expired"
        );

        // Pre-stage reward token balance on the cToken (simulating rewards
        // already claimed via prior pre-expiry redeemRewards).
        uint256 rewardBalance = 100e18;
        deal(_PENDLE, address(pendleCTokenSTETH), rewardBalance);

        // Capture DAO balance before harvest. `daoAddress` is the test
        // contract per `_deployCentralRegistry()`.
        address daoAddr = centralRegistry.daoAddress();
        uint256 daoBalanceBefore = IERC20(_PENDLE).balanceOf(daoAddr);
        uint256 totalAssetsBefore = pendleCTokenSTETH.totalAssets();
        uint256 lpBalanceBefore =
            IERC20(_LP_STETH).balanceOf(address(pendleCTokenSTETH));

        // Harvest data is unused on the post-expiry path; pass dummy values.
        SwapperLib.Swap[] memory emptySwaps;
        ApproxParams memory approx;
        LimitOrderData memory limit;

        // Pre-fix this would revert at `addLiquiditySingleSy`. Post-fix it
        // returns 0 and transfers `rewardBalance` to dao.
        uint256 yield = pendleCTokenSTETH.harvest(
            abi.encode(emptySwaps, uint256(0), approx, limit)
        );

        assertEq(yield, 0, "expected zero yield on post-expiry harvest");

        // Reward token swept to DAO.
        uint256 daoBalanceAfter = IERC20(_PENDLE).balanceOf(daoAddr);
        assertEq(
            daoBalanceAfter - daoBalanceBefore,
            rewardBalance,
            "expected reward balance routed to daoAddress"
        );
        assertEq(
            IERC20(_PENDLE).balanceOf(address(pendleCTokenSTETH)),
            0,
            "expected zero reward residue on cToken"
        );
        assertEq(
            pendleCTokenSTETH.totalAssets(),
            totalAssetsBefore,
            "post-expiry reward sweep MUST NOT increase share assets"
        );
        assertEq(
            IERC20(_LP_STETH).balanceOf(address(pendleCTokenSTETH)),
            lpBalanceBefore,
            "post-expiry reward sweep MUST NOT consume principal LP"
        );

        // Harvest must remain callable so newly-accrued post-expiry SY-side
        // rewards can be swept. Pre-stage a second reward batch to simulate
        // continued accrual; second harvest call should sweep it cleanly.
        uint256 secondBatch = 25e18;
        deal(_PENDLE, address(pendleCTokenSTETH), secondBatch);

        uint256 yield2 = pendleCTokenSTETH.harvest(
            abi.encode(emptySwaps, uint256(0), approx, limit)
        );

        assertEq(
            yield2, 0, "expected zero yield on subsequent post-expiry harvest"
        );
        assertEq(
            IERC20(_PENDLE).balanceOf(daoAddr) - daoBalanceBefore,
            rewardBalance + secondBatch,
            "expected second batch swept to dao on subsequent harvest"
        );
    }

    /// @notice Post-expiry sweep with zero claimable rewards — the shared
    ///         `_processRewardBalances` loop iterates `sd.rewardTokens` but
    ///         skips every entry via `if (amount == 0) continue`. Verifies
    ///         no spurious transfers, no revert, return-zero still applies.
    function testHarvestPostExpiry_zeroRewardsIsHarmlessNoOp() public {
        uint256 assets = 100e18;
        deal(_LP_STETH, user1, assets);
        deal(_LP_STETH, address(this), 77777);

        _prepareDAI(address(this), 77777);
        dai.approve(address(borrowableCDAI), 77777);

        IERC20(_LP_STETH).approve(address(pendleCTokenSTETH), 77777);
        marketManagerIsolated.listTokens(
            address(pendleCTokenSTETH), address(borrowableCDAI)
        );

        vm.prank(user1);
        IERC20(_LP_STETH).approve(address(pendleCTokenSTETH), assets);

        vm.prank(user1);
        pendleCTokenSTETH.deposit(assets, user1);

        // Warp past expiry; do NOT pre-stage any reward balance.
        vm.warp(IPMarket(_LP_STETH).expiry() + 1);

        address daoAddr = centralRegistry.daoAddress();
        uint256 daoBefore = IERC20(_PENDLE).balanceOf(daoAddr);

        SwapperLib.Swap[] memory emptySwaps;
        ApproxParams memory approx;
        LimitOrderData memory limit;

        uint256 yield = pendleCTokenSTETH.harvest(
            abi.encode(emptySwaps, uint256(0), approx, limit)
        );

        assertEq(yield, 0, "expected zero yield with no rewards");
        assertEq(
            IERC20(_PENDLE).balanceOf(daoAddr) - daoBefore,
            0,
            "expected zero transfers when no balances"
        );
        // Path remains harvestable for future emissions.
        assertEq(
            pendleCTokenSTETH.harvestingPaused(),
            1,
            "expected harvest to remain unpaused for future post-expiry sweeps"
        );
    }
}
