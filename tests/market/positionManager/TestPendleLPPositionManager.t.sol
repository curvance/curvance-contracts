// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { PendleLib } from "contracts/libraries/PendleLib.sol";
import { PendleLPCToken } from "contracts/market/token/PendleLPCToken.sol";
import { PendleLPPositionManager } from "contracts/market/position-management/PendleLPPositionManager.sol";
import { PendleLPTokenAdaptor } from "contracts/oracles/adaptors/pendle/PendleLPTokenAdaptor.sol";
import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IUniswapV3Router } from "contracts/interfaces/external/uniswap/IUniswapV3Router.sol";
import { IPendleRouter } from "contracts/interfaces/external/pendle/IPendleRouter.sol";
import { IPendlePTOracle } from "contracts/interfaces/external/pendle/IPendlePtOracle.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { ICToken, AccountSnapshot } from "contracts/interfaces/ICToken.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

contract TestPendleLPPositionManager is TestBaseMarketIsolated {
    address internal _UNISWAP_V3_SWAP_ROUTER =
        0xE592427A0AEce92De3Edee1F18E0157C05861564;
    IPendleRouter internal _ROUTER =
        IPendleRouter(0x888888888889758F76e7103c6CbF23ABbF58F946);

    address internal _PT_STETH = 0x7758896b6AC966BbABcf143eFA963030f17D3EdF; // PT-stETH-26DEC24
    address internal _PENDLE = 0x808507121B80c02388fAd14726482e061B8da827;
    address internal _LP_STETH = 0xD0354D4e7bCf345fB117cabe41aCaDb724eccCa2; // PT-stETH-26DEC24/SY-stETH Market
    address internal _PT_ORACLE = 0x14030836AEc15B2ad48bB097bd57032559339c92;
    PendleLPPositionManager public positionManager;
    PendleLPCToken public strategyCTokenSTETH;
    MockV3Aggregator public chainlinkPendleUsd;
    PendleLPTokenAdaptor public adaptor;

    address public owner;
    address public user;

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

        chainlinkPendleUsd = new MockV3Aggregator(18, 3.6e18, 3.6e24, 3.6e13);
        chainlinkAdaptor.addAsset(
            _PENDLE,
            address(chainlinkPendleUsd),
            0,
            true
        );
        chainlinkAdaptor.addAsset(_STETH, _CHAINLINK_ETH_USD, 0, true);
        oracleManager.addAssetPriceFeed(_PENDLE, address(chainlinkAdaptor));
        oracleManager.addAssetPriceFeed(_STETH, address(chainlinkAdaptor));

        centralRegistry.addHarvestPermissions(address(this));
        centralRegistry.setFeeManager(address(this));
        centralRegistry.setExternalCalldataChecker(
            _UNISWAP_V3_SWAP_ROUTER,
            address(new MockCalldataChecker(_UNISWAP_V3_SWAP_ROUTER))
        );
        centralRegistry.setExternalCalldataChecker(
            _UNISWAP_V2_ROUTER,
            address(new MockCalldataChecker(_UNISWAP_V2_ROUTER))
        );

        adaptor = new PendleLPTokenAdaptor(
            ICentralRegistry(address(centralRegistry)),
            IPendlePTOracle(_PT_ORACLE)
        );
        PendleLPTokenAdaptor.AdaptorData memory adapterData;
        adapterData.twapDuration = 12;
        adapterData.quoteAsset = _STETH;
        adapterData.pt = _PT_STETH;
        adapterData.quoteAssetDecimals = 18;
        adaptor.addAsset(_LP_STETH, adapterData);
        oracleManager.addApprovedAdaptor(address(adaptor));
        oracleManager.addAssetPriceFeed(_LP_STETH, address(adaptor));

        owner = address(this);
        user = user1;

        // Setup borrowable cDAI.
        {
            _deployBorrowableCDAI();
            // Add cToken support on Oracle Manager.
            oracleManager.addCTokenSupport(address(borrowableCDAI));

            _prepareDAI(owner, 200000e18);
            dai.approve(address(borrowableCDAI), 200000e18);
        }

        strategyCTokenSTETH = new PendleLPCToken(
            ICentralRegistry(address(centralRegistry)),
            IERC20(_LP_STETH),
            address(marketManagerIsolated),
            _ROUTER,
            1 days
        );
        oracleManager.addCTokenSupport(address(strategyCTokenSTETH));

        deal(_LP_STETH, owner, 1 ether);
        IERC20(_LP_STETH).approve(address(strategyCTokenSTETH), 1 ether);
        
        marketManagerIsolated.listTokens(address(strategyCTokenSTETH), address(borrowableCDAI));

         _setCTokenConfigBasic(address(strategyCTokenSTETH), 100_000e18, 0);
         _setCTokenConfigBasic(address(borrowableCDAI), 100_000e18, 100_000e18);

        positionManager = new PendleLPPositionManager(
            ICentralRegistry(address(centralRegistry)),
            address(marketManagerIsolated),
            _WETH_ADDRESS,
            _ROUTER
        );

        marketManagerIsolated.addPositionManager(address(positionManager));

        _provideEnoughLiquidityForLeverage();
    }

    function _provideEnoughLiquidityForLeverage() internal {
        address liquidityProvider = makeAddr("liquidityProvider");

        deal(_LP_STETH, liquidityProvider, 100 ether);
        _prepareDAI(liquidityProvider, 20000000e18);

        vm.startPrank(liquidityProvider);

        // Deposit borrowable cDAI.
        dai.approve(address(borrowableCDAI), 20000000 ether);
        borrowableCDAI.deposit(20000000 ether, liquidityProvider);

        // Deposit strategyCTokenSTETH.
        IERC20(_LP_STETH).approve(address(strategyCTokenSTETH), 100 ether);
        strategyCTokenSTETH.deposit(100 ether, liquidityProvider);

        vm.stopPrank();
    }

    function testInitialize() public {
        assertEq(
            address(positionManager.centralRegistry()),
            address(centralRegistry)
        );
        assertEq(
            address(positionManager.marketManager()),
            address(marketManagerIsolated)
        );
    }

    function testLeverage() public {
        vm.startPrank(user);

        deal(_LP_STETH, user, 1 ether);
        IERC20(_LP_STETH).approve(address(strategyCTokenSTETH), 1 ether);

        // Mint strategyCTokenSTETH.
        assertGt(strategyCTokenSTETH.deposit(1 ether, user), 0);
        strategyCTokenSTETH.postCollateral(1 ether);
        assertEq(strategyCTokenSTETH.balanceOf(user), 1 ether);

        uint256 balanceBeforeBorrow = dai.balanceOf(user);
        
        // Borrow borrowable cDAI.
        borrowableCDAI.borrow(100 ether, user);
        assertEq(balanceBeforeBorrow + 100 ether, dai.balanceOf(user));

        // Try leverage with 50% of max.
        uint256 amountForLeverage = (positionManager.maxRemainingLeverageOf(
            user,
            address(borrowableCDAI)
        ) * 50) / 100;

        PendleLPPositionManager.LeverageStruct memory leverageData;
        leverageData.debtToken = IBorrowableCToken(address(borrowableCDAI));
        leverageData.borrowAssets = amountForLeverage;
        leverageData.collateralToken = ICToken(address(strategyCTokenSTETH));
        leverageData.swapData.inputToken = _DAI_ADDRESS;
        leverageData.swapData.inputAmount = amountForLeverage;
        leverageData.swapData.outputToken = _WETH_ADDRESS;
        leverageData.swapData.target = address(_UNISWAP_V3_SWAP_ROUTER);
        IUniswapV3Router.ExactInputSingleParams memory params;
        params.tokenIn = _DAI_ADDRESS;
        params.tokenOut = _WETH_ADDRESS;
        params.fee = 3000;
        params.recipient = address(positionManager);
        params.deadline = block.timestamp;
        params.amountIn = amountForLeverage;
        params.amountOutMinimum = 0;
        params.sqrtPriceLimitX96 = 0;
        leverageData.swapData.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector,
            params
        );
        leverageData.swapData.slippage = 0.6e18;

        PendleLib.PendleData memory data;
        data.approx.guessMin = 1e10;
        data.approx.guessMax = 1e18;
        data.approx.guessOffchain = 0;
        data.approx.maxIteration = 200;
        data.approx.eps = 1e18;

        leverageData.auxData = abi.encode(0, data);

        positionManager.leverage(leverageData, 0.05e18); // 5% slippage

        AccountSnapshot memory borrowableCDAISnapshot = borrowableCDAI.getSnapshot(user);
        assertEq(borrowableCDAI.balanceOf(user), 0);
        assertEq(borrowableCDAISnapshot.debtBalance, 100 ether + amountForLeverage);

        AccountSnapshot memory strategyCTokenSTETHSnapshot = strategyCTokenSTETH.getSnapshot(
            user
        );
        assertGt(strategyCTokenSTETHSnapshot.collateralPosted, 2 ether);
        assertEq(strategyCTokenSTETHSnapshot.debtBalance, 0 ether);

        vm.stopPrank();
    }

    function testDepositAndLeverage() public {
        vm.startPrank(user);

        deal(_LP_STETH, user, 1 ether);
        IERC20(_LP_STETH).approve(address(positionManager), 1 ether);

        // allow delegation for postCollateral
        strategyCTokenSTETH.setDelegateApproval(address(positionManager), true);

        // Try leverage with 50% of max.
        uint256 amountForLeverage = 7.4983181832e21;

        PendleLPPositionManager.LeverageStruct memory leverageData;
        leverageData.debtToken = IBorrowableCToken(address(borrowableCDAI));
        leverageData.borrowAssets = amountForLeverage;
        leverageData.collateralToken = ICToken(address(strategyCTokenSTETH));
        leverageData.swapData.inputToken = _DAI_ADDRESS;
        leverageData.swapData.inputAmount = amountForLeverage;
        leverageData.swapData.outputToken = _WETH_ADDRESS;
        leverageData.swapData.target = address(_UNISWAP_V3_SWAP_ROUTER);
        IUniswapV3Router.ExactInputSingleParams memory params;
        params.tokenIn = _DAI_ADDRESS;
        params.tokenOut = _WETH_ADDRESS;
        params.fee = 3000;
        params.recipient = address(positionManager);
        params.deadline = block.timestamp;
        params.amountIn = amountForLeverage;
        params.amountOutMinimum = 0;
        params.sqrtPriceLimitX96 = 0;
        leverageData.swapData.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector,
            params
        );
        leverageData.swapData.slippage = 0.6e18;

        PendleLib.PendleData memory data;
        data.approx.guessMin = 1e10;
        data.approx.guessMax = 1e18;
        data.approx.guessOffchain = 0;
        data.approx.maxIteration = 200;
        data.approx.eps = 1e18;

        leverageData.auxData = abi.encode(0, data);

        positionManager.depositAndLeverage(1 ether, leverageData, 0.05e18); // 5% slippage

        AccountSnapshot memory borrowableCDAISnapshot = borrowableCDAI.getSnapshot(user);
        assertEq(borrowableCDAI.balanceOf(user), 0);
        assertEq(borrowableCDAISnapshot.debtBalance, amountForLeverage);

        AccountSnapshot memory strategyCTokenSTETHSnapshot = strategyCTokenSTETH.getSnapshot(
            user
        );
        assertGt(strategyCTokenSTETHSnapshot.collateralPosted, 2 ether);
        assertEq(strategyCTokenSTETHSnapshot.debtBalance, 0 ether);

        vm.stopPrank();
    }

    function testDeLeverage() public {
        testLeverage();

        // Warp until collateralization cooldown period ends.
        vm.warp(block.timestamp + 20 minutes);
        borrowableCDAI.accrueIfNeeded();

        vm.startPrank(user);
        PendleLPPositionManager.DeleverageStruct memory deleverageData;
        AccountSnapshot memory borrowableCDAIBeforeSnapshot = borrowableCDAI.getSnapshot(user);
        uint256 strategyCTokenSTETHCollateralBefore = strategyCTokenSTETH.collateralPosted(user);

        deleverageData.collateralToken = ICToken(address(strategyCTokenSTETH));
        deleverageData.collateralAssets = 1 ether;
        deleverageData.debtToken = IBorrowableCToken(address(borrowableCDAI));

        deleverageData.swapData = new SwapperLib.Swap[](1);
        deleverageData.swapData[0].inputToken = _STETH;
        deleverageData.swapData[0].inputAmount = 2.149 ether;
        deleverageData.swapData[0].outputToken = _DAI_ADDRESS;
        deleverageData.swapData[0].target = address(_UNISWAP_V2_ROUTER);
        address[] memory path = new address[](3);
        path[0] = _STETH;
        path[1] = _WETH_ADDRESS;
        path[2] = _DAI_ADDRESS;
        deleverageData.swapData[0].call = abi.encodeWithSignature(
            "swapExactTokensForTokensSupportingFeeOnTransferTokens(uint256,uint256,address[],address,uint256)",
            2.149 ether,
            0,
            path,
            address(positionManager),
            block.timestamp
        );
        deleverageData.swapData[0].slippage = 0.6e18;
        deleverageData.repayAssets = 6500e18;
        PendleLib.PendleData memory data;
        data.approx.guessMin = 1e10;
        data.approx.guessMax = 1e18;
        data.approx.guessOffchain = 0;
        data.approx.maxIteration = 200;
        data.approx.eps = 1e18;
        deleverageData.auxData = abi.encode(0, data);

        strategyCTokenSTETH.approve(address(positionManager), type(uint256).max);
        positionManager.deleverage(deleverageData, 0.05e18); // 5% slippage

        AccountSnapshot memory borrowableCDAISnapshot = borrowableCDAI.getSnapshot(user);
        assertEq(borrowableCDAI.balanceOf(user), 0);
        assertEq(
            borrowableCDAISnapshot.debtBalance,
            borrowableCDAIBeforeSnapshot.debtBalance - deleverageData.repayAssets
        );

        AccountSnapshot memory strategyCTokenSTETHSnapshot = strategyCTokenSTETH.getSnapshot(
            user
        );
        assertEq(
            strategyCTokenSTETHSnapshot.collateralPosted,
            strategyCTokenSTETHCollateralBefore - deleverageData.collateralAssets
        );
        assertEq(strategyCTokenSTETHSnapshot.debtBalance, 0);

        vm.stopPrank();
    }

    function testLeverageFor() public {
        vm.startPrank(user);

        deal(_LP_STETH, user, 1 ether);
        IERC20(_LP_STETH).approve(address(strategyCTokenSTETH), 1 ether);

        // Mint strategyCTokenSTETH.
        assertGt(strategyCTokenSTETH.deposit(1 ether, user), 0);
        strategyCTokenSTETH.postCollateral(1 ether);
        assertEq(strategyCTokenSTETH.balanceOf(user), 1 ether);

        uint256 balanceBeforeBorrow = dai.balanceOf(user);
        
        // Borrow borrowable cDAI.
        borrowableCDAI.borrow(100 ether, user);
        assertEq(balanceBeforeBorrow + 100 ether, dai.balanceOf(user));

        // Try leverage with 50% of max.
        uint256 amountForLeverage = (positionManager.maxRemainingLeverageOf(
            user,
            address(borrowableCDAI)
        ) * 50) / 100;

        PendleLPPositionManager.LeverageStruct memory leverageData;
        leverageData.debtToken = IBorrowableCToken(address(borrowableCDAI));
        leverageData.borrowAssets = amountForLeverage;
        leverageData.collateralToken = ICToken(address(strategyCTokenSTETH));
        leverageData.swapData.inputToken = _DAI_ADDRESS;
        leverageData.swapData.inputAmount = amountForLeverage;
        leverageData.swapData.outputToken = _WETH_ADDRESS;
        leverageData.swapData.target = address(_UNISWAP_V3_SWAP_ROUTER);
        IUniswapV3Router.ExactInputSingleParams memory params;
        params.tokenIn = _DAI_ADDRESS;
        params.tokenOut = _WETH_ADDRESS;
        params.fee = 3000;
        params.recipient = address(positionManager);
        params.deadline = block.timestamp;
        params.amountIn = amountForLeverage;
        params.amountOutMinimum = 0;
        params.sqrtPriceLimitX96 = 0;
        leverageData.swapData.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector,
            params
        );
        leverageData.swapData.slippage = 0.6e18;

        PendleLib.PendleData memory data;
        data.approx.guessMin = 1e10;
        data.approx.guessMax = 1e18;
        data.approx.guessOffchain = 0;
        data.approx.maxIteration = 200;
        data.approx.eps = 1e18;

        leverageData.auxData = abi.encode(0, data);

        positionManager.setDelegateApproval(address(user2), true);
        vm.stopPrank();

        vm.prank(user2);
        positionManager.leverageFor(leverageData, user, 0.05e18); // 5% slippage

        AccountSnapshot memory borrowableCDAISnapshot = borrowableCDAI.getSnapshot(user);
        assertEq(borrowableCDAI.balanceOf(user), 0);
        assertEq(borrowableCDAISnapshot.debtBalance, 100 ether + amountForLeverage);

        AccountSnapshot memory strategyCTokenSTETHSnapshot = strategyCTokenSTETH.getSnapshot(
            user
        );
        assertGt(strategyCTokenSTETHSnapshot.collateralPosted, 2 ether);
        assertEq(strategyCTokenSTETHSnapshot.debtBalance, 0 ether);
    }

    function testDeLeverageFor() public {
        testLeverage();

        // Warp until collateralization cooldown period ends.
        vm.warp(block.timestamp + 20 minutes);
        borrowableCDAI.accrueIfNeeded();

        vm.startPrank(user);
        PendleLPPositionManager.DeleverageStruct memory deleverageData;
        AccountSnapshot memory borrowableCDAIBeforeSnapshot = borrowableCDAI.getSnapshot(user);
        uint256 strategyCTokenSTETHCollateralBefore = strategyCTokenSTETH.collateralPosted(user);

        deleverageData.collateralToken = ICToken(address(strategyCTokenSTETH));
        deleverageData.collateralAssets = 1 ether;
        deleverageData.debtToken = IBorrowableCToken(address(borrowableCDAI));

        deleverageData.swapData = new SwapperLib.Swap[](1);
        deleverageData.swapData[0].inputToken = _STETH;
        deleverageData.swapData[0].inputAmount = 2.149 ether;
        deleverageData.swapData[0].outputToken = _DAI_ADDRESS;
        deleverageData.swapData[0].target = address(_UNISWAP_V2_ROUTER);
        address[] memory path = new address[](3);
        path[0] = _STETH;
        path[1] = _WETH_ADDRESS;
        path[2] = _DAI_ADDRESS;
        deleverageData.swapData[0].call = abi.encodeWithSignature(
            "swapExactTokensForTokensSupportingFeeOnTransferTokens(uint256,uint256,address[],address,uint256)",
            2.149 ether,
            0,
            path,
            address(positionManager),
            block.timestamp
        );
        deleverageData.swapData[0].slippage = 0.6e18;
        deleverageData.repayAssets = 6500e18;
        PendleLib.PendleData memory data;
        data.approx.guessMin = 1e10;
        data.approx.guessMax = 1e18;
        data.approx.guessOffchain = 0;
        data.approx.maxIteration = 200;
        data.approx.eps = 1e18;
        deleverageData.auxData = abi.encode(0, data);

        strategyCTokenSTETH.approve(address(positionManager), type(uint256).max);
        positionManager.setDelegateApproval(address(user2), true);
        vm.stopPrank();

        vm.prank(user2);
        positionManager.deleverageFor(deleverageData, user, 0.05e18); // 5% slippage

        AccountSnapshot memory borrowableCDAISnapshot = borrowableCDAI.getSnapshot(user);
        assertEq(borrowableCDAI.balanceOf(user), 0);
        assertEq(
            borrowableCDAISnapshot.debtBalance,
            borrowableCDAIBeforeSnapshot.debtBalance - deleverageData.repayAssets
        );

        AccountSnapshot memory strategyCTokenSTETHSnapshot = strategyCTokenSTETH.getSnapshot(
            user
        );
        assertEq(
            strategyCTokenSTETHSnapshot.collateralPosted,
            strategyCTokenSTETHCollateralBefore - deleverageData.collateralAssets
        );
        assertEq(strategyCTokenSTETHSnapshot.debtBalance, 0);
    }
}
