// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { SimpleZapper } from "contracts/plugins/market/SimpleZapper.sol";
import { ZapperBase } from "contracts/plugins/ZapperBase.sol";
import { Convex2PoolPToken, IERC20 } from "contracts/market/token/Convex2PoolPToken.sol";
import { Curve2PoolLPAdaptor } from "contracts/oracles/adaptors/curve/Curve2PoolLPAdaptor.sol";
import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";
import { IUniswapV3Router } from "contracts/interfaces/external/uniswap/IUniswapV3Router.sol";

import "tests/market/TestBaseMarket.sol";

contract User {}

contract TestSimpleZapper is TestBaseMarket {
    address internal _UNISWAP_V3_SWAP_ROUTER =
        0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address internal _CURVE_STETH_LP =
        0x21E27a5E5513D6e65C4f830167390997aA84843a;
    address internal _CURVE_STETH_MINTER =
        0x21E27a5E5513D6e65C4f830167390997aA84843a;
    address internal _STETH_ADDRESS =
        0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

    IERC20 public CONVEX_STETH_ETH_POOL =
        IERC20(0x21E27a5E5513D6e65C4f830167390997aA84843a);
    uint256 public CONVEX_STETH_ETH_POOL_ID = 177;
    address public CONVEX_STETH_ETH_REWARD =
        0x6B27D7BC63F1999D14fF9bA900069ee516669ee8;
    address public CONVEX_BOOSTER = 0xF403C135812408BFbE8713b5A23a04b3D48AAE31;

    address public owner;

    Convex2PoolPToken public cSTETH;
    SimpleZapper public simpleZapper;

    receive() external payable {}

    fallback() external payable {}

    function setUp() public override {
        super.setUp();

        owner = address(this);

        simpleZapper = new SimpleZapper(
            ICentralRegistry(address(centralRegistry)),
            _WETH_ADDRESS
        );

        centralRegistry.addHarvester(address(this));
        centralRegistry.setFeeManager(address(this));

        // set price oracle
        chainlinkAdaptor = new ChainlinkAdaptor(
            ICentralRegistry(address(centralRegistry))
        );
        chainlinkAdaptor.addAsset(
            0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE,
            address(chainlinkEthUsd),
            0,
            true
        );
        chainlinkAdaptor.addAsset(
            _STETH_ADDRESS,
            address(chainlinkEthUsd),
            0,
            true
        );

        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));
        oracleManager.addAssetPriceFeed(
            0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE,
            address(chainlinkAdaptor)
        );
        oracleManager.addAssetPriceFeed(
            _STETH_ADDRESS,
            address(chainlinkAdaptor)
        );

        Curve2PoolLPAdaptor adaptor = new Curve2PoolLPAdaptor(
            ICentralRegistry(address(centralRegistry))
        );
        adaptor.setReentrancyConfig(2, 10000);
        Curve2PoolLPAdaptor.AdaptorData memory data;
        data.pool = _CURVE_STETH_LP;
        data.underlying0 = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
        data.underlying1 = _STETH_ADDRESS;
        data.divideRate0 = true;
        data.divideRate1 = true;
        data.isCorrelated = true;
        data.upperBound = 10200;
        data.lowerBound = 10000;
        adaptor.addAsset(_CURVE_STETH_LP, data);

        oracleManager.addApprovedAdaptor(address(adaptor));
        oracleManager.addAssetPriceFeed(_CURVE_STETH_LP, address(adaptor));

        // start epoch
        vm.warp(gaugeManager.startTime());
        vm.roll(block.number + 1000);

        chainlinkEthUsd.updateRoundData(
            0,
            1500e8,
            block.timestamp,
            block.timestamp
        );

        // deploy cSTETH
        cSTETH = new Convex2PoolPToken(
            ICentralRegistry(address(centralRegistry)),
            CONVEX_STETH_ETH_POOL,
            address(marketManager),
            CONVEX_STETH_ETH_POOL_ID,
            CONVEX_STETH_ETH_REWARD,
            CONVEX_BOOSTER
        );

        deal(address(CONVEX_STETH_ETH_POOL), owner, 1 ether);
        CONVEX_STETH_ETH_POOL.approve(address(cSTETH), 1 ether);
        marketManager.listToken(address(cSTETH));
        oracleManager.addMTokenSupport(address(cSTETH));

        marketManager.updatePositionToken(
            address(cSTETH),
            5000,
            1500,
            1200,
            200,
            400,
            10,
            1000
        );
        address[] memory tokens = new address[](1);
        tokens[0] = address(cSTETH);
        uint256[] memory caps = new uint256[](1);
        caps[0] = 100_000e18;
        marketManager.setPTokenCollateralCaps(tokens, caps);

        // deploy eDAI
        {
            // support market
            _prepareDAI(owner, 200000e18);
            dai.approve(address(eDAI), 200000e18);
            marketManager.listToken(address(eDAI));
            // add MToken support on oracle manager
            oracleManager.addMTokenSupport(address(eDAI));
        }

        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareDAI(liquidityProvider, 1000 ether);
        // mint eDAI
        vm.startPrank(liquidityProvider);
        dai.approve(address(eDAI), 1000 ether);
        eDAI.mint(1000 ether);

        chainlinkDaiUsd.updateRoundData(
            0,
            1e8,
            block.timestamp,
            block.timestamp
        );
        vm.stopPrank();
    }

    function testSwapAndDeposit() public {
        uint256 ethAmount = 3 ether;
        vm.deal(user1, ethAmount);

        SwapperLib.Swap memory swapData;
        swapData.inputToken = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
        swapData.inputAmount = ethAmount;
        swapData.target = address(complexZapper);
        swapData.outputToken = _CURVE_STETH_LP;

        address[] memory tokens = new address[](2);
        tokens[0] = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
        tokens[1] = _STETH_ADDRESS;
        swapData.call = abi.encodeWithSelector(
            ComplexZapper.enterCurve.selector,
            address(0),
            ComplexZapper.ZapperData(
                0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE,
                ethAmount,
                _CURVE_STETH_LP,
                1,
                false
            ),
            new SwapperLib.Swap[](0),
            _CURVE_STETH_MINTER,
            tokens,
            0,
            false,
            address(simpleZapper)
        );

        vm.prank(user1);
        simpleZapper.swapAndDeposit{ value: ethAmount }(
            address(cSTETH),
            true,
            false,
            swapData,
            0,
            false,
            user1
        );

        assertEq(user1.balance, 0);
        assertGt(cSTETH.balanceOf(user1), 0);
    }

    function testSwapAndRepay() external {
        testSwapAndDeposit();
        vm.startPrank(user1);
        marketManager.postCollateral(user1, address(cSTETH), 1 ether);

        // try borrow()
        eDAI.borrow(500 ether);
        vm.stopPrank();

        assertEq(dai.balanceOf(user1), 500 ether);
        assertApproxEqAbs(eDAI.debtBalanceCached(user1), 500 ether, 1 ether);

        // skip min hold period
        skip(20 minutes);

        centralRegistry.setExternalCalldataChecker(
            _UNISWAP_V3_SWAP_ROUTER,
            address(new MockCalldataChecker(_UNISWAP_V3_SWAP_ROUTER))
        );

        SwapperLib.Swap memory swapData;
        swapData.inputToken = _USDC_ADDRESS;
        swapData.inputAmount = 500e6;
        swapData.outputToken = _DAI_ADDRESS;
        swapData.target = _UNISWAP_V3_SWAP_ROUTER;
        IUniswapV3Router.ExactInputSingleParams memory params;
        params.tokenIn = _USDC_ADDRESS;
        params.tokenOut = _DAI_ADDRESS;
        params.fee = 100;
        params.recipient = address(simpleZapper);
        params.deadline = block.timestamp;
        params.amountIn = 500e6;
        params.amountOutMinimum = 0;
        params.sqrtPriceLimitX96 = 0;
        swapData.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector,
            params
        );

        _prepareUSDC(user1, 500e6);
        vm.startPrank(user1);
        usdc.approve(address(simpleZapper), 500e6);
        simpleZapper.swapAndRepay(
            address(eDAI),
            false,
            swapData,
            450e18,
            user1
        );
        vm.stopPrank();

        assertApproxEqAbs(dai.balanceOf(user1), 550 ether, 1 ether);
        assertApproxEqAbs(eDAI.debtBalanceCached(user1), 50 ether, 1 ether);
    }

    function testRedeemAndSwapPToken() public {
        testSwapAndDeposit();

        vm.prank(user1);
        cSTETH.setDelegateApproval(address(simpleZapper), true);

        uint256 shares = cSTETH.balanceOf(user1);

        ZapperBase.RedemptionData memory redemptionData;
        redemptionData.mToken = address(cSTETH);
        redemptionData.shares = shares;
        redemptionData.forceRedeemCollateral = false;

        SwapperLib.Swap memory swapData;
        swapData.inputToken = _CURVE_STETH_LP;
        swapData.inputAmount = shares;
        swapData.outputToken = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
        swapData.target = address(complexZapper);

        address[] memory tokens = new address[](2);
        tokens[0] = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
        tokens[1] = _STETH_ADDRESS;

        swapData.call = abi.encodeWithSelector(
            ComplexZapper.exitCurve.selector,
            _CURVE_STETH_MINTER,
            ComplexZapper.ZapperData(
                _CURVE_STETH_LP,
                shares,
                0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE,
                1,
                false
            ),
            tokens,
            2,
            0,
            new SwapperLib.Swap[](0),
            address(simpleZapper)
        );

        vm.prank(user1);
        simpleZapper.redeemAndSwap(redemptionData, swapData, user1);

        assertGt(user1.balance, 2.99 ether); // 3 ether - fees
    }

    function testRedeemAndSwapEToken() public {
        centralRegistry.setExternalCalldataChecker(
            _UNISWAP_V3_SWAP_ROUTER,
            address(new MockCalldataChecker(_UNISWAP_V3_SWAP_ROUTER))
        );

        vm.startPrank(user1);

        // mint eDAI
        _prepareDAI(user1, 10 ether);
        dai.approve(address(eDAI), 10 ether);
        eDAI.mint(10 ether);

        eDAI.setDelegateApproval(address(simpleZapper), true);

        ZapperBase.RedemptionData memory redemptionData;
        redemptionData.mToken = address(eDAI);
        redemptionData.shares = 10 ether;
        redemptionData.forceRedeemCollateral = false;

        SwapperLib.Swap memory swapData;
        swapData.inputToken = _DAI_ADDRESS;
        swapData.inputAmount = 10 ether;
        swapData.outputToken = _USDC_ADDRESS;
        swapData.target = _UNISWAP_V3_SWAP_ROUTER;
        IUniswapV3Router.ExactInputSingleParams memory params;
        params.tokenIn = _DAI_ADDRESS;
        params.tokenOut = _USDC_ADDRESS;
        params.fee = 100;
        params.recipient = address(simpleZapper);
        params.deadline = block.timestamp;
        params.amountIn = 10 ether;
        params.amountOutMinimum = 0;
        params.sqrtPriceLimitX96 = 0;
        swapData.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector,
            params
        );

        simpleZapper.redeemAndSwap(redemptionData, swapData, user1);

        assertGt(usdc.balanceOf(user1), 9.99e6); // 10e6 - fees

        vm.stopPrank();
    }
}
