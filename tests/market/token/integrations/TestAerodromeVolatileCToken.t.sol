// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { AerodromeVolatileCToken, IVeloGauge, IVeloRouter, IVeloPairFactory, IERC20 } from "contracts/market/token/AerodromeVolatileCToken.sol";
import { VelodromeVolatileLPAdaptor } from "contracts/oracles/adaptors/velodrome/VelodromeVolatileLPAdaptor.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";

contract TestAerodromeVolatileCToken is TestBaseMarketIsolated {
    address internal _AERO_ADDRESS =
        0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    address internal _AERODROME_WETH_USDC =
        0xcDAC0d6c6C59727a65F871236188350531885C43;
    IVeloGauge public gauge =
        IVeloGauge(0x519BBD1Dd8C6A94C46080E24f316c14Ee758C025);
    IVeloPairFactory public aeroPairFactory =
        IVeloPairFactory(0x420DD381b31aEf6683db6B902084cB0FFECe40Da);
    IVeloRouter public aeroRouter =
        IVeloRouter(0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43);

    AerodromeVolatileCToken public aeroCTokenWETHUSDC;
    VelodromeVolatileLPAdaptor public adaptor;
    MockV3Aggregator public chainlinkAERO;
    MockV3Aggregator public chainlinkWETH;
    MockV3Aggregator public chainlinkUSDC;

    receive() external payable {}

    fallback() external payable {}

    function setUp() public override {
        _fork("ETH_NODE_URI_BASE", 19000000);

        
        _deployCentralRegistry();
        _deployCVE();
        _deployRewardManager();
        _deployVeCVE();
        _deployGaugeManager();
        _deployMarketManager();

        centralRegistry.addHarvestPermissions(address(this));
        centralRegistry.setFeeManager(address(this));
        centralRegistry.setExternalCalldataChecker(
            address(aeroRouter),
            address(new MockCalldataChecker(address(aeroRouter)))
        );

        _deployBorrowableCUSDC();

        aeroCTokenWETHUSDC = new AerodromeVolatileCToken(
            ICentralRegistry(address(centralRegistry)),
            IERC20(_AERODROME_WETH_USDC),
            address(marketManagerIsolated),
            gauge,
            aeroPairFactory,
            aeroRouter,
            1 days
        );

        vm.warp(veCVE.nextEpochStartTime());

        _deployOracleManager();

        chainlinkAdaptor = new ChainlinkAdaptor(
            ICentralRegistry(address(centralRegistry))
        );
        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));

        chainlinkAERO = new MockV3Aggregator(8, 0.67e8);
        chainlinkAdaptor.addAsset(
            _AERO_ADDRESS,
            true,
            address(chainlinkAERO),
            0
        );
        oracleManager.addAssetPriceFeed(
            _AERO_ADDRESS,
            address(chainlinkAdaptor)
        );

        chainlinkWETH = new MockV3Aggregator(8, 2700e8);
        chainlinkAdaptor.addAsset(
            _WETH_ADDRESS,
            true,
            address(chainlinkWETH),
            0
        );
        oracleManager.addAssetPriceFeed(
            _WETH_ADDRESS,
            address(chainlinkAdaptor)
        );

        chainlinkUSDC = new MockV3Aggregator(8, 1e8);
        chainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            true,
            address(chainlinkUSDC),
            0
        );
        oracleManager.addAssetPriceFeed(
            _USDC_ADDRESS,
            address(chainlinkAdaptor)
        );

        adaptor = new VelodromeVolatileLPAdaptor(
            ICentralRegistry(address(centralRegistry))
        );
        adaptor.addAsset(_AERODROME_WETH_USDC);
        oracleManager.addApprovedAdaptor(address(adaptor));
        oracleManager.addAssetPriceFeed(
            _AERODROME_WETH_USDC,
            address(adaptor)
        );

        centralRegistry.setSlippageLimit(6000);
    }

    function testWethUsdcVolatilePool_fuzzed(uint256 amount1) public {
        vm.assume(100e6 < amount1 && amount1 < 500_000e6);

        (uint256 price, uint256 errorCode) = oracleManager.getPrice(
            _AERODROME_WETH_USDC,
            true,
            false
        );
        assertEq(errorCode, 0);
        assertGt(price, 0);

        _prepareUSDC(user1, amount1 * 2);

        IVeloRouter.Route[] memory routes = new IVeloRouter.Route[](1);
        routes[0].from = _USDC_ADDRESS;
        routes[0].to = _WETH_ADDRESS;
        routes[0].stable = false;
        routes[0].factory = address(aeroPairFactory);

        vm.startPrank(user1);

        SwapperLib._approveIfNeeded(
            _USDC_ADDRESS,
            address(aeroRouter),
            amount1
        );
        aeroRouter.swapExactTokensForTokens(
            amount1,
            0,
            routes,
            user1,
            type(uint256).max
        );

        uint256 amount0 = weth.balanceOf(user1);

        SwapperLib._approveIfNeeded(
            _WETH_ADDRESS,
            address(aeroRouter),
            amount0
        );
        SwapperLib._approveIfNeeded(
            _USDC_ADDRESS,
            address(aeroRouter),
            amount1
        );
        (, , uint256 assets) = aeroRouter.addLiquidity(
            _WETH_ADDRESS,
            _USDC_ADDRESS,
            false,
            amount0,
            amount1,
            0,
            0,
            user1,
            block.timestamp
        );

        vm.stopPrank();

        (uint256 updatedPrice, ) = oracleManager.getPrice(
            _AERODROME_WETH_USDC,
            true,
            false
        );
        assertApproxEqRel(updatedPrice, price, 0.0001e18);

        deal(_AERODROME_WETH_USDC, address(this), 77777);
        deal(_USDC_ADDRESS, address(this), 77777);

        IERC20(_AERODROME_WETH_USDC).approve(address(aeroCTokenWETHUSDC), 77777);
        IERC20(_USDC_ADDRESS).approve(address(borrowableCUSDC), 77777);
        
        marketManagerIsolated.listTokens(address(aeroCTokenWETHUSDC),address(borrowableCUSDC));

        vm.prank(user1);
        IERC20(_AERODROME_WETH_USDC).approve(address(aeroCTokenWETHUSDC), assets);

        vm.prank(user1);
        aeroCTokenWETHUSDC.deposit(assets, user1);

        assertEq(
            aeroCTokenWETHUSDC.totalAssets(),
            assets + 77777,
            "Total Assets should equal user deposit plus initial mint."
        );

        vm.startPrank(gauge.voter());
        deal(_AERO_ADDRESS, gauge.voter(), 10e18);
        IERC20(_AERO_ADDRESS).approve(address(gauge), 10e18);
        gauge.notifyRewardAmount(10e18);
        vm.stopPrank();

        // Advance time to earn CRV and CVX rewards
        vm.warp(block.timestamp + 1 days);
        chainlinkAERO.updateAnswer(chainlinkAERO.latestAnswer());
        chainlinkWETH.updateAnswer(chainlinkWETH.latestAnswer());

        // Mint some extra rewards for Vault.
        uint256 earned = gauge.earned(address(aeroCTokenWETHUSDC));
        uint256 amount = (earned * 84) / 100;
        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _AERO_ADDRESS;
        swapAction.inputAmount = amount;
        swapAction.outputToken = _WETH_ADDRESS;
        swapAction.target = address(aeroRouter);
        routes = new IVeloRouter.Route[](1);
        routes[0].from = _AERO_ADDRESS;
        routes[0].to = _WETH_ADDRESS;
        routes[0].stable = false;
        routes[0].factory = address(aeroPairFactory);
        swapAction.call = abi.encodeWithSelector(
            IVeloRouter.swapExactTokensForTokens.selector,
            amount,
            0,
            routes,
            address(aeroCTokenWETHUSDC),
            type(uint256).max
        );
        swapAction.slippage = 50e16;

        aeroCTokenWETHUSDC.harvest(abi.encode(swapAction, 1e7));

        assertEq(
            aeroCTokenWETHUSDC.totalAssets(),
            assets + 77777,
            "Total Assets should equal user deposit plus initial mint."
        );

        vm.warp(block.timestamp + 8 days);
        chainlinkAERO.updateAnswer(chainlinkAERO.latestAnswer());
        chainlinkWETH.updateAnswer(chainlinkWETH.latestAnswer());

        // Mint some extra rewards for Vault.
        earned = gauge.earned(address(aeroCTokenWETHUSDC));
        amount = (earned * 84) / 100;
        swapAction.inputAmount = amount;
        swapAction.call = abi.encodeWithSelector(
            IVeloRouter.swapExactTokensForTokens.selector,
            amount,
            0,
            routes,
            address(aeroCTokenWETHUSDC),
            type(uint256).max
        );
        aeroCTokenWETHUSDC.harvest(abi.encode(swapAction, 1e7));

        vm.warp(block.timestamp + 7 days);
        chainlinkAERO.updateAnswer(chainlinkAERO.latestAnswer());
        chainlinkWETH.updateAnswer(chainlinkWETH.latestAnswer());

        assertGt(
            aeroCTokenWETHUSDC.totalAssets(),
            assets + 77777,
            "Total Assets should greater than original deposit plus initial mint."
        );

        vm.prank(user1);
        aeroCTokenWETHUSDC.withdraw(assets, user1, user1);
    }
}
