// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {SwapperLib} from "contracts/libraries/SwapperLib.sol";
import {Multicall} from "contracts/libraries/Multicall.sol";
import {VaultZapper} from "contracts/plugins/market/VaultZapper.sol";
import {BaseZapper} from "contracts/plugins/BaseZapper.sol";
import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";
import {IERC20} from "contracts/interfaces/IERC20.sol";
import {ICToken} from "contracts/interfaces/ICToken.sol";

import {TestBaseMarketIsolated} from "tests/market/TestBaseMarketIsolated.sol";
import {MockCalldataChecker} from "contracts/mocks/MockCalldataChecker.sol";

import {SimpleCToken} from "contracts/market/token/SimpleCToken.sol";
import {
    IUniswapV3Router
} from "contracts/interfaces/external/uniswap/IUniswapV3Router.sol";
import {IVault} from "contracts/interfaces/IVault.sol";

// 1. For this test's deposit functions, we use simpleCSFRAX-borrowableCUSDC market since there is liquidity for FRAX which is the underlying asset for sFRAX,
//    and sFRAX is an erc4626 token.
// 2. We use simpleCUSDC-borrowableCDAI market for redeemAndSwap/swapAndRepay functions since there is no liquidity for sFRAX, and
//    there is liquidity for USDC and DAI.

contract TestVaultZapperWithTokens is TestBaseMarketIsolated {
    address internal _UNISWAP_V3_SWAP_ROUTER =
        0xE592427A0AEce92De3Edee1F18E0157C05861564;
    uint256 internal constant _TEST_SWAP_SLIPPAGE = 0.01e18;
    uint256 internal constant _TEST_DEEP_ROUTE_SLIPPAGE = 0.999e18;

    address internal _SFRAX_ADDRESS =
        0xA663B02CF0a4b149d2aD41910CB81e23e1c41c32;

    VaultZapper public vaultZapper;

    SimpleCToken public simpleCSFRAX;

    function setUp() public override {}

    function test_vaultZapper_success_swapAndDeposit() public {
        _setUpSimpleCSFRAX_borrowableCUSDC();

        _prepareUSDC(user1, 100e6);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = address(usdc);
        swapAction.inputAmount = 100e6;
        swapAction.target = _UNISWAP_V3_SWAP_ROUTER;
        swapAction.outputToken = _FRAX_ADDRESS;
        swapAction.slippage = _TEST_DEEP_ROUTE_SLIPPAGE;

        // multi-hop swap USDC -> WETH -> FRAX
        IUniswapV3Router.ExactInputParams memory params;
        params.path = abi.encodePacked(
            address(usdc),
            uint24(500),
            _WETH_ADDRESS,
            uint24(3000),
            _FRAX_ADDRESS
        );
        params.recipient = address(vaultZapper);
        params.deadline = block.timestamp;
        params.amountIn = 100e6;
        params.amountOutMinimum = 0;

        swapAction.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInput.selector, params
        );

        vm.startPrank(user1);
        usdc.approve(address(vaultZapper), 100e6);

        uint256 balanceBefore = simpleCSFRAX.balanceOf(user1);
        uint256 returnedShares = vaultZapper.swapAndDeposit(
            address(simpleCSFRAX), false, swapAction, 0, false, user1
        );

        vm.stopPrank();

        assertEq(
            simpleCSFRAX.balanceOf(user1) - balanceBefore,
            returnedShares,
            "receiver cSFRAX delta should match returned shares"
        );
        assertGt(returnedShares, 0, "vault zap should mint cToken shares");
        _assertVaultZapperHasNoResidue();
    }

    function test_vaultZapper_fail_swapAndDeposit_TightSwapSafeSlippage()
        public
    {
        _setUpSimpleCSFRAX_borrowableCUSDC();

        _prepareUSDC(user1, 100e6);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = address(usdc);
        swapAction.inputAmount = 100e6;
        swapAction.target = _UNISWAP_V3_SWAP_ROUTER;
        swapAction.outputToken = _FRAX_ADDRESS;
        swapAction.slippage = _TEST_SWAP_SLIPPAGE;

        IUniswapV3Router.ExactInputParams memory params;
        params.path = abi.encodePacked(
            address(usdc),
            uint24(500),
            _WETH_ADDRESS,
            uint24(3000),
            _FRAX_ADDRESS
        );
        params.recipient = address(vaultZapper);
        params.deadline = block.timestamp;
        params.amountIn = 100e6;
        params.amountOutMinimum = 0;

        swapAction.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInput.selector, params
        );

        vm.startPrank(user1);
        usdc.approve(address(vaultZapper), 100e6);

        uint256 userUsdcBefore = usdc.balanceOf(user1);
        uint256 userSharesBefore = simpleCSFRAX.balanceOf(user1);

        vm.expectPartialRevert(SwapperLib.SwapperLib__Slippage.selector);
        vaultZapper.swapAndDeposit(
            address(simpleCSFRAX), false, swapAction, 0, false, user1
        );

        assertEq(usdc.balanceOf(user1), userUsdcBefore);
        assertEq(simpleCSFRAX.balanceOf(user1), userSharesBefore);
        _assertVaultZapperHasNoResidue();

        vm.stopPrank();
    }

    function test_vaultZapper_fail_swapAndDeposit_AssetMismatchBeforeSwap()
        public
    {
        _setUpSimpleCSFRAX_borrowableCUSDC();

        uint256 amount = 100e6;
        _prepareUSDC(user1, amount);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = address(usdc);
        swapAction.inputAmount = amount;
        swapAction.target = address(0xBEEF);
        swapAction.outputToken = address(usdc);
        swapAction.call = hex"deadbeef";

        vm.startPrank(user1);
        usdc.approve(address(vaultZapper), amount);

        uint256 userUsdcBefore = usdc.balanceOf(user1);
        uint256 userSharesBefore = simpleCSFRAX.balanceOf(user1);

        vm.expectRevert(
            BaseZapper.BaseZapper__UnderlyingTokenIsNotInputToken.selector
        );
        vaultZapper.swapAndDeposit(
            address(simpleCSFRAX), false, swapAction, 0, false, user1
        );

        assertEq(usdc.balanceOf(user1), userUsdcBefore);
        assertEq(simpleCSFRAX.balanceOf(user1), userSharesBefore);
        _assertVaultZapperHasNoResidue();
        vm.stopPrank();
    }

    function test_vaultZapper_fail_unlistedCTokenBeforeAssetLookup() public {
        _setUpSimpleCSFRAX_borrowableCUSDC();

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

        vm.expectRevert(BaseZapper.BaseZapper__Unauthorized.selector);
        vaultZapper.swapAndDeposit(
            fakeCToken, false, swapAction, 0, false, user1
        );
    }

    function test_vaultZapper_success_swapAndDeposit_withETH() public {
        _setUpSimpleCSFRAX_borrowableCUSDC();

        uint256 ethAmount = 1 ether;
        vm.deal(user1, ethAmount);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE; // Native ETH
        swapAction.inputAmount = ethAmount;
        swapAction.target = _UNISWAP_V3_SWAP_ROUTER;
        swapAction.outputToken = _FRAX_ADDRESS;
        swapAction.slippage = _TEST_DEEP_ROUTE_SLIPPAGE;

        // swap ETH -> FRAX
        IUniswapV3Router.ExactInputParams memory params;
        params.path =
            abi.encodePacked(_WETH_ADDRESS, uint24(3000), _FRAX_ADDRESS);
        params.recipient = address(vaultZapper);
        params.deadline = block.timestamp + 1 hours;
        params.amountIn = ethAmount;
        params.amountOutMinimum = 0;

        swapAction.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInput.selector, params
        );

        vm.startPrank(user1);

        uint256 balanceBefore = simpleCSFRAX.balanceOf(user1);
        uint256 returnedShares = vaultZapper.swapAndDeposit{value: ethAmount}(
            address(simpleCSFRAX),
            true, // depositAsWrappedNative=true
            swapAction,
            0,
            false,
            user1
        );

        vm.stopPrank();

        assertEq(
            simpleCSFRAX.balanceOf(user1) - balanceBefore,
            returnedShares,
            "native wrapped zap delta should match returned shares"
        );
        assertGt(returnedShares, 0, "native wrapped zap should mint shares");
        _assertVaultZapperHasNoResidue();
    }

    function test_vaultZapper_success_swapAndDeposit_withETH_noWrapping()
        public
    {
        _setUpSimpleCSFRAX_borrowableCUSDC();

        uint256 ethAmount = 1 ether;
        vm.deal(user1, ethAmount);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
        swapAction.inputAmount = ethAmount;
        swapAction.target = _UNISWAP_V3_SWAP_ROUTER;
        swapAction.outputToken = _FRAX_ADDRESS;
        swapAction.slippage = _TEST_DEEP_ROUTE_SLIPPAGE;

        // swap ETH -> FRAX
        IUniswapV3Router.ExactInputParams memory params;
        params.path =
            abi.encodePacked(_WETH_ADDRESS, uint24(3000), _FRAX_ADDRESS);
        params.recipient = address(vaultZapper);
        params.deadline = block.timestamp + 1 hours;
        params.amountIn = ethAmount;
        params.amountOutMinimum = 0;

        swapAction.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInput.selector, params
        );

        vm.startPrank(user1);

        uint256 balanceBefore = simpleCSFRAX.balanceOf(user1);
        uint256 returnedShares = vaultZapper.swapAndDeposit{value: ethAmount}(
            address(simpleCSFRAX),
            false, // depositAsWrappedNative=false
            swapAction,
            0,
            false,
            user1
        );

        vm.stopPrank();

        assertEq(
            simpleCSFRAX.balanceOf(user1) - balanceBefore,
            returnedShares,
            "native unwrapped zap delta should match returned shares"
        );
        assertGt(returnedShares, 0, "native unwrapped zap should mint shares");
        _assertVaultZapperHasNoResidue();
    }

    function testSwapAndRepay() external {
        _setUpSimpleCUSDC_borrowableCDAI();

        _prepareUSDC(user1, 2000e6);

        vm.startPrank(user1);
        usdc.approve(address(simpleCUSDC), 2000e6);
        simpleCUSDC.depositAsCollateral(2000e6, user1);

        simpleCUSDC.setDelegateApproval(address(vaultZapper), true);

        // try borrow()
        // Borrow slightly more, the zapper will repay as much as possible.
        // This small amount extra repays the loan under the minimum loan size.
        borrowableCDAI.borrow(550 ether, user1);
        vm.stopPrank();

        assertEq(dai.balanceOf(user1), 550 ether);
        assertApproxEqAbs(
            borrowableCDAI.debtBalance(user1), 550 ether, 1 ether
        );

        // skip min hold period
        skip(20 minutes);

        uint256 debtBefore = borrowableCDAI.debtBalance(user1);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 500e6;
        swapAction.outputToken = _DAI_ADDRESS;
        swapAction.target = _UNISWAP_V3_SWAP_ROUTER;
        swapAction.slippage = _TEST_SWAP_SLIPPAGE;

        IUniswapV3Router.ExactInputSingleParams memory params;
        params.tokenIn = _USDC_ADDRESS;
        params.tokenOut = _DAI_ADDRESS;
        params.fee = 100;
        params.recipient = address(vaultZapper);
        params.deadline = block.timestamp;
        params.amountIn = 500e6;
        params.amountOutMinimum = 0;
        params.sqrtPriceLimitX96 = 0;
        swapAction.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector, params
        );

        _prepareUSDC(user1, 500e6);
        vm.startPrank(user1);
        usdc.approve(address(vaultZapper), 500e6);
        vaultZapper.swapAndRepay(
            address(borrowableCDAI), false, swapAction, 450e18, user1
        );
        vm.stopPrank();

        uint256 debtAfter = borrowableCDAI.debtBalance(user1);
        uint256 repaid = debtBefore - debtAfter;
        assertGe(repaid, 450 ether); // repayAssets is a minimum. Actually repays ~499 dai
        _assertVaultZapperHasNoResidue();
    }

    function testRedeemAndSwapCToken() public {
        _setUpSimpleCUSDC_borrowableCDAI();

        _prepareUSDC(user1, 2000e6);
        vm.startPrank(user1);
        usdc.approve(address(simpleCUSDC), 2000e6);
        simpleCUSDC.deposit(2000e6, user1);
        vm.stopPrank();

        assertGt(simpleCUSDC.balanceOf(user1), 0);

        vm.prank(user1);
        simpleCUSDC.setDelegateApproval(address(vaultZapper), true);

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
        params.recipient = address(vaultZapper);
        params.deadline = block.timestamp;
        params.amountIn = 2000e6;
        params.amountOutMinimum = 0;
        params.sqrtPriceLimitX96 = 0;
        swapAction.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector, params
        );

        uint256 userWethBefore = weth.balanceOf(user1);
        vm.prank(user1);
        uint256 returnedOut =
            vaultZapper.redeemAndSwap(redeemAction, swapAction, user1);

        assertEq(
            weth.balanceOf(user1) - userWethBefore,
            returnedOut,
            "redeem swap WETH delta should match returned output"
        );
        assertGt(returnedOut, 0, "redeem swap should return WETH");
        _assertVaultZapperHasNoResidue();
    }

    function testRedeemAndSwapCToken_fail_OutputSentAwayRollsBackAtMaxSlippage()
        public
    {
        _setUpSimpleCUSDC_borrowableCDAI();

        uint256 amount = 10e6;
        _prepareUSDC(user1, amount);

        vm.startPrank(user1);
        usdc.approve(address(simpleCUSDC), amount);
        uint256 shares = simpleCUSDC.deposit(amount, user1);
        simpleCUSDC.setDelegateApproval(address(vaultZapper), true);

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
        vaultZapper.redeemAndSwap(redeemAction, swapAction, user1);

        assertEq(
            simpleCUSDC.balanceOf(user1),
            sharesBefore,
            "failed vault redeem swap should restore cToken shares"
        );
        assertEq(
            usdc.balanceOf(user1),
            usdcBefore,
            "failed vault redeem swap should restore user USDC"
        );
        assertEq(
            weth.balanceOf(user2),
            user2WethBefore,
            "failed vault redeem swap should not pay wrong recipient"
        );
        _assertVaultZapperHasNoResidue();

        vm.stopPrank();
    }

    function test_vaultZapper_fail_redeemAndSwapCannotRedeemVictimShares()
        public
    {
        _setUpSimpleCUSDC_borrowableCDAI();

        _prepareUSDC(user1, 2000e6);
        vm.startPrank(user1);
        usdc.approve(address(simpleCUSDC), 2000e6);
        simpleCUSDC.deposit(2000e6, user1);
        simpleCUSDC.setDelegateApproval(address(vaultZapper), true);
        vm.stopPrank();

        uint256 victimSharesBefore = simpleCUSDC.balanceOf(user1);
        uint256 attackerUsdcBefore = usdc.balanceOf(user2);

        BaseZapper.RedeemAction memory redeemAction;
        redeemAction.cToken = address(simpleCUSDC);
        redeemAction.shares = victimSharesBefore;
        redeemAction.forceRedeemCollateral = false;

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = victimSharesBefore;
        swapAction.outputToken = _USDC_ADDRESS;

        vm.prank(user2);
        vm.expectRevert();
        vaultZapper.redeemAndSwap(redeemAction, swapAction, user2);

        assertEq(simpleCUSDC.balanceOf(user1), victimSharesBefore);
        assertEq(usdc.balanceOf(user2), attackerUsdcBefore);
    }

    function testRedeemAndSwapBorrowableCToken() public {
        _setUpSimpleCUSDC_borrowableCDAI();

        vm.startPrank(user1);

        // Mint borrowable cDAI.
        _prepareDAI(user1, 10 ether);
        dai.approve(address(borrowableCDAI), 10 ether);
        borrowableCDAI.deposit(10 ether, user1);

        borrowableCDAI.setDelegateApproval(address(vaultZapper), true);

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
        params.recipient = address(vaultZapper);
        params.deadline = block.timestamp;
        params.amountIn = 10 ether;
        params.amountOutMinimum = 0;
        params.sqrtPriceLimitX96 = 0;
        swapAction.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector, params
        );

        uint256 userUsdcBefore = usdc.balanceOf(user1);
        uint256 returnedOut =
            vaultZapper.redeemAndSwap(redeemAction, swapAction, user1);

        assertEq(
            usdc.balanceOf(user1) - userUsdcBefore,
            returnedOut,
            "redeem swap USDC delta should match returned output"
        );
        assertGt(returnedOut, 9.99e6, "redeem swap should clear fee floor");
        _assertVaultZapperHasNoResidue();

        vm.stopPrank();
    }

    function testRedeemSwapAndDeposit() public {
        _setUpSimpleCUSDC_borrowableCDAI();

        // redeem eDAI and deposit to simpleCUSDC

        _prepareDAI(user1, 100 ether);

        vm.startPrank(user1);
        dai.approve(address(borrowableCDAI), 100 ether);
        borrowableCDAI.deposit(100 ether, user1);
        borrowableCDAI.setDelegateApproval(address(vaultZapper), true);
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
        params.recipient = address(vaultZapper);
        params.deadline = block.timestamp;
        params.amountIn = 100 ether;
        params.amountOutMinimum = 0;
        params.sqrtPriceLimitX96 = 0;
        swapAction.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector, params
        );

        vm.startPrank(user1);

        uint256 userSharesBefore = simpleCUSDC.balanceOf(user1);
        uint256 returnedShares = vaultZapper.redeemSwapAndDeposit(
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
        _assertVaultZapperHasNoResidue();
    }

    function testRedeemSwapAndDeposit_fail_expectedSharesTooHighRollsBack()
        public
    {
        _setUpSimpleCUSDC_borrowableCDAI();

        _prepareDAI(user1, 100 ether);

        vm.startPrank(user1);
        dai.approve(address(borrowableCDAI), 100 ether);
        uint256 originalShares = borrowableCDAI.deposit(100 ether, user1);
        borrowableCDAI.setDelegateApproval(address(vaultZapper), true);
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
        params.recipient = address(vaultZapper);
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
        vaultZapper.redeemSwapAndDeposit(
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
            "failed vault compound zap should restore cDAI shares"
        );
        assertEq(
            simpleCUSDC.balanceOf(user1),
            cUsdcSharesBefore,
            "failed vault compound zap should not mint cUSDC shares"
        );
        assertEq(
            simpleCUSDC.totalAssets(),
            cUsdcTotalAssetsBefore,
            "failed vault compound zap should not change cUSDC assets"
        );
        assertEq(
            dai.balanceOf(user1),
            userDaiBefore,
            "failed vault compound zap should not leak DAI"
        );
        assertEq(
            usdc.balanceOf(user1),
            userUsdcBefore,
            "failed vault compound zap should not pay USDC"
        );
        _assertVaultZapperHasNoResidue();
    }

    // NO-SWAP TESTS

    function testRedeemSwapAndDeposit_fail_forceRedeemCollateralExpectedSharesTooHighRollsBack()
        public
    {
        _setUpSimpleCUSDC_borrowableCDAI();

        _prepareDAI(user1, 100 ether);

        vm.startPrank(user1);
        dai.approve(address(borrowableCDAI), 100 ether);
        uint256 originalShares = borrowableCDAI.deposit(100 ether, user1);
        borrowableCDAI.postCollateral(originalShares);
        borrowableCDAI.setDelegateApproval(address(vaultZapper), true);
        vm.stopPrank();

        vm.warp(
            marketManagerIsolated.accountAssets(user1)
                + marketManagerIsolated.MIN_HOLD_PERIOD()
        );

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
        params.recipient = address(vaultZapper);
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
        vaultZapper.redeemSwapAndDeposit(
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
        _assertVaultZapperHasNoResidue();
    }

    function test_vaultZapper_success_swapAndDeposit_noSwap() public {
        _setUpSimpleCSFRAX_borrowableCUSDC();

        deal(_FRAX_ADDRESS, user1, 100e18);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _FRAX_ADDRESS;
        swapAction.inputAmount = 100e18;
        swapAction.target = _UNISWAP_V3_SWAP_ROUTER;
        swapAction.outputToken = _FRAX_ADDRESS;
        swapAction.call = "";

        vm.startPrank(user1);
        IERC20(_FRAX_ADDRESS).approve(address(vaultZapper), 100e18);

        uint256 balanceBefore = simpleCSFRAX.balanceOf(user1);
        uint256 expectedVaultShares =
            IVault(_SFRAX_ADDRESS).previewDeposit(100e18);
        uint256 expectedShares =
            simpleCSFRAX.previewDeposit(expectedVaultShares);

        uint256 returnedShares = vaultZapper.swapAndDeposit(
            address(simpleCSFRAX), false, swapAction, 0, false, user1
        );

        vm.stopPrank();

        uint256 balanceAfter = simpleCSFRAX.balanceOf(user1);
        assertEq(
            balanceAfter - balanceBefore,
            expectedShares,
            "no-swap cSFRAX delta should match preview"
        );
        assertEq(
            returnedShares,
            expectedShares,
            "no-swap returned shares should match preview"
        );
        _assertVaultZapperHasNoResidue();
    }

    function test_vaultZapper_preExistingUnderlyingAndVaultShareResidueDoNotMintExtraShares()
        public
    {
        _setUpSimpleCSFRAX_borrowableCUSDC();

        uint256 amount = 100e18;
        uint256 fraxResidue = 25e18;
        uint256 vaultShareResidue = 1e18;

        deal(_FRAX_ADDRESS, user1, amount);
        deal(_FRAX_ADDRESS, address(vaultZapper), fraxResidue);
        deal(_SFRAX_ADDRESS, address(vaultZapper), vaultShareResidue);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _FRAX_ADDRESS;
        swapAction.inputAmount = amount;
        swapAction.outputToken = _FRAX_ADDRESS;

        uint256 expectedVaultShares =
            IVault(_SFRAX_ADDRESS).previewDeposit(amount);
        uint256 expectedCTokenShares =
            simpleCSFRAX.previewDeposit(expectedVaultShares);
        uint256 userSharesBefore = simpleCSFRAX.balanceOf(user1);

        vm.startPrank(user1);
        IERC20(_FRAX_ADDRESS).approve(address(vaultZapper), amount);

        uint256 shares = vaultZapper.swapAndDeposit(
            address(simpleCSFRAX), false, swapAction, 0, false, user1
        );
        vm.stopPrank();

        assertEq(shares, expectedCTokenShares);
        assertEq(simpleCSFRAX.balanceOf(user1) - userSharesBefore, shares);
        assertEq(
            IERC20(_FRAX_ADDRESS).balanceOf(address(vaultZapper)),
            fraxResidue,
            "pre-existing underlying residue should not enter vault"
        );
        assertEq(
            IERC20(_SFRAX_ADDRESS).balanceOf(address(vaultZapper)),
            vaultShareResidue,
            "pre-existing vault share residue should not enter cToken"
        );
    }

    function test_vaultZapper_fail_swapAndDeposit_expectedSharesTooHigh()
        public
    {
        _setUpSimpleCSFRAX_borrowableCUSDC();

        deal(_FRAX_ADDRESS, user1, 100e18);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _FRAX_ADDRESS;
        swapAction.inputAmount = 100e18;
        swapAction.outputToken = _FRAX_ADDRESS;

        vm.startPrank(user1);
        IERC20(_FRAX_ADDRESS).approve(address(vaultZapper), 100e18);

        uint256 userFraxBefore = IERC20(_FRAX_ADDRESS).balanceOf(user1);
        uint256 userSharesBefore = simpleCSFRAX.balanceOf(user1);
        uint256 totalAssetsBefore = simpleCSFRAX.totalAssets();

        vm.expectRevert(BaseZapper.BaseZapper__ExecutionError.selector);
        vaultZapper.swapAndDeposit(
            address(simpleCSFRAX),
            false,
            swapAction,
            type(uint256).max,
            false,
            user1
        );

        assertEq(IERC20(_FRAX_ADDRESS).balanceOf(user1), userFraxBefore);
        assertEq(simpleCSFRAX.balanceOf(user1), userSharesBefore);
        assertEq(simpleCSFRAX.totalAssets(), totalAssetsBefore);
        _assertVaultZapperHasNoResidue();
        vm.stopPrank();
    }

    function test_vaultZapper_fail_swapAndDeposit_zeroReceiver() public {
        _setUpSimpleCSFRAX_borrowableCUSDC();

        deal(_FRAX_ADDRESS, user1, 100e18);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _FRAX_ADDRESS;
        swapAction.inputAmount = 100e18;
        swapAction.target = _UNISWAP_V3_SWAP_ROUTER;
        swapAction.outputToken = _FRAX_ADDRESS;
        swapAction.call = "";

        vm.startPrank(user1);
        IERC20(_FRAX_ADDRESS).approve(address(vaultZapper), 100e18);

        uint256 userFraxBefore = IERC20(_FRAX_ADDRESS).balanceOf(user1);
        uint256 userSharesBefore = simpleCSFRAX.balanceOf(user1);
        uint256 totalAssetsBefore = simpleCSFRAX.totalAssets();

        vm.expectRevert(BaseZapper.BaseZapper__ExecutionError.selector);
        vaultZapper.swapAndDeposit(
            address(simpleCSFRAX), false, swapAction, 0, false, address(0)
        );

        assertEq(IERC20(_FRAX_ADDRESS).balanceOf(user1), userFraxBefore);
        assertEq(simpleCSFRAX.balanceOf(user1), userSharesBefore);
        assertEq(simpleCSFRAX.totalAssets(), totalAssetsBefore);
        _assertVaultZapperHasNoResidue();
        vm.stopPrank();
    }

    function test_vaultZapper_fail_multicallCannotCollateralizeForNonDelegate()
        public
    {
        _setUpSimpleCSFRAX_borrowableCUSDC();

        deal(_FRAX_ADDRESS, user2, 100e18);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _FRAX_ADDRESS;
        swapAction.inputAmount = 100e18;
        swapAction.outputToken = _FRAX_ADDRESS;

        Multicall.MulticallAction[] memory calls =
            new Multicall.MulticallAction[](1);
        calls[0] = Multicall.MulticallAction({
            target: address(vaultZapper),
            isPriceUpdate: false,
            data: abi.encodeWithSelector(
                vaultZapper.swapAndDeposit.selector,
                address(simpleCSFRAX),
                false,
                swapAction,
                0,
                true,
                user1
            )
        });

        uint256 user2BalanceBefore = IERC20(_FRAX_ADDRESS).balanceOf(user2);
        uint256 user1CollateralBefore = simpleCSFRAX.collateralPosted(user1);

        vm.startPrank(user2);
        IERC20(_FRAX_ADDRESS).approve(address(vaultZapper), 100e18);
        vm.expectRevert(BaseZapper.BaseZapper__Unauthorized.selector);
        vaultZapper.multicall(calls);
        vm.stopPrank();

        assertEq(IERC20(_FRAX_ADDRESS).balanceOf(user2), user2BalanceBefore);
        assertEq(simpleCSFRAX.collateralPosted(user1), user1CollateralBefore);
        assertEq(simpleCSFRAX.balanceOf(user1), 0);
        _assertVaultZapperHasNoResidue();
    }

    function test_vaultZapper_fail_swapAndDepositErc20WithMsgValue() public {
        _setUpSimpleCSFRAX_borrowableCUSDC();

        // Dummy values, we are reverting fairly early in the function.
        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _FRAX_ADDRESS;
        swapAction.inputAmount = 1e18;
        swapAction.target = _UNISWAP_V3_SWAP_ROUTER;
        swapAction.outputToken = _FRAX_ADDRESS;
        swapAction.call = "";

        vm.deal(user1, 1); // Incorrectly attach 1 wei to the call

        vm.startPrank(user1);

        vm.expectRevert(BaseZapper.BaseZapper__ExecutionError.selector);

        vaultZapper.swapAndDeposit{value: 1}(
            address(simpleCSFRAX), false, swapAction, 0, false, user1
        );

        vm.stopPrank();
    }

    // Market setup

    function _assertVaultZapperHasNoResidue() internal view {
        assertEq(address(vaultZapper).balance, 0, "zapper native residue");
        assertEq(
            usdc.balanceOf(address(vaultZapper)), 0, "zapper USDC residue"
        );
        assertEq(dai.balanceOf(address(vaultZapper)), 0, "zapper DAI residue");
        assertEq(
            weth.balanceOf(address(vaultZapper)), 0, "zapper WETH residue"
        );
        assertEq(
            IERC20(_FRAX_ADDRESS).balanceOf(address(vaultZapper)),
            0,
            "zapper FRAX residue"
        );
        assertEq(
            IERC20(_SFRAX_ADDRESS).balanceOf(address(vaultZapper)),
            0,
            "zapper sFRAX residue"
        );
        assertEq(
            simpleCUSDC.balanceOf(address(vaultZapper)),
            0,
            "zapper cUSDC residue"
        );
        assertEq(
            borrowableCDAI.balanceOf(address(vaultZapper)),
            0,
            "zapper cDAI residue"
        );
        if (address(simpleCSFRAX) != address(0)) {
            assertEq(
                simpleCSFRAX.balanceOf(address(vaultZapper)),
                0,
                "zapper cSFRAX residue"
            );
        }
    }

    function _setUpSimpleCSFRAX_borrowableCUSDC() internal {
        _fork(21000000); // Use a more recent block where sFRAX exists

        _init();

        vaultZapper = new VaultZapper(
            ICentralRegistry(address(centralRegistry)), _WETH_ADDRESS
        );

        centralRegistry.setExternalCalldataChecker(
            _UNISWAP_V3_SWAP_ROUTER,
            address(new MockCalldataChecker(_UNISWAP_V3_SWAP_ROUTER))
        );

        simpleCSFRAX = new SimpleCToken(
            ICentralRegistry(address(centralRegistry)),
            IERC20(_SFRAX_ADDRESS),
            address(marketManagerIsolated)
        );

        chainlinkAdaptor.addAsset(_FRAX_ADDRESS, true, _CHAINLINK_FRAX_USD, 0);
        oracleManager.addAssetPricingAdaptor(
            _FRAX_ADDRESS, address(chainlinkAdaptor), 100, 50, 100, 50
        );

        chainlinkAdaptor.addAsset(_SFRAX_ADDRESS, true, _CHAINLINK_FRAX_USD, 0);
        oracleManager.addAssetPricingAdaptor(
            _SFRAX_ADDRESS, address(chainlinkAdaptor), 100, 50, 100, 50
        );

        oracleManager.addCTokenSupport(address(simpleCSFRAX));

        deal(_SFRAX_ADDRESS, address(this), 77777);
        _prepareUSDC(address(this), 77777);

        IERC20(_SFRAX_ADDRESS).approve(address(simpleCSFRAX), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);

        marketManagerIsolated.listTokens(
            address(simpleCSFRAX), address(borrowableCUSDC)
        );

        _setCTokenConfigBasic(address(simpleCSFRAX), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 100_000e18, 100_000e18);
    }

    function _setUpSimpleCUSDC_borrowableCDAI() internal {
        super.setUp();

        oracleManager.addCTokenSupport(address(simpleCUSDC));

        vaultZapper = new VaultZapper(
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
}
