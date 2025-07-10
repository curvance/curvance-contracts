// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { VelodromeVolatileCToken, IVeloGauge, IVeloRouter, IVeloPairFactory, IERC20 } from "contracts/market/token/VelodromeVolatileCToken.sol";
import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";

import "tests/market/TestBaseMarketIsolated.sol";

contract TestVelodromeVolatileCToken is TestBaseMarketIsolated {
    address internal _VELO_ADDRESS =
        0x9560e827aF36c94D2Ac33a39bCE1Fe78631088Db;
    address internal _WETH_USDC = 0x0493Bf8b6DBB159Ce2Db2E0E8403E753Abd1235b;

    IVeloPairFactory public veloPairFactory =
        IVeloPairFactory(0xF1046053aa5682b4F9a81b5481394DA16BE5FF5a);
    IVeloRouter public veloRouter =
        IVeloRouter(0xa062aE8A9c5e11aaA026fc2670B0D65cCc8B2858);
    address public optiSwap = 0x6108FeAA628155b073150F408D0b390eC3121834;
    IVeloGauge public gauge =
        IVeloGauge(0xE7630c9560C59CCBf5EEd8f33dd0ccA2E67a3981);

    VelodromeVolatileCToken public pWETHUSDC;
    MockV3Aggregator public chainlinkVELO;
    MockV3Aggregator public chainlinkWETH;

    receive() external payable {}

    fallback() external payable {}

    function setUp() public override {
        _fork("ETH_NODE_URI_OPTIMISM", 109095500);

        
        _deployCentralRegistry();
        _deployCVE();
        _deployRewardManager();
        _deployVeCVE();
        _deployGaugeManager();
        _deployMarketManager();
        _deployBorrowableCDAI();

        centralRegistry.addHarvestPermissions(address(this));
        centralRegistry.setFeeManager(address(this));
        centralRegistry.setExternalCalldataChecker(
            address(veloRouter),
            address(new MockCalldataChecker(address(veloRouter)))
        );

        pWETHUSDC = new VelodromeVolatileCToken(
            ICentralRegistry(address(centralRegistry)),
            IERC20(_WETH_USDC),
            address(marketManagerIsolated),
            gauge,
            veloPairFactory,
            veloRouter,
            1 days
        );

        vm.warp(veCVE.nextEpochStartTime());

        _deployOracleManager();

        chainlinkAdaptor = new ChainlinkAdaptor(
            ICentralRegistry(address(centralRegistry))
        );
        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));

        chainlinkVELO = new MockV3Aggregator(8, 0.08e8, 1e50, 1e6);
        chainlinkAdaptor.addAsset(
            _VELO_ADDRESS,
            address(chainlinkVELO),
            0,
            true
        );
        oracleManager.addAssetPriceFeed(
            _VELO_ADDRESS,
            address(chainlinkAdaptor)
        );

        chainlinkWETH = new MockV3Aggregator(8, 3000e8, 1e50, 1e6);
        chainlinkAdaptor.addAsset(
            _WETH_ADDRESS,
            address(chainlinkWETH),
            0,
            true
        );
        oracleManager.addAssetPriceFeed(
            _WETH_ADDRESS,
            address(chainlinkAdaptor)
        );

        centralRegistry.setSlippageLimit(6000);
    }

    function testWethUsdcVolatilePool() public {
        uint256 assets = 0.0001e18;
        deal(_WETH_USDC, user1, assets);
        deal(_WETH_USDC, address(this), 77777);

        _prepareDAI(address(this), 77777);
        dai.approve(address(borrowableCDAI), 77777);

        IERC20(_WETH_USDC).approve(address(pWETHUSDC), 77777);
        marketManagerIsolated.listTokens(address(pWETHUSDC), address(borrowableCDAI));

        vm.prank(user1);
        IERC20(_WETH_USDC).approve(address(pWETHUSDC), assets);

        vm.prank(user1);
        pWETHUSDC.deposit(assets, user1);

        assertEq(
            pWETHUSDC.totalAssets(),
            assets + 77777,
            "Total Assets should equal user deposit plus initial mint."
        );

        vm.startPrank(gauge.voter());
        IERC20(_VELO_ADDRESS).approve(address(gauge), 10e18);
        gauge.notifyRewardAmount(10e18);
        vm.stopPrank();

        // Advance time to earn CRV and CVX rewards
        vm.warp(block.timestamp + 1 days);
        chainlinkVELO.updateAnswer(chainlinkVELO.latestAnswer());
        chainlinkWETH.updateAnswer(chainlinkWETH.latestAnswer());

        // Mint some extra rewards for Vault.
        uint256 earned = gauge.earned(address(pWETHUSDC));
        uint256 amount = (earned * 84) / 100;
        SwapperLib.Swap memory swapData;
        swapData.inputToken = _VELO_ADDRESS;
        swapData.inputAmount = amount;
        swapData.outputToken = _WETH_ADDRESS;
        swapData.target = address(veloRouter);
        IVeloRouter.Route[] memory routes = new IVeloRouter.Route[](1);
        routes[0].from = _VELO_ADDRESS;
        routes[0].to = _WETH_ADDRESS;
        routes[0].stable = false;
        routes[0].factory = address(veloPairFactory);
        swapData.call = abi.encodeWithSelector(
            IVeloRouter.swapExactTokensForTokens.selector,
            amount,
            0,
            routes,
            address(pWETHUSDC),
            type(uint256).max
        );
        swapData.slippage = 50e16;

        pWETHUSDC.harvest(abi.encode(swapData, 1.407e10));

        assertEq(
            pWETHUSDC.totalAssets(),
            assets + 77777,
            "Total Assets should equal user deposit plus initial mint."
        );

        vm.warp(block.timestamp + 8 days);
        chainlinkVELO.updateAnswer(chainlinkVELO.latestAnswer());
        chainlinkWETH.updateAnswer(chainlinkWETH.latestAnswer());

        // Mint some extra rewards for Vault.
        earned = gauge.earned(address(pWETHUSDC));
        amount = (earned * 84) / 100;
        swapData.inputAmount = amount;
        swapData.call = abi.encodeWithSelector(
            IVeloRouter.swapExactTokensForTokens.selector,
            amount,
            0,
            routes,
            address(pWETHUSDC),
            type(uint256).max
        );
        pWETHUSDC.harvest(abi.encode(swapData, 1.407e10));

        vm.warp(block.timestamp + 7 days);
        chainlinkVELO.updateAnswer(chainlinkVELO.latestAnswer());
        chainlinkWETH.updateAnswer(chainlinkWETH.latestAnswer());

        assertGt(
            pWETHUSDC.totalAssets(),
            assets + 77777,
            "Total Assets should greater than original deposit plus initial mint."
        );

        vm.prank(user1);
        pWETHUSDC.withdraw(assets, user1, user1);
    }
}
