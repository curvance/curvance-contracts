// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {SwapperLib} from "contracts/libraries/SwapperLib.sol";
import {
    SimplePositionManager
} from "contracts/market/position-management/SimplePositionManager.sol";
import {SimpleCToken} from "contracts/market/token/SimpleCToken.sol";
import {BorrowableCToken} from "contracts/market/token/BorrowableCToken.sol";
import {MockCalldataChecker} from "contracts/mocks/MockCalldataChecker.sol";
import {MockV3Aggregator} from "contracts/mocks/MockV3Aggregator.sol";
import {OracleManager} from "contracts/oracles/OracleManager.sol";
import {ERC20} from "contracts/libraries/external/ERC20.sol";
import {MockSimpleCToken} from "contracts/mocks/MockSimpleCToken.sol";
import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";
import {IBorrowableCToken} from "contracts/interfaces/IBorrowableCToken.sol";
import {ICToken, AccountSnapshot} from "contracts/interfaces/ICToken.sol";
import {IERC20} from "contracts/interfaces/IERC20.sol";
import {
    IUniswapV2Router
} from "contracts/interfaces/external/uniswap/IUniswapV2Router.sol";
import {TestBaseMarketIsolated} from "tests/market/TestBaseMarketIsolated.sol";
import {
    MarketManagerIsolated
} from "contracts/market/isolated/MarketManagerIsolated.sol";
import {
    BasePositionManager
} from "contracts/market/position-management/BasePositionManager.sol";

contract TestSimplePositionManager is TestBaseMarketIsolated {
    address public owner;
    address public user;

    SimplePositionManager public positionManager;
    MockSimpleCToken internal unlistedCToken;

    struct PMDeleverageRollbackState {
        AccountSnapshot debtSnapshot;
        AccountSnapshot collateralSnapshot;
        uint256 cTokenBalance;
        uint256 marketCollateral;
        uint256 userDai;
        uint256 userUsdc;
        uint256 pmDai;
        uint256 pmUsdc;
        uint256 targetDai;
        uint256 targetUsdc;
    }

    struct PMTerminalCautionContext {
        MarketManagerIsolated market;
        SimplePositionManager pm;
        OracleFlipToken debt;
        OracleFlipToken collateral;
        SimpleCToken collateralCToken;
        BorrowableCToken debtCToken;
        ExactOutTestSwapTarget swapTarget;
        MockV3Aggregator terminalDebtFeed;
    }

    struct PMTerminalCautionState {
        AccountSnapshot debtSnapshot;
        AccountSnapshot collateralSnapshot;
        uint256 cTokenBalance;
        uint256 marketCollateral;
        uint256 marketDebt;
        uint256 userDebtToken;
        uint256 userCollateralToken;
        uint256 pmDebtToken;
        uint256 pmCollateralToken;
        uint256 targetDebtToken;
        uint256 targetCollateralToken;
    }

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

        marketManagerIsolated.listTokens(
            address(borrowableCUSDC), address(borrowableCDAI)
        );

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
        uint256 amountForLeverage =
            _maxRemainingLeverageOfHelper(user, address(borrowableCDAI)) / 2;

        SimplePositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken =
            IBorrowableCToken(address(borrowableCDAI));
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

        AccountSnapshot memory debtBefore = borrowableCDAI.getSnapshot(user);
        AccountSnapshot memory collBefore = borrowableCUSDC.getSnapshot(user);
        uint256 userDaiBefore = dai.balanceOf(user);

        // Should revert with `InvalidSwapperParam`.
        vm.expectRevert(
            bytes4(keccak256("BasePositionManager__InvalidParam()"))
        );
        positionManager.leverage(leverageAction, 0.05e18);

        AccountSnapshot memory debtAfter = borrowableCDAI.getSnapshot(user);
        AccountSnapshot memory collAfter = borrowableCUSDC.getSnapshot(user);
        assertEq(debtAfter.debtBalance, debtBefore.debtBalance);
        assertEq(collAfter.collateralPosted, collBefore.collateralPosted);
        assertEq(dai.balanceOf(user), userDaiBefore);
        _assertSimplePositionManagerHasNoResidue();

        vm.stopPrank();
    }

    function test_onBorrow_fail_unlistedCollateralCToken() public {
        vm.startPrank(user);

        // Setup collateral
        _prepareUSDC(user, 1_000e6);
        usdc.approve(address(borrowableCUSDC), 1_000e6);
        borrowableCUSDC.depositAsCollateral(1_000e6, user);

        SimplePositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken =
            IBorrowableCToken(address(borrowableCDAI));
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

        vm.expectRevert(
            bytes4(keccak256("BasePositionManager__Unauthorized()"))
        );
        positionManager.leverage(leverageAction, 0.05e18);

        vm.stopPrank();
    }

    function test_onBorrow_fail_unauthorizedCallbackBeforeAssetLookup()
        public
    {
        SimplePositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken =
            IBorrowableCToken(address(borrowableCDAI));
        leverageAction.borrowAssets = 1 ether;
        leverageAction.cToken = ICToken(address(borrowableCUSDC));

        vm.expectRevert(
            BasePositionManager.BasePositionManager__Unauthorized.selector
        );
        positionManager.onBorrow(address(this), 1 ether, user, leverageAction);
    }

    function test_onRedeem_fail_unauthorizedCallbackBeforeAssetLookup()
        public
    {
        SimplePositionManager.DeleverageAction memory deleverageAction;
        deleverageAction.cToken = ICToken(address(borrowableCUSDC));
        deleverageAction.collateralAssets = 10e6;
        deleverageAction.borrowableCToken =
            IBorrowableCToken(address(borrowableCDAI));

        vm.expectRevert(
            BasePositionManager.BasePositionManager__Unauthorized.selector
        );
        positionManager.onRedeem(address(this), 10e6, user, deleverageAction);
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
        deleverageAction.borrowableCToken =
            IBorrowableCToken(address(unlistedCToken));
        deleverageAction.swapActions = new SwapperLib.Swap[](1);

        // placeholder swap data
        deleverageAction.swapActions[0].inputToken = address(usdc);
        deleverageAction.swapActions[0].inputAmount = 10e6;
        deleverageAction.swapActions[0].outputToken = address(dai);
        deleverageAction.swapActions[0].target = address(_UNISWAP_V2_ROUTER);
        deleverageAction.swapActions[0].call = hex"01";
        deleverageAction.swapActions[0].slippage = 0.3e18;
        deleverageAction.repayAssets = 1; // Repay as much as possible

        vm.expectRevert(
            bytes4(keccak256("BasePositionManager__Unauthorized()"))
        );
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
        deleverageAction.borrowableCToken =
            IBorrowableCToken(address(borrowableCDAI));
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
        vm.expectRevert(
            bytes4(keccak256("BasePositionManager__InvalidParam()"))
        );
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
        uint256 amountForLeverage =
            _maxRemainingLeverageOfHelper(user, address(borrowableCDAI)) / 2;

        SimplePositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken =
            IBorrowableCToken(address(borrowableCDAI));
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
        vm.expectRevert(
            bytes4(keccak256("BasePositionManager__InvalidParam()"))
        );
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
        deleverageAction.borrowableCToken =
            IBorrowableCToken(address(borrowableCDAI));
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
        vm.expectRevert(
            bytes4(keccak256("BasePositionManager__InvalidParam()"))
        );
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
        uint256 amountForLeverage =
            _maxRemainingLeverageOfHelper(user, address(borrowableCDAI)) / 2;

        SimplePositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken =
            IBorrowableCToken(address(borrowableCDAI));
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
        vm.expectRevert(
            bytes4(keccak256("BasePositionManager__InvalidParam()"))
        );
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
        uint256 amountForLeverage =
            _maxRemainingLeverageOfHelper(user, address(borrowableCDAI)) / 2;

        SimplePositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken =
            IBorrowableCToken(address(borrowableCDAI));
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
        vm.expectRevert(
            bytes4(keccak256("BasePositionManager__InvalidParam()"))
        );
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
        deleverageAction.borrowableCToken =
            IBorrowableCToken(address(borrowableCDAI));
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
        vm.expectRevert(
            bytes4(keccak256("BasePositionManager__InvalidParam()"))
        );
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
        uint256 amountForLeverage =
            _maxRemainingLeverageOfHelper(user, address(borrowableCDAI)) / 2;

        SimplePositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken =
            IBorrowableCToken(address(borrowableCDAI));
        leverageAction.borrowAssets = amountForLeverage;
        leverageAction.cToken = ICToken(address(borrowableCUSDC));
        leverageAction.swapAction.inputToken = address(dai);
        leverageAction.swapAction.inputAmount = amountForLeverage;
        leverageAction.swapAction.outputToken = address(usdc);
        leverageAction.swapAction.target = address(_UNISWAP_V2_ROUTER);
        leverageAction.swapAction.call = bytes(""); // Empty call data
        leverageAction.swapAction.slippage = 0.3e18;

        // Should revert with `InvalidSwapperParam`.
        vm.expectRevert(
            bytes4(keccak256("BasePositionManager__InvalidParam()"))
        );
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
        deleverageAction.borrowableCToken =
            IBorrowableCToken(address(borrowableCDAI));
        deleverageAction.swapActions = new SwapperLib.Swap[](0); // Empty array
        deleverageAction.repayAssets = 890 ether;

        // Should revert with InvalidSwapperParam
        vm.expectRevert(
            bytes4(keccak256("BasePositionManager__InvalidParam()"))
        );
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
        uint256 amountForLeverage =
            _maxRemainingLeverageOfHelper(user, address(borrowableCDAI)) / 2;

        SimplePositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken =
            IBorrowableCToken(address(borrowableCDAI));
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
        uint256 amountForLeverage =
            _maxRemainingLeverageOfHelper(user, address(borrowableCDAI)) / 2;

        SimplePositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken =
            IBorrowableCToken(address(borrowableCDAI));
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
        deleverageAction.borrowableCToken =
            IBorrowableCToken(address(borrowableCDAI));
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
        uint256 amountForLeverage =
            _maxRemainingLeverageOfHelper(user, address(borrowableCDAI)) / 2;

        SimplePositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken =
            IBorrowableCToken(address(borrowableCDAI));
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
        leverageAction.borrowableCToken =
            IBorrowableCToken(address(borrowableCDAI));
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
        vm.expectRevert(
            MarketManagerIsolated.MarketManager__CapReached.selector
        );
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
        uint256 amountForLeverage =
            _maxRemainingLeverageOfHelper(user, address(borrowableCDAI)) / 2;

        SimplePositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken =
            IBorrowableCToken(address(borrowableCDAI));
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

        uint256 collateralBefore =
            borrowableCUSDC.getSnapshot(user).collateralPosted;
        uint256 expectedSwapOut = IUniswapV2Router(_UNISWAP_V2_ROUTER)
            .getAmountsOut(amountForLeverage, path)[1];

        positionManager.leverage(leverageAction, 0.05e18); // 5% slippage

        AccountSnapshot memory borrowableCDAISnapshot =
            borrowableCDAI.getSnapshot(user);
        assertEq(borrowableCDAI.balanceOf(user), 0);
        assertEq(
            borrowableCDAISnapshot.debtBalance,
            100 ether + amountForLeverage,
            "leverage debt should include borrowed amount"
        );

        AccountSnapshot memory borrowableCUSDCSnapshot =
            borrowableCUSDC.getSnapshot(user);
        assertEq(
            borrowableCUSDCSnapshot.collateralPosted - collateralBefore,
            expectedSwapOut,
            "collateral delta should match router quote"
        );
        assertEq(
            borrowableCUSDCSnapshot.debtBalance,
            0,
            "collateral cToken should not accrue debt"
        );
        _assertSimplePositionManagerHasNoResidue();

        vm.stopPrank();
    }

    function testLeverage_fail_whenTerminalCanBorrowRejectsAfterRealRouteAndRollsBack()
        public
    {
        ExactOutTestSwapTarget swapTarget = new ExactOutTestSwapTarget();
        centralRegistry.setExternalCalldataChecker(
            address(swapTarget),
            address(new MockCalldataChecker(address(swapTarget)))
        );

        uint256 startingCollateral = 1_000e6;
        uint256 borrowAssets = 3_000e18;
        uint256 swapOut = 3_000e6;
        _prepareUSDC(address(swapTarget), swapOut);

        vm.startPrank(user);
        deal(address(usdc), user, startingCollateral);
        usdc.approve(address(borrowableCUSDC), startingCollateral);
        borrowableCUSDC.depositAsCollateral(startingCollateral, user);

        SimplePositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken =
            IBorrowableCToken(address(borrowableCDAI));
        leverageAction.borrowAssets = borrowAssets;
        leverageAction.cToken = ICToken(address(borrowableCUSDC));
        leverageAction.swapAction.inputToken = address(dai);
        leverageAction.swapAction.inputAmount = borrowAssets;
        leverageAction.swapAction.outputToken = address(usdc);
        leverageAction.swapAction.target = address(swapTarget);
        leverageAction.swapAction.call = abi.encodeWithSelector(
            ExactOutTestSwapTarget.exactSwap.selector,
            address(dai),
            address(usdc),
            borrowAssets,
            3_000e6
        );
        leverageAction.swapAction.slippage = 0;

        AccountSnapshot memory debtBefore = borrowableCDAI.getSnapshot(user);
        AccountSnapshot memory collBefore = borrowableCUSDC.getSnapshot(user);
        uint256 userDaiBefore = dai.balanceOf(user);
        uint256 targetDaiBefore = dai.balanceOf(address(swapTarget));
        uint256 targetUsdcBefore = usdc.balanceOf(address(swapTarget));

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__InsufficientCollateral
            .selector
        );
        positionManager.leverage(leverageAction, 0.999e18);
        vm.stopPrank();

        AccountSnapshot memory debtAfter = borrowableCDAI.getSnapshot(user);
        AccountSnapshot memory collAfter = borrowableCUSDC.getSnapshot(user);
        assertEq(debtAfter.debtBalance, debtBefore.debtBalance);
        assertEq(collAfter.collateralPosted, collBefore.collateralPosted);
        assertEq(dai.balanceOf(user), userDaiBefore);
        assertEq(dai.balanceOf(address(swapTarget)), targetDaiBefore);
        assertEq(usdc.balanceOf(address(swapTarget)), targetUsdcBefore);
        _assertSimplePositionManagerHasNoResidue();
    }

    function testLeverage_fail_whenPrefundedCollateralResidueTerminalCheckRejectsAndRollsBack()
        public
    {
        ExactOutTestSwapTarget swapTarget = new ExactOutTestSwapTarget();
        centralRegistry.setExternalCalldataChecker(
            address(swapTarget),
            address(new MockCalldataChecker(address(swapTarget)))
        );

        uint256 borrowAssets = 3_000e18;
        _prepareUSDC(address(swapTarget), 3_000e6);
        deal(address(usdc), address(positionManager), 25e6);

        vm.startPrank(user);
        deal(address(usdc), user, 1_000e6);
        usdc.approve(address(borrowableCUSDC), 1_000e6);
        borrowableCUSDC.depositAsCollateral(1_000e6, user);

        SimplePositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken =
            IBorrowableCToken(address(borrowableCDAI));
        leverageAction.borrowAssets = borrowAssets;
        leverageAction.cToken = ICToken(address(borrowableCUSDC));
        leverageAction.swapAction.inputToken = address(dai);
        leverageAction.swapAction.inputAmount = borrowAssets;
        leverageAction.swapAction.outputToken = address(usdc);
        leverageAction.swapAction.target = address(swapTarget);
        leverageAction.swapAction.call = abi.encodeWithSelector(
            ExactOutTestSwapTarget.exactSwap.selector,
            address(dai),
            address(usdc),
            borrowAssets,
            3_000e6
        );
        leverageAction.swapAction.slippage = 0;

        AccountSnapshot memory debtBefore = borrowableCDAI.getSnapshot(user);
        AccountSnapshot memory collBefore = borrowableCUSDC.getSnapshot(user);
        uint256 pmDaiBefore = dai.balanceOf(address(positionManager));
        uint256 pmUsdcBefore = usdc.balanceOf(address(positionManager));

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__InsufficientCollateral
            .selector
        );
        positionManager.leverage(leverageAction, 0.999e18);
        vm.stopPrank();

        AccountSnapshot memory debtAfter = borrowableCDAI.getSnapshot(user);
        AccountSnapshot memory collAfter = borrowableCUSDC.getSnapshot(user);
        assertEq(debtAfter.debtBalance, debtBefore.debtBalance);
        assertEq(collAfter.collateralPosted, collBefore.collateralPosted);
        assertEq(dai.balanceOf(address(positionManager)), pmDaiBefore);
        assertEq(usdc.balanceOf(address(positionManager)), pmUsdcBefore);
    }

    function testLeverage_sweepsPreExistingCollateralResidueIntoPosition()
        public
    {
        vm.startPrank(user);

        deal(address(usdc), user, 1000e6);
        usdc.approve(address(borrowableCUSDC), 1000e6);
        borrowableCUSDC.deposit(1000e6, user);
        borrowableCUSDC.postCollateral(1000e6);
        borrowableCDAI.borrow(100 ether, user);

        uint256 amountForLeverage =
            _maxRemainingLeverageOfHelper(user, address(borrowableCDAI)) / 2;

        uint256 residue = 25e6;
        deal(address(usdc), address(positionManager), residue);

        SimplePositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken =
            IBorrowableCToken(address(borrowableCDAI));
        leverageAction.borrowAssets = amountForLeverage;
        leverageAction.cToken = ICToken(address(borrowableCUSDC));
        leverageAction.swapAction.inputToken = address(dai);
        leverageAction.swapAction.inputAmount = amountForLeverage;
        leverageAction.swapAction.outputToken = address(usdc);
        leverageAction.swapAction.target = address(_UNISWAP_V2_ROUTER);

        address[] memory path = new address[](2);
        path[0] = address(dai);
        path[1] = address(usdc);
        uint256 expectedSwapOut = IUniswapV2Router(_UNISWAP_V2_ROUTER)
            .getAmountsOut(amountForLeverage, path)[1];

        leverageAction.swapAction.call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            amountForLeverage,
            0,
            path,
            address(positionManager),
            block.timestamp
        );
        leverageAction.swapAction.slippage = 0.3e18;

        AccountSnapshot memory collBefore = borrowableCUSDC.getSnapshot(user);

        positionManager.leverage(leverageAction, 0.05e18);

        AccountSnapshot memory collAfter = borrowableCUSDC.getSnapshot(user);
        assertGe(
            collAfter.collateralPosted - collBefore.collateralPosted,
            expectedSwapOut + residue,
            "pre-existing collateral asset residue should be swept"
        );
        _assertSimplePositionManagerHasNoResidue();

        vm.stopPrank();
    }

    function testLeverage_fail_OutputSentAwayRollsBackAtMaxSlippage() public {
        vm.startPrank(user);

        deal(address(usdc), user, 1000e6);
        usdc.approve(address(borrowableCUSDC), 1000e6);
        borrowableCUSDC.deposit(1000e6, user);
        borrowableCUSDC.postCollateral(1000e6);
        borrowableCDAI.borrow(100 ether, user);

        uint256 amountForLeverage =
            _maxRemainingLeverageOfHelper(user, address(borrowableCDAI)) / 2;

        SimplePositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken =
            IBorrowableCToken(address(borrowableCDAI));
        leverageAction.borrowAssets = amountForLeverage;
        leverageAction.cToken = ICToken(address(borrowableCUSDC));
        leverageAction.swapAction.inputToken = address(dai);
        leverageAction.swapAction.inputAmount = amountForLeverage;
        leverageAction.swapAction.outputToken = address(usdc);
        leverageAction.swapAction.target = address(_UNISWAP_V2_ROUTER);
        leverageAction.swapAction.slippage = 0.999e18;

        address[] memory path = new address[](2);
        path[0] = address(dai);
        path[1] = address(usdc);
        leverageAction.swapAction.call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            amountForLeverage,
            0,
            path,
            user2,
            block.timestamp
        );

        AccountSnapshot memory debtBefore = borrowableCDAI.getSnapshot(user);
        AccountSnapshot memory collBefore = borrowableCUSDC.getSnapshot(user);
        uint256 user2UsdcBefore = usdc.balanceOf(user2);

        vm.expectRevert(
            abi.encodeWithSelector(
                SwapperLib.SwapperLib__Slippage.selector, 1e18
            )
        );
        positionManager.leverage(leverageAction, 0.999e18);

        AccountSnapshot memory debtAfter = borrowableCDAI.getSnapshot(user);
        AccountSnapshot memory collAfter = borrowableCUSDC.getSnapshot(user);
        assertEq(debtAfter.debtBalance, debtBefore.debtBalance);
        assertEq(collAfter.collateralPosted, collBefore.collateralPosted);
        assertEq(usdc.balanceOf(user2), user2UsdcBefore);
        _assertSimplePositionManagerHasNoResidue();

        vm.stopPrank();
    }

    function testDepositAndLeverage() public {
        vm.startPrank(user);

        deal(address(usdc), user, 1000e6);
        usdc.approve(address(positionManager), 1000e6);

        // Try leverage with 50% of max.
        uint256 amountForLeverage = 0.99e21;

        SimplePositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken =
            IBorrowableCToken(address(borrowableCDAI));
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

        AccountSnapshot memory borrowableCDAISnapshot =
            borrowableCDAI.getSnapshot(user);
        assertEq(borrowableCDAI.balanceOf(user), 0);
        assertEq(borrowableCDAISnapshot.debtBalance, amountForLeverage);

        AccountSnapshot memory borrowableCUSDCSnapshot =
            borrowableCUSDC.getSnapshot(user);
        assertGt(borrowableCUSDCSnapshot.collateralPosted, 1900e6);
        assertEq(borrowableCUSDCSnapshot.debtBalance, 0);
        _assertSimplePositionManagerHasNoResidue();

        vm.stopPrank();
    }

    function testDepositAndLeverage_fail_onTinySlippage() public {
        vm.startPrank(user);

        // Provide deposit assets and approvals
        deal(address(usdc), user, 1000e6);
        usdc.approve(address(positionManager), 1000e6);

        uint256 amountForLeverage = 0.99e21;

        SimplePositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken =
            IBorrowableCToken(address(borrowableCDAI));
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

        uint256 userUsdcBefore = usdc.balanceOf(user);
        AccountSnapshot memory debtBefore = borrowableCDAI.getSnapshot(user);
        AccountSnapshot memory collBefore = borrowableCUSDC.getSnapshot(user);
        uint256 marketCollateralBefore =
            borrowableCUSDC.marketCollateralPosted();

        // Expect the sanity slippage check to revert due to extremely small tolerated slippage
        vm.expectRevert(
            bytes4(keccak256("BasePositionManager__InvalidSlippage()"))
        );
        positionManager.depositAndLeverage(1000e6, leverageAction, 0.00001e18);

        AccountSnapshot memory debtAfter = borrowableCDAI.getSnapshot(user);
        AccountSnapshot memory collAfter = borrowableCUSDC.getSnapshot(user);
        assertEq(usdc.balanceOf(user), userUsdcBefore);
        assertEq(debtAfter.debtBalance, debtBefore.debtBalance);
        assertEq(collAfter.collateralPosted, collBefore.collateralPosted);
        assertEq(
            borrowableCUSDC.marketCollateralPosted(), marketCollateralBefore
        );
        _assertSimplePositionManagerHasNoResidue();

        vm.stopPrank();
    }

    function testDeLeverage() public {
        testLeverage();

        // Warp until collateralization cooldown period ends.
        vm.warp(block.timestamp + 20 minutes);
        borrowableCDAI.accrueIfNeeded();

        vm.startPrank(user);
        AccountSnapshot memory borrowableCDAIBeforeSnapshot =
            borrowableCDAI.getSnapshot(user);
        AccountSnapshot memory borrowableCUSDCBeforeSnapshot =
            borrowableCUSDC.getSnapshot(user);

        SimplePositionManager.DeleverageAction memory deleverageAction;
        deleverageAction.cToken = ICToken(address(borrowableCUSDC));
        deleverageAction.collateralAssets = 900e6;
        deleverageAction.borrowableCToken =
            IBorrowableCToken(address(borrowableCDAI));
        deleverageAction.swapActions = new SwapperLib.Swap[](1);
        deleverageAction.swapActions[0].inputToken = address(usdc);
        deleverageAction.swapActions[0].inputAmount = 900e6;
        deleverageAction.swapActions[0].outputToken = address(dai);
        deleverageAction.swapActions[0].target = address(_UNISWAP_V2_ROUTER);
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(dai);

        // Quote amount out from swap. repayAssets servers as a minimum.
        uint256 expectedDaiOut = IUniswapV2Router(_UNISWAP_V2_ROUTER)
            .getAmountsOut(
                deleverageAction.swapActions[0].inputAmount, path
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

        AccountSnapshot memory borrowableCDAISnapshot =
            borrowableCDAI.getSnapshot(user);
        assertEq(borrowableCDAI.balanceOf(user), 0);
        uint256 repaid = borrowableCDAIBeforeSnapshot.debtBalance
            - borrowableCDAISnapshot.debtBalance;
        assertGe(repaid, deleverageAction.repayAssets);
        assertEq(repaid, expectedDaiOut);

        AccountSnapshot memory borrowableCUSDCSnapshot =
            borrowableCUSDC.getSnapshot(user);
        assertEq(
            borrowableCUSDCSnapshot.collateralPosted,
            borrowableCUSDCBeforeSnapshot.collateralPosted
                - deleverageAction.collateralAssets
        );
        assertEq(borrowableCUSDCSnapshot.debtBalance, 0);
        _assertSimplePositionManagerHasNoResidue();

        vm.stopPrank();
    }

    function testDeLeverage_fail_ZeroRepayAssets() public {
        vm.startPrank(user);
        SimplePositionManager.DeleverageAction memory deleverageAction;
        deleverageAction.repayAssets = 0;

        // Zero amount repayment is not supported in Position Managers.
        vm.expectRevert(
            BasePositionManager.BasePositionManager__InvalidAmount.selector
        );
        positionManager.deleverage(deleverageAction, 0.05e18);

        vm.stopPrank();
    }

    function testDeLeverage_fail_InsufficientRepayRollsBack() public {
        testLeverage();

        vm.warp(block.timestamp + 20 minutes);
        borrowableCDAI.accrueIfNeeded();

        vm.startPrank(user);

        AccountSnapshot memory debtBefore = borrowableCDAI.getSnapshot(user);
        AccountSnapshot memory collBefore = borrowableCUSDC.getSnapshot(user);
        uint256 cTokenBalanceBefore = borrowableCUSDC.balanceOf(user);
        uint256 marketCollateralBefore =
            borrowableCUSDC.marketCollateralPosted();

        SimplePositionManager.DeleverageAction memory deleverageAction;
        deleverageAction.cToken = ICToken(address(borrowableCUSDC));
        deleverageAction.collateralAssets = 900e6;
        deleverageAction.borrowableCToken =
            IBorrowableCToken(address(borrowableCDAI));
        deleverageAction.swapActions = new SwapperLib.Swap[](1);
        deleverageAction.swapActions[0].inputToken = address(usdc);
        deleverageAction.swapActions[0].inputAmount = 900e6;
        deleverageAction.swapActions[0].outputToken = address(dai);
        deleverageAction.swapActions[0].target = address(_UNISWAP_V2_ROUTER);

        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(dai);
        uint256 expectedDaiOut = IUniswapV2Router(_UNISWAP_V2_ROUTER)
            .getAmountsOut(
                deleverageAction.swapActions[0].inputAmount, path
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
        deleverageAction.repayAssets = expectedDaiOut + 1;

        vm.expectRevert(
            BasePositionManager.BasePositionManager__InsufficientAssetsForRepayment
                .selector
        );
        positionManager.deleverage(deleverageAction, 0.05e18);

        AccountSnapshot memory debtAfter = borrowableCDAI.getSnapshot(user);
        AccountSnapshot memory collAfter = borrowableCUSDC.getSnapshot(user);
        assertEq(debtAfter.debtBalance, debtBefore.debtBalance);
        assertEq(collAfter.collateralPosted, collBefore.collateralPosted);
        assertEq(borrowableCUSDC.balanceOf(user), cTokenBalanceBefore);
        assertEq(
            borrowableCUSDC.marketCollateralPosted(), marketCollateralBefore
        );
        _assertSimplePositionManagerHasNoResidue();

        vm.stopPrank();
    }

    function testDeLeverage_fail_whenPrefundedDebtResidueTerminalCheckRejectsAndRollsBack()
        public
    {
        testLeverage();

        vm.warp(block.timestamp + 20 minutes);
        borrowableCDAI.accrueIfNeeded();

        ExactOutTestSwapTarget swapTarget = new ExactOutTestSwapTarget();
        centralRegistry.setExternalCalldataChecker(
            address(swapTarget),
            address(new MockCalldataChecker(address(swapTarget)))
        );

        uint256 targetDaiOut = 1 ether;
        uint256 pmResidue = 25 ether;
        deal(address(dai), address(swapTarget), targetDaiOut);
        deal(address(dai), address(positionManager), pmResidue);

        vm.startPrank(user);

        PMDeleverageRollbackState memory stateBefore =
            _pmDeleverageRollbackState(address(swapTarget));

        SimplePositionManager.DeleverageAction memory deleverageAction;
        deleverageAction.cToken = ICToken(address(borrowableCUSDC));
        deleverageAction.collateralAssets = 900e6;
        deleverageAction.borrowableCToken =
            IBorrowableCToken(address(borrowableCDAI));
        deleverageAction.swapActions = new SwapperLib.Swap[](1);
        deleverageAction.swapActions[0].inputToken = address(usdc);
        deleverageAction.swapActions[0].inputAmount = 900e6;
        deleverageAction.swapActions[0].outputToken = address(dai);
        deleverageAction.swapActions[0].target = address(swapTarget);
        deleverageAction.swapActions[0].call = abi.encodeWithSelector(
            ExactOutTestSwapTarget.exactSwap.selector,
            address(usdc),
            address(dai),
            900e6,
            targetDaiOut
        );
        deleverageAction.swapActions[0].slippage = 0.999e18;
        deleverageAction.repayAssets = targetDaiOut;

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__InsufficientCollateral
            .selector
        );
        positionManager.deleverage(deleverageAction, 0.999e18);

        _assertPMDeleverageRollbackStateEq(
            _pmDeleverageRollbackState(address(swapTarget)), stateBefore
        );

        vm.stopPrank();
    }

    function testDeLeverage_sweepsPreExistingDebtResidueIntoRepayment()
        public
    {
        testLeverage();

        vm.warp(block.timestamp + 20 minutes);
        borrowableCDAI.accrueIfNeeded();

        uint256 residue = 25 ether;
        deal(address(dai), address(positionManager), residue);

        vm.startPrank(user);

        AccountSnapshot memory debtBefore = borrowableCDAI.getSnapshot(user);
        AccountSnapshot memory collBefore = borrowableCUSDC.getSnapshot(user);

        SimplePositionManager.DeleverageAction memory deleverageAction;
        deleverageAction.cToken = ICToken(address(borrowableCUSDC));
        deleverageAction.collateralAssets = 900e6;
        deleverageAction.borrowableCToken =
            IBorrowableCToken(address(borrowableCDAI));
        deleverageAction.swapActions = new SwapperLib.Swap[](1);
        deleverageAction.swapActions[0].inputToken = address(usdc);
        deleverageAction.swapActions[0].inputAmount = 900e6;
        deleverageAction.swapActions[0].outputToken = address(dai);
        deleverageAction.swapActions[0].target = address(_UNISWAP_V2_ROUTER);

        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(dai);
        uint256 expectedDaiOut = IUniswapV2Router(_UNISWAP_V2_ROUTER)
            .getAmountsOut(
                deleverageAction.swapActions[0].inputAmount, path
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
        deleverageAction.repayAssets = expectedDaiOut + (residue / 2);

        positionManager.deleverage(deleverageAction, 0.05e18);

        AccountSnapshot memory debtAfter = borrowableCDAI.getSnapshot(user);
        AccountSnapshot memory collAfter = borrowableCUSDC.getSnapshot(user);
        uint256 repaid = debtBefore.debtBalance - debtAfter.debtBalance;

        assertGt(repaid, expectedDaiOut);
        assertGe(repaid, deleverageAction.repayAssets);
        assertLt(collAfter.collateralPosted, collBefore.collateralPosted);
        _assertSimplePositionManagerHasNoResidue();

        vm.stopPrank();
    }

    function testDeLeverage_fail_OutputSentAwayRollsBackAtMaxSlippage()
        public
    {
        testLeverage();

        vm.warp(block.timestamp + 20 minutes);
        borrowableCDAI.accrueIfNeeded();

        vm.startPrank(user);

        AccountSnapshot memory debtBefore = borrowableCDAI.getSnapshot(user);
        AccountSnapshot memory collBefore = borrowableCUSDC.getSnapshot(user);
        uint256 cTokenBalanceBefore = borrowableCUSDC.balanceOf(user);
        uint256 marketCollateralBefore =
            borrowableCUSDC.marketCollateralPosted();
        uint256 user2DaiBefore = dai.balanceOf(user2);

        SimplePositionManager.DeleverageAction memory deleverageAction;
        deleverageAction.cToken = ICToken(address(borrowableCUSDC));
        deleverageAction.collateralAssets = 900e6;
        deleverageAction.borrowableCToken =
            IBorrowableCToken(address(borrowableCDAI));
        deleverageAction.swapActions = new SwapperLib.Swap[](1);
        deleverageAction.swapActions[0].inputToken = address(usdc);
        deleverageAction.swapActions[0].inputAmount = 900e6;
        deleverageAction.swapActions[0].outputToken = address(dai);
        deleverageAction.swapActions[0].target = address(_UNISWAP_V2_ROUTER);
        deleverageAction.swapActions[0].slippage = 0.999e18;
        deleverageAction.repayAssets = 1;

        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(dai);
        deleverageAction.swapActions[0].call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            900e6,
            0,
            path,
            user2,
            block.timestamp
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                SwapperLib.SwapperLib__Slippage.selector, 1e18
            )
        );
        positionManager.deleverage(deleverageAction, 0.999e18);

        AccountSnapshot memory debtAfter = borrowableCDAI.getSnapshot(user);
        AccountSnapshot memory collAfter = borrowableCUSDC.getSnapshot(user);
        assertEq(debtAfter.debtBalance, debtBefore.debtBalance);
        assertEq(collAfter.collateralPosted, collBefore.collateralPosted);
        assertEq(borrowableCUSDC.balanceOf(user), cTokenBalanceBefore);
        assertEq(
            borrowableCUSDC.marketCollateralPosted(), marketCollateralBefore
        );
        assertEq(dai.balanceOf(user2), user2DaiBefore);
        _assertSimplePositionManagerHasNoResidue();

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
        uint256 amountForLeverage =
            _maxRemainingLeverageOfHelper(user, address(borrowableCDAI)) / 2;

        SimplePositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken =
            IBorrowableCToken(address(borrowableCDAI));
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

        AccountSnapshot memory borrowableCDAISnapshot =
            borrowableCDAI.getSnapshot(user);
        assertEq(borrowableCDAI.balanceOf(user), 0);
        assertEq(
            borrowableCDAISnapshot.debtBalance, 100 ether + amountForLeverage
        );

        AccountSnapshot memory borrowableCUSDCSnapshot =
            borrowableCUSDC.getSnapshot(user);
        assertGt(borrowableCUSDCSnapshot.collateralPosted, 1900e6);
        assertEq(borrowableCUSDCSnapshot.debtBalance, 0);
        _assertSimplePositionManagerHasNoResidue();

        vm.stopPrank();
    }

    function testDeLeverageFor() public {
        testLeverage();

        // Warp until collateralization cooldown period ends.
        vm.warp(block.timestamp + 20 minutes);
        borrowableCDAI.accrueIfNeeded();

        vm.startPrank(user);
        AccountSnapshot memory borrowableCDAIBeforeSnapshot =
            borrowableCDAI.getSnapshot(user);
        AccountSnapshot memory borrowableCUSDCBeforeSnapshot =
            borrowableCUSDC.getSnapshot(user);

        SimplePositionManager.DeleverageAction memory deleverageAction;
        deleverageAction.cToken = ICToken(address(borrowableCUSDC));
        deleverageAction.collateralAssets = 900e6;
        deleverageAction.borrowableCToken =
            IBorrowableCToken(address(borrowableCDAI));
        deleverageAction.swapActions = new SwapperLib.Swap[](1);
        deleverageAction.swapActions[0].inputToken = address(usdc);
        deleverageAction.swapActions[0].inputAmount = 900e6;
        deleverageAction.swapActions[0].outputToken = address(dai);
        deleverageAction.swapActions[0].target = address(_UNISWAP_V2_ROUTER);
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(dai);

        // Quote amount out from swap. repayAssets serves as a minimum.
        uint256 expectedDaiOut = IUniswapV2Router(_UNISWAP_V2_ROUTER)
            .getAmountsOut(
                deleverageAction.swapActions[0].inputAmount, path
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

        AccountSnapshot memory borrowableCDAISnapshot =
            borrowableCDAI.getSnapshot(user);
        assertEq(borrowableCDAI.balanceOf(user), 0);
        uint256 repaid = borrowableCDAIBeforeSnapshot.debtBalance
            - borrowableCDAISnapshot.debtBalance;
        assertGe(repaid, deleverageAction.repayAssets);
        assertEq(repaid, expectedDaiOut);

        AccountSnapshot memory borrowableCUSDCSnapshot =
            borrowableCUSDC.getSnapshot(user);
        assertEq(
            borrowableCUSDCSnapshot.collateralPosted,
            borrowableCUSDCBeforeSnapshot.collateralPosted
                - deleverageAction.collateralAssets
        );
        assertEq(borrowableCUSDCSnapshot.debtBalance, 0);
        _assertSimplePositionManagerHasNoResidue();

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
        leverageAction.borrowableCToken =
            IBorrowableCToken(address(borrowableCDAI));
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

        uint256 amountForLeverage =
            _maxRemainingLeverageOfHelper(user, address(borrowableCDAI)) / 2;

        SimplePositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken =
            IBorrowableCToken(address(borrowableCDAI));
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

        vm.expectRevert(
            BasePositionManager.BasePositionManager__InvalidSlippage.selector
        );
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

        uint256 amountForLeverage =
            _maxRemainingLeverageOfHelper(user, address(borrowableCDAI)) / 2;

        SimplePositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken =
            IBorrowableCToken(address(borrowableCDAI));
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

    function testLeverage_fail_whenTerminalDebtOracleTurnsCautionAndRollsBackRealPM()
        public
    {
        PMTerminalCautionContext memory ctx = _setupTerminalCautionPMMarket();

        (, uint256 normalDebtError) =
            oracleManager.getPrice(address(ctx.debt), true, false);
        assertEq(normalDebtError, 0, "debt oracle should start clean");

        PMTerminalCautionState memory stateBefore =
            _pmTerminalCautionState(ctx);

        SimplePositionManager.LeverageAction memory leverageAction =
            _terminalCautionLeverageAction(ctx, 100e18, 100e18);

        vm.prank(user);
        vm.expectRevert(OracleManager.OracleManager__ErrorCodeFlagged.selector);
        ctx.pm.leverage(leverageAction, 0.05e18);

        _assertPMTerminalCautionStateEq(
            _pmTerminalCautionState(ctx), stateBefore
        );
        assertEq(ctx.terminalDebtFeed.latestAnswer(), 1e8);
    }

    function _setupTerminalCautionPMMarket()
        internal
        returns (PMTerminalCautionContext memory ctx)
    {
        ctx.market = new MarketManagerIsolated(
            ICentralRegistry(address(centralRegistry)), 10e18, false
        );
        centralRegistry.addMarketManager(address(ctx.market));

        ctx.debt = new OracleFlipToken("PM Debt", "pmDEBT", 18);
        ctx.collateral = new OracleFlipToken("PM Collateral", "pmCOLL", 18);

        ctx.collateralCToken = new SimpleCToken(
            ICentralRegistry(address(centralRegistry)),
            IERC20(address(ctx.collateral)),
            address(ctx.market)
        );
        ctx.debtCToken = new BorrowableCToken(
            ICentralRegistry(address(centralRegistry)),
            IERC20(address(ctx.debt)),
            address(ctx.market),
            _deployDynamicIRM(address(ctx.debt))
        );
        IRMs[block.chainid][address(
                ctx.debt
            )].setLinkedToken(address(ctx.debtCToken));

        ctx.pm = new SimplePositionManager(
            ICentralRegistry(address(centralRegistry)),
            address(ctx.market),
            _WETH_ADDRESS
        );
        ctx.market.addPositionManager(address(ctx.pm));

        MockV3Aggregator collateralFeed = new MockV3Aggregator(8, 1e8);
        MockV3Aggregator primaryDebtFeed = new MockV3Aggregator(8, 1e8);
        ctx.terminalDebtFeed = new MockV3Aggregator(8, 1e8);

        chainlinkAdaptor.addAsset(
            address(ctx.collateral), true, address(collateralFeed), 0
        );
        chainlinkAdaptor.addAsset(
            address(ctx.debt), true, address(primaryDebtFeed), 0
        );
        dualChainlinkAdaptor.addAsset(
            address(ctx.debt), true, address(ctx.terminalDebtFeed), 0
        );

        oracleManager.addAssetPricingAdaptor(
            address(ctx.collateral),
            address(chainlinkAdaptor),
            500,
            50,
            500,
            50
        );
        oracleManager.addAssetPricingAdaptor(
            address(ctx.debt), address(chainlinkAdaptor), 250, 150, 250, 150
        );
        oracleManager.addAssetPricingAdaptor(
            address(ctx.debt),
            address(dualChainlinkAdaptor),
            250,
            150,
            250,
            150
        );
        oracleManager.addCTokenSupport(address(ctx.collateralCToken));
        oracleManager.addCTokenSupport(address(ctx.debtCToken));

        ctx.debt.mint(address(this), 20_000e18);
        ctx.collateral.mint(address(this), 20_000e18);
        ctx.debt.approve(address(ctx.debtCToken), type(uint256).max);
        ctx.collateral
            .approve(address(ctx.collateralCToken), type(uint256).max);

        ctx.market
            .listTokens(address(ctx.collateralCToken), address(ctx.debtCToken));
        _setCTokenConfigBasic(
            ctx.market, address(ctx.collateralCToken), 100_000e18, 0
        );
        _setCTokenConfigBasic(
            ctx.market, address(ctx.debtCToken), 100_000e18, 100_000e18
        );

        ctx.debtCToken.deposit(10_000e18, address(this));

        ctx.collateral.mint(user, 1_000e18);
        vm.startPrank(user);
        ctx.collateral
            .approve(address(ctx.collateralCToken), type(uint256).max);
        ctx.collateralCToken.depositAsCollateral(1_000e18, user);
        vm.stopPrank();

        ctx.swapTarget = new ExactOutTestSwapTarget();
        centralRegistry.setExternalCalldataChecker(
            address(ctx.swapTarget),
            address(new MockCalldataChecker(address(ctx.swapTarget)))
        );

        ctx.collateral.mint(address(ctx.swapTarget), 100e18);
        ctx.collateral
            .configureOracleFlip(
                address(ctx.collateralCToken),
                address(ctx.pm),
                address(ctx.collateralCToken),
                ctx.terminalDebtFeed,
                102e6
            );
    }

    function _terminalCautionLeverageAction(
        PMTerminalCautionContext memory ctx,
        uint256 borrowAssets,
        uint256 collateralOut
    )
        internal
        view
        returns (SimplePositionManager.LeverageAction memory action)
    {
        action.borrowableCToken = IBorrowableCToken(address(ctx.debtCToken));
        action.borrowAssets = borrowAssets;
        action.cToken = ICToken(address(ctx.collateralCToken));
        action.expectedShares = 1;
        action.swapAction.inputToken = address(ctx.debt);
        action.swapAction.inputAmount = borrowAssets;
        action.swapAction.outputToken = address(ctx.collateral);
        action.swapAction.target = address(ctx.swapTarget);
        action.swapAction.call = abi.encodeWithSelector(
            ExactOutTestSwapTarget.exactSwap.selector,
            address(ctx.debt),
            address(ctx.collateral),
            borrowAssets,
            collateralOut
        );
        action.swapAction.slippage = 0.3e18;
    }

    function _pmTerminalCautionState(PMTerminalCautionContext memory ctx)
        internal
        view
        returns (PMTerminalCautionState memory state)
    {
        state.debtSnapshot = ctx.debtCToken.getSnapshot(user);
        state.collateralSnapshot = ctx.collateralCToken.getSnapshot(user);
        state.cTokenBalance = ctx.collateralCToken.balanceOf(user);
        state.marketCollateral = ctx.collateralCToken.marketCollateralPosted();
        state.marketDebt = ctx.debtCToken.marketOutstandingDebt();
        state.userDebtToken = ctx.debt.balanceOf(user);
        state.userCollateralToken = ctx.collateral.balanceOf(user);
        state.pmDebtToken = ctx.debt.balanceOf(address(ctx.pm));
        state.pmCollateralToken = ctx.collateral.balanceOf(address(ctx.pm));
        state.targetDebtToken = ctx.debt.balanceOf(address(ctx.swapTarget));
        state.targetCollateralToken =
            ctx.collateral.balanceOf(address(ctx.swapTarget));
    }

    function _assertPMTerminalCautionStateEq(
        PMTerminalCautionState memory actual,
        PMTerminalCautionState memory expected
    ) internal pure {
        assertEq(
            actual.debtSnapshot.debtBalance, expected.debtSnapshot.debtBalance
        );
        assertEq(
            actual.collateralSnapshot.collateralPosted,
            expected.collateralSnapshot.collateralPosted
        );
        assertEq(actual.cTokenBalance, expected.cTokenBalance);
        assertEq(actual.marketCollateral, expected.marketCollateral);
        assertEq(actual.marketDebt, expected.marketDebt);
        assertEq(actual.userDebtToken, expected.userDebtToken);
        assertEq(actual.userCollateralToken, expected.userCollateralToken);
        assertEq(actual.pmDebtToken, expected.pmDebtToken);
        assertEq(actual.pmCollateralToken, expected.pmCollateralToken);
        assertEq(actual.targetDebtToken, expected.targetDebtToken);
        assertEq(actual.targetCollateralToken, expected.targetCollateralToken);
    }

    function _setCTokenConfigBasic(
        MarketManagerIsolated manager,
        address cToken,
        uint256 collateralCap,
        uint256 debtCap
    ) internal {
        MarketManagerIsolated.TokenConfig memory tokenConfig;
        tokenConfig.cToken = cToken;
        tokenConfig.collRatio = 7000;
        tokenConfig.collReqSoft = 4000;
        tokenConfig.collReqHard = 3000;
        tokenConfig.liqIncBase = 1000;
        tokenConfig.liqIncHard = 1500;
        tokenConfig.liqIncMin = 10;
        tokenConfig.liqIncMax = 2000;
        tokenConfig.closeFactorBase = 2000;
        tokenConfig.closeFactorMin = 2000;
        tokenConfig.closeFactorMax = 5000;
        tokenConfig.collateralCap = collateralCap;
        tokenConfig.debtCap = debtCap;

        manager.updateTokenConfig(tokenConfig);
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

    function _pmDeleverageRollbackState(address swapTarget)
        internal
        view
        returns (PMDeleverageRollbackState memory state)
    {
        state.debtSnapshot = borrowableCDAI.getSnapshot(user);
        state.collateralSnapshot = borrowableCUSDC.getSnapshot(user);
        state.cTokenBalance = borrowableCUSDC.balanceOf(user);
        state.marketCollateral = borrowableCUSDC.marketCollateralPosted();
        state.userDai = dai.balanceOf(user);
        state.userUsdc = usdc.balanceOf(user);
        state.pmDai = dai.balanceOf(address(positionManager));
        state.pmUsdc = usdc.balanceOf(address(positionManager));
        state.targetDai = dai.balanceOf(swapTarget);
        state.targetUsdc = usdc.balanceOf(swapTarget);
    }

    function _assertPMDeleverageRollbackStateEq(
        PMDeleverageRollbackState memory actual,
        PMDeleverageRollbackState memory expected
    ) internal pure {
        assertEq(
            actual.debtSnapshot.debtBalance, expected.debtSnapshot.debtBalance
        );
        assertEq(
            actual.collateralSnapshot.collateralPosted,
            expected.collateralSnapshot.collateralPosted
        );
        assertEq(actual.cTokenBalance, expected.cTokenBalance);
        assertEq(actual.marketCollateral, expected.marketCollateral);
        assertEq(actual.userDai, expected.userDai);
        assertEq(actual.userUsdc, expected.userUsdc);
        assertEq(actual.pmDai, expected.pmDai);
        assertEq(actual.pmUsdc, expected.pmUsdc);
        assertEq(actual.targetDai, expected.targetDai);
        assertEq(actual.targetUsdc, expected.targetUsdc);
    }

    function _assertSimplePositionManagerHasNoResidue() internal view {
        assertEq(address(positionManager).balance, 0, "PM native residue");
        assertEq(
            usdc.balanceOf(address(positionManager)), 0, "PM USDC residue"
        );
        assertEq(dai.balanceOf(address(positionManager)), 0, "PM DAI residue");
        assertEq(
            borrowableCUSDC.balanceOf(address(positionManager)),
            0,
            "PM cUSDC residue"
        );
        assertEq(
            borrowableCDAI.balanceOf(address(positionManager)),
            0,
            "PM cDAI residue"
        );
    }
}

contract OracleFlipToken is ERC20 {
    string internal _name;
    string internal _symbol;
    uint8 internal _decimals;

    address public triggerCaller;
    address public triggerFrom;
    address public triggerTo;
    MockV3Aggregator public triggerFeed;
    int256 public triggerAnswer;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        _name = name_;
        _symbol = symbol_;
        _decimals = decimals_;
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function configureOracleFlip(
        address caller,
        address from,
        address to,
        MockV3Aggregator feed,
        int256 answer
    ) external {
        triggerCaller = caller;
        triggerFrom = from;
        triggerTo = to;
        triggerFeed = feed;
        triggerAnswer = answer;
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount)
        internal
        override
    {
        amount;
        if (
            msg.sender == triggerCaller && from == triggerFrom
                && to == triggerTo && address(triggerFeed) != address(0)
        ) {
            triggerFeed.updateAnswer(triggerAnswer);
        }
    }
}

contract ExactOutTestSwapTarget {
    function exactSwap(
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 outputAmount
    ) external {
        IERC20(inputToken).transferFrom(msg.sender, address(this), inputAmount);
        IERC20(outputToken).transfer(msg.sender, outputAmount);
    }
}
