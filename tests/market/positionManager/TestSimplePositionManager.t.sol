// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { SimplePositionManager } from "contracts/market/position-management/SimplePositionManager.sol";
import { SimpleCToken } from "contracts/market/token/SimpleCToken.sol";
import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";
import { MockSimpleCToken } from "contracts/mocks/MockSimpleCToken.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { ICToken, AccountSnapshot } from "contracts/interfaces/ICToken.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IUniswapV2Router } from "contracts/interfaces/external/uniswap/IUniswapV2Router.sol";
import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { BasePositionManager } from "contracts/market/position-management/BasePositionManager.sol";

contract TestSimplePositionManager is TestBaseMarketIsolated {
    address public owner;
    address public user;

    SimplePositionManager public positionManager;
    MockSimpleCToken internal unlistedCToken;

    receive() external payable {}

    fallback() external payable {}

    function setUp() public override {
        super.setUp();

        owner = address(this);
        user = user1;

        centralRegistry.setExternalCalldataChecker(
            _UNISWAP_V2_ROUTER,
            address(new MockCalldataChecker(_UNISWAP_V2_ROUTER))
        );

        // Setup borrowable cDAI.
        {
            
            // Add cToken support on Oracle Manager.
            

            _prepareDAI(owner, 200000e18);
            dai.approve(address(borrowableCDAI), 200000e18);
        }

        // Setup borrowable cUSDC.
        {
            _deployBorrowableCUSDC();
            _prepareUSDC(owner, 100e6);
            usdc.approve(address(borrowableCUSDC), 100e6);
            oracleManager.addCTokenSupport(address(borrowableCUSDC));
        }

        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(borrowableCDAI));

         _setCTokenConfigBasic(address(borrowableCUSDC), 100_000e18, 100_000e18);
         _setCTokenConfigBasic(address(borrowableCDAI), 100_000e18, 100_000e18);

        positionManager = new SimplePositionManager(
            ICentralRegistry(address(centralRegistry)),
            address(marketManagerIsolated),
            _WETH_ADDRESS
        );

        marketManagerIsolated.addPositionManager(address(positionManager));

        _provideEnoughLiquidityForLeverage();

        unlistedCToken = new MockSimpleCToken(
            ICentralRegistry(address(centralRegistry)),
            address(usdc),
            address(marketManagerIsolated)
        );
    }

    function testRevert_LeverageInvalidSwapTarget() public {
        vm.startPrank(user);
        
        deal(address(usdc), user, 1000e6);
        usdc.approve(address(borrowableCUSDC), 1000e6);
        
        // Mint borrowable cUSDC.
        borrowableCUSDC.deposit(1000e6, user);
        borrowableCUSDC.postCollateral(1000e6);
        
        // Borrow borrowable cDAI.
        borrowableCDAI.borrow(100 ether, user);
        
        // Try leveraging with 50% of limit.
        uint256 amountForLeverage = _maxRemainingLeverageOfHelper(
            user,
            address(borrowableCDAI)
        ) / 2;
        
        SimplePositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCDAI));
        leverageAction.borrowAssets = amountForLeverage;
        leverageAction.cToken = ICToken(address(borrowableCUSDC));
        leverageAction.swapAction.inputToken = address(dai);
        leverageAction.swapAction.inputAmount = amountForLeverage;
        leverageAction.swapAction.outputToken = address(usdc);
        leverageAction.swapAction.target = address(0); // Invalid target
        
        address[] memory path = new address[](2);
        path[0] = address(dai);
        path[1] = address(usdc);
        leverageAction.swapAction.call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            amountForLeverage,
            0,
            path,
            address(positionManager),
            block.timestamp
        );
        leverageAction.swapAction.slippage = 0.3e18;
        
        // Should revert with `InvalidSwapperParam`.
        vm.expectRevert(bytes4(keccak256("BasePositionManager__InvalidParam()")));
        positionManager.leverage(leverageAction, 0.05e18);
        
        vm.stopPrank();
    }

    function test_onBorrow_fail_unlistedCollateralCToken() public {
        vm.startPrank(user);

        // Setup collateral
        _prepareUSDC(user, 1_000e6);
        usdc.approve(address(borrowableCUSDC), 1_000e6);
        borrowableCUSDC.depositAsCollateral(1_000e6, user);

        SimplePositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCDAI));
        leverageAction.borrowAssets = 1 ether;
        // use unlisted cToken
        leverageAction.cToken = ICToken(address(unlistedCToken));
        
        // placeholder swap data
        leverageAction.swapAction.inputToken = address(dai);
        leverageAction.swapAction.inputAmount = leverageAction.borrowAssets;
        leverageAction.swapAction.outputToken = address(usdc);
        leverageAction.swapAction.target = address(_UNISWAP_V2_ROUTER);
        address[] memory path = new address[](2);
        path[0] = address(dai);
        path[1] = address(usdc);
        leverageAction.swapAction.call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            leverageAction.borrowAssets,
            0,
            path,
            address(positionManager),
            block.timestamp
        );
        leverageAction.swapAction.slippage = 0.3e18;

        vm.expectRevert(bytes4(keccak256("BasePositionManager__Unauthorized()")));
        positionManager.leverage(leverageAction, 0.05e18);

        vm.stopPrank();
    }

    function test_onBorrow_fail_unauthorizedCallbackBeforeAssetLookup() public {
        SimplePositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken = IBorrowableCToken(
            address(borrowableCDAI)
        );
        leverageAction.borrowAssets = 1 ether;
        leverageAction.cToken = ICToken(address(borrowableCUSDC));

        vm.expectRevert(
            BasePositionManager.BasePositionManager__Unauthorized.selector
        );
        positionManager.onBorrow(
            address(this),
            1 ether,
            user,
            leverageAction
        );
    }

    function test_onRedeem_fail_unauthorizedCallbackBeforeAssetLookup() public {
        SimplePositionManager.DeleverageAction memory deleverageAction;
        deleverageAction.cToken = ICToken(address(borrowableCUSDC));
        deleverageAction.collateralAssets = 10e6;
        deleverageAction.borrowableCToken = IBorrowableCToken(
            address(borrowableCDAI)
        );

        vm.expectRevert(
            BasePositionManager.BasePositionManager__Unauthorized.selector
        );
        positionManager.onRedeem(
            address(this),
            10e6,
            user,
            deleverageAction
        );
    }

    function test_onRedeem_fail_unlistedBorrowableCToken() public {
        vm.startPrank(user);
        deal(address(usdc), user, 1_000e6);
        usdc.approve(address(borrowableCUSDC), 1_000e6);
        borrowableCUSDC.deposit(1_000e6, user);
        borrowableCUSDC.postCollateral(1_000e6);

        SimplePositionManager.DeleverageAction memory deleverageAction;
        deleverageAction.cToken = ICToken(address(borrowableCUSDC));
        deleverageAction.collateralAssets = 10e6;
        // use unlisted cToken
        deleverageAction.borrowableCToken = IBorrowableCToken(address(unlistedCToken));
        deleverageAction.swapActions = new SwapperLib.Swap[](1);

        // placeholder swap data
        deleverageAction.swapActions[0].inputToken = address(usdc);
        deleverageAction.swapActions[0].inputAmount = 10e6;
        deleverageAction.swapActions[0].outputToken = address(dai);
        deleverageAction.swapActions[0].target = address(_UNISWAP_V2_ROUTER);
        deleverageAction.swapActions[0].call = hex"01";
        deleverageAction.swapActions[0].slippage = 0.3e18;
        deleverageAction.repayAssets = 1; // Repay as much as possible

        vm.expectRevert(bytes4(keccak256("BasePositionManager__Unauthorized()")));
        positionManager.deleverage(deleverageAction, 0.05e18);

        vm.stopPrank();
    }

    function testRevert_DeleverageInvalidSwapTarget() public {
        testLeverage();
        
        // Warp until collateralization cooldown period ends.
        vm.warp(block.timestamp + 20 minutes);
        borrowableCDAI.accrueIfNeeded();
        
        vm.startPrank(user);
        
        SimplePositionManager.DeleverageAction memory deleverageAction;
        deleverageAction.cToken = ICToken(address(borrowableCUSDC));
        deleverageAction.collateralAssets = 900e6;
        deleverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCDAI));
        deleverageAction.swapActions = new SwapperLib.Swap[](1);
        deleverageAction.swapActions[0].inputToken = address(usdc);
        deleverageAction.swapActions[0].inputAmount = 900e6;
        deleverageAction.swapActions[0].outputToken = address(dai);
        deleverageAction.swapActions[0].target = address(0); // Invalid target
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(dai);
        deleverageAction.swapActions[0].call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            900e6,
            0,
            path,
            address(positionManager),
            block.timestamp
        );
        deleverageAction.swapActions[0].slippage = 0.3e18;
        deleverageAction.repayAssets = 890 ether;
        
        // Should revert with `InvalidSwapperParam`.
        vm.expectRevert(bytes4(keccak256("BasePositionManager__InvalidParam()")));
        positionManager.deleverage(deleverageAction, 0.05e18);
        
        vm.stopPrank();
    }

    function testRevert_LeverageInvalidInputToken() public {
        vm.startPrank(user);
        
        deal(address(usdc), user, 1000e6);
        usdc.approve(address(borrowableCUSDC), 1000e6);
        
        // Mint borrowable cUSDC.
        borrowableCUSDC.deposit(1000e6, user);
        borrowableCUSDC.postCollateral(1000e6);
        
        // Borrow borrowable cDAI.
        borrowableCDAI.borrow(100 ether, user);
        
        // Try leveraging with 50% of limit.
        uint256 amountForLeverage = _maxRemainingLeverageOfHelper(
            user,
            address(borrowableCDAI)
        ) / 2;
        
        SimplePositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCDAI));
        leverageAction.borrowAssets = amountForLeverage;
        leverageAction.cToken = ICToken(address(borrowableCUSDC));
        leverageAction.swapAction.inputToken = address(usdc); // incorrect input token
        leverageAction.swapAction.inputAmount = amountForLeverage;
        leverageAction.swapAction.outputToken = address(usdc);
        leverageAction.swapAction.target = address(_UNISWAP_V2_ROUTER);
        
        address[] memory path = new address[](2);
        path[0] = address(dai);
        path[1] = address(usdc);
        leverageAction.swapAction.call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            amountForLeverage,
            0,
            path,
            address(positionManager),
            block.timestamp
        );
        leverageAction.swapAction.slippage = 0.3e18;
        
        // This should revert with `InvalidSwapperParam`.
        vm.expectRevert(bytes4(keccak256("BasePositionManager__InvalidParam()")));
        positionManager.leverage(leverageAction, 0.05e18);
        
        vm.stopPrank();
    }

    function testRevert_DeleverageInvalidInputToken() public {
        testLeverage();
        
        // Warp until collateralization cooldown period ends.
        vm.warp(block.timestamp + 20 minutes);
        borrowableCDAI.accrueIfNeeded();
        
        vm.startPrank(user);
        
        SimplePositionManager.DeleverageAction memory deleverageAction;
        deleverageAction.cToken = ICToken(address(borrowableCUSDC));
        deleverageAction.collateralAssets = 900e6;
        deleverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCDAI));
        deleverageAction.swapActions = new SwapperLib.Swap[](1);
        deleverageAction.swapActions[0].inputToken = address(dai); // Incorrect input token (should be USDC)
        deleverageAction.swapActions[0].inputAmount = 900e6;
        deleverageAction.swapActions[0].outputToken = address(dai);
        deleverageAction.swapActions[0].target = address(_UNISWAP_V2_ROUTER);
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(dai);
        deleverageAction.swapActions[0].call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            900e6,
            0,
            path,
            address(positionManager),
            block.timestamp
        );
        deleverageAction.swapActions[0].slippage = 0.3e18;
        deleverageAction.repayAssets = 890 ether;
        
        // Should revert with `InvalidSwapperParam`.
        vm.expectRevert(bytes4(keccak256("BasePositionManager__InvalidParam()")));
        positionManager.deleverage(deleverageAction, 0.05e18);
        
        vm.stopPrank();
    }

    function testRevert_LeverageInvalidOutputToken() public {
        vm.startPrank(user);
        
        deal(address(usdc), user, 1000e6);
        usdc.approve(address(borrowableCUSDC), 1000e6);
        
        // Mint borrowable cUSDC.
        borrowableCUSDC.deposit(1000e6, user);
        borrowableCUSDC.postCollateral(1000e6);
        
        // Borrow borrowable cDAI.
        borrowableCDAI.borrow(100 ether, user);
        
        // Try leveraging with 50% of limit.
        uint256 amountForLeverage = _maxRemainingLeverageOfHelper(
            user,
            address(borrowableCDAI)
        ) / 2;
        
        SimplePositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCDAI));
        leverageAction.borrowAssets = amountForLeverage;
        leverageAction.cToken = ICToken(address(borrowableCUSDC));
        leverageAction.swapAction.inputToken = address(dai);
        leverageAction.swapAction.inputAmount = amountForLeverage;
        leverageAction.swapAction.outputToken = address(dai); // incorrect output token
        leverageAction.swapAction.target = address(_UNISWAP_V2_ROUTER);
        
        address[] memory path = new address[](2);
        path[0] = address(dai);
        path[1] = address(usdc);
        leverageAction.swapAction.call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            amountForLeverage,
            0,
            path,
            address(positionManager),
            block.timestamp
        );
        leverageAction.swapAction.slippage = 0.3e18;
        
        // Should revert with `InvalidSwapperParam`.
        vm.expectRevert(bytes4(keccak256("BasePositionManager__InvalidParam()")));
        positionManager.leverage(leverageAction, 0.05e18);
        
        vm.stopPrank();
    }

    function testRevert_LeverageInvalidInputAmount() public {
        vm.startPrank(user);
        
        deal(address(usdc), user, 1000e6);
        usdc.approve(address(borrowableCUSDC), 1000e6);
        
        // Mint borrowable cUSDC.
        borrowableCUSDC.deposit(1000e6, user);
        borrowableCUSDC.postCollateral(1000e6);
        
        // Borrow borrowable cDAI.
        borrowableCDAI.borrow(100 ether, user);
        
        // Try leveraging with 50% of limit.
        uint256 amountForLeverage = _maxRemainingLeverageOfHelper(
            user,
            address(borrowableCDAI)
        ) / 2;
        
        SimplePositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCDAI));
        leverageAction.borrowAssets = amountForLeverage;
        leverageAction.cToken = ICToken(address(borrowableCUSDC));
        leverageAction.swapAction.inputToken = address(dai);
        leverageAction.swapAction.inputAmount = amountForLeverage - 1; // incorrect input amount
        leverageAction.swapAction.outputToken = address(usdc);
        leverageAction.swapAction.target = address(_UNISWAP_V2_ROUTER);
        
        address[] memory path = new address[](2);
        path[0] = address(dai);
        path[1] = address(usdc);
        leverageAction.swapAction.call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            amountForLeverage,
            0,
            path,
            address(positionManager),
            block.timestamp
        );
        leverageAction.swapAction.slippage = 0.3e18;
        
        // Should revert with `InvalidSwapperParam`.
        vm.expectRevert(bytes4(keccak256("BasePositionManager__InvalidParam()")));
        positionManager.leverage(leverageAction, 0.05e18);
        
        vm.stopPrank();
    }

    function testRevert_DeleverageInvalidInputAmount() public {
        testLeverage();
        
        // Warp until collateralization cooldown period ends.
        vm.warp(block.timestamp + 20 minutes);
        borrowableCDAI.accrueIfNeeded();
        
        vm.startPrank(user);
        
        SimplePositionManager.DeleverageAction memory deleverageAction;
        deleverageAction.cToken = ICToken(address(borrowableCUSDC));
        deleverageAction.collateralAssets = 900e6;
        deleverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCDAI));
        deleverageAction.swapActions = new SwapperLib.Swap[](1);
        deleverageAction.swapActions[0].inputToken = address(usdc);
        deleverageAction.swapActions[0].inputAmount = 800e6; // Incorrect amount (should match collateralAmount)
        deleverageAction.swapActions[0].outputToken = address(dai);
        deleverageAction.swapActions[0].target = address(_UNISWAP_V2_ROUTER);
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(dai);
        deleverageAction.swapActions[0].call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            800e6,
            0,
            path,
            address(positionManager),
            block.timestamp
        );
        deleverageAction.swapActions[0].slippage = 0.3e18;
        deleverageAction.repayAssets = 890 ether;
        
        // Should revert with InvalidSwapperParam
        vm.expectRevert(bytes4(keccak256("BasePositionManager__InvalidParam()")));
        positionManager.deleverage(deleverageAction, 0.05e18);
        
        vm.stopPrank();
    }

    function testRevert_LeverageInvalidSwapActionLength() public {
        vm.startPrank(user);
        
        deal(address(usdc), user, 1000e6);
        usdc.approve(address(borrowableCUSDC), 1000e6);
        
        // Mint borrowable cUSDC.
        borrowableCUSDC.deposit(1000e6, user);
        borrowableCUSDC.postCollateral(1000e6);
        
        // Borrow borrowable cDAI.
        borrowableCDAI.borrow(100 ether, user);
        
        // Try leveraging with 50% of limit.
        uint256 amountForLeverage = _maxRemainingLeverageOfHelper(
            user,
            address(borrowableCDAI)
        ) / 2;
        
        SimplePositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCDAI));
        leverageAction.borrowAssets = amountForLeverage;
        leverageAction.cToken = ICToken(address(borrowableCUSDC));
        leverageAction.swapAction.inputToken = address(dai);
        leverageAction.swapAction.inputAmount = amountForLeverage;
        leverageAction.swapAction.outputToken = address(usdc);
        leverageAction.swapAction.target = address(_UNISWAP_V2_ROUTER);
        leverageAction.swapAction.call = bytes(""); // Empty call data
        leverageAction.swapAction.slippage = 0.3e18;
        
        // Should revert with `InvalidSwapperParam`.
        vm.expectRevert(bytes4(keccak256("BasePositionManager__InvalidParam()")));
        positionManager.leverage(leverageAction, 0.05e18);
        
        vm.stopPrank();
    }

    function testRevert_DeleverageInvalidSwapActionLength() public {
        testLeverage();
        
        // Warp until collateralization cooldown period ends.
        vm.warp(block.timestamp + 20 minutes);
        borrowableCDAI.accrueIfNeeded();
        
        vm.startPrank(user);
        
        SimplePositionManager.DeleverageAction memory deleverageAction;
        deleverageAction.cToken = ICToken(address(borrowableCUSDC));
        deleverageAction.collateralAssets = 900e6;
        deleverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCDAI));
        deleverageAction.swapActions = new SwapperLib.Swap[](0); // Empty array
        deleverageAction.repayAssets = 890 ether;
        
        // Should revert with InvalidSwapperParam
        vm.expectRevert(bytes4(keccak256("BasePositionManager__InvalidParam()")));
        positionManager.deleverage(deleverageAction, 0.05e18);
        
        vm.stopPrank();
    }

    function testRevert_LeverageExcessiveSlippage() public {
        vm.startPrank(user);
        
        deal(address(usdc), user, 1000e6);
        usdc.approve(address(borrowableCUSDC), 1000e6);
        
        // Mint borrowable cUSDC.
        borrowableCUSDC.deposit(1000e6, user);
        borrowableCUSDC.postCollateral(1000e6);
        
        // Borrow borrowable cDAI.
        borrowableCDAI.borrow(100 ether, user);
        
        // Try leveraging with 50% of limit.
        uint256 amountForLeverage =_maxRemainingLeverageOfHelper(
            user,
            address(borrowableCDAI)
        ) / 2;
        
        SimplePositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCDAI));
        leverageAction.borrowAssets = amountForLeverage;
        leverageAction.cToken = ICToken(address(borrowableCUSDC));
        leverageAction.swapAction.inputToken = address(dai);
        leverageAction.swapAction.inputAmount = amountForLeverage;
        leverageAction.swapAction.outputToken = address(usdc);
        leverageAction.swapAction.target = address(_UNISWAP_V2_ROUTER);
        
        address[] memory path = new address[](2);
        path[0] = address(dai);
        path[1] = address(usdc);
        
        leverageAction.swapAction.call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            amountForLeverage,
            amountForLeverage * 1e12, // Very high min amount out, which will fail
            path,
            address(positionManager),
            block.timestamp
        );
        leverageAction.swapAction.slippage = 0.3e18;
        
        // We use a tiny slippage tolerance to revert.
        vm.expectRevert();
        positionManager.leverage(leverageAction, 0.00001e18); // Very low slippage tolerance
        
        vm.stopPrank();
    }

    function testRevert_LeverageForWithoutPermission() public {
        vm.startPrank(user);
        
        // Set up the collateral position.
        deal(address(usdc), user, 1000e6);
        usdc.approve(address(borrowableCUSDC), 1000e6);

        // Mint borrowable cUSDC.
        borrowableCUSDC.deposit(1000e6, user);
        borrowableCUSDC.postCollateral(1000e6);

        // Borrow borrowable cDAI.
        borrowableCDAI.borrow(100 ether, user);
        
        // Do not set delegate approval for user2.

        vm.stopPrank();
        
        // Try leveraging with 50% of limit.
        uint256 amountForLeverage =_maxRemainingLeverageOfHelper(
            user,
            address(borrowableCDAI)
        ) / 2;
        
        SimplePositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCDAI));
        leverageAction.borrowAssets = amountForLeverage;
        leverageAction.cToken = ICToken(address(borrowableCUSDC));
        leverageAction.swapAction.inputToken = address(dai);
        leverageAction.swapAction.inputAmount = amountForLeverage;
        leverageAction.swapAction.outputToken = address(usdc);
        leverageAction.swapAction.target = address(_UNISWAP_V2_ROUTER);
        address[] memory path = new address[](2);
        path[0] = address(dai);
        path[1] = address(usdc);
        leverageAction.swapAction.call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            amountForLeverage,
            0,
            path,
            address(positionManager),
            block.timestamp
        );
        leverageAction.swapAction.slippage = 0.3e18;
        
        // User2 tries to leverage for user without permission.
        vm.startPrank(user2);
        vm.expectRevert(bytes4(keccak256("PluginDelegable__Unauthorized()")));
        positionManager.leverageFor(leverageAction, user, 0.05e18);
        vm.stopPrank();
    }

    function testRevert_DeleverageForWithoutPermission() public {
        testLeverage();
        
        // Warp until collateralization cooldown period ends.
        vm.warp(block.timestamp + 20 minutes);
        borrowableCDAI.accrueIfNeeded();
        
        vm.startPrank(user);
        
        // Deleverage data
        SimplePositionManager.DeleverageAction memory deleverageAction;
        deleverageAction.cToken = ICToken(address(borrowableCUSDC));
        deleverageAction.collateralAssets = 900e6;
        deleverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCDAI));
        deleverageAction.swapActions = new SwapperLib.Swap[](1);
        deleverageAction.swapActions[0].inputToken = address(usdc);
        deleverageAction.swapActions[0].inputAmount = 900e6;
        deleverageAction.swapActions[0].outputToken = address(dai);
        deleverageAction.swapActions[0].target = address(_UNISWAP_V2_ROUTER);
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(dai);
        deleverageAction.swapActions[0].call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            900e6,
            0,
            path,
            address(positionManager),
            block.timestamp
        );
        deleverageAction.swapActions[0].slippage = 0.3e18;
        deleverageAction.repayAssets = 890 ether;
        borrowableCUSDC.approve(address(positionManager), type(uint256).max);
        
        // Do not set delegate approval for user2.
        vm.stopPrank();
        
        // User2 tries to deleverage for user without permission.
        vm.startPrank(user2);
        vm.expectRevert(bytes4(keccak256("PluginDelegable__Unauthorized()")));
        positionManager.deleverageFor(deleverageAction, user, 0.05e18);
        vm.stopPrank();
    }

    function testRevert_SetAndRevokeDelegate() public {
        vm.startPrank(user);

        // At this point, user2 should not have delegation.
        assertFalse(positionManager.isDelegate(user, address(user2)));

        positionManager.setDelegateApproval(address(user2), true);
        
        // Verify delegation was set.
        assertTrue(positionManager.isDelegate(user, address(user2)));
        
        // Set up leverage operation.
        deal(address(usdc), user, 1000e6);
        usdc.approve(address(borrowableCUSDC), 1000e6);
        borrowableCUSDC.deposit(1000e6, user);
        borrowableCUSDC.postCollateral(1000e6);

        // Borrow borrowable cDAI.
        borrowableCDAI.borrow(100 ether, user);
        
        vm.stopPrank();

        // Try leveraging with 50% of limit.
        uint256 amountForLeverage =_maxRemainingLeverageOfHelper(
            user,
            address(borrowableCDAI)
        ) / 2;
        
        SimplePositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCDAI));
        leverageAction.borrowAssets = amountForLeverage;
        leverageAction.cToken = ICToken(address(borrowableCUSDC));
        leverageAction.swapAction.inputToken = address(dai);
        leverageAction.swapAction.inputAmount = amountForLeverage;
        leverageAction.swapAction.outputToken = address(usdc);
        leverageAction.swapAction.target = address(_UNISWAP_V2_ROUTER);
        address[] memory path = new address[](2);
        path[0] = address(dai);
        path[1] = address(usdc);
        leverageAction.swapAction.call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            amountForLeverage,
            0,
            path,
            address(positionManager),
            block.timestamp
        );
        leverageAction.swapAction.slippage = 0.3e18;

        
        // User2 is able to leverage on behalf of user.
        vm.startPrank(user2);
        positionManager.leverageFor(leverageAction, user, 0.05e18);
        vm.stopPrank();
        
        // Revoke the delegation.
        vm.startPrank(user);
        positionManager.setDelegateApproval(address(user2), false);
        
        // Verify delegation was revoked.
        assertFalse(positionManager.isDelegate(user, address(user2)));
        vm.stopPrank();
        
        // User2 is not able to leverage on behalf of user anymore.
        vm.startPrank(user2);
        vm.expectRevert(bytes4(keccak256("PluginDelegable__Unauthorized()")));
        positionManager.leverageFor(leverageAction, user, 0.05e18);
        vm.stopPrank();
    }

    function testRevert_leverageAboveDebtCap() public {
        vm.startPrank(user);

        deal(address(usdc), user, 1000e6);
        usdc.approve(address(borrowableCUSDC), 1000e6);
        assertGt(borrowableCUSDC.deposit(1000e6, user), 0);
        borrowableCUSDC.postCollateral(1000e6);
        assertEq(borrowableCUSDC.balanceOf(user), 1000e6);

        vm.stopPrank();

        // Set debt cap and borrow slightly more than half to show double counting.
        uint256 debtCap = 100 ether;
        _setCTokenConfigBasic(address(borrowableCDAI), 100_000e18, debtCap);
        uint256 amountForLeverage = debtCap + 1;

        SimplePositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCDAI));
        leverageAction.borrowAssets = amountForLeverage;
        leverageAction.cToken = ICToken(address(borrowableCUSDC));
        leverageAction.swapAction.inputToken = address(dai);
        leverageAction.swapAction.inputAmount = amountForLeverage;
        leverageAction.swapAction.outputToken = address(usdc);
        leverageAction.swapAction.target = address(_UNISWAP_V2_ROUTER);

        address[] memory path = new address[](2);
        path[0] = address(dai);
        path[1] = address(usdc);
        leverageAction.swapAction.call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            amountForLeverage,
            0,
            path,
            address(positionManager),
            block.timestamp
        );
        leverageAction.swapAction.slippage = 0.3e18;

        // Expect revert due to double-counting 
        // new net debt uses (marketOutstandingDebt + assets).
        vm.startPrank(user);
        vm.expectRevert(MarketManagerIsolated.MarketManager__CapReached.selector);
        positionManager.leverage(leverageAction, 0.05e18);
        vm.stopPrank();
    }

    function testInitialize() public view {
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

        deal(address(usdc), user, 1000e6);
        usdc.approve(address(borrowableCUSDC), 1000e6);

        // Mint borrowable cUSDC.
        assertGt(borrowableCUSDC.deposit(1000e6, user), 0);
        borrowableCUSDC.postCollateral(1000e6);
        assertEq(borrowableCUSDC.balanceOf(user), 1000e6);

        uint256 balanceBeforeBorrow = dai.balanceOf(user);
        
        // Borrow borrowable cDAI.
        borrowableCDAI.borrow(100 ether, user);
        assertEq(dai.balanceOf(user), balanceBeforeBorrow + 100 ether);

        // Try leveraging with 50% of limit.
        uint256 amountForLeverage = _maxRemainingLeverageOfHelper(
            user,
            address(borrowableCDAI)
        ) / 2;

        SimplePositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCDAI));
        leverageAction.borrowAssets = amountForLeverage;
        leverageAction.cToken = ICToken(address(borrowableCUSDC));
        leverageAction.swapAction.inputToken = address(dai);
        leverageAction.swapAction.inputAmount = amountForLeverage;
        leverageAction.swapAction.outputToken = address(usdc);
        leverageAction.swapAction.target = address(_UNISWAP_V2_ROUTER);
        address[] memory path = new address[](2);
        path[0] = address(dai);
        path[1] = address(usdc);
        leverageAction.swapAction.call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            amountForLeverage,
            0,
            path,
            address(positionManager),
            block.timestamp
        );
        leverageAction.swapAction.slippage = 0.3e18;

        positionManager.leverage(leverageAction, 0.05e18); // 5% slippage

        AccountSnapshot memory borrowableCDAISnapshot = borrowableCDAI.getSnapshot(user);
        assertEq(borrowableCDAI.balanceOf(user), 0);
        assertEq(borrowableCDAISnapshot.debtBalance, 100 ether + amountForLeverage);

        AccountSnapshot memory borrowableCUSDCSnapshot = borrowableCUSDC.getSnapshot(
            user
        );
        assertGt(borrowableCUSDCSnapshot.collateralPosted, 1900e6);
        assertEq(borrowableCUSDCSnapshot.debtBalance, 0);

        vm.stopPrank();
    }

    function testDepositAndLeverage() public {
        vm.startPrank(user);

        deal(address(usdc), user, 1000e6);
        usdc.approve(address(positionManager), 1000e6);

        // Try leverage with 50% of max.
        uint256 amountForLeverage = 0.99e21;

        SimplePositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCDAI));
        leverageAction.borrowAssets = amountForLeverage;
        leverageAction.cToken = ICToken(address(borrowableCUSDC));
        leverageAction.swapAction.inputToken = address(dai);
        leverageAction.swapAction.inputAmount = amountForLeverage;
        leverageAction.swapAction.outputToken = address(usdc);
        leverageAction.swapAction.target = address(_UNISWAP_V2_ROUTER);
        address[] memory path = new address[](2);
        path[0] = address(dai);
        path[1] = address(usdc);
        leverageAction.swapAction.call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            amountForLeverage,
            0,
            path,
            address(positionManager),
            block.timestamp
        );
        leverageAction.swapAction.slippage = 0.3e18;

        positionManager.depositAndLeverage(1000e6, leverageAction, 0.05e18); // 5% slippage

        AccountSnapshot memory borrowableCDAISnapshot = borrowableCDAI.getSnapshot(user);
        assertEq(borrowableCDAI.balanceOf(user), 0);
        assertEq(borrowableCDAISnapshot.debtBalance, amountForLeverage);

        AccountSnapshot memory borrowableCUSDCSnapshot = borrowableCUSDC.getSnapshot(
            user
        );
        assertGt(borrowableCUSDCSnapshot.collateralPosted, 1900e6);
        assertEq(borrowableCUSDCSnapshot.debtBalance, 0);

        vm.stopPrank();
    }

    function testDepositAndLeverage_fail_onTinySlippage() public {
        vm.startPrank(user);

        // Provide deposit assets and approvals
        deal(address(usdc), user, 1000e6);
        usdc.approve(address(positionManager), 1000e6);

        uint256 amountForLeverage = 0.99e21;

        SimplePositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCDAI));
        leverageAction.borrowAssets = amountForLeverage;
        leverageAction.cToken = ICToken(address(borrowableCUSDC));
        leverageAction.swapAction.inputToken = address(dai);
        leverageAction.swapAction.inputAmount = amountForLeverage;
        leverageAction.swapAction.outputToken = address(usdc);
        leverageAction.swapAction.target = address(_UNISWAP_V2_ROUTER);
        address[] memory path = new address[](2);
        path[0] = address(dai);
        path[1] = address(usdc);
        leverageAction.swapAction.call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            amountForLeverage,
            0,
            path,
            address(positionManager),
            block.timestamp
        );
        leverageAction.swapAction.slippage = 0.3e18;

        // Expect the sanity slippage check to revert due to extremely small tolerated slippage
        vm.expectRevert(bytes4(keccak256("BasePositionManager__InvalidSlippage()")));
        positionManager.depositAndLeverage(1000e6, leverageAction, 0.00001e18);

        vm.stopPrank();
    }

    function testDeLeverage() public {
        testLeverage();

        // Warp until collateralization cooldown period ends.
        vm.warp(block.timestamp + 20 minutes);
        borrowableCDAI.accrueIfNeeded();

        vm.startPrank(user);
        AccountSnapshot memory borrowableCDAIBeforeSnapshot = borrowableCDAI.getSnapshot(user);
        AccountSnapshot memory borrowableCUSDCBeforeSnapshot = borrowableCUSDC.getSnapshot(user);

        SimplePositionManager.DeleverageAction memory deleverageAction;
        deleverageAction.cToken = ICToken(address(borrowableCUSDC));
        deleverageAction.collateralAssets = 900e6;
        deleverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCDAI));
        deleverageAction.swapActions = new SwapperLib.Swap[](1);
        deleverageAction.swapActions[0].inputToken = address(usdc);
        deleverageAction.swapActions[0].inputAmount = 900e6;
        deleverageAction.swapActions[0].outputToken = address(dai);
        deleverageAction.swapActions[0].target = address(_UNISWAP_V2_ROUTER);
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(dai);

        // Quote amount out from swap. repayAssets servers as a minimum.
        uint256 expectedDaiOut = IUniswapV2Router(_UNISWAP_V2_ROUTER).getAmountsOut(
            deleverageAction.swapActions[0].inputAmount,
            path
        )[1];
        deleverageAction.swapActions[0].call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            900e6,
            0,
            path,
            address(positionManager),
            block.timestamp
        );
        deleverageAction.swapActions[0].slippage = 0.3e18;
        deleverageAction.repayAssets = 890 ether;
        positionManager.deleverage(deleverageAction, 0.05e18); // 5% slippage

        AccountSnapshot memory borrowableCDAISnapshot = borrowableCDAI.getSnapshot(user);
        assertEq(borrowableCDAI.balanceOf(user), 0);
        uint256 repaid = borrowableCDAIBeforeSnapshot.debtBalance - borrowableCDAISnapshot.debtBalance;
        assertGe(repaid, deleverageAction.repayAssets);
        assertEq(repaid, expectedDaiOut);

        AccountSnapshot memory borrowableCUSDCSnapshot = borrowableCUSDC.getSnapshot(
            user
        );
        assertEq(
            borrowableCUSDCSnapshot.collateralPosted,
            borrowableCUSDCBeforeSnapshot.collateralPosted - deleverageAction.collateralAssets
        );
        assertEq(borrowableCUSDCSnapshot.debtBalance, 0);

        vm.stopPrank();
    }

    function testDeLeverage_fail_ZeroRepayAssets() public {
        vm.startPrank(user);
        SimplePositionManager.DeleverageAction memory deleverageAction;
        deleverageAction.repayAssets = 0;

        // Zero amount repayment is not supported in Position Managers.
        vm.expectRevert(BasePositionManager.BasePositionManager__InvalidAmount.selector);
        positionManager.deleverage(deleverageAction, 0.05e18);

        vm.stopPrank();
    }

    function testLeverageFor() public {
        vm.startPrank(user);

        deal(address(usdc), user, 1000e6);
        usdc.approve(address(borrowableCUSDC), 1000e6);

        // Mint borrowable cUSDC.
        assertGt(borrowableCUSDC.deposit(1000e6, user), 0);
        borrowableCUSDC.postCollateral(1000e6);
        assertEq(borrowableCUSDC.balanceOf(user), 1000e6);

        uint256 balanceBeforeBorrow = dai.balanceOf(user);

        // Borrow borrowable cDAI.
        borrowableCDAI.borrow(100 ether, user);
        assertEq(dai.balanceOf(user), balanceBeforeBorrow + 100 ether);

        // Try leveraging with 50% of limit.
        uint256 amountForLeverage = _maxRemainingLeverageOfHelper(
            user,
            address(borrowableCDAI)
        ) / 2;

        SimplePositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCDAI));
        leverageAction.borrowAssets = amountForLeverage;
        leverageAction.cToken = ICToken(address(borrowableCUSDC));
        leverageAction.swapAction.inputToken = address(dai);
        leverageAction.swapAction.inputAmount = amountForLeverage;
        leverageAction.swapAction.outputToken = address(usdc);
        leverageAction.swapAction.target = address(_UNISWAP_V2_ROUTER);
        address[] memory path = new address[](2);
        path[0] = address(dai);
        path[1] = address(usdc);
        leverageAction.swapAction.call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            amountForLeverage,
            0,
            path,
            address(positionManager),
            block.timestamp
        );
        leverageAction.swapAction.slippage = 0.3e18;

        positionManager.setDelegateApproval(address(user2), true);
        vm.stopPrank();

        vm.prank(user2);
        positionManager.leverageFor(leverageAction, user, 0.05e18); // 5% slippage

        AccountSnapshot memory borrowableCDAISnapshot = borrowableCDAI.getSnapshot(user);
        assertEq(borrowableCDAI.balanceOf(user), 0);
        assertEq(borrowableCDAISnapshot.debtBalance, 100 ether + amountForLeverage);

        AccountSnapshot memory borrowableCUSDCSnapshot = borrowableCUSDC.getSnapshot(
            user
        );
        assertGt(borrowableCUSDCSnapshot.collateralPosted, 1900e6);
        assertEq(borrowableCUSDCSnapshot.debtBalance, 0);

        vm.stopPrank();
    }

    function testDeLeverageFor() public {
        testLeverage();

        // Warp until collateralization cooldown period ends.
        vm.warp(block.timestamp + 20 minutes);
        borrowableCDAI.accrueIfNeeded();

        vm.startPrank(user);
        AccountSnapshot memory borrowableCDAIBeforeSnapshot = borrowableCDAI.getSnapshot(user);
        AccountSnapshot memory borrowableCUSDCBeforeSnapshot = borrowableCUSDC.getSnapshot(user);

        SimplePositionManager.DeleverageAction memory deleverageAction;
        deleverageAction.cToken = ICToken(address(borrowableCUSDC));
        deleverageAction.collateralAssets = 900e6;
        deleverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCDAI));
        deleverageAction.swapActions = new SwapperLib.Swap[](1);
        deleverageAction.swapActions[0].inputToken = address(usdc);
        deleverageAction.swapActions[0].inputAmount = 900e6;
        deleverageAction.swapActions[0].outputToken = address(dai);
        deleverageAction.swapActions[0].target = address(_UNISWAP_V2_ROUTER);
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(dai);

        // Quote amount out from swap. repayAssets serves as a minimum.
        uint256 expectedDaiOut = IUniswapV2Router(_UNISWAP_V2_ROUTER).getAmountsOut(
            deleverageAction.swapActions[0].inputAmount,
            path
        )[1];
        deleverageAction.swapActions[0].call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            900e6,
            0,
            path,
            address(positionManager),
            block.timestamp
        );
        deleverageAction.swapActions[0].slippage = 0.3e18;
        deleverageAction.repayAssets = 890 ether;
        borrowableCUSDC.approve(address(positionManager), type(uint256).max);

        positionManager.setDelegateApproval(address(user2), true);
        vm.stopPrank();

        vm.prank(user2);
        positionManager.deleverageFor(deleverageAction, user, 0.05e18); // 5% slippage

        AccountSnapshot memory borrowableCDAISnapshot = borrowableCDAI.getSnapshot(user);
        assertEq(borrowableCDAI.balanceOf(user), 0);
        uint256 repaid = borrowableCDAIBeforeSnapshot.debtBalance - borrowableCDAISnapshot.debtBalance;
        assertGe(repaid, deleverageAction.repayAssets);
        assertEq(repaid, expectedDaiOut);

        AccountSnapshot memory borrowableCUSDCSnapshot = borrowableCUSDC.getSnapshot(
            user
        );
        assertEq(
            borrowableCUSDCSnapshot.collateralPosted,
            borrowableCUSDCBeforeSnapshot.collateralPosted - deleverageAction.collateralAssets
        );
        assertEq(borrowableCUSDCSnapshot.debtBalance, 0);

        vm.stopPrank();
    }

    function testLeverageUpToDebtCap() public {
        vm.startPrank(user);

        deal(address(usdc), user, 1000e6);
        usdc.approve(address(borrowableCUSDC), 1000e6);
        assertGt(borrowableCUSDC.deposit(1000e6, user), 0);
        borrowableCUSDC.postCollateral(1000e6);
        assertEq(borrowableCUSDC.balanceOf(user), 1000e6);

        vm.stopPrank();

        // Set debt cap and borrow slightly more than half to show double counting.
        uint256 debtCap = 100 ether;
        _setCTokenConfigBasic(address(borrowableCDAI), 100_000e18, debtCap);
        uint256 amountForLeverage = debtCap - 1;

        SimplePositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCDAI));
        leverageAction.borrowAssets = amountForLeverage;
        leverageAction.cToken = ICToken(address(borrowableCUSDC));
        leverageAction.swapAction.inputToken = address(dai);
        leverageAction.swapAction.inputAmount = amountForLeverage;
        leverageAction.swapAction.outputToken = address(usdc);
        leverageAction.swapAction.target = address(_UNISWAP_V2_ROUTER);

        address[] memory path = new address[](2);
        path[0] = address(dai);
        path[1] = address(usdc);
        leverageAction.swapAction.call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            amountForLeverage,
            0,
            path,
            address(positionManager),
            block.timestamp
        );
        leverageAction.swapAction.slippage = 0.3e18;

        vm.startPrank(user);
        positionManager.leverage(leverageAction, 0.05e18); // 5% slippage

        AccountSnapshot memory borrowableCDAISnapshot =
            borrowableCDAI.getSnapshot(user);
        assertEq(borrowableCDAI.balanceOf(user), 0);
        assertEq(borrowableCDAISnapshot.debtBalance, amountForLeverage);

        AccountSnapshot memory borrowableCUSDCSnapshot =
            borrowableCUSDC.getSnapshot(user);
        assertGt(borrowableCUSDCSnapshot.collateralPosted, 1000e6);
        assertEq(borrowableCUSDCSnapshot.debtBalance, 0);

        vm.stopPrank();
    }

    function test_leverage_fail_whenExpectedSharesTooHigh() public {
        vm.startPrank(user);

        deal(address(usdc), user, 1000e6);
        usdc.approve(address(borrowableCUSDC), 1000e6);
        borrowableCUSDC.deposit(1000e6, user);
        borrowableCUSDC.postCollateral(1000e6);

        borrowableCDAI.borrow(100 ether, user);

        uint256 amountForLeverage = _maxRemainingLeverageOfHelper(
            user,
            address(borrowableCDAI)
        ) / 2;

        SimplePositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCDAI));
        leverageAction.borrowAssets = amountForLeverage;
        leverageAction.cToken = ICToken(address(borrowableCUSDC));
        
        // Set an unrealistically large expectedShares to force revert
        leverageAction.expectedShares = type(uint256).max;
        leverageAction.swapAction.inputToken = address(dai);
        leverageAction.swapAction.inputAmount = amountForLeverage;
        leverageAction.swapAction.outputToken = address(usdc);
        leverageAction.swapAction.target = address(_UNISWAP_V2_ROUTER);

        address[] memory path = new address[](2);
        path[0] = address(dai);
        path[1] = address(usdc);
        leverageAction.swapAction.call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            amountForLeverage,
            0,
            path,
            address(positionManager),
            block.timestamp
        );
        leverageAction.swapAction.slippage = 0.3e18;

        vm.expectRevert(BasePositionManager.BasePositionManager__InvalidSlippage.selector);
        positionManager.leverage(leverageAction, 0.05e18);

        vm.stopPrank();
    }

    function test_leverage_succeed_whenExpectedSharesLow() public {
        vm.startPrank(user);

        deal(address(usdc), user, 1000e6);
        usdc.approve(address(borrowableCUSDC), 1000e6);

        assertGt(borrowableCUSDC.deposit(1000e6, user), 0);
        borrowableCUSDC.postCollateral(1000e6);
        assertEq(borrowableCUSDC.balanceOf(user), 1000e6);

        borrowableCDAI.borrow(100 ether, user);

        uint256 amountForLeverage = _maxRemainingLeverageOfHelper(
            user,
            address(borrowableCDAI)
        ) / 2;

        SimplePositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCDAI));
        leverageAction.borrowAssets = amountForLeverage;
        leverageAction.cToken = ICToken(address(borrowableCUSDC));

        // Set tiny expectedShares to succeed
        leverageAction.expectedShares = 1;
        leverageAction.swapAction.inputToken = address(dai);
        leverageAction.swapAction.inputAmount = amountForLeverage;
        leverageAction.swapAction.outputToken = address(usdc);
        leverageAction.swapAction.target = address(_UNISWAP_V2_ROUTER);

        address[] memory path = new address[](2);
        path[0] = address(dai);
        path[1] = address(usdc);
        leverageAction.swapAction.call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            amountForLeverage,
            0,
            path,
            address(positionManager),
            block.timestamp
        );
        leverageAction.swapAction.slippage = 0.3e18;

        positionManager.leverage(leverageAction, 0.05e18);

        vm.stopPrank();
    }

    function _provideEnoughLiquidityForLeverage() internal {
        address liquidityProvider = makeAddr("liquidityProvider");

        _prepareUSDC(liquidityProvider, 100e6);
        _prepareDAI(liquidityProvider, 20000000e18);

        vm.startPrank(liquidityProvider);

        // Mint borrowable cDAI.
        dai.approve(address(borrowableCDAI), 20000000 ether);
        borrowableCDAI.deposit(20000000 ether, liquidityProvider);

        // Mint borrowable cUSDC.
        usdc.approve(address(borrowableCUSDC), 100e6);
        borrowableCUSDC.deposit(100e6, liquidityProvider);

        vm.stopPrank();
    }

}
