// // SPDX-License-Identifier: UNLICENSED
// pragma solidity ^0.8.19;

// import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
// import { PendleLib } from "contracts/libraries/PendleLib.sol";
// import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
// import { IUniswapV3Router } from "contracts/interfaces/external/uniswap/IUniswapV3Router.sol";
// import { IPendleRouter } from "contracts/interfaces/external/pendle/IPendleRouter.sol";
// import { IPendlePTOracle } from "contracts/interfaces/external/pendle/IPendlePtOracle.sol";
// import { IMToken } from "contracts/market/LiquidityManager.sol";
// import { PendleLPPToken, IERC20 } from "contracts/market/token/PendleLPPToken.sol";
// import { PositionManagementPendleLP } from "contracts/market/position-management/PositionManagementPendleLP.sol";
// import { PendleLPTokenAdaptor } from "contracts/oracles/adaptors/pendle/PendleLPTokenAdaptor.sol";
// import { SimplePToken } from "contracts/market/token/SimplePToken.sol";
// import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";
// import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";
// import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";

// contract TestPositionManagementPendlePT is TestBaseMarket {
//     address internal _UNISWAP_V3_SWAP_ROUTER =
//         0xE592427A0AEce92De3Edee1F18E0157C05861564;
//     IPendleRouter internal _ROUTER =
//         IPendleRouter(0x888888888889758F76e7103c6CbF23ABbF58F946);
//     address internal _STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
//     address internal _WSTETH = 0x7F39C581E8c495158ea4730aA4b21e8C7b444528;
//     address internal _PT_STETH = 0x7758896b6AC966BbABcf143eFA963030f17D3EdF; // PT-stETH-26DEC24
//     address internal _PENDLE = 0x808507121B80c02388fAd14726482e061B8da827;
//     address internal _LP_STETH = 0xD0354D4e7bCf345fB117cabe41aCaDb724eccCa2; // PT-stETH-26DEC24/SY-stETH Market
//     address internal _PT_ORACLE = 0x14030836AEc15B2ad48bB097bd57032559339c92;

//     PositionManagementPendleLP public positionManagement;
//     PendleLPPToken public cSTETH;
//     MockV3Aggregator public chainlinkPendleUsd;
//     PendleLPTokenAdaptor public adaptor;

//     address public owner;
//     address public user;

//     receive() external payable {}

//     fallback() external payable {}

//     // this is to use address(this) as mock cToken address
//     function tokenType() external pure returns (uint256) {
//         return 1;
//     }

//     function setUp() public override {
//         _fork(20287400);

//         _deployCentralRegistry();
//         _deployCVE();
//         _deployRewardManager();
//         _deployVeCVE();
//         _deployGaugeManager();
//         _deployOracleRouter();
//         _deployChainlinkAdaptors();
//         _deployMarketManager();
//         _deployDynamicInterestRateModel();

//         chainlinkPendleUsd = new MockV3Aggregator(18, 3.6e18, 3.6e24, 3.6e13);
//         chainlinkAdaptor.addAsset(
//             _PENDLE,
//             address(chainlinkPendleUsd),
//             0,
//             true
//         );
//         chainlinkAdaptor.addAsset(_STETH, _CHAINLINK_ETH_USD, 0, true);
//         oracleRouter.addAssetPriceFeed(_PENDLE, address(chainlinkAdaptor));
//         oracleRouter.addAssetPriceFeed(_STETH, address(chainlinkAdaptor));

//         centralRegistry.addHarvester(address(this));
//         centralRegistry.setFeeAccumulator(address(this));

//         centralRegistry.setExternalCalldataChecker(
//             _UNISWAP_V3_SWAP_ROUTER,
//             address(new MockCalldataChecker(_UNISWAP_V3_SWAP_ROUTER))
//         );
//         centralRegistry.setExternalCalldataChecker(
//             _UNISWAP_V2_ROUTER,
//             address(new MockCalldataChecker(_UNISWAP_V2_ROUTER))
//         );

//         adaptor = new PendleLPTokenAdaptor(
//             ICentralRegistry(address(centralRegistry)),
//             IPendlePTOracle(_PT_ORACLE)
//         );
//         PendleLPTokenAdaptor.AdaptorData memory adapterData;
//         adapterData.twapDuration = 12;
//         adapterData.quoteAsset = _STETH;
//         adapterData.pt = _PT_STETH;
//         adapterData.quoteAssetDecimals = 18;
//         adaptor.addAsset(_LP_STETH, adapterData);
//         oracleRouter.addApprovedAdaptor(address(adaptor));
//         oracleRouter.addAssetPriceFeed(_LP_STETH, address(adaptor));

//         owner = address(this);
//         user = user1;

//         // setup dDAI
//         {
//             _deployDDAI();
//             // add MToken support on price router
//             oracleRouter.addMTokenSupport(address(dDAI));

//             _prepareDAI(owner, 200000e18);
//             dai.approve(address(dDAI), 200000e18);
//             marketManager.listToken(address(dDAI));
//         }

//         cSTETH = new PendleLPPToken(
//             ICentralRegistry(address(centralRegistry)),
//             IERC20(_LP_STETH),
//             address(marketManager),
//             _ROUTER
//         );
//         oracleRouter.addMTokenSupport(address(cSTETH));

//         deal(_LP_STETH, owner, 1 ether);
//         IERC20(_LP_STETH).approve(address(cSTETH), 1 ether);
//         marketManager.listToken(address(cSTETH));

//         marketManager.updateCollateralToken(
//             IMToken(address(cSTETH)),
//             7000,
//             4000,
//             3000,
//             200,
//             400,
//             10,
//             1000
//         );

//         address[] memory tokens = new address[](1);
//         tokens[0] = address(cSTETH);
//         uint256[] memory caps = new uint256[](1);
//         caps[0] = 100_000e18;

//         marketManager.setCTokenCollateralCaps(tokens, caps);

//         positionManagement = new PositionManagementPendleLP(
//             ICentralRegistry(address(centralRegistry)),
//             address(marketManager),
//             _ROUTER
//         );

//         marketManager.setPositionManagement(address(positionManagement));

//         _provideEnoughLiquidityForLeverage();
//     }

//     function _provideEnoughLiquidityForLeverage() internal {
//         address liquidityProvider = makeAddr("liquidityProvider");

//         deal(_LP_STETH, liquidityProvider, 100 ether);
//         _prepareDAI(liquidityProvider, 20000000e18);

//         vm.startPrank(liquidityProvider);

//         // mint dDAI
//         dai.approve(address(dDAI), 20000000 ether);
//         dDAI.mint(20000000 ether);

//         // mint cSTETH
//         IERC20(_LP_STETH).approve(address(cSTETH), 100 ether);
//         cSTETH.deposit(100 ether, liquidityProvider);

//         vm.stopPrank();
//     }

//     function testInitialize() public {
//         assertEq(
//             address(positionManagement.centralRegistry()),
//             address(centralRegistry)
//         );
//         assertEq(
//             address(positionManagement.marketManager()),
//             address(marketManager)
//         );
//     }

//     function testLeverage() public {
//         vm.startPrank(user);

//         deal(_LP_STETH, user, 1 ether);
//         IERC20(_LP_STETH).approve(address(cSTETH), 1 ether);

//         // mint
//         assertGt(cSTETH.deposit(1 ether, user), 0);
//         marketManager.postCollateral(user, address(cSTETH), 1 ether);
//         assertEq(cSTETH.balanceOf(user), 1 ether);

//         uint256 balanceBeforeBorrow = dai.balanceOf(user);
//         // borrow
//         dDAI.borrow(100 ether);
//         assertEq(balanceBeforeBorrow + 100 ether, dai.balanceOf(user));

//         // try leverage with 50% of max
//         uint256 amountForLeverage = (positionManagement
//             .queryAmountToBorrowForLeverageMax(user, address(dDAI)) * 50) /
//             100;

//         PositionManagementPendleLP.LeverageStruct memory leverageData;
//         leverageData.borrowToken = dDAI;
//         leverageData.borrowAmount = amountForLeverage;
//         leverageData.collateralToken = SimplePToken(address(cSTETH));
//         leverageData.swapData.inputToken = _DAI_ADDRESS;
//         leverageData.swapData.inputAmount = amountForLeverage;
//         leverageData.swapData.outputToken = _WETH_ADDRESS;
//         leverageData.swapData.target = address(_UNISWAP_V3_SWAP_ROUTER);
//         IUniswapV3Router.ExactInputSingleParams memory params;
//         params.tokenIn = _DAI_ADDRESS;
//         params.tokenOut = _WETH_ADDRESS;
//         params.fee = 3000;
//         params.recipient = address(positionManagement);
//         params.deadline = block.timestamp;
//         params.amountIn = amountForLeverage;
//         params.amountOutMinimum = 0;
//         params.sqrtPriceLimitX96 = 0;
//         leverageData.swapData.call = abi.encodeWithSelector(
//             IUniswapV3Router.exactInputSingle.selector,
//             params
//         );
//         leverageData.swapData.slippage = 0.6e18;

//         PendleLib.PendleData memory data;
//         data.approx.guessMin = 1e10;
//         data.approx.guessMax = 1e18;
//         data.approx.guessOffchain = 0;
//         data.approx.maxIteration = 200;
//         data.approx.eps = 1e18;

//         leverageData.data = abi.encode(0, data);

//         positionManagement.leverage(leverageData, 500);

//         (uint256 dDAIBalance, uint256 dDAIBorrowed, ) = dDAI.getSnapshot(user);
//         assertEq(dDAIBalance, 0);
//         assertEq(dDAIBorrowed, 100 ether + amountForLeverage);

//         (uint256 cSTETHBalance, uint256 cSTETHBorrowed, ) = cSTETH.getSnapshot(
//             user
//         );
//         assertGt(cSTETHBalance, 2 ether);
//         assertEq(cSTETHBorrowed, 0 ether);

//         vm.stopPrank();
//     }

//     function testDeLeverage() public {
//         testLeverage();
//         // Warp until collateral posting wait time ends
//         vm.warp(block.timestamp + 20 minutes);
//         dDAI.accrueInterest();

//         vm.startPrank(user);

//         PositionManagementPendleLP.DeleverageStruct memory deleverageData;

//         (, uint256 dDAIBorrowedBefore, ) = dDAI.getSnapshot(user);
//         (uint256 cSTETHBalanceBefore, , ) = cSTETH.getSnapshot(user);

//         deleverageData.collateralToken = SimplePToken(address(cSTETH));
//         deleverageData.collateralAmount = 1 ether;
//         deleverageData.borrowToken = dDAI;

//         deleverageData.swapData = new SwapperLib.Swap[](1);
//         deleverageData.swapData[0].inputToken = _STETH;
//         deleverageData.swapData[0].inputAmount = 2.149 ether;
//         deleverageData.swapData[0].outputToken = _DAI_ADDRESS;
//         deleverageData.swapData[0].target = address(_UNISWAP_V2_ROUTER);
//         address[] memory path = new address[](3);
//         path[0] = _STETH;
//         path[1] = _WETH_ADDRESS;
//         path[2] = _DAI_ADDRESS;
//         deleverageData.swapData[0].call = abi.encodeWithSignature(
//             "swapExactTokensForTokensSupportingFeeOnTransferTokens(uint256,uint256,address[],address,uint256)",
//             2.149 ether,
//             0,
//             path,
//             address(positionManagement),
//             block.timestamp
//         );
//         deleverageData.swapData[0].slippage = 0.6e18;
//         deleverageData.repayAmount = 6500e18;
//         PendleLib.PendleData memory data;
//         data.approx.guessMin = 1e10;
//         data.approx.guessMax = 1e18;
//         data.approx.guessOffchain = 0;
//         data.approx.maxIteration = 200;
//         data.approx.eps = 1e18;
//         deleverageData.data = abi.encode(data);

//         cSTETH.approve(address(positionManagement), type(uint256).max);
//         positionManagement.deleverage(deleverageData, 500);

//         (uint256 dDAIBalance, uint256 dDAIBorrowed, ) = dDAI.getSnapshot(user);
//         assertEq(dDAIBalance, 0);
//         assertEq(
//             dDAIBorrowed,
//             dDAIBorrowedBefore - deleverageData.repayAmount
//         );

//         (uint256 cSTETHBalance, uint256 cSTETHBorrowed, ) = cSTETH.getSnapshot(
//             user
//         );
//         assertEq(
//             cSTETHBalance,
//             cSTETHBalanceBefore - deleverageData.collateralAmount
//         );
//         assertEq(cSTETHBorrowed, 0);

//         vm.stopPrank();
//     }
// }
