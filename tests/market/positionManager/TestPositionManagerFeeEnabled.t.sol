// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

import { VelodromeStableCToken } from "contracts/market/token/VelodromeStableCToken.sol";
import { VelodromeStableLPAdaptor } from "contracts/oracles/adaptors/velodrome/VelodromeStableLPAdaptor.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { VelodromePositionManager } from "contracts/market/position-management/VelodromePositionManager.sol";
import { OdosCalldataChecker } from "contracts/calldata-checker/swap-checker/OdosCalldataChecker.sol";

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { BPS } from "contracts/libraries/ConstantsLib.sol";

import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";

import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";

import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { ICToken, AccountSnapshot } from "contracts/interfaces/ICToken.sol";

import { IVeloGauge } from "contracts/interfaces/external/velodrome/IVeloGauge.sol";
import { IVeloRouter } from "contracts/interfaces/external/velodrome/IVeloRouter.sol";
import { IVeloPairFactory } from "contracts/interfaces/external/velodrome/IVeloPairFactory.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

contract TestPositionManagerFeeEnabled is TestBaseMarketIsolated {
    address internal _VELODROME_DAI_USDC =
        0x19715771E30c93915A5bbDa134d782b81A820076;
    address public odosRouterV2 = 0xCa423977156BB05b13A2BA3b76Bc5419E2fE9680;
    IVeloGauge public gauge =
        IVeloGauge(0x6998089F6bDd9c74C7D8d01b99d7e379ccCcb02D);
    IVeloPairFactory public veloPairFactory =
        IVeloPairFactory(0xF1046053aa5682b4F9a81b5481394DA16BE5FF5a);
    IVeloRouter public veloRouter =
        IVeloRouter(0xa062aE8A9c5e11aaA026fc2670B0D65cCc8B2858);

    OdosCalldataChecker public odosCallDataChecker;
    VelodromeStableCToken public strategyCTokenUSDCDAI;
    VelodromeStableLPAdaptor public adaptor;
    VelodromePositionManager public positionManager;

    address public owner;
    address public user;

    receive() external payable {}
    fallback() external payable {}

    function getOdosSwapAction(
        uint256 chainId,
        address fromToken,
        address toToken,
        uint256 amount,
        address swapperAddress,
        uint256 slippage
    ) public returns (bytes memory) {
        string[] memory args = new string[](8);
        args[0] = "node";
        args[1] = "getOdosSwapData.js";
        args[2] = vm.toString(chainId);
        args[3] = vm.toString(fromToken);
        args[4] = vm.toString(toToken);
        args[5] = vm.toString(amount);
        args[6] = vm.toString(swapperAddress);
        args[7] = vm.toString(slippage);

        return vm.ffi(args);
    }

    function setUp() public override {
        _fork("ETH_NODE_URI_OPTIMISM");

        _deployCentralRegistry();
        _deployCVE();
        _deployRewardManager();
        _deployVeCVE();
        _deployGaugeManager();
        _deployMarketManager();
        _deployOracleManager();

        chainlinkAdaptor = new ChainlinkAdaptor(
            ICentralRegistry(address(centralRegistry))
        );
        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));

        chainlinkDaiUsd = new MockV3Aggregator(8, 1e8);
        chainlinkAdaptor.addAsset(
            _DAI_ADDRESS,
            true,
            address(chainlinkDaiUsd),
            0
        );
        oracleManager.addAssetPriceFeed(
            _DAI_ADDRESS,
            address(chainlinkAdaptor)
        );
        chainlinkUsdcUsd = new MockV3Aggregator(8, 1e8);
        chainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            true,
            address(chainlinkUsdcUsd),
            0
        );
        oracleManager.addAssetPriceFeed(
            _USDC_ADDRESS,
            address(chainlinkAdaptor)
        );

        adaptor = new VelodromeStableLPAdaptor(
            ICentralRegistry(address(centralRegistry))
        );
        adaptor.addAsset(_VELODROME_DAI_USDC);
        oracleManager.addApprovedAdaptor(address(adaptor));
        oracleManager.addAssetPriceFeed(_VELODROME_DAI_USDC, address(adaptor));

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

        // Setup strategyCTokenUSDCDAI.
        {
            strategyCTokenUSDCDAI = new VelodromeStableCToken(
                ICentralRegistry(address(centralRegistry)),
                IERC20(_VELODROME_DAI_USDC),
                address(marketManagerIsolated),
                gauge,
                veloPairFactory,
                veloRouter,
                1 days
            );
            // Add cToken support on Oracle Manager.
            oracleManager.addCTokenSupport(address(strategyCTokenUSDCDAI));

            deal(_VELODROME_DAI_USDC, owner, 1 ether);
            IERC20(_VELODROME_DAI_USDC).approve(address(strategyCTokenUSDCDAI), 1 ether);


        }

        marketManagerIsolated.listTokens(address(strategyCTokenUSDCDAI),address(borrowableCDAI));

         _setCTokenConfigBasic(address(strategyCTokenUSDCDAI), 100_000e18, 0);
         _setCTokenConfigBasic(address(borrowableCDAI), 100_000e18, 100_000e18);

        positionManager = new VelodromePositionManager(
            ICentralRegistry(address(centralRegistry)),
            address(marketManagerIsolated),
            _WETH_ADDRESS,
            address(veloRouter),
            address(veloPairFactory)
        );
        marketManagerIsolated.addPositionManager(address(positionManager));

        _provideEnoughLiquidityForLeverage();

        address[] memory addressList;
        odosCallDataChecker = new OdosCalldataChecker(
            odosRouterV2,
            addressList
        );

        centralRegistry.setExternalCalldataChecker(
            odosRouterV2,
            address(odosCallDataChecker)
        );
        centralRegistry.setExternalCalldataChecker(
            address(veloRouter),
            address(new MockCalldataChecker(address(veloRouter)))
        );
    }

    function testLeverageWithFeeEnabled() public {
        // 1% leverage fee
        centralRegistry.setProtocolLeverageFee(100);

        vm.startPrank(user);

        deal(_VELODROME_DAI_USDC, user, 0.0001 ether);
        IERC20(_VELODROME_DAI_USDC).approve(address(strategyCTokenUSDCDAI), 0.0001 ether);

        // Mint strategyCTokenUSDCDAI.
        assertGt(strategyCTokenUSDCDAI.deposit(0.0001 ether, user), 0);
        strategyCTokenUSDCDAI.postCollateral(0.0001 ether);
        assertEq(strategyCTokenUSDCDAI.balanceOf(user), 0.0001 ether);

        uint256 balanceBeforeBorrow = dai.balanceOf(user);
        
        // Borrow borrowable cDAI.
        borrowableCDAI.borrow(100 ether, user);
        assertEq(balanceBeforeBorrow + 100 ether, dai.balanceOf(user));

        // Try leveraging with 50% of limit.
        uint256 amountForLeverage = positionManager.maxRemainingLeverageOf(
            user,
            address(borrowableCDAI)
        ) / 2;
        uint256 protocolBalanceBeforeLeverage = dai.balanceOf(
            centralRegistry.daoAddress()
        );
        uint256 leverageFee = FixedPointMathLib.mulDivUp(
            amountForLeverage,
            centralRegistry.protocolLeverageFee(),
            BPS
        );
        uint256 swapInputAmount = amountForLeverage - leverageFee;
        bytes memory result = getOdosSwapAction(
            block.chainid,
            _DAI_ADDRESS,
            _USDC_ADDRESS,
            swapInputAmount,
            address(positionManager),
            5 // 0.5%
        );
        (uint256 minUsdcOut, bytes memory odosCallData) = abi.decode(
            result,
            (uint256, bytes)
        );

        VelodromePositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCDAI));
        leverageAction.borrowAssets = amountForLeverage;
        leverageAction.cToken = ICToken(address(strategyCTokenUSDCDAI));
        leverageAction.swapAction.inputToken = _DAI_ADDRESS;
        leverageAction.swapAction.inputAmount = swapInputAmount;
        leverageAction.swapAction.outputToken = _USDC_ADDRESS;
        leverageAction.swapAction.target = odosRouterV2;
        leverageAction.swapAction.slippage = 0.005e18; // 0.5%
        leverageAction.swapAction.call = odosCallData;
        leverageAction.auxData = abi.encode(0);
        positionManager.leverage(leverageAction, 0.05e18);

        AccountSnapshot memory borrowableCDAISnapshot = borrowableCDAI.getSnapshot(user);
        assertEq(borrowableCDAI.balanceOf(user), 0);
        assertEq(borrowableCDAISnapshot.debtBalance, 100 ether + amountForLeverage);

        AccountSnapshot memory strategyCTokenUSDCDAISnapshot = strategyCTokenUSDCDAI.getSnapshot(user);
        assertGt(strategyCTokenUSDCDAI.balanceOf(user), 0.00013 ether);
        assertEq(strategyCTokenUSDCDAISnapshot.collateralPosted, strategyCTokenUSDCDAI.balanceOf(user));

        uint256 protocolBalanceAfterLeverage = dai.balanceOf(
            centralRegistry.daoAddress()
        );
        assertEq(
            protocolBalanceAfterLeverage,
            protocolBalanceBeforeLeverage + leverageFee
        );

        vm.stopPrank();
    }

    function testDeLeverageWithFeeEnabled() public {
        testLeverageWithFeeEnabled();

        // Warp until collateralization cooldown period ends.
        vm.warp(block.timestamp + 20 minutes);
        borrowableCDAI.accrueIfNeeded();

        vm.startPrank(user);

        VelodromePositionManager.DeleverageAction memory deleverageAction;

        AccountSnapshot memory borrowableCDAISnapshotBefore = borrowableCDAI.getSnapshot(user);
        uint256 strategyCTokenUSDCDAIBalanceBefore = strategyCTokenUSDCDAI.balanceOf(user);

        uint256 collateralAmount = 0.00003 ether;
        uint256 leverageFee = FixedPointMathLib.mulDivUp(
            collateralAmount,
            centralRegistry.protocolLeverageFee(),
            BPS
        );
        uint256 collateralWithoutFee = collateralAmount - leverageFee;
        uint256 protocolBalanceBeforeDeLeverage = IERC20(_VELODROME_DAI_USDC)
            .balanceOf(centralRegistry.daoAddress());

        {
            (uint256 usdcOutAmount, uint256 daiOutAmount) = veloRouter
                .quoteRemoveLiquidity(
                    _USDC_ADDRESS,
                    _DAI_ADDRESS,
                    true,
                    address(veloPairFactory),
                    collateralWithoutFee
                );
            bytes memory result = getOdosSwapAction(
                block.chainid,
                _USDC_ADDRESS,
                _DAI_ADDRESS,
                usdcOutAmount,
                address(positionManager),
                5 // 0.5%
            );
            (uint256 minDaiOut, bytes memory odosCallData) = abi.decode(
                result,
                (uint256, bytes)
            );

            deleverageAction.cToken = ICToken(address(strategyCTokenUSDCDAI));
            deleverageAction.collateralAssets = collateralAmount;
            deleverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCDAI));
            deleverageAction.swapActions = new SwapperLib.Swap[](1);
            deleverageAction.swapActions[0].inputToken = _USDC_ADDRESS;
            deleverageAction.swapActions[0].inputAmount = usdcOutAmount;
            deleverageAction.swapActions[0].outputToken = _DAI_ADDRESS;
            deleverageAction.swapActions[0].target = address(odosRouterV2);
            deleverageAction.swapActions[0].slippage = 0.005e18; // 0.5%
            deleverageAction.swapActions[0].call = odosCallData;
            deleverageAction.repayAssets = daiOutAmount + (minDaiOut / 10) * 9;
        }

        strategyCTokenUSDCDAI.approve(address(positionManager), type(uint256).max);
        positionManager.deleverage(deleverageAction, 0.05e18);

        AccountSnapshot memory borrowableCDAISnapshot = borrowableCDAI.getSnapshot(user);
        assertEq(borrowableCDAI.balanceOf(user), 0);
        assertEq(
            borrowableCDAISnapshot.debtBalance,
            borrowableCDAISnapshotBefore.debtBalance - deleverageAction.repayAssets
        );

        AccountSnapshot memory strategyCTokenUSDCDAISnapshot = strategyCTokenUSDCDAI.getSnapshot(user);
        assertEq(
            strategyCTokenUSDCDAI.balanceOf(user),
            strategyCTokenUSDCDAIBalanceBefore - deleverageAction.collateralAssets
        );
        assertEq(strategyCTokenUSDCDAISnapshot.collateralPosted, strategyCTokenUSDCDAIBalanceBefore - deleverageAction.collateralAssets);

        uint256 protocolBalanceAfterDeLeverage = IERC20(_VELODROME_DAI_USDC)
            .balanceOf(centralRegistry.daoAddress());
        assertEq(
            protocolBalanceAfterDeLeverage,
            protocolBalanceBeforeDeLeverage + leverageFee
        );

        vm.stopPrank();
    }

    function _provideEnoughLiquidityForLeverage() internal {
        address liquidityProvider = makeAddr("liquidityProvider");

        deal(_VELODROME_DAI_USDC, liquidityProvider, 1 ether);
        _prepareDAI(liquidityProvider, 20000000e18);

        vm.startPrank(liquidityProvider);

        // Deposit borrowable cDAI.
        dai.approve(address(borrowableCDAI), 20000000 ether);
        borrowableCDAI.deposit(20000000 ether, liquidityProvider);

        // Deposit strategyCTokenUSDCDAI.
        IERC20(_VELODROME_DAI_USDC).approve(address(strategyCTokenUSDCDAI), 1 ether);
        strategyCTokenUSDCDAI.deposit(1 ether, liquidityProvider);

        vm.stopPrank();
    }
}
