// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IMToken } from "contracts/market/LiquidityManager.sol";
import { PositionManagementSimple } from "contracts/market/position-management/PositionManagementSimple.sol";
import { SimplePToken, IERC20 } from "contracts/market/token/SimplePToken.sol";
import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";

contract TestPositionManagementSimple is TestBaseMarket {
    address public owner;
    address public user;

    SimplePToken public pUSDC;
    PositionManagementSimple public positionManagement;

    receive() external payable {}

    fallback() external payable {}

    // this is to use address(this) as mock cToken address
    function tokenType() external pure returns (uint256) {
        return 1;
    }

    function setUp() public override {
        super.setUp();

        owner = address(this);
        user = user1;

        centralRegistry.setExternalCalldataChecker(
            _UNISWAP_V2_ROUTER,
            address(new MockCalldataChecker(_UNISWAP_V2_ROUTER))
        );

        // setup eDAI
        {
            _deployEDAI();
            // add MToken support on price router
            oracleManager.addMTokenSupport(address(eDAI));

            _prepareDAI(owner, 200000e18);
            dai.approve(address(eDAI), 200000e18);
            marketManager.listToken(address(eDAI));
        }

        // deploy simple pToken
        {
            pUSDC = new SimplePToken(
                ICentralRegistry(address(centralRegistry)),
                IERC20(address(usdc)),
                address(marketManager)
            );

            _prepareUSDC(owner, 100e6);
            usdc.approve(address(pUSDC), 100e6);
            marketManager.listToken(address(pUSDC));
            oracleManager.addMTokenSupport(address(pUSDC));
            marketManager.updatePositionToken(
                IMToken(address(pUSDC)),
                7000,
                4000, // liquidate at 71%
                3000,
                200, // 2% liq incentive
                400,
                0,
                1000
            );

            address[] memory mTokens = new address[](1);
            mTokens[0] = address(pUSDC);
            uint256[] memory caps = new uint256[](1);
            caps[0] = 100 ether;
            marketManager.setPTokenCollateralCaps(mTokens, caps);
        }

        positionManagement = new PositionManagementSimple(
            ICentralRegistry(address(centralRegistry)),
            address(marketManager)
        );

        marketManager.setPositionManagement(address(positionManagement));

        _provideEnoughLiquidityForLeverage();
    }

    function _provideEnoughLiquidityForLeverage() internal {
        address liquidityProvider = makeAddr("liquidityProvider");

        _prepareUSDC(liquidityProvider, 100e6);
        _prepareDAI(liquidityProvider, 20000000e18);

        vm.startPrank(liquidityProvider);

        // mint eDAI
        dai.approve(address(eDAI), 20000000 ether);
        eDAI.mint(20000000 ether);

        // mint pUSDC
        usdc.approve(address(pUSDC), 100e6);
        pUSDC.mint(100e6, liquidityProvider);

        vm.stopPrank();
    }

    function testInitialize() public {
        assertEq(
            address(positionManagement.centralRegistry()),
            address(centralRegistry)
        );
        assertEq(
            address(positionManagement.marketManager()),
            address(marketManager)
        );
    }

    function testLeverage() public {
        vm.startPrank(user);

        deal(address(usdc), user, 1000e6);
        usdc.approve(address(pUSDC), 1000e6);

        // mint
        assertGt(pUSDC.mint(1000e6, user), 0);
        marketManager.postCollateral(user, address(pUSDC), 1000e6);
        assertEq(pUSDC.balanceOf(user), 1000e6);

        uint256 balanceBeforeBorrow = dai.balanceOf(user);
        // borrow
        eDAI.borrow(100 ether);
        assertEq(dai.balanceOf(user), balanceBeforeBorrow + 100 ether);

        // try leverage with 50% of max
        uint256 amountForLeverage = (positionManagement.maxRemainingLeverageOf(
            user,
            address(eDAI)
        ) * 50) / 100;

        PositionManagementSimple.LeverageStruct memory leverageData;
        leverageData.borrowToken = eDAI;
        leverageData.borrowAmount = amountForLeverage;
        leverageData.positionToken = SimplePToken(address(pUSDC));
        leverageData.swapData.inputToken = address(dai);
        leverageData.swapData.inputAmount = amountForLeverage;
        leverageData.swapData.outputToken = address(usdc);
        leverageData.swapData.target = address(_UNISWAP_V2_ROUTER);
        address[] memory path = new address[](2);
        path[0] = address(dai);
        path[1] = address(usdc);
        leverageData.swapData.call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            amountForLeverage,
            0,
            path,
            address(positionManagement),
            block.timestamp
        );
        leverageData.swapData.slippage = 0.3e18;

        positionManagement.leverage(leverageData, 0.05e18); // 5% slippage

        (uint256 eDAIBalance, uint256 eDAIBorrowed, ) = eDAI.getSnapshot(user);
        assertEq(eDAIBalance, 0);
        assertEq(eDAIBorrowed, 100 ether + amountForLeverage);

        (uint256 pUSDCBalance, uint256 pUSDCBorrowed, ) = pUSDC.getSnapshot(
            user
        );
        assertGt(pUSDCBalance, 1900e6);
        assertEq(pUSDCBorrowed, 0);

        vm.stopPrank();
    }

    function testDepositAndLeverage() public {
        vm.startPrank(user);

        deal(address(usdc), user, 1000e6);
        usdc.approve(address(positionManagement), 1000e6);

        // allow delegation for postCollateral
        pUSDC.setDelegateApproval(address(positionManagement), true);

        // try leverage with 50% of max
        uint256 amountForLeverage = 0.99e21;

        PositionManagementSimple.LeverageStruct memory leverageData;
        leverageData.borrowToken = eDAI;
        leverageData.borrowAmount = amountForLeverage;
        leverageData.positionToken = SimplePToken(address(pUSDC));
        leverageData.swapData.inputToken = address(dai);
        leverageData.swapData.inputAmount = amountForLeverage;
        leverageData.swapData.outputToken = address(usdc);
        leverageData.swapData.target = address(_UNISWAP_V2_ROUTER);
        address[] memory path = new address[](2);
        path[0] = address(dai);
        path[1] = address(usdc);
        leverageData.swapData.call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            amountForLeverage,
            0,
            path,
            address(positionManagement),
            block.timestamp
        );
        leverageData.swapData.slippage = 0.3e18;

        positionManagement.depositAndLeverage(1000e6, leverageData, 0.05e18); // 5% slippage

        (uint256 eDAIBalance, uint256 eDAIBorrowed, ) = eDAI.getSnapshot(user);
        assertEq(eDAIBalance, 0);
        assertEq(eDAIBorrowed, amountForLeverage);

        (uint256 pUSDCBalance, uint256 pUSDCBorrowed, ) = pUSDC.getSnapshot(
            user
        );
        assertGt(pUSDCBalance, 1900e6);
        assertEq(pUSDCBorrowed, 0);

        vm.stopPrank();
    }

    function testDeLeverage() public {
        testLeverage();
        // Warp until collateral posting wait time ends
        vm.warp(block.timestamp + 20 minutes);
        eDAI.accrueInterest();

        vm.startPrank(user);
        (, uint256 eDAIBorrowedBefore, ) = eDAI.getSnapshot(user);
        (uint256 pUSDCBalanceBefore, , ) = pUSDC.getSnapshot(user);

        PositionManagementSimple.DeleverageStruct memory deleverageData;
        deleverageData.positionToken = SimplePToken(address(pUSDC));
        deleverageData.collateralAmount = 900e6;
        deleverageData.borrowToken = eDAI;
        deleverageData.swapData = new SwapperLib.Swap[](1);
        deleverageData.swapData[0].inputToken = address(usdc);
        deleverageData.swapData[0].inputAmount = 900e6;
        deleverageData.swapData[0].outputToken = address(dai);
        deleverageData.swapData[0].target = address(_UNISWAP_V2_ROUTER);
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(dai);
        deleverageData.swapData[0].call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            900e6,
            0,
            path,
            address(positionManagement),
            block.timestamp
        );
        deleverageData.swapData[0].slippage = 0.3e18;
        deleverageData.repayAmount = 890 ether;
        positionManagement.deleverage(deleverageData, 0.05e18); // 5% slippage

        (uint256 eDAIBalance, uint256 eDAIBorrowed, ) = eDAI.getSnapshot(user);
        assertEq(eDAIBalance, 0);
        assertEq(
            eDAIBorrowed,
            eDAIBorrowedBefore - deleverageData.repayAmount
        );

        (uint256 pUSDCBalance, uint256 pUSDCBorrowed, ) = pUSDC.getSnapshot(
            user
        );
        assertEq(
            pUSDCBalance,
            pUSDCBalanceBefore - deleverageData.collateralAmount
        );
        assertEq(pUSDCBorrowed, 0);

        vm.stopPrank();
    }

    function testLeverageFor() public {
        vm.startPrank(user);

        deal(address(usdc), user, 1000e6);
        usdc.approve(address(pUSDC), 1000e6);

        // mint
        assertGt(pUSDC.mint(1000e6, user), 0);
        marketManager.postCollateral(user, address(pUSDC), 1000e6);
        assertEq(pUSDC.balanceOf(user), 1000e6);

        uint256 balanceBeforeBorrow = dai.balanceOf(user);
        // borrow
        eDAI.borrow(100 ether);
        assertEq(dai.balanceOf(user), balanceBeforeBorrow + 100 ether);

        // try leverage with 50% of max
        uint256 amountForLeverage = (positionManagement.maxRemainingLeverageOf(
            user,
            address(eDAI)
        ) * 50) / 100;

        PositionManagementSimple.LeverageStruct memory leverageData;
        leverageData.borrowToken = eDAI;
        leverageData.borrowAmount = amountForLeverage;
        leverageData.positionToken = SimplePToken(address(pUSDC));
        leverageData.swapData.inputToken = address(dai);
        leverageData.swapData.inputAmount = amountForLeverage;
        leverageData.swapData.outputToken = address(usdc);
        leverageData.swapData.target = address(_UNISWAP_V2_ROUTER);
        address[] memory path = new address[](2);
        path[0] = address(dai);
        path[1] = address(usdc);
        leverageData.swapData.call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            amountForLeverage,
            0,
            path,
            address(positionManagement),
            block.timestamp
        );
        leverageData.swapData.slippage = 0.3e18;

        positionManagement.setDelegateApproval(address(user2), true);
        vm.stopPrank();

        vm.prank(user2);
        positionManagement.leverageFor(leverageData, user, 0.05e18); // 5% slippage

        (uint256 eDAIBalance, uint256 eDAIBorrowed, ) = eDAI.getSnapshot(user);
        assertEq(eDAIBalance, 0);
        assertEq(eDAIBorrowed, 100 ether + amountForLeverage);

        (uint256 pUSDCBalance, uint256 pUSDCBorrowed, ) = pUSDC.getSnapshot(
            user
        );
        assertGt(pUSDCBalance, 1900e6);
        assertEq(pUSDCBorrowed, 0);

        vm.stopPrank();
    }

    function testDeLeverageFor() public {
        testLeverage();

        // Warp until collateral posting wait time ends
        vm.warp(block.timestamp + 20 minutes);
        eDAI.accrueInterest();

        vm.startPrank(user);
        (, uint256 eDAIBorrowedBefore, ) = eDAI.getSnapshot(user);
        (uint256 pUSDCBalanceBefore, , ) = pUSDC.getSnapshot(user);

        PositionManagementSimple.DeleverageStruct memory deleverageData;
        deleverageData.positionToken = SimplePToken(address(pUSDC));
        deleverageData.collateralAmount = 900e6;
        deleverageData.borrowToken = eDAI;
        deleverageData.swapData = new SwapperLib.Swap[](1);
        deleverageData.swapData[0].inputToken = address(usdc);
        deleverageData.swapData[0].inputAmount = 900e6;
        deleverageData.swapData[0].outputToken = address(dai);
        deleverageData.swapData[0].target = address(_UNISWAP_V2_ROUTER);
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(dai);
        deleverageData.swapData[0].call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            900e6,
            0,
            path,
            address(positionManagement),
            block.timestamp
        );
        deleverageData.swapData[0].slippage = 0.3e18;
        deleverageData.repayAmount = 890 ether;
        pUSDC.approve(address(positionManagement), type(uint256).max);

        positionManagement.setDelegateApproval(address(user2), true);
        vm.stopPrank();

        vm.prank(user2);
        positionManagement.deleverageFor(deleverageData, user, 0.05e18); // 5% slippage

        (uint256 eDAIBalance, uint256 eDAIBorrowed, ) = eDAI.getSnapshot(user);
        assertEq(eDAIBalance, 0);
        assertEq(
            eDAIBorrowed,
            eDAIBorrowedBefore - deleverageData.repayAmount
        );

        (uint256 pUSDCBalance, uint256 pUSDCBorrowed, ) = pUSDC.getSnapshot(
            user
        );
        assertEq(
            pUSDCBalance,
            pUSDCBalanceBefore - deleverageData.collateralAmount
        );
        assertEq(pUSDCBorrowed, 0);

        vm.stopPrank();
    }
}
