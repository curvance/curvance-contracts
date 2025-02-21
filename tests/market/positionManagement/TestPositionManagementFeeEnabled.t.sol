// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { VelodromeStablePToken, FixedPointMathLib, IVeloGauge, IVeloRouter, IVeloPairFactory, IERC20 } from "contracts/market/token/VelodromeStablePToken.sol";
import { VelodromeStableLPAdaptor } from "contracts/oracles/adaptors/velodrome/VelodromeStableLPAdaptor.sol";
import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { PositionManagementVelodrome } from "contracts/market/position-management/PositionManagementVelodrome.sol";
import { OdosCalldataChecker } from "contracts/calldata-checker/swap-checker/OdosCalldataChecker.sol";
import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { IEToken } from "contracts/interfaces/IEToken.sol";
import { IPToken } from "contracts/interfaces/IPToken.sol";

contract TestPositionManagementFeeEnabled is TestBaseMarket {
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
    VelodromeStablePToken public pUSDCDAI;
    VelodromeStableLPAdaptor public adaptor;
    PositionManagementVelodrome public positionManagement;

    address public owner;
    address public user;

    receive() external payable {}
    fallback() external payable {}

    function getRedstonePayload(
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

        chainlinkDaiUsd = new MockV3Aggregator(8, 1e8, 1e50, 1e6);
        chainlinkAdaptor.addAsset(
            _DAI_ADDRESS,
            address(chainlinkDaiUsd),
            0,
            true
        );
        oracleManager.addAssetPriceFeed(
            _DAI_ADDRESS,
            address(chainlinkAdaptor)
        );
        chainlinkUsdcUsd = new MockV3Aggregator(8, 1e8, 1e50, 1e6);
        chainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            address(chainlinkUsdcUsd),
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
        adaptor.addAsset(_VELODROME_DAI_USDC);
        oracleManager.addApprovedAdaptor(address(adaptor));
        oracleManager.addAssetPriceFeed(_VELODROME_DAI_USDC, address(adaptor));

        owner = address(this);
        user = user1;

        // setup eDAI
        {
            _deployEDAI();
            // add MToken support on price router
            oracleManager.addMTokenSupport(address(eDAI));

            _prepareDAI(owner, 200000e18);
            dai.approve(address(eDAI), 200000e18);
            marketManager.listToken(address(eDAI));
        }

        // setup pUSDCDAI
        {
            pUSDCDAI = new VelodromeStablePToken(
                ICentralRegistry(address(centralRegistry)),
                IERC20(_VELODROME_DAI_USDC),
                address(marketManager),
                gauge,
                veloPairFactory,
                veloRouter
            );
            // add MToken support on price router
            oracleManager.addMTokenSupport(address(pUSDCDAI));

            deal(_VELODROME_DAI_USDC, owner, 1 ether);
            IERC20(_VELODROME_DAI_USDC).approve(address(pUSDCDAI), 1 ether);
            marketManager.listToken(address(pUSDCDAI));

            marketManager.updatePositionToken(
                address(pUSDCDAI),
                7000,
                4000,
                3000,
                200,
                400,
                1000
            );

            address[] memory tokens = new address[](1);
            tokens[0] = address(pUSDCDAI);
            uint256[] memory caps = new uint256[](1);
            caps[0] = 100_000e18;

            marketManager.setPTokenCollateralCaps(tokens, caps);
        }

        positionManagement = new PositionManagementVelodrome(
            ICentralRegistry(address(centralRegistry)),
            address(marketManager),
            _WETH_ADDRESS,
            address(veloRouter),
            address(veloPairFactory)
        );
        marketManager.setPositionManagement(address(positionManagement));

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
        IERC20(_VELODROME_DAI_USDC).approve(address(pUSDCDAI), 0.0001 ether);

        // mint
        assertGt(pUSDCDAI.deposit(0.0001 ether, user), 0);
        marketManager.postCollateral(user, address(pUSDCDAI), 0.0001 ether);
        assertEq(pUSDCDAI.balanceOf(user), 0.0001 ether);

        uint256 balanceBeforeBorrow = dai.balanceOf(user);
        // borrow
        eDAI.borrow(100 ether);
        assertEq(balanceBeforeBorrow + 100 ether, dai.balanceOf(user));

        // try leverage with 50% of max
        uint256 amountForLeverage = (positionManagement.maxRemainingLeverageOf(
            user,
            address(eDAI)
        ) * 50) / 100;
        uint256 protocolBalanceBeforeLeverage = dai.balanceOf(
            centralRegistry.daoAddress()
        );
        uint256 leverageFee = FixedPointMathLib.mulDivUp(
            amountForLeverage,
            centralRegistry.protocolLeverageFee(),
            1e18
        );
        uint256 swapInputAmount = amountForLeverage - leverageFee;
        bytes memory result = getRedstonePayload(
            block.chainid,
            _DAI_ADDRESS,
            _USDC_ADDRESS,
            swapInputAmount,
            address(positionManagement),
            5 // 0.5%
        );
        (uint256 minUsdcOut, bytes memory odosCallData) = abi.decode(
            result,
            (uint256, bytes)
        );

        PositionManagementVelodrome.LeverageStruct memory leverageData;
        leverageData.borrowToken = IEToken(address(eDAI));
        leverageData.borrowAmount = amountForLeverage;
        leverageData.positionToken = IPToken(address(pUSDCDAI));
        leverageData.swapData.inputToken = _DAI_ADDRESS;
        leverageData.swapData.inputAmount = swapInputAmount;
        leverageData.swapData.outputToken = _USDC_ADDRESS;
        leverageData.swapData.target = odosRouterV2;
        leverageData.swapData.slippage = 0.005e18; // 0.5%
        leverageData.swapData.call = odosCallData;
        leverageData.auxData = abi.encode(0);
        positionManagement.leverage(leverageData, 0.05e18);

        (uint256 eDAIBalance, uint256 eDAIBorrowed, ) = eDAI.getSnapshot(user);
        assertEq(eDAIBalance, 0);
        assertEq(eDAIBorrowed, 100 ether + amountForLeverage);

        (uint256 pUSDCDAIBalance, uint256 pUSDCDAIBorrowed, ) = pUSDCDAI
            .getSnapshot(user);
        assertGt(pUSDCDAIBalance, 0.00013 ether);
        assertEq(pUSDCDAIBorrowed, 0 ether);

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
        // Warp until collateral posting wait time ends
        vm.warp(block.timestamp + 20 minutes);
        eDAI.accrueInterest();

        vm.startPrank(user);

        PositionManagementVelodrome.DeleverageStruct memory deleverageData;

        (, uint256 eDAIBorrowedBefore, ) = eDAI.getSnapshot(user);
        (uint256 pUSDCDAIBalanceBefore, , ) = pUSDCDAI.getSnapshot(user);

        uint256 collateralAmount = 0.00003 ether;
        uint256 leverageFee = FixedPointMathLib.mulDivUp(
            collateralAmount,
            centralRegistry.protocolLeverageFee(),
            1e18
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
            bytes memory result = getRedstonePayload(
                block.chainid,
                _USDC_ADDRESS,
                _DAI_ADDRESS,
                usdcOutAmount,
                address(positionManagement),
                5 // 0.5%
            );
            (uint256 minDaiOut, bytes memory odosCallData) = abi.decode(
                result,
                (uint256, bytes)
            );

            deleverageData.positionToken = IPToken(address(pUSDCDAI));
            deleverageData.collateralAmount = collateralAmount;
            deleverageData.borrowToken = IEToken(address(eDAI));
            deleverageData.swapData = new SwapperLib.Swap[](1);
            deleverageData.swapData[0].inputToken = _USDC_ADDRESS;
            deleverageData.swapData[0].inputAmount = usdcOutAmount;
            deleverageData.swapData[0].outputToken = _DAI_ADDRESS;
            deleverageData.swapData[0].target = address(odosRouterV2);
            deleverageData.swapData[0].slippage = 0.005e18; // 0.5%
            deleverageData.swapData[0].call = odosCallData;
            deleverageData.repayAmount = daiOutAmount + (minDaiOut / 10) * 9;
        }

        pUSDCDAI.approve(address(positionManagement), type(uint256).max);
        positionManagement.deleverage(deleverageData, 0.05e18);

        (uint256 eDAIBalance, uint256 eDAIBorrowed, ) = eDAI.getSnapshot(user);
        assertEq(eDAIBalance, 0);
        assertEq(
            eDAIBorrowed,
            eDAIBorrowedBefore - deleverageData.repayAmount
        );

        (uint256 pUSDCDAIBalance, uint256 pUSDCDAIBorrowed, ) = pUSDCDAI
            .getSnapshot(user);
        assertEq(
            pUSDCDAIBalance,
            pUSDCDAIBalanceBefore - deleverageData.collateralAmount
        );
        assertEq(pUSDCDAIBorrowed, 0);

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

        // mint eDAI
        dai.approve(address(eDAI), 20000000 ether);
        eDAI.mint(20000000 ether);

        // mint pUSDCDAI
        IERC20(_VELODROME_DAI_USDC).approve(address(pUSDCDAI), 1 ether);
        pUSDCDAI.deposit(1 ether, liquidityProvider);

        vm.stopPrank();
    }
}
