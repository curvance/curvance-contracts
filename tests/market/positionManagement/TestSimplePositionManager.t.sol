// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { SimplePositionManager } from "contracts/market/position-management/SimplePositionManager.sol";
import { SimplePToken } from "contracts/market/token/SimplePToken.sol";
import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IEToken } from "contracts/interfaces/IEToken.sol";
import { IPToken } from "contracts/interfaces/IPToken.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

contract TestSimplePositionManager is TestBaseMarketIsolated {
    address public owner;
    address public user;

    SimplePositionManager public positionManagement;

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
            marketManagerIsolated.listToken(address(eDAI));
        }

        // deploy simple pToken
        {
            _deployPUSDC();
            _prepareUSDC(owner, 100e6);
            usdc.approve(address(pUSDC), 100e6);
            marketManagerIsolated.listToken(address(pUSDC));
            oracleManager.addMTokenSupport(address(pUSDC));
            marketManagerIsolated.updatePositionToken(
                address(pUSDC),
                7000,
                4000, // liquidate at 71%
                3000,
                200, // 2% liq incentive
                400,
                1000
            );

            address[] memory mTokens = new address[](1);
            mTokens[0] = address(pUSDC);
            uint256[] memory caps = new uint256[](1);
            caps[0] = 100 ether;
            marketManagerIsolated.setCollateralCaps(mTokens, caps);
        }

        positionManagement = new SimplePositionManager(
            ICentralRegistry(address(centralRegistry)),
            address(marketManagerIsolated),
            _WETH_ADDRESS
        );

        marketManagerIsolated.addPositionManager(address(positionManagement));

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
            address(marketManagerIsolated)
        );
    }

    function testLeverage() public {
        vm.startPrank(user);

        deal(address(usdc), user, 1000e6);
        usdc.approve(address(pUSDC), 1000e6);

        // mint
        assertGt(pUSDC.mint(1000e6, user), 0);
        pUSDC.postCollateral(1000e6);
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

        SimplePositionManager.LeverageStruct memory leverageData;
        leverageData.borrowToken = IEToken(address(eDAI));
        leverageData.borrowAmount = amountForLeverage;
        leverageData.positionToken = IPToken(address(pUSDC));
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

        (,,,, uint256 eDAIBorrowed, ) = eDAI.getSnapshot(user);
        assertEq(eDAI.balanceOf(user), 0);
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

        SimplePositionManager.LeverageStruct memory leverageData;
        leverageData.borrowToken = IEToken(address(eDAI));
        leverageData.borrowAmount = amountForLeverage;
        leverageData.positionToken = IPToken(address(pUSDC));
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

        (,,,, uint256 eDAIBorrowed, ) = eDAI.getSnapshot(user);
        assertEq(eDAI.balanceOf(user), 0);
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
        (,,,, uint256 eDAIBorrowedBefore, ) = eDAI.getSnapshot(user);
        (uint256 pUSDCBalanceBefore, , ) = pUSDC.getSnapshot(user);

        SimplePositionManager.DeleverageStruct memory deleverageData;
        deleverageData.positionToken = IPToken(address(pUSDC));
        deleverageData.collateralAmount = 900e6;
        deleverageData.borrowToken = IEToken(address(eDAI));
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

        (,,,, uint256 eDAIBorrowed, ) = eDAI.getSnapshot(user);
        assertEq(eDAI.balanceOf(user), 0);
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
        pUSDC.postCollateral(1000e6);
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

        SimplePositionManager.LeverageStruct memory leverageData;
        leverageData.borrowToken = IEToken(address(eDAI));
        leverageData.borrowAmount = amountForLeverage;
        leverageData.positionToken = IPToken(address(pUSDC));
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

        (,,,, uint256 eDAIBorrowed, ) = eDAI.getSnapshot(user);
        assertEq(eDAI.balanceOf(user), 0);
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
        (,,,, uint256 eDAIBorrowedBefore, ) = eDAI.getSnapshot(user);
        (uint256 pUSDCBalanceBefore, , ) = pUSDC.getSnapshot(user);

        SimplePositionManager.DeleverageStruct memory deleverageData;
        deleverageData.positionToken = IPToken(address(pUSDC));
        deleverageData.collateralAmount = 900e6;
        deleverageData.borrowToken = IEToken(address(eDAI));
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

        (,,,, uint256 eDAIBorrowed, ) = eDAI.getSnapshot(user);
        assertEq(eDAI.balanceOf(user), 0);
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

    function testRevert_LeverageInvalidSwapTarget() public {
        vm.startPrank(user);
        
        deal(address(usdc), user, 1000e6);
        usdc.approve(address(pUSDC), 1000e6);
        
        pUSDC.mint(1000e6, user);
        pUSDC.postCollateral(1000e6);
        
        eDAI.borrow(100 ether);
        
        uint256 amountForLeverage = (positionManagement.maxRemainingLeverageOf(
            user,
            address(eDAI)
        ) * 50) / 100;
        
        SimplePositionManager.LeverageStruct memory leverageData;
        leverageData.borrowToken = IEToken(address(eDAI));
        leverageData.borrowAmount = amountForLeverage;
        leverageData.positionToken = IPToken(address(pUSDC));
        leverageData.swapData.inputToken = address(dai);
        leverageData.swapData.inputAmount = amountForLeverage;
        leverageData.swapData.outputToken = address(usdc);
        leverageData.swapData.target = address(0); // Invalid target
        
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
        
        // Should revert with InvalidSwapperParam
        vm.expectRevert(bytes4(keccak256("BasePositionManager__InvalidSwapperParam()")));
        positionManagement.leverage(leverageData, 0.05e18);
        
        vm.stopPrank();
    }

    function testRevert_DeleverageInvalidSwapTarget() public {
        testLeverage();
        
        // Warp until collateral posting wait time ends
        vm.warp(block.timestamp + 20 minutes);
        eDAI.accrueInterest();
        
        vm.startPrank(user);
        
        SimplePositionManager.DeleverageStruct memory deleverageData;
        deleverageData.positionToken = IPToken(address(pUSDC));
        deleverageData.collateralAmount = 900e6;
        deleverageData.borrowToken = IEToken(address(eDAI));
        deleverageData.swapData = new SwapperLib.Swap[](1);
        deleverageData.swapData[0].inputToken = address(usdc);
        deleverageData.swapData[0].inputAmount = 900e6;
        deleverageData.swapData[0].outputToken = address(dai);
        deleverageData.swapData[0].target = address(0); // Invalid target
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
        
        // Should revert with InvalidSwapperParam
        vm.expectRevert(bytes4(keccak256("BasePositionManager__InvalidSwapperParam()")));
        positionManagement.deleverage(deleverageData, 0.05e18);
        
        vm.stopPrank();
    }

    function testRevert_LeverageInvalidInputToken() public {
        vm.startPrank(user);
        
        deal(address(usdc), user, 1000e6);
        usdc.approve(address(pUSDC), 1000e6);
        
        pUSDC.mint(1000e6, user);
        pUSDC.postCollateral(1000e6);
        
        // borrow
        eDAI.borrow(100 ether);
        
        uint256 amountForLeverage = (positionManagement.maxRemainingLeverageOf(
            user,
            address(eDAI)
        ) * 50) / 100;
        
        SimplePositionManager.LeverageStruct memory leverageData;
        leverageData.borrowToken = IEToken(address(eDAI));
        leverageData.borrowAmount = amountForLeverage;
        leverageData.positionToken = IPToken(address(pUSDC));
        leverageData.swapData.inputToken = address(usdc); // incorrect input token
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
        
        // This should revert with InvalidSwapperParam
        vm.expectRevert(bytes4(keccak256("BasePositionManager__InvalidSwapperParam()")));
        positionManagement.leverage(leverageData, 0.05e18);
        
        vm.stopPrank();
    }

    function testRevert_DeleverageInvalidInputToken() public {
        testLeverage();
        
        // Warp until collateral posting wait time ends
        vm.warp(block.timestamp + 20 minutes);
        eDAI.accrueInterest();
        
        vm.startPrank(user);
        
        SimplePositionManager.DeleverageStruct memory deleverageData;
        deleverageData.positionToken = IPToken(address(pUSDC));
        deleverageData.collateralAmount = 900e6;
        deleverageData.borrowToken = IEToken(address(eDAI));
        deleverageData.swapData = new SwapperLib.Swap[](1);
        deleverageData.swapData[0].inputToken = address(dai); // Incorrect input token (should be USDC)
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
        
        // Should revert with InvalidSwapperParam
        vm.expectRevert(bytes4(keccak256("BasePositionManager__InvalidSwapperParam()")));
        positionManagement.deleverage(deleverageData, 0.05e18);
        
        vm.stopPrank();
    }

    function testRevert_LeverageInvalidOutputToken() public {
        vm.startPrank(user);
        
        deal(address(usdc), user, 1000e6);
        usdc.approve(address(pUSDC), 1000e6);
        
        pUSDC.mint(1000e6, user);
        pUSDC.postCollateral(1000e6);
        
        // borrow
        eDAI.borrow(100 ether);
        
        uint256 amountForLeverage = (positionManagement.maxRemainingLeverageOf(
            user,
            address(eDAI)
        ) * 50) / 100;
        
        SimplePositionManager.LeverageStruct memory leverageData;
        leverageData.borrowToken = IEToken(address(eDAI));
        leverageData.borrowAmount = amountForLeverage;
        leverageData.positionToken = IPToken(address(pUSDC));
        leverageData.swapData.inputToken = address(dai);
        leverageData.swapData.inputAmount = amountForLeverage;
        leverageData.swapData.outputToken = address(dai); // incorrect output token
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
        
        // Should revert with InvalidSwapperParam
        vm.expectRevert(bytes4(keccak256("BasePositionManager__InvalidSwapperParam()")));
        positionManagement.leverage(leverageData, 0.05e18);
        
        vm.stopPrank();
    }

    function testRevert_LeverageInvalidInputAmount() public {
        vm.startPrank(user);
        
        deal(address(usdc), user, 1000e6);
        usdc.approve(address(pUSDC), 1000e6);
        
        pUSDC.mint(1000e6, user);
        pUSDC.postCollateral(1000e6);
        
        // borrow
        eDAI.borrow(100 ether);
        
        uint256 amountForLeverage = (positionManagement.maxRemainingLeverageOf(
            user,
            address(eDAI)
        ) * 50) / 100;
        
        SimplePositionManager.LeverageStruct memory leverageData;
        leverageData.borrowToken = IEToken(address(eDAI));
        leverageData.borrowAmount = amountForLeverage;
        leverageData.positionToken = IPToken(address(pUSDC));
        leverageData.swapData.inputToken = address(dai);
        leverageData.swapData.inputAmount = amountForLeverage - 1; // incorrect input amount
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
        
        // Should revert with InvalidSwapperParam
        vm.expectRevert(bytes4(keccak256("BasePositionManager__InvalidSwapperParam()")));
        positionManagement.leverage(leverageData, 0.05e18);
        
        vm.stopPrank();
    }

    function testRevert_DeleverageInvalidInputAmount() public {
        testLeverage();
        
        // Warp until collateral posting wait time ends
        vm.warp(block.timestamp + 20 minutes);
        eDAI.accrueInterest();
        
        vm.startPrank(user);
        
        SimplePositionManager.DeleverageStruct memory deleverageData;
        deleverageData.positionToken = IPToken(address(pUSDC));
        deleverageData.collateralAmount = 900e6;
        deleverageData.borrowToken = IEToken(address(eDAI));
        deleverageData.swapData = new SwapperLib.Swap[](1);
        deleverageData.swapData[0].inputToken = address(usdc);
        deleverageData.swapData[0].inputAmount = 800e6; // Incorrect amount (should match collateralAmount)
        deleverageData.swapData[0].outputToken = address(dai);
        deleverageData.swapData[0].target = address(_UNISWAP_V2_ROUTER);
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(dai);
        deleverageData.swapData[0].call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            800e6,
            0,
            path,
            address(positionManagement),
            block.timestamp
        );
        deleverageData.swapData[0].slippage = 0.3e18;
        deleverageData.repayAmount = 890 ether;
        
        // Should revert with InvalidSwapperParam
        vm.expectRevert(bytes4(keccak256("BasePositionManager__InvalidSwapperParam()")));
        positionManagement.deleverage(deleverageData, 0.05e18);
        
        vm.stopPrank();
    }

    function testRevert_LeverageInvalidSwapDataLength() public {
        vm.startPrank(user);
        
        deal(address(usdc), user, 1000e6);
        usdc.approve(address(pUSDC), 1000e6);
        
        pUSDC.mint(1000e6, user);
        pUSDC.postCollateral(1000e6);
        
        // borrow
        eDAI.borrow(100 ether);
        
        uint256 amountForLeverage = (positionManagement.maxRemainingLeverageOf(
            user,
            address(eDAI)
        ) * 50) / 100;
        
        SimplePositionManager.LeverageStruct memory leverageData;
        leverageData.borrowToken = IEToken(address(eDAI));
        leverageData.borrowAmount = amountForLeverage;
        leverageData.positionToken = IPToken(address(pUSDC));
        leverageData.swapData.inputToken = address(dai);
        leverageData.swapData.inputAmount = amountForLeverage;
        leverageData.swapData.outputToken = address(usdc);
        leverageData.swapData.target = address(_UNISWAP_V2_ROUTER);
        leverageData.swapData.call = bytes(""); // Empty call data
        leverageData.swapData.slippage = 0.3e18;
        
        // Should revert with InvalidSwapperParam
        vm.expectRevert(bytes4(keccak256("BasePositionManager__InvalidSwapperParam()")));
        positionManagement.leverage(leverageData, 0.05e18);
        
        vm.stopPrank();
    }

    function testRevert_DeleverageInvalidSwapDataLength() public {
        testLeverage();
        
        // Warp until collateral posting wait time ends
        vm.warp(block.timestamp + 20 minutes);
        eDAI.accrueInterest();
        
        vm.startPrank(user);
        
        SimplePositionManager.DeleverageStruct memory deleverageData;
        deleverageData.positionToken = IPToken(address(pUSDC));
        deleverageData.collateralAmount = 900e6;
        deleverageData.borrowToken = IEToken(address(eDAI));
        deleverageData.swapData = new SwapperLib.Swap[](0); // Empty array
        deleverageData.repayAmount = 890 ether;
        
        // Should revert with InvalidSwapperParam
        vm.expectRevert(bytes4(keccak256("BasePositionManager__InvalidSwapperParam()")));
        positionManagement.deleverage(deleverageData, 0.05e18);
        
        vm.stopPrank();
    }

    function testRevert_LeverageExcessiveSlippage() public {
        vm.startPrank(user);
        
        deal(address(usdc), user, 1000e6);
        usdc.approve(address(pUSDC), 1000e6);
        
        // mint
        pUSDC.mint(1000e6, user);
        pUSDC.postCollateral(1000e6);
        
        // borrow
        eDAI.borrow(100 ether);
        
        uint256 amountForLeverage = (positionManagement.maxRemainingLeverageOf(
            user,
            address(eDAI)
        ) * 50) / 100;
        
        SimplePositionManager.LeverageStruct memory leverageData;
        leverageData.borrowToken = IEToken(address(eDAI));
        leverageData.borrowAmount = amountForLeverage;
        leverageData.positionToken = IPToken(address(pUSDC));
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
            amountForLeverage * 1e12, // Very high min amount out, which will fail
            path,
            address(positionManagement),
            block.timestamp
        );
        leverageData.swapData.slippage = 0.3e18;
        
        // We use a tiny slippage tolerance to revert
        vm.expectRevert();
        positionManagement.leverage(leverageData, 0.00001e18); // Very low slippage tolerance
        
        vm.stopPrank();
    }

    function testRevert_LeverageForWithoutPermission() public {
        vm.startPrank(user);
        
        // Set up the collateral and position
        deal(address(usdc), user, 1000e6);
        usdc.approve(address(pUSDC), 1000e6);
        pUSDC.mint(1000e6, user);
        pUSDC.postCollateral(1000e6);
        eDAI.borrow(100 ether);
        
        // Do not set delegate approval for user2

        vm.stopPrank();
        
        // Set up leverage data
        uint256 amountForLeverage = (positionManagement.maxRemainingLeverageOf(
            user,
            address(eDAI)
        ) * 50) / 100;
        
        SimplePositionManager.LeverageStruct memory leverageData;
        leverageData.borrowToken = IEToken(address(eDAI));
        leverageData.borrowAmount = amountForLeverage;
        leverageData.positionToken = IPToken(address(pUSDC));
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
        
        // user2 tries to leverage for user without permission
        vm.startPrank(user2);
        vm.expectRevert(bytes4(keccak256("PluginDelegable__Unauthorized()")));
        positionManagement.leverageFor(leverageData, user, 0.05e18);
        vm.stopPrank();
    }


    function testRevert_DeleverageForWithoutPermission() public {
        testLeverage();
        
        // Warp until collateral posting wait time ends
        vm.warp(block.timestamp + 20 minutes);
        eDAI.accrueInterest();
        
        vm.startPrank(user);
        
        // Deleverage data
        SimplePositionManager.DeleverageStruct memory deleverageData;
        deleverageData.positionToken = IPToken(address(pUSDC));
        deleverageData.collateralAmount = 900e6;
        deleverageData.borrowToken = IEToken(address(eDAI));
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
        
        // Do not set delegate approval for user2
        vm.stopPrank();
        
        // user2 tries to deleverage for user without permission
        vm.startPrank(user2);
        vm.expectRevert(bytes4(keccak256("PluginDelegable__Unauthorized()")));
        positionManagement.deleverageFor(deleverageData, user, 0.05e18);
        vm.stopPrank();
    }

    function testSetAndRevokeDelegate() public {
        vm.startPrank(user);

        // At this point, user2 should not have delegation
        assertFalse(positionManagement.isDelegate(user, address(user2)));

        positionManagement.setDelegateApproval(address(user2), true);
        
        // Verify delegation was set
        assertTrue(positionManagement.isDelegate(user, address(user2)));
        
        // Set up leverage operation
        deal(address(usdc), user, 1000e6);
        usdc.approve(address(pUSDC), 1000e6);
        pUSDC.mint(1000e6, user);
        pUSDC.postCollateral(1000e6);
        eDAI.borrow(100 ether);
        
        vm.stopPrank();

        uint256 amountForLeverage = (positionManagement.maxRemainingLeverageOf(
            user,
            address(eDAI)
        ) * 50) / 100;
        
        SimplePositionManager.LeverageStruct memory leverageData;
        leverageData.borrowToken = IEToken(address(eDAI));
        leverageData.borrowAmount = amountForLeverage;
        leverageData.positionToken = IPToken(address(pUSDC));
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

        
        // user2 is able to leverage on behalf of user
        vm.startPrank(user2);
        positionManagement.leverageFor(leverageData, user, 0.05e18);
        vm.stopPrank();
        
        // Revoke the delegation
        vm.startPrank(user);
        positionManagement.setDelegateApproval(address(user2), false);
        
        // Verify delegation was revoked
        assertFalse(positionManagement.isDelegate(user, address(user2)));
        vm.stopPrank();
        
        // user2 is not able to leverage on behalf of user anymore
        vm.startPrank(user2);
        vm.expectRevert(bytes4(keccak256("PluginDelegable__Unauthorized()")));
        positionManagement.leverageFor(leverageData, user, 0.05e18);
        vm.stopPrank();
    }


}
