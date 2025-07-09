// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { AerodromeStableCToken, IVeloGauge, IVeloRouter, IVeloPairFactory, IERC20 } from "contracts/market/token/AerodromeStableCToken.sol";
import { VelodromeStableLPAdaptor } from "contracts/oracles/adaptors/velodrome/VelodromeStableLPAdaptor.sol";
import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

// NOTE: This test fails when input amount is very small.
// Fails when amount0 is 3.584e18. Probably due to precision loss.
// Issues arise with getAmountOut execution.
contract TestAerodromeStableCToken is TestBaseMarketIsolated {
    address internal _AERO_ADDRESS =
        0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    address internal _AERODROME_DAI_USDC =
        0x67b00B46FA4f4F24c03855c5C8013C0B938B3eEc;
    IVeloGauge public gauge =
        IVeloGauge(0x640e9ef68e1353112fF18826c4eDa844E1dC5eD0);
    IVeloPairFactory public aeroPairFactory =
        IVeloPairFactory(0x420DD381b31aEf6683db6B902084cB0FFECe40Da);
    IVeloRouter public aeroRouter =
        IVeloRouter(0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43);

    AerodromeStableCToken public cUSDCDAI;
    VelodromeStableLPAdaptor public adaptor;
    MockV3Aggregator public chainlinkAERO;
    MockV3Aggregator public chainlinkDAI;
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

        cUSDCDAI = new AerodromeStableCToken(
            ICentralRegistry(address(centralRegistry)),
            IERC20(_AERODROME_DAI_USDC),
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

        chainlinkAERO = new MockV3Aggregator(8, 0.65e8, 1e50, 1e6);
        chainlinkAdaptor.addAsset(
            _AERO_ADDRESS,
            address(chainlinkAERO),
            0,
            true
        );
        oracleManager.addAssetPriceFeed(
            _AERO_ADDRESS,
            address(chainlinkAdaptor)
        );

        chainlinkDAI = new MockV3Aggregator(8, 1e8, 1e50, 1e6);
        chainlinkAdaptor.addAsset(
            _DAI_ADDRESS,
            address(chainlinkDAI),
            0,
            true
        );
        oracleManager.addAssetPriceFeed(
            _DAI_ADDRESS,
            address(chainlinkAdaptor)
        );

        chainlinkUSDC = new MockV3Aggregator(8, 1e8, 1e50, 1e6);
        chainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            address(chainlinkUSDC),
            0,
            true
        );
        oracleManager.addAssetPriceFeed(
            _USDC_ADDRESS,
            address(chainlinkAdaptor)
        );

        adaptor = new VelodromeStableLPAdaptor(
            ICentralRegistry(address(centralRegistry))
        );
        adaptor.addAsset(_AERODROME_DAI_USDC);
        oracleManager.addApprovedAdaptor(address(adaptor));
        oracleManager.addAssetPriceFeed(_AERODROME_DAI_USDC, address(adaptor));

        centralRegistry.setSlippageLimit(6000);
    }

    function testDaiUsdcStablePool_fuzzed(uint256 amount0) public {
        vm.assume(10e18 < amount0 && amount0 < 60_000e18);

        (uint256 price, uint256 errorCode) = oracleManager.getPrice(
            _AERODROME_DAI_USDC,
            true,
            false
        );
        assertEq(errorCode, 0);
        assertGt(price, 0);

        _prepareDAI(user1, amount0 * 2);

        IVeloRouter.Route[] memory routes = new IVeloRouter.Route[](1);
        routes[0].from = _DAI_ADDRESS;
        routes[0].to = _USDC_ADDRESS;
        routes[0].stable = true;
        routes[0].factory = address(aeroPairFactory);

        vm.startPrank(user1);

        SwapperLib._approveTokenIfNeeded(
            _DAI_ADDRESS,
            address(aeroRouter),
            amount0
        );
        aeroRouter.swapExactTokensForTokens(
            amount0,
            0,
            routes,
            user1,
            type(uint256).max
        );

        uint256 amount1 = usdc.balanceOf(user1);

        SwapperLib._approveTokenIfNeeded(
            _DAI_ADDRESS,
            address(aeroRouter),
            amount0
        );
        SwapperLib._approveTokenIfNeeded(
            _USDC_ADDRESS,
            address(aeroRouter),
            amount1
        );
        (, , uint256 assets) = aeroRouter.addLiquidity(
            _DAI_ADDRESS,
            _USDC_ADDRESS,
            true,
            amount0,
            amount1,
            0,
            0,
            user1,
            block.timestamp
        );

        vm.stopPrank();

        (uint256 updatedPrice, ) = oracleManager.getPrice(
            _AERODROME_DAI_USDC,
            true,
            false
        );
        assertApproxEqRel(updatedPrice, price, 0.0001e18);

        deal(_AERODROME_DAI_USDC, address(this), 77777);

        IERC20(_AERODROME_DAI_USDC).approve(address(cUSDCDAI), 77777);
        marketManagerIsolated.listTokens(address(cUSDCDAI), address(borrowableCDAI));

        vm.prank(user1);
        IERC20(_AERODROME_DAI_USDC).approve(address(cUSDCDAI), assets);

        vm.prank(user1);
        cUSDCDAI.deposit(assets, user1);

        assertEq(
            cUSDCDAI.totalAssets(),
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
        chainlinkDAI.updateAnswer(chainlinkDAI.latestAnswer());

        // Mint some extra rewards for Vault.
        uint256 earned = gauge.earned(address(cUSDCDAI));
        uint256 amount = (earned * 84) / 100;
        SwapperLib.Swap memory swapData;
        swapData.inputToken = _AERO_ADDRESS;
        swapData.inputAmount = amount;
        swapData.outputToken = _DAI_ADDRESS;
        swapData.target = address(aeroRouter);
        routes = new IVeloRouter.Route[](1);
        routes[0].from = _AERO_ADDRESS;
        routes[0].to = _DAI_ADDRESS;
        routes[0].stable = false;
        routes[0].factory = address(aeroPairFactory);
        swapData.call = abi.encodeWithSelector(
            IVeloRouter.swapExactTokensForTokens.selector,
            amount,
            0,
            routes,
            address(cUSDCDAI),
            type(uint256).max
        );
        swapData.slippage = 50e16;

        cUSDCDAI.harvest(abi.encode(swapData, 1e4));

        assertEq(
            cUSDCDAI.totalAssets(),
            assets + 77777,
            "Total Assets should equal user deposit plus initial mint."
        );

        vm.warp(block.timestamp + 8 days);
        chainlinkAERO.updateAnswer(chainlinkAERO.latestAnswer());
        chainlinkDAI.updateAnswer(chainlinkDAI.latestAnswer());

        // Mint some extra rewards for Vault.
        earned = gauge.earned(address(cUSDCDAI));
        amount = (earned * 84) / 100;
        swapData.inputAmount = amount;
        swapData.call = abi.encodeWithSelector(
            IVeloRouter.swapExactTokensForTokens.selector,
            amount,
            0,
            routes,
            address(cUSDCDAI),
            type(uint256).max
        );
        cUSDCDAI.harvest(abi.encode(swapData, 1e4));

        vm.warp(block.timestamp + 7 days);
        chainlinkAERO.updateAnswer(chainlinkAERO.latestAnswer());
        chainlinkDAI.updateAnswer(chainlinkDAI.latestAnswer());

        assertGt(
            cUSDCDAI.totalAssets(),
            assets + 77777,
            "Total Assets should greater than original deposit plus initial mint."
        );

        vm.prank(user1);
        cUSDCDAI.withdraw(assets, user1, user1);
    }
}
