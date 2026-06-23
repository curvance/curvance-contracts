// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {SwapperLib} from "contracts/libraries/SwapperLib.sol";
import {SimpleZapper} from "contracts/plugins/market/SimpleZapper.sol";
import {BaseZapper} from "contracts/plugins/BaseZapper.sol";
import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";
import {ICToken} from "contracts/interfaces/ICToken.sol";
import {SimpleCToken, IERC20} from "contracts/market/token/SimpleCToken.sol";
import {
    IUniswapV3Router
} from "contracts/interfaces/external/uniswap/IUniswapV3Router.sol";
import {Multicall} from "contracts/libraries/Multicall.sol";

import {TestBaseMarketIsolated} from "tests/market/TestBaseMarketIsolated.sol";
import {MockCalldataChecker} from "contracts/mocks/MockCalldataChecker.sol";
import {
    MarketManagerIsolated
} from "contracts/market/isolated/MarketManagerIsolated.sol";

contract TestSimpleZapper is TestBaseMarketIsolated {
    address internal _UNISWAP_V3_SWAP_ROUTER =
        0xE592427A0AEce92De3Edee1F18E0157C05861564;
    uint256 internal constant _TEST_SWAP_SLIPPAGE = 0.01e18;

    SimpleZapper public simpleZapper;

    receive() external payable {}

    fallback() external payable {}

    function setUp() public override {
        super.setUp();

        oracleManager.addCTokenSupport(address(simpleCUSDC));

        simpleZapper = new SimpleZapper(
            ICentralRegistry(address(centralRegistry)), _WETH_ADDRESS
        );

        centralRegistry.setExternalCalldataChecker(
            _UNISWAP_V3_SWAP_ROUTER,
            address(new MockCalldataChecker(_UNISWAP_V3_SWAP_ROUTER))
        );

        _prepareDAI(address(this), 200000e18);
        dai.approve(address(borrowableCDAI), 200000e18);

        _prepareUSDC(address(this), 100e6);
        usdc.approve(address(simpleCUSDC), 100e6);

        marketManagerIsolated.listTokens(
            address(simpleCUSDC), address(borrowableCDAI)
        );

        _setCTokenConfigHighValues(address(simpleCUSDC), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCDAI), 100_000e18, 100_000e18);

        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareDAI(liquidityProvider, 1000 ether);
        _prepareUSDC(liquidityProvider, 100e6);

        vm.startPrank(liquidityProvider);

        // Mint borrowable cDAI.
        dai.approve(address(borrowableCDAI), 1000 ether);
        borrowableCDAI.deposit(1000 ether, liquidityProvider);
        // mint simpleCUSDC
        usdc.approve(address(simpleCUSDC), 100e6);
        simpleCUSDC.mint(100e6, liquidityProvider);

        vm.stopPrank();
    }

    function testSwapAndDeposit() public {
        uint256 ethAmount = 3 ether;
        vm.deal(user1, ethAmount);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
        swapAction.inputAmount = ethAmount;
        swapAction.target = _UNISWAP_V3_SWAP_ROUTER;
        swapAction.outputToken = address(usdc);

        IUniswapV3Router.ExactInputSingleParams memory params;
        params.tokenIn = _WETH_ADDRESS;
        params.tokenOut = _USDC_ADDRESS;
        params.fee = 100;
        params.recipient = address(simpleZapper);
        params.deadline = block.timestamp;
        params.amountIn = 3 ether;
        params.amountOutMinimum = 0;
        params.sqrtPriceLimitX96 = 0;
        swapAction.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector, params
        );

        vm.prank(user1);
        uint256 returnedShares = simpleZapper.swapAndDeposit{value: ethAmount}(
            address(simpleCUSDC),
            false, // was false before contract refactor
            swapAction,
            0,
            false,
            user1
        );

        assertEq(user1.balance, 0, "user should spend all ETH");
        assertEq(
            simpleCUSDC.balanceOf(user1),
            returnedShares,
            "receiver shares should match returned shares"
        );
        assertGt(returnedShares, 0, "zap should mint cToken shares");
        _assertSimpleZapperHasNoResidue();
    }

    function testSwapAndDeposit_fail_expectedSharesTooHighRollsBack() public {
        uint256 amount = 10e6;
        _prepareUSDC(user1, amount);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = amount;
        swapAction.outputToken = _USDC_ADDRESS;

        vm.startPrank(user1);
        usdc.approve(address(simpleZapper), amount);

        uint256 userUsdcBefore = usdc.balanceOf(user1);
        uint256 userSharesBefore = simpleCUSDC.balanceOf(user1);
        uint256 totalAssetsBefore = simpleCUSDC.totalAssets();

        vm.expectRevert(BaseZapper.BaseZapper__ExecutionError.selector);
        simpleZapper.swapAndDeposit(
            address(simpleCUSDC),
            false,
            swapAction,
            type(uint256).max,
            false,
            user1
        );

        assertEq(usdc.balanceOf(user1), userUsdcBefore);
        assertEq(simpleCUSDC.balanceOf(user1), userSharesBefore);
        assertEq(simpleCUSDC.totalAssets(), totalAssetsBefore);
        _assertSimpleZapperHasNoResidue();
        vm.stopPrank();
    }

    function testSwapAndDeposit_fail_collateralizeForNonDelegateRollsBack()
        public
    {
        uint256 amount = 10e6;
        _prepareUSDC(user2, amount);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = amount;
        swapAction.outputToken = _USDC_ADDRESS;

        vm.startPrank(user2);
        usdc.approve(address(simpleZapper), amount);

        uint256 payerUsdcBefore = usdc.balanceOf(user2);
        uint256 receiverSharesBefore = simpleCUSDC.balanceOf(user1);
        uint256 receiverCollateralBefore = simpleCUSDC.collateralPosted(user1);

        vm.expectRevert(BaseZapper.BaseZapper__Unauthorized.selector);
        simpleZapper.swapAndDeposit(
            address(simpleCUSDC), false, swapAction, 0, true, user1
        );

        assertEq(usdc.balanceOf(user2), payerUsdcBefore);
        assertEq(simpleCUSDC.balanceOf(user1), receiverSharesBefore);
        assertEq(simpleCUSDC.collateralPosted(user1), receiverCollateralBefore);
        _assertSimpleZapperHasNoResidue();
        vm.stopPrank();
    }

    function testSwapAndDeposit_preExistingOutputResidueDoesNotMintExtraShares()
        public
    {
        uint256 residue = 25e6;
        _prepareUSDC(address(simpleZapper), residue);

        uint256 ethAmount = 1 ether;
        vm.deal(user1, ethAmount);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
        swapAction.inputAmount = ethAmount;
        swapAction.target = _UNISWAP_V3_SWAP_ROUTER;
        swapAction.outputToken = address(usdc);
        swapAction.slippage = _TEST_SWAP_SLIPPAGE;

        IUniswapV3Router.ExactInputSingleParams memory params;
        params.tokenIn = _WETH_ADDRESS;
        params.tokenOut = _USDC_ADDRESS;
        params.fee = 100;
        params.recipient = address(simpleZapper);
        params.deadline = block.timestamp;
        params.amountIn = ethAmount;
        params.amountOutMinimum = 0;
        params.sqrtPriceLimitX96 = 0;
        swapAction.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector, params
        );

        uint256 userSharesBefore = simpleCUSDC.balanceOf(user1);

        vm.prank(user1);
        uint256 returnedShares = simpleZapper.swapAndDeposit{value: ethAmount}(
            address(simpleCUSDC), false, swapAction, 0, false, user1
        );

        assertEq(
            simpleCUSDC.balanceOf(user1) - userSharesBefore,
            returnedShares,
            "fresh share delta should match returned shares"
        );
        assertGt(returnedShares, 0, "zap should mint fresh shares");
        assertEq(
            usdc.balanceOf(address(simpleZapper)),
            residue,
            "pre-existing output residue should not be deposited"
        );
    }

    function test_swapAndDeposit_fail_unlistedCTokenBeforeAssetLookup()
        public
    {
        address fakeCToken = address(0xBEEF);

        vm.mockCall(
            fakeCToken,
            abi.encodeWithSelector(ICToken.marketManager.selector),
            abi.encode(address(marketManagerIsolated))
        );
        vm.mockCallRevert(
            fakeCToken,
            abi.encodeWithSelector(ICToken.asset.selector),
            "asset called"
        );

        SwapperLib.Swap memory swapAction;
        swapAction.outputToken = address(usdc);

        vm.expectRevert(BaseZapper.BaseZapper__Unauthorized.selector);
        simpleZapper.swapAndDeposit(
            fakeCToken, false, swapAction, 0, false, user1
        );
    }

    function testSwapAndRepay() external {
        testSwapAndDeposit();
        vm.startPrank(user1);
        simpleCUSDC.postCollateral(2e9);

        // try borrow()
        borrowableCDAI.borrow(500 ether, user1);
        vm.stopPrank();

        assertEq(dai.balanceOf(user1), 500 ether);
        assertApproxEqAbs(
            borrowableCDAI.debtBalance(user1), 500 ether, 1 ether
        );

        // skip min hold period
        skip(20 minutes);

        uint256 debt = borrowableCDAI.debtBalanceUpdated(user1);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 505e6; // Buffer so we dont end up with lower than min loan.
        swapAction.outputToken = _DAI_ADDRESS;
        swapAction.target = _UNISWAP_V3_SWAP_ROUTER;
        swapAction.slippage = _TEST_SWAP_SLIPPAGE;
        IUniswapV3Router.ExactInputSingleParams memory params;
        params.tokenIn = _USDC_ADDRESS;
        params.tokenOut = _DAI_ADDRESS;
        params.fee = 100;
        params.recipient = address(simpleZapper);
        params.deadline = block.timestamp;
        params.amountIn = 505e6;
        params.amountOutMinimum = 0;
        params.sqrtPriceLimitX96 = 0;
        swapAction.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector, params
        );

        _prepareUSDC(user1, 505e6);
        vm.startPrank(user1);
        usdc.approve(address(simpleZapper), 505e6);
        simpleZapper.swapAndRepay(
            address(borrowableCDAI),
            false,
            swapAction,
            debt, // swapAndRepay will repay up to totalDebt and refund dust
            user1
        );
        vm.stopPrank();

        assertEq(borrowableCDAI.debtBalance(user1), 0);
        assertGt(
            dai.balanceOf(user1), 500 ether, "user should receive swap dust"
        );
        _assertSimpleZapperHasNoResidue();
    }

    function testSwapAndRepay_fail_ZeroRepayAssets() external {
        SwapperLib.Swap memory swapAction;

        vm.prank(user1);
        vm.expectRevert(BaseZapper.BaseZapper__InvalidRepaymentAmount.selector);
        simpleZapper.swapAndRepay(
            address(borrowableCDAI), false, swapAction, 0, user1
        );
    }

    function testSwapAndRepayDifferentRepayer() external {
        testSwapAndDeposit();
        vm.startPrank(user1);
        simpleCUSDC.postCollateral(2e9);

        // try borrow()
        borrowableCDAI.borrow(500 ether, user1);
        vm.stopPrank();

        assertEq(dai.balanceOf(user1), 500 ether);

        // skip min hold period
        skip(20 minutes);

        uint256 user2DaiBalanceBefore = dai.balanceOf(user2);
        uint256 debt = borrowableCDAI.debtBalanceUpdated(user1);

        // swap 501 as a buffer for interest and slippage.
        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 505e6; // buffer for interest + swap fee
        swapAction.outputToken = _DAI_ADDRESS;
        swapAction.target = _UNISWAP_V3_SWAP_ROUTER;
        swapAction.slippage = _TEST_SWAP_SLIPPAGE;
        IUniswapV3Router.ExactInputSingleParams memory params;
        params.tokenIn = _USDC_ADDRESS;
        params.tokenOut = _DAI_ADDRESS;
        params.fee = 100;
        params.recipient = address(simpleZapper);
        params.deadline = block.timestamp;
        params.amountIn = 505e6;
        params.amountOutMinimum = 0;
        params.sqrtPriceLimitX96 = 0;
        swapAction.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector, params
        );

        // user2 pays the debt, and should receive the excess dai from the swap.
        _prepareUSDC(user2, 505e6);
        vm.startPrank(user2);
        usdc.approve(address(simpleZapper), 505e6);
        simpleZapper.swapAndRepay(
            address(borrowableCDAI),
            false,
            swapAction,
            debt, // must be non-zero
            user1
        );
        vm.stopPrank();

        uint256 user2DaiBalanceAfter = dai.balanceOf(user2);
        assertGt(
            user2DaiBalanceAfter,
            user2DaiBalanceBefore,
            "Excess dai should be sent to user2"
        );

        assertEq(
            borrowableCDAI.debtBalance(user1), 0, "Debt should be fully repaid"
        );
        _assertSimpleZapperHasNoResidue();
    }

    function testSwapAndRepay_doesNotGuaranteeReceiverMinCredit() external {
        testSwapAndDeposit();
        vm.startPrank(user1);
        simpleCUSDC.postCollateral(2e9);
        borrowableCDAI.borrow(500 ether, user1);
        vm.stopPrank();

        skip(20 minutes);

        uint256 receiverDebtBefore = borrowableCDAI.debtBalanceUpdated(user1);
        uint256 repayAssets = receiverDebtBefore + 1;
        uint256 user1DaiBalanceBefore = dai.balanceOf(user1);
        uint256 user2DaiBalanceBefore = dai.balanceOf(user2);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 505e6;
        swapAction.outputToken = _DAI_ADDRESS;
        swapAction.target = _UNISWAP_V3_SWAP_ROUTER;
        swapAction.slippage = _TEST_SWAP_SLIPPAGE;
        IUniswapV3Router.ExactInputSingleParams memory params;
        params.tokenIn = _USDC_ADDRESS;
        params.tokenOut = _DAI_ADDRESS;
        params.fee = 100;
        params.recipient = address(simpleZapper);
        params.deadline = block.timestamp;
        params.amountIn = 505e6;
        params.amountOutMinimum = 0;
        params.sqrtPriceLimitX96 = 0;
        swapAction.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector, params
        );

        _prepareUSDC(user2, 505e6);
        vm.startPrank(user2);
        usdc.approve(address(simpleZapper), 505e6);
        uint256 returnedToCaller = simpleZapper.swapAndRepay(
            address(borrowableCDAI), false, swapAction, repayAssets, user1
        );
        vm.stopPrank();

        uint256 user2DaiBalanceAfter = dai.balanceOf(user2);

        assertLt(
            receiverDebtBefore,
            repayAssets,
            "precondition: repay floor should exceed live debt"
        );
        assertEq(
            borrowableCDAI.debtBalance(user1), 0, "Debt should be fully repaid"
        );
        assertEq(
            dai.balanceOf(user1),
            user1DaiBalanceBefore,
            "receiver should not get direct transfer"
        );
        assertEq(
            user2DaiBalanceAfter - user2DaiBalanceBefore,
            returnedToCaller,
            "caller should receive leftover debt asset"
        );
        assertGt(
            returnedToCaller, 0, "caller should receive leftover debt asset"
        );
        _assertSimpleZapperHasNoResidue();
    }

    function testSwapAndRepay_preExistingDebtResidueDoesNotSatisfyRepayFloor()
        public
    {
        testSwapAndDeposit();

        vm.startPrank(user1);
        simpleCUSDC.postCollateral(2e9);
        borrowableCDAI.borrow(500 ether, user1);
        vm.stopPrank();

        skip(20 minutes);

        uint256 residue = 25 ether;
        deal(address(dai), address(simpleZapper), residue);

        uint256 inputAmount = 1 ether;
        _prepareDAI(user2, inputAmount);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _DAI_ADDRESS;
        swapAction.inputAmount = inputAmount;
        swapAction.outputToken = _DAI_ADDRESS;

        uint256 debtBefore = borrowableCDAI.debtBalanceUpdated(user1);
        uint256 payerDaiBefore = dai.balanceOf(user2);

        vm.startPrank(user2);
        dai.approve(address(simpleZapper), inputAmount);

        vm.expectRevert(
            BaseZapper.BaseZapper__InsufficientAssetsForRepayment.selector
        );
        simpleZapper.swapAndRepay(
            address(borrowableCDAI), false, swapAction, inputAmount + 1, user1
        );

        assertEq(borrowableCDAI.debtBalance(user1), debtBefore);
        assertEq(dai.balanceOf(user2), payerDaiBefore);
        assertEq(
            dai.balanceOf(address(simpleZapper)),
            residue,
            "pre-existing debt residue should not satisfy repay floor"
        );
        vm.stopPrank();
    }

    function testRedeemAndSwapCToken() public {
        testSwapAndDeposit();

        vm.prank(user1);
        simpleCUSDC.setDelegateApproval(address(simpleZapper), true);

        uint256 shares = simpleCUSDC.balanceOf(user1);

        BaseZapper.RedeemAction memory redeemAction;
        redeemAction.cToken = address(simpleCUSDC);
        redeemAction.shares = shares;
        redeemAction.forceRedeemCollateral = false;

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = shares;
        swapAction.outputToken = _WETH_ADDRESS;
        swapAction.target = _UNISWAP_V3_SWAP_ROUTER;
        swapAction.slippage = _TEST_SWAP_SLIPPAGE;

        IUniswapV3Router.ExactInputSingleParams memory params;
        params.tokenIn = _USDC_ADDRESS;
        params.tokenOut = _WETH_ADDRESS;
        params.fee = 100;
        params.recipient = address(simpleZapper);
        params.deadline = block.timestamp;
        params.amountIn = shares;
        params.amountOutMinimum = 0;
        params.sqrtPriceLimitX96 = 0;
        swapAction.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector, params
        );

        uint256 userWethBefore = weth.balanceOf(user1);
        vm.prank(user1);
        uint256 returnedOut =
            simpleZapper.redeemAndSwap(redeemAction, swapAction, user1);

        assertGt(returnedOut, 2.99 ether, "weth balance of user1 mismatch"); // 3 ether - fees
        assertEq(
            weth.balanceOf(user1) - userWethBefore,
            returnedOut,
            "receiver WETH delta should match returned output"
        );
        _assertSimpleZapperHasNoResidue();
    }

    function testRedeemAndSwapCToken_fail_zeroReceiver() public {
        _prepareUSDC(user1, 10e6);

        vm.startPrank(user1);
        usdc.approve(address(simpleCUSDC), 10e6);
        uint256 shares = simpleCUSDC.deposit(10e6, user1);
        simpleCUSDC.setDelegateApproval(address(simpleZapper), true);

        BaseZapper.RedeemAction memory redeemAction;
        redeemAction.cToken = address(simpleCUSDC);
        redeemAction.shares = shares;
        redeemAction.forceRedeemCollateral = false;

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 10e6;
        swapAction.outputToken = _USDC_ADDRESS;

        uint256 userUsdcBefore = usdc.balanceOf(user1);

        vm.expectRevert(BaseZapper.BaseZapper__ExecutionError.selector);
        simpleZapper.redeemAndSwap(redeemAction, swapAction, address(0));

        assertEq(simpleCUSDC.balanceOf(user1), shares);
        assertEq(usdc.balanceOf(user1), userUsdcBefore);
        _assertSimpleZapperHasNoResidue();
        vm.stopPrank();
    }

    function testRedeemAndSwapCToken_routesOutputToReceiverButBurnsCallerShares()
        public
    {
        _prepareUSDC(user1, 10e6);

        vm.startPrank(user1);
        usdc.approve(address(simpleCUSDC), 10e6);
        uint256 shares = simpleCUSDC.deposit(10e6, user1);
        simpleCUSDC.setDelegateApproval(address(simpleZapper), true);
        vm.stopPrank();

        uint256 receiverUsdcBefore = usdc.balanceOf(user2);

        BaseZapper.RedeemAction memory redeemAction;
        redeemAction.cToken = address(simpleCUSDC);
        redeemAction.shares = shares;
        redeemAction.forceRedeemCollateral = false;

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 10e6;
        swapAction.outputToken = _USDC_ADDRESS;

        vm.prank(user1);
        simpleZapper.redeemAndSwap(redeemAction, swapAction, user2);

        assertEq(simpleCUSDC.balanceOf(user1), 0);
        assertEq(usdc.balanceOf(user2) - receiverUsdcBefore, 10e6);
    }

    function testRedeemAndSwapCToken_fail_cannotRedeemReceiverShares() public {
        _prepareUSDC(user1, 10e6);

        vm.startPrank(user1);
        usdc.approve(address(simpleCUSDC), 10e6);
        uint256 victimShares = simpleCUSDC.deposit(10e6, user1);
        simpleCUSDC.setDelegateApproval(address(simpleZapper), true);
        vm.stopPrank();

        uint256 victimUsdcBefore = usdc.balanceOf(user1);
        uint256 callerUsdcBefore = usdc.balanceOf(user2);

        BaseZapper.RedeemAction memory redeemAction;
        redeemAction.cToken = address(simpleCUSDC);
        redeemAction.shares = victimShares;
        redeemAction.forceRedeemCollateral = false;

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 10e6;
        swapAction.outputToken = _USDC_ADDRESS;

        vm.prank(user2);
        vm.expectRevert();
        simpleZapper.redeemAndSwap(redeemAction, swapAction, user1);

        assertEq(simpleCUSDC.balanceOf(user1), victimShares);
        assertEq(usdc.balanceOf(user1), victimUsdcBefore);
        assertEq(usdc.balanceOf(user2), callerUsdcBefore);
    }

    function testRedeemAndSwapBorrowableCToken() public {
        vm.startPrank(user1);

        // Mint borrowable cDAI.
        _prepareDAI(user1, 10 ether);
        dai.approve(address(borrowableCDAI), 10 ether);
        borrowableCDAI.deposit(10 ether, user1);

        borrowableCDAI.setDelegateApproval(address(simpleZapper), true);

        BaseZapper.RedeemAction memory redeemAction;
        redeemAction.cToken = address(borrowableCDAI);
        redeemAction.shares = 10 ether;
        redeemAction.forceRedeemCollateral = false;

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _DAI_ADDRESS;
        swapAction.inputAmount = 10 ether;
        swapAction.outputToken = _USDC_ADDRESS;
        swapAction.target = _UNISWAP_V3_SWAP_ROUTER;
        swapAction.slippage = _TEST_SWAP_SLIPPAGE;
        IUniswapV3Router.ExactInputSingleParams memory params;
        params.tokenIn = _DAI_ADDRESS;
        params.tokenOut = _USDC_ADDRESS;
        params.fee = 100;
        params.recipient = address(simpleZapper);
        params.deadline = block.timestamp;
        params.amountIn = 10 ether;
        params.amountOutMinimum = 0;
        params.sqrtPriceLimitX96 = 0;
        swapAction.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector, params
        );

        uint256 userUsdcBefore = usdc.balanceOf(user1);
        uint256 returnedOut =
            simpleZapper.redeemAndSwap(redeemAction, swapAction, user1);

        assertEq(
            usdc.balanceOf(user1) - userUsdcBefore,
            returnedOut,
            "receiver USDC delta should match returned output"
        );
        assertGt(returnedOut, 9.99e6, "redeem swap should clear fee floor");

        vm.stopPrank();
    }

    function testRedeemAndSwapBorrowableCToken_fail_TightSwapSafeSlippage()
        public
    {
        vm.startPrank(user1);

        _prepareDAI(user1, 10 ether);
        dai.approve(address(borrowableCDAI), 10 ether);
        borrowableCDAI.deposit(10 ether, user1);

        borrowableCDAI.setDelegateApproval(address(simpleZapper), true);

        uint256 sharesBefore = borrowableCDAI.balanceOf(user1);
        uint256 daiBefore = dai.balanceOf(user1);
        uint256 usdcBefore = usdc.balanceOf(user1);

        BaseZapper.RedeemAction memory redeemAction;
        redeemAction.cToken = address(borrowableCDAI);
        redeemAction.shares = 10 ether;
        redeemAction.forceRedeemCollateral = false;

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _DAI_ADDRESS;
        swapAction.inputAmount = 10 ether;
        swapAction.outputToken = _USDC_ADDRESS;
        swapAction.target = _UNISWAP_V3_SWAP_ROUTER;
        swapAction.slippage = 0;
        IUniswapV3Router.ExactInputSingleParams memory params;
        params.tokenIn = _DAI_ADDRESS;
        params.tokenOut = _USDC_ADDRESS;
        params.fee = 100;
        params.recipient = address(simpleZapper);
        params.deadline = block.timestamp;
        params.amountIn = 10 ether;
        params.amountOutMinimum = 0;
        params.sqrtPriceLimitX96 = 0;
        swapAction.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector, params
        );

        vm.expectPartialRevert(SwapperLib.SwapperLib__Slippage.selector);
        simpleZapper.redeemAndSwap(redeemAction, swapAction, user1);

        assertEq(borrowableCDAI.balanceOf(user1), sharesBefore);
        assertEq(dai.balanceOf(user1), daiBefore);
        assertEq(usdc.balanceOf(user1), usdcBefore);
        _assertSimpleZapperHasNoResidue();

        vm.stopPrank();
    }

    function testRedeemAndSwapCToken_fail_OutputSentAwayRollsBackAtMaxSlippage()
        public
    {
        uint256 amount = 10e6;
        _prepareUSDC(user1, amount);

        vm.startPrank(user1);
        usdc.approve(address(simpleCUSDC), amount);
        uint256 shares = simpleCUSDC.deposit(amount, user1);
        simpleCUSDC.setDelegateApproval(address(simpleZapper), true);

        uint256 sharesBefore = simpleCUSDC.balanceOf(user1);
        uint256 usdcBefore = usdc.balanceOf(user1);
        uint256 user2WethBefore = weth.balanceOf(user2);

        BaseZapper.RedeemAction memory redeemAction;
        redeemAction.cToken = address(simpleCUSDC);
        redeemAction.shares = shares;
        redeemAction.forceRedeemCollateral = false;

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = amount;
        swapAction.outputToken = _WETH_ADDRESS;
        swapAction.target = _UNISWAP_V3_SWAP_ROUTER;
        swapAction.slippage = _TEST_SWAP_SLIPPAGE;

        IUniswapV3Router.ExactInputSingleParams memory params;
        params.tokenIn = _USDC_ADDRESS;
        params.tokenOut = _WETH_ADDRESS;
        params.fee = 100;
        params.recipient = user2;
        params.deadline = block.timestamp;
        params.amountIn = amount;
        params.amountOutMinimum = 0;
        params.sqrtPriceLimitX96 = 0;
        swapAction.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector, params
        );

        vm.expectPartialRevert(SwapperLib.SwapperLib__Slippage.selector);
        simpleZapper.redeemAndSwap(redeemAction, swapAction, user1);

        assertEq(
            simpleCUSDC.balanceOf(user1),
            sharesBefore,
            "failed redeem swap should restore cToken shares"
        );
        assertEq(
            usdc.balanceOf(user1),
            usdcBefore,
            "failed redeem swap should restore user USDC"
        );
        assertEq(
            weth.balanceOf(user2),
            user2WethBefore,
            "failed redeem swap should not pay wrong recipient"
        );
        _assertSimpleZapperHasNoResidue();

        vm.stopPrank();
    }

    function testRedeemAndSwapCToken_fail_forceRedeemCollateralSwapFailureRollsBack()
        public
    {
        uint256 amount = 10e6;
        _prepareUSDC(user1, amount);

        vm.startPrank(user1);
        usdc.approve(address(simpleCUSDC), amount);
        uint256 shares = simpleCUSDC.depositAsCollateral(amount, user1);
        simpleCUSDC.setDelegateApproval(address(simpleZapper), true);
        skip(20 minutes);

        uint256 sharesBefore = simpleCUSDC.balanceOf(user1);
        uint256 collateralBefore = simpleCUSDC.collateralPosted(user1);
        uint256 marketCollateralBefore = simpleCUSDC.marketCollateralPosted();
        uint256 totalSupplyBefore = simpleCUSDC.totalSupply();
        uint256 totalAssetsBefore = simpleCUSDC.totalAssets();
        uint256 usdcBefore = usdc.balanceOf(user1);
        uint256 user2WethBefore = weth.balanceOf(user2);

        BaseZapper.RedeemAction memory redeemAction;
        redeemAction.cToken = address(simpleCUSDC);
        redeemAction.shares = shares;
        redeemAction.forceRedeemCollateral = true;

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = amount;
        swapAction.outputToken = _WETH_ADDRESS;
        swapAction.target = _UNISWAP_V3_SWAP_ROUTER;
        swapAction.slippage = _TEST_SWAP_SLIPPAGE;

        IUniswapV3Router.ExactInputSingleParams memory params;
        params.tokenIn = _USDC_ADDRESS;
        params.tokenOut = _WETH_ADDRESS;
        params.fee = 100;
        params.recipient = user2;
        params.deadline = block.timestamp;
        params.amountIn = amount;
        params.amountOutMinimum = 0;
        params.sqrtPriceLimitX96 = 0;
        swapAction.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector, params
        );

        vm.expectPartialRevert(SwapperLib.SwapperLib__Slippage.selector);
        simpleZapper.redeemAndSwap(redeemAction, swapAction, user1);

        assertEq(simpleCUSDC.balanceOf(user1), sharesBefore);
        assertEq(simpleCUSDC.collateralPosted(user1), collateralBefore);
        assertEq(simpleCUSDC.marketCollateralPosted(), marketCollateralBefore);
        assertEq(simpleCUSDC.totalSupply(), totalSupplyBefore);
        assertEq(simpleCUSDC.totalAssets(), totalAssetsBefore);
        assertEq(usdc.balanceOf(user1), usdcBefore);
        assertEq(weth.balanceOf(user2), user2WethBefore);
        _assertSimpleZapperHasNoResidue();

        vm.stopPrank();
    }

    function testRedeemAndSwapCToken_fail_forceRedeemCollateralTerminalLiquidityRollsBack()
        public
    {
        uint256 amount = 2_000e6;
        _prepareUSDC(user1, amount);

        vm.startPrank(user1);
        usdc.approve(address(simpleCUSDC), amount);
        uint256 shares = simpleCUSDC.depositAsCollateral(amount, user1);
        borrowableCDAI.borrow(900 ether, user1);
        simpleCUSDC.setDelegateApproval(address(simpleZapper), true);
        skip(20 minutes);

        uint256 sharesBefore = simpleCUSDC.balanceOf(user1);
        uint256 collateralBefore = simpleCUSDC.collateralPosted(user1);
        uint256 marketCollateralBefore = simpleCUSDC.marketCollateralPosted();
        uint256 totalSupplyBefore = simpleCUSDC.totalSupply();
        uint256 totalAssetsBefore = simpleCUSDC.totalAssets();
        uint256 debtBefore = borrowableCDAI.debtBalance(user1);
        uint256 userUsdcBefore = usdc.balanceOf(user1);
        uint256 zapperUsdcBefore = usdc.balanceOf(address(simpleZapper));
        uint256 receiverWethBefore = weth.balanceOf(user2);

        BaseZapper.RedeemAction memory redeemAction;
        redeemAction.cToken = address(simpleCUSDC);
        redeemAction.shares = (shares * 6) / 10;
        redeemAction.forceRedeemCollateral = true;

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = redeemAction.shares;
        swapAction.outputToken = _WETH_ADDRESS;

        vm.expectRevert(
            MarketManagerIsolated.MarketManager__InsufficientCollateral
            .selector
        );
        simpleZapper.redeemAndSwap(redeemAction, swapAction, user2);

        assertEq(simpleCUSDC.balanceOf(user1), sharesBefore);
        assertEq(simpleCUSDC.collateralPosted(user1), collateralBefore);
        assertEq(simpleCUSDC.marketCollateralPosted(), marketCollateralBefore);
        assertEq(simpleCUSDC.totalSupply(), totalSupplyBefore);
        assertEq(simpleCUSDC.totalAssets(), totalAssetsBefore);
        assertEq(borrowableCDAI.debtBalance(user1), debtBefore);
        assertEq(usdc.balanceOf(user1), userUsdcBefore);
        assertEq(usdc.balanceOf(address(simpleZapper)), zapperUsdcBefore);
        assertEq(weth.balanceOf(user2), receiverWethBefore);
        _assertSimpleZapperHasNoResidue();

        vm.stopPrank();
    }

    function testRedeemSwapAndDeposit() public {
        // redeem eDAI and deposit to simpleCUSDC

        _prepareDAI(user1, 100 ether);

        vm.startPrank(user1);
        dai.approve(address(borrowableCDAI), 100 ether);
        borrowableCDAI.deposit(100 ether, user1);
        borrowableCDAI.setDelegateApproval(address(simpleZapper), true);
        vm.stopPrank();

        BaseZapper.RedeemAction memory redeemAction;
        redeemAction.cToken = address(borrowableCDAI);
        redeemAction.shares = 100 ether;
        redeemAction.forceRedeemCollateral = false;

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _DAI_ADDRESS;
        swapAction.inputAmount = 100 ether;
        swapAction.outputToken = _USDC_ADDRESS;
        swapAction.target = _UNISWAP_V3_SWAP_ROUTER;
        swapAction.slippage = _TEST_SWAP_SLIPPAGE;
        IUniswapV3Router.ExactInputSingleParams memory params;
        params.tokenIn = _DAI_ADDRESS;
        params.tokenOut = _USDC_ADDRESS;
        params.fee = 100;
        params.recipient = address(simpleZapper);
        params.deadline = block.timestamp;
        params.amountIn = 100 ether;
        params.amountOutMinimum = 0;
        params.sqrtPriceLimitX96 = 0;
        swapAction.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector, params
        );

        uint256 userSharesBefore = simpleCUSDC.balanceOf(user1);
        vm.startPrank(user1);

        uint256 returnedShares = simpleZapper.redeemSwapAndDeposit(
            address(simpleCUSDC), redeemAction, swapAction, 0, false, user1
        );
        vm.stopPrank();

        assertEq(
            simpleCUSDC.balanceOf(user1) - userSharesBefore,
            returnedShares,
            "redeem-swap-deposit share delta should match return value"
        );
        assertGt(
            returnedShares, 99e6, "redeem-swap-deposit should clear fee floor"
        );
        _assertSimpleZapperHasNoResidue();
    }

    function testRedeemSwapAndDeposit_fail_expectedSharesTooHighRollsBack()
        public
    {
        _prepareDAI(user1, 100 ether);

        vm.startPrank(user1);
        dai.approve(address(borrowableCDAI), 100 ether);
        uint256 originalShares = borrowableCDAI.deposit(100 ether, user1);
        borrowableCDAI.setDelegateApproval(address(simpleZapper), true);
        vm.stopPrank();

        BaseZapper.RedeemAction memory redeemAction;
        redeemAction.cToken = address(borrowableCDAI);
        redeemAction.shares = originalShares;
        redeemAction.forceRedeemCollateral = false;

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _DAI_ADDRESS;
        swapAction.inputAmount = 100 ether;
        swapAction.outputToken = _USDC_ADDRESS;
        swapAction.target = _UNISWAP_V3_SWAP_ROUTER;
        swapAction.slippage = _TEST_SWAP_SLIPPAGE;

        IUniswapV3Router.ExactInputSingleParams memory params;
        params.tokenIn = _DAI_ADDRESS;
        params.tokenOut = _USDC_ADDRESS;
        params.fee = 100;
        params.recipient = address(simpleZapper);
        params.deadline = block.timestamp;
        params.amountIn = 100 ether;
        params.amountOutMinimum = 0;
        params.sqrtPriceLimitX96 = 0;
        swapAction.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector, params
        );

        uint256 userDaiBefore = dai.balanceOf(user1);
        uint256 userUsdcBefore = usdc.balanceOf(user1);
        uint256 cDaiSharesBefore = borrowableCDAI.balanceOf(user1);
        uint256 cUsdcSharesBefore = simpleCUSDC.balanceOf(user1);
        uint256 cUsdcTotalAssetsBefore = simpleCUSDC.totalAssets();

        vm.prank(user1);
        vm.expectRevert(BaseZapper.BaseZapper__ExecutionError.selector);
        simpleZapper.redeemSwapAndDeposit(
            address(simpleCUSDC),
            redeemAction,
            swapAction,
            type(uint256).max,
            false,
            user1
        );

        assertEq(
            borrowableCDAI.balanceOf(user1),
            cDaiSharesBefore,
            "failed compound zap should restore redeemed cDAI shares"
        );
        assertEq(
            simpleCUSDC.balanceOf(user1),
            cUsdcSharesBefore,
            "failed compound zap should not mint cUSDC shares"
        );
        assertEq(
            simpleCUSDC.totalAssets(),
            cUsdcTotalAssetsBefore,
            "failed compound zap should not change cUSDC assets"
        );
        assertEq(
            dai.balanceOf(user1),
            userDaiBefore,
            "failed compound zap should not leak DAI"
        );
        assertEq(
            usdc.balanceOf(user1),
            userUsdcBefore,
            "failed compound zap should not pay USDC"
        );
        _assertSimpleZapperHasNoResidue();
    }

    function testRedeemSwapAndDeposit_fail_forceRedeemCollateralExpectedSharesTooHighRollsBack()
        public
    {
        _prepareDAI(user1, 100 ether);

        vm.startPrank(user1);
        dai.approve(address(borrowableCDAI), 100 ether);
        uint256 originalShares = borrowableCDAI.deposit(100 ether, user1);
        borrowableCDAI.postCollateral(originalShares);
        borrowableCDAI.setDelegateApproval(address(simpleZapper), true);
        skip(20 minutes);
        vm.stopPrank();

        BaseZapper.RedeemAction memory redeemAction;
        redeemAction.cToken = address(borrowableCDAI);
        redeemAction.shares = originalShares;
        redeemAction.forceRedeemCollateral = true;

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _DAI_ADDRESS;
        swapAction.inputAmount = 100 ether;
        swapAction.outputToken = _USDC_ADDRESS;
        swapAction.target = _UNISWAP_V3_SWAP_ROUTER;
        swapAction.slippage = _TEST_SWAP_SLIPPAGE;

        IUniswapV3Router.ExactInputSingleParams memory params;
        params.tokenIn = _DAI_ADDRESS;
        params.tokenOut = _USDC_ADDRESS;
        params.fee = 100;
        params.recipient = address(simpleZapper);
        params.deadline = block.timestamp;
        params.amountIn = 100 ether;
        params.amountOutMinimum = 0;
        params.sqrtPriceLimitX96 = 0;
        swapAction.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector, params
        );

        uint256 userDaiBefore = dai.balanceOf(user1);
        uint256 userUsdcBefore = usdc.balanceOf(user1);
        uint256 cDaiSharesBefore = borrowableCDAI.balanceOf(user1);
        uint256 cDaiCollateralBefore = borrowableCDAI.collateralPosted(user1);
        uint256 cDaiMarketCollateralBefore =
            borrowableCDAI.marketCollateralPosted();
        uint256 cUsdcSharesBefore = simpleCUSDC.balanceOf(user1);
        uint256 cUsdcTotalAssetsBefore = simpleCUSDC.totalAssets();

        vm.prank(user1);
        vm.expectRevert(BaseZapper.BaseZapper__ExecutionError.selector);
        simpleZapper.redeemSwapAndDeposit(
            address(simpleCUSDC),
            redeemAction,
            swapAction,
            type(uint256).max,
            false,
            user1
        );

        assertEq(borrowableCDAI.balanceOf(user1), cDaiSharesBefore);
        assertEq(borrowableCDAI.collateralPosted(user1), cDaiCollateralBefore);
        assertEq(
            borrowableCDAI.marketCollateralPosted(), cDaiMarketCollateralBefore
        );
        assertEq(simpleCUSDC.balanceOf(user1), cUsdcSharesBefore);
        assertEq(simpleCUSDC.totalAssets(), cUsdcTotalAssetsBefore);
        assertEq(dai.balanceOf(user1), userDaiBefore);
        assertEq(usdc.balanceOf(user1), userUsdcBefore);
        _assertSimpleZapperHasNoResidue();
    }

    function test_Multicall_fail_nonPriceCallCannotTargetExternalRouter()
        public
    {
        Multicall.MulticallAction[] memory calls =
            new Multicall.MulticallAction[](1);
        calls[0].target = _UNISWAP_V3_SWAP_ROUTER;
        calls[0].isPriceUpdate = false;
        calls[0].data =
            abi.encodeWithSelector(IUniswapV3Router.exactInputSingle.selector);

        vm.expectRevert(Multicall.Multicall__InvalidTarget.selector);
        simpleZapper.multicall(calls);
    }

    function test_Multicall_fail_priceUpdateRequiresRegisteredChecker()
        public
    {
        Multicall.MulticallAction[] memory calls =
            new Multicall.MulticallAction[](1);
        calls[0].target = makeAddr("unregistered price target");
        calls[0].isPriceUpdate = true;
        calls[0].data = "";

        vm.expectRevert(Multicall.Multicall__UnknownCalldata.selector);
        simpleZapper.multicall(calls);
    }

    function test_Multicall_fail_native_doubleZap() public {
        uint256 ethAmount = 1 ether;
        vm.deal(user1, ethAmount);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
        swapAction.inputAmount = ethAmount;
        swapAction.outputToken = _USDC_ADDRESS;
        swapAction.target = _UNISWAP_V3_SWAP_ROUTER;
        swapAction.slippage = 0;

        IUniswapV3Router.ExactInputSingleParams memory params;
        params.tokenIn = _WETH_ADDRESS;
        params.tokenOut = _USDC_ADDRESS;
        params.fee = 100;
        params.recipient = address(simpleZapper);
        params.deadline = block.timestamp;
        params.amountIn = ethAmount;
        params.amountOutMinimum = 0;
        params.sqrtPriceLimitX96 = 0;
        swapAction.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector, params
        );

        Multicall.MulticallAction[] memory calls =
            new Multicall.MulticallAction[](2);

        bytes memory data = abi.encodeWithSelector(
            simpleZapper.swapAndDeposit.selector,
            address(simpleCUSDC),
            false, // depositAsWrappedNative
            swapAction,
            0,
            false,
            user1
        );

        calls[0].target = address(simpleZapper);
        calls[0].isPriceUpdate = false;
        calls[0].data = data;

        calls[1].target = address(simpleZapper);
        calls[1].isPriceUpdate = false;
        calls[1].data = data;

        // if (inputAmount != msg.value) {
        //     revert BaseZapper__ExecutionError();
        // }
        vm.prank(user1);
        vm.expectRevert(BaseZapper.BaseZapper__ExecutionError.selector);
        simpleZapper.multicall(calls);
    }

    function test_Multicall_success_nonNative() public {
        uint256 total = 10e6;
        uint256 half = total / 2;
        _prepareUSDC(user1, total);
        vm.startPrank(user1);
        usdc.approve(address(simpleZapper), total);

        SwapperLib.Swap memory swap1;
        swap1.inputToken = _USDC_ADDRESS;
        swap1.inputAmount = half;
        swap1.outputToken = _USDC_ADDRESS;

        SwapperLib.Swap memory swap2 = swap1;

        Multicall.MulticallAction[] memory calls =
            new Multicall.MulticallAction[](2);

        calls[0].target = address(simpleZapper);
        calls[0].isPriceUpdate = false;
        calls[0].data = abi.encodeWithSelector(
            simpleZapper.swapAndDeposit.selector,
            address(simpleCUSDC),
            false,
            swap1,
            0,
            false,
            user1
        );

        calls[1].target = address(simpleZapper);
        calls[1].isPriceUpdate = false;
        calls[1].data = abi.encodeWithSelector(
            simpleZapper.swapAndDeposit.selector,
            address(simpleCUSDC),
            false,
            swap2,
            0,
            false,
            user1
        );

        uint256 balanceBefore = simpleCUSDC.balanceOf(user1);
        uint256 expectedShares = simpleCUSDC.previewDeposit(total);
        simpleZapper.multicall(calls);
        vm.stopPrank();

        uint256 balanceAfter = simpleCUSDC.balanceOf(user1);

        assertEq(
            balanceAfter - balanceBefore,
            expectedShares,
            "multicall share delta should match previewed deposits"
        );
        _assertSimpleZapperHasNoResidue();
    }

    function test_swapAndDeposit_fail_whenMsgValueNonZeroWithNonNativeSwap()
        public
    {
        uint256 total = 10e6;
        deal(user1, 10 ether);
        _prepareUSDC(user1, total);
        vm.startPrank(user1);
        usdc.approve(address(simpleZapper), total);

        SwapperLib.Swap memory swap1;
        swap1.inputToken = _USDC_ADDRESS;
        swap1.inputAmount = total;
        swap1.outputToken = _USDC_ADDRESS;

        vm.expectRevert(BaseZapper.BaseZapper__ExecutionError.selector);

        simpleZapper.swapAndDeposit{value: 10 ether}(
            address(simpleCUSDC), false, swap1, 0, false, user1
        );

        vm.stopPrank();
    }

    function test_swapAndRepay_fail_whenMsgValueNonZeroWithNonNativeSwap()
        public
    {
        uint256 total = 100e6;
        _prepareUSDC(user1, total);
        vm.startPrank(user1);
        usdc.approve(address(simpleCUSDC), total);

        simpleCUSDC.depositAsCollateral(100e6, user1);
        borrowableCDAI.borrow(20e18, user1);

        skip(20 minutes);

        borrowableCDAI.setDelegateApproval(address(simpleZapper), true);

        _prepareUSDC(user1, 20e6);

        usdc.approve(address(simpleZapper), 20e6);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = address(usdc);
        swapAction.inputAmount = 20e6;
        swapAction.target = _UNISWAP_V3_SWAP_ROUTER;
        swapAction.outputToken = address(dai);

        IUniswapV3Router.ExactInputSingleParams memory params;
        params.tokenIn = _USDC_ADDRESS;
        params.tokenOut = _DAI_ADDRESS;
        params.fee = 100;
        params.recipient = address(simpleZapper);
        params.deadline = block.timestamp;
        params.amountIn = 20e6;
        params.amountOutMinimum = 0;
        params.sqrtPriceLimitX96 = 0;
        swapAction.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector, params
        );

        vm.deal(user1, 100 ether);

        vm.expectRevert(BaseZapper.BaseZapper__ExecutionError.selector);

        simpleZapper.swapAndRepay{value: 100 ether}(
            address(borrowableCDAI), false, swapAction, 19e18, user1
        );

        vm.stopPrank();
    }

    function _assertSimpleZapperHasNoResidue() internal view {
        assertEq(address(simpleZapper).balance, 0, "zapper native residue");
        assertEq(
            usdc.balanceOf(address(simpleZapper)), 0, "zapper USDC residue"
        );
        assertEq(dai.balanceOf(address(simpleZapper)), 0, "zapper DAI residue");
        assertEq(
            weth.balanceOf(address(simpleZapper)), 0, "zapper WETH residue"
        );
        assertEq(
            simpleCUSDC.balanceOf(address(simpleZapper)),
            0,
            "zapper cUSDC residue"
        );
        assertEq(
            borrowableCDAI.balanceOf(address(simpleZapper)),
            0,
            "zapper cDAI residue"
        );
    }
}
