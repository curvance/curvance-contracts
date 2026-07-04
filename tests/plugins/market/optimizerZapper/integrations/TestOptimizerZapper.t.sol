// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {SwapperLib} from "contracts/libraries/SwapperLib.sol";
import {BaseSwapChecker} from "contracts/calldata-checker/swap-checker/BaseSwapChecker.sol";
import {OptimizerZapper} from "contracts/plugins/market/OptimizerZapper.sol";
import {
    LendingOptimizer
} from "contracts/market/optimizer/LendingOptimizer.sol";

import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";
import {IERC20} from "contracts/interfaces/IERC20.sol";
import {BorrowableCToken} from "contracts/market/token/BorrowableCToken.sol";
import {DynamicIRM} from "contracts/market/DynamicIRM.sol";
import {
    MarketManagerIsolated
} from "contracts/market/isolated/MarketManagerIsolated.sol";
import {
    IUniswapV3Router
} from "contracts/interfaces/external/uniswap/IUniswapV3Router.sol";

import {TestBaseMarketIsolated} from "tests/market/TestBaseMarketIsolated.sol";
import {MockCalldataChecker} from "contracts/mocks/MockCalldataChecker.sol";

contract TestUniswapV3ExactInputSingleChecker is BaseSwapChecker {
    address internal immutable _wrappedNative;

    constructor(address target_, address wrappedNative_) BaseSwapChecker(target_) {
        _wrappedNative = wrappedNative_;
    }

    function checkCalldata(
        SwapperLib.Swap memory swapAction,
        address expectedRecipient
    ) external view override returns (uint256 minOutAmount) {
        if (swapAction.target != target) {
            revert CalldataChecker__TargetError();
        }

        if (
            _getFuncSigHash(swapAction.call)
                != IUniswapV3Router.exactInputSingle.selector
        ) {
            revert CalldataChecker__InvalidFuncSig();
        }

        IUniswapV3Router.ExactInputSingleParams memory params = abi.decode(
            _getFuncParams(swapAction.call),
            (IUniswapV3Router.ExactInputSingleParams)
        );

        address expectedInputToken = swapAction.inputToken == SwapperLib.native
            ? _wrappedNative
            : swapAction.inputToken;
        if (params.tokenIn != expectedInputToken) {
            revert CalldataChecker__InputTokenError();
        }

        if (params.amountIn != swapAction.inputAmount) {
            revert CalldataChecker__InputAmountError();
        }

        if (params.tokenOut != swapAction.outputToken) {
            revert CalldataChecker__OutputTokenError();
        }

        if (params.recipient != expectedRecipient) {
            revert CalldataChecker__RecipientError();
        }

        minOutAmount = params.amountOutMinimum;
        if (minOutAmount == 0) {
            revert CalldataChecker__InvalidMinOut();
        }
    }
}

contract ReentrantOptimizerZapperSwapTarget {
    IERC20 internal immutable inputToken;
    IERC20 internal immutable outputToken;

    bool public reentryAttempted;
    bool public reentrySucceeded;

    constructor(IERC20 inputToken_, IERC20 outputToken_) {
        inputToken = inputToken_;
        outputToken = outputToken_;
    }

    function swapAndAttemptReentry(
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 reentryAmount,
        address zapper,
        address optimizer,
        address receiver
    ) external {
        inputToken.transferFrom(msg.sender, address(this), inputAmount);

        reentryAttempted = true;
        outputToken.approve(zapper, reentryAmount);

        SwapperLib.Swap memory reentryAction = SwapperLib.Swap({
            inputToken: address(outputToken),
            inputAmount: reentryAmount,
            outputToken: address(outputToken),
            target: address(0),
            slippage: 0,
            call: bytes("")
        });

        try OptimizerZapper(zapper)
            .swapAndDeposit(
                optimizer, false, reentryAction, 1, receiver
            ) returns (
            uint256
        ) {
            reentrySucceeded = true;
        } catch {}

        outputToken.approve(zapper, 0);
        outputToken.transfer(msg.sender, outputAmount);
    }
}

contract TestOptimizerZapper is TestBaseMarketIsolated {
    address internal _UNISWAP_V3_SWAP_ROUTER =
        0xE592427A0AEce92De3Edee1F18E0157C05861564;

    OptimizerZapper public optimizerZapper;
    LendingOptimizer public optimizer;

    receive() external payable {}

    fallback() external payable {}

    function setUp() public override {
        super.setUp();

        // Deploy OptimizerZapper.
        optimizerZapper = new OptimizerZapper(
            ICentralRegistry(address(centralRegistry)), _WETH_ADDRESS
        );

        // Register Uniswap V3 calldata checker.
        centralRegistry.setExternalCalldataChecker(
            _UNISWAP_V3_SWAP_ROUTER,
            address(new MockCalldataChecker(_UNISWAP_V3_SWAP_ROUTER))
        );

        // Prepare underlying tokens for listTokens — each cToken pulls
        // 77777 of its underlying via initializeDeposits(msg.sender).
        _prepareWETH(address(this), 77777);
        _prepareUSDC(address(this), 77777);
        weth.approve(address(borrowableCWETH), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);

        // List borrowableCUSDC so market manager accepts deposits.
        // Pair with borrowableCWETH as collateral (deployed by _init()).
        marketManagerIsolated.listTokens(
            address(borrowableCWETH), address(borrowableCUSDC)
        );
        _setCTokenConfigBasic(address(borrowableCUSDC), 100_000e18, 100_000e18);
        _setCTokenConfigHighValues(address(borrowableCWETH), 100_000e18, 0);

        // Deploy LendingOptimizer with borrowableCUSDC as the sole market.
        // Must be after listTokens since _validateCToken checks isListed().
        address[] memory cTokens = new address[](1);
        cTokens[0] = address(borrowableCUSDC);
        uint256[] memory caps = new uint256[](1);
        caps[0] = 10000; // 100%

        optimizer = new LendingOptimizer(
            usdc,
            "Flagship",
            "Flag",
            ICentralRegistry(address(centralRegistry)),
            cTokens,
            caps,
            0 // No performance fee for test simplicity.
        );

        // Initialize the optimizer (pulls 77777 USDC via initializeDeposits).
        _prepareUSDC(address(this), 77777);
        usdc.approve(address(optimizer), 77777);
        optimizer.initializeDeposits(address(borrowableCUSDC));

        // Seed liquidity into borrowableCUSDC so deposits have somewhere to go.
        address liquidityProvider = makeAddr("liquidityProvider");
        _prepareUSDC(liquidityProvider, 10_000e6);
        vm.startPrank(liquidityProvider);
        usdc.approve(address(borrowableCUSDC), 10_000e6);
        borrowableCUSDC.deposit(10_000e6, liquidityProvider);
        vm.stopPrank();
    }

    // ─── Happy Path ──────────────────────────────────────────────────

    function testSwapAndDeposit() public {
        uint256 ethAmount = 3 ether;
        vm.deal(user1, ethAmount);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
        swapAction.inputAmount = ethAmount;
        swapAction.target = _UNISWAP_V3_SWAP_ROUTER;
        swapAction.outputToken = _USDC_ADDRESS;

        IUniswapV3Router.ExactInputSingleParams memory params;
        params.tokenIn = _WETH_ADDRESS;
        params.tokenOut = _USDC_ADDRESS;
        params.fee = 100;
        params.recipient = address(optimizerZapper);
        params.deadline = block.timestamp;
        params.amountIn = ethAmount;
        params.amountOutMinimum = 0;
        params.sqrtPriceLimitX96 = 0;
        swapAction.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector, params
        );

        vm.prank(user1);
        uint256 shares = optimizerZapper.swapAndDeposit{value: ethAmount}(
            address(optimizer), false, swapAction, 1, user1
        );

        assertEq(user1.balance, 0, "User should have spent all ETH");
        assertGt(shares, 0, "Should receive optimizer shares");
        assertEq(
            optimizer.balanceOf(user1),
            shares,
            "Balance should match returned shares"
        );
        _assertOptimizerZapperHasNoResidue(address(optimizer));
    }

    function testSwapAndDeposit_MaliciousSwapTargetCannotReenterZapper()
        public
    {
        ReentrantOptimizerZapperSwapTarget swapTarget =
            new ReentrantOptimizerZapperSwapTarget(dai, usdc);
        centralRegistry.setExternalCalldataChecker(
            address(swapTarget),
            address(new MockCalldataChecker(address(swapTarget)))
        );

        uint256 inputAmount = 1000e18;
        uint256 outputAmount = 1000e6;
        uint256 reentryAmount = 10e6;
        _prepareDAI(user1, inputAmount);
        _prepareUSDC(address(swapTarget), outputAmount + reentryAmount);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _DAI_ADDRESS;
        swapAction.inputAmount = inputAmount;
        swapAction.outputToken = _USDC_ADDRESS;
        swapAction.target = address(swapTarget);
        swapAction.call = abi.encodeWithSelector(
            ReentrantOptimizerZapperSwapTarget.swapAndAttemptReentry.selector,
            inputAmount,
            outputAmount,
            reentryAmount,
            address(optimizerZapper),
            address(optimizer),
            user1
        );
        swapAction.slippage = 0;

        uint256 expectedShares = optimizer.previewDeposit(outputAmount);
        vm.startPrank(user1);
        dai.approve(address(optimizerZapper), inputAmount);
        uint256 shares = optimizerZapper.swapAndDeposit(
            address(optimizer), false, swapAction, expectedShares, user1
        );
        vm.stopPrank();

        assertTrue(swapTarget.reentryAttempted(), "reentry attempted");
        assertFalse(swapTarget.reentrySucceeded(), "reentry blocked");
        assertEq(shares, expectedShares, "original call share output");
        assertEq(optimizer.balanceOf(user1), shares, "only original shares");
        assertEq(dai.balanceOf(address(swapTarget)), inputAmount);
        assertEq(usdc.balanceOf(address(swapTarget)), reentryAmount);
        _assertOptimizerZapperHasNoResidue(address(optimizer));
    }

    function testSwapAndDeposit_UniswapCheckerValidatesRecipientAndMinOut()
        public
    {
        centralRegistry.setExternalCalldataChecker(
            _UNISWAP_V3_SWAP_ROUTER,
            address(
                new TestUniswapV3ExactInputSingleChecker(
                    _UNISWAP_V3_SWAP_ROUTER,
                    _WETH_ADDRESS
                )
            )
        );

        uint256 ethAmount = 3 ether;
        vm.deal(user1, ethAmount);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = SwapperLib.native;
        swapAction.inputAmount = ethAmount;
        swapAction.target = _UNISWAP_V3_SWAP_ROUTER;
        swapAction.outputToken = _USDC_ADDRESS;

        IUniswapV3Router.ExactInputSingleParams memory params;
        params.tokenIn = _WETH_ADDRESS;
        params.tokenOut = _USDC_ADDRESS;
        params.fee = 100;
        params.recipient = address(optimizerZapper);
        params.deadline = block.timestamp;
        params.amountIn = ethAmount;
        params.amountOutMinimum = 1;
        params.sqrtPriceLimitX96 = 0;
        swapAction.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector, params
        );

        vm.prank(user1);
        uint256 shares = optimizerZapper.swapAndDeposit{value: ethAmount}(
            address(optimizer), false, swapAction, 1, user1
        );

        assertGt(shares, 0, "Should receive optimizer shares");
        assertEq(optimizer.balanceOf(user1), shares, "shares");
        _assertOptimizerZapperHasNoResidue(address(optimizer));
    }

    function testSwapAndDeposit_NoSwap() public {
        uint256 amount = 1000e6;
        _prepareUSDC(user1, amount);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = amount;
        swapAction.outputToken = _USDC_ADDRESS;

        vm.startPrank(user1);
        usdc.approve(address(optimizerZapper), amount);

        uint256 expectedShares = optimizer.previewDeposit(amount);
        uint256 shares = optimizerZapper.swapAndDeposit(
            address(optimizer), false, swapAction, expectedShares, user1
        );
        vm.stopPrank();

        assertEq(
            shares, expectedShares, "Returned shares should match preview"
        );
        assertGt(shares, 0, "Should receive optimizer shares");
        assertEq(
            optimizer.balanceOf(user1),
            shares,
            "Balance should match returned shares"
        );
        assertEq(
            usdc.balanceOf(user1), 0, "User should have deposited all USDC"
        );
        _assertOptimizerZapperHasNoResidue(address(optimizer));
    }

    function testSwapAndDeposit_preExistingUnderlyingResidueDoesNotMintShares()
        public
    {
        uint256 residue = 25e6;
        _prepareUSDC(address(optimizerZapper), residue);

        uint256 amount = 1000e6;
        _prepareUSDC(user1, amount);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = amount;
        swapAction.outputToken = _USDC_ADDRESS;

        uint256 expectedShares = optimizer.previewDeposit(amount);
        uint256 userSharesBefore = optimizer.balanceOf(user1);

        vm.startPrank(user1);
        usdc.approve(address(optimizerZapper), amount);

        uint256 shares = optimizerZapper.swapAndDeposit(
            address(optimizer), false, swapAction, expectedShares, user1
        );
        vm.stopPrank();

        assertEq(
            shares,
            expectedShares,
            "returned shares should ignore pre-existing residue"
        );
        assertEq(
            optimizer.balanceOf(user1) - userSharesBefore,
            shares,
            "user share delta should match returned shares"
        );
        assertEq(
            usdc.balanceOf(address(optimizerZapper)),
            residue,
            "pre-existing underlying residue should not be deposited"
        );
    }

    function testSwapAndDeposit_SwapOutputIgnoresPreExistingUnderlyingResidue()
        public
    {
        uint256 residue = 25e6;
        _prepareUSDC(address(optimizerZapper), residue);

        uint256 ethAmount = 3 ether;
        vm.deal(user1, ethAmount);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = SwapperLib.native;
        swapAction.inputAmount = ethAmount;
        swapAction.target = _UNISWAP_V3_SWAP_ROUTER;
        swapAction.outputToken = _USDC_ADDRESS;

        IUniswapV3Router.ExactInputSingleParams memory params;
        params.tokenIn = _WETH_ADDRESS;
        params.tokenOut = _USDC_ADDRESS;
        params.fee = 100;
        params.recipient = address(optimizerZapper);
        params.deadline = block.timestamp;
        params.amountIn = ethAmount;
        params.amountOutMinimum = 0;
        params.sqrtPriceLimitX96 = 0;
        swapAction.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector, params
        );

        uint256 userSharesBefore = optimizer.balanceOf(user1);

        vm.prank(user1);
        uint256 shares = optimizerZapper.swapAndDeposit{value: ethAmount}(
            address(optimizer), false, swapAction, 1, user1
        );

        assertGt(shares, 0, "swap should mint optimizer shares");
        assertEq(
            optimizer.balanceOf(user1) - userSharesBefore,
            shares,
            "user share delta should match returned shares"
        );
        assertEq(
            usdc.balanceOf(address(optimizerZapper)),
            residue,
            "pre-existing swap-output residue should not be deposited"
        );
        assertEq(address(optimizerZapper).balance, 0, "native residue");
        assertEq(dai.balanceOf(address(optimizerZapper)), 0, "DAI residue");
        assertEq(weth.balanceOf(address(optimizerZapper)), 0, "WETH residue");
        assertEq(
            optimizer.balanceOf(address(optimizerZapper)),
            0,
            "optimizer share residue"
        );
    }

    function testSwapAndDeposit_NoSwap_WrappedNativeInput() public {
        uint256 amount = 3 ether;
        vm.deal(user1, amount);

        address[] memory cTokens = new address[](1);
        cTokens[0] = address(borrowableCWETH);
        uint256[] memory caps = new uint256[](1);
        caps[0] = 10000;

        LendingOptimizer wethOptimizer = new LendingOptimizer(
            weth,
            "Flagship",
            "Flag",
            ICentralRegistry(address(centralRegistry)),
            cTokens,
            caps,
            0
        );

        _prepareWETH(address(this), 77777);
        weth.approve(address(wethOptimizer), 77777);
        wethOptimizer.initializeDeposits(address(borrowableCWETH));

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
        swapAction.inputAmount = amount;
        swapAction.outputToken = _WETH_ADDRESS;

        uint256 expectedShares = wethOptimizer.previewDeposit(amount);
        vm.prank(user1);
        uint256 shares = optimizerZapper.swapAndDeposit{value: amount}(
            address(wethOptimizer), true, swapAction, 1, user1
        );

        assertEq(user1.balance, 0, "User should have spent all ETH");
        assertEq(
            shares, expectedShares, "Returned shares should match preview"
        );
        assertGt(shares, 0, "Should receive optimizer shares");
        assertEq(
            wethOptimizer.balanceOf(user1),
            shares,
            "Balance should match returned shares"
        );
        _assertOptimizerZapperHasNoResidue(address(wethOptimizer));
    }

    function testSwapAndDeposit_DifferentReceiver() public {
        uint256 amount = 1000e6;
        _prepareUSDC(user1, amount);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = amount;
        swapAction.outputToken = _USDC_ADDRESS;

        vm.startPrank(user1);
        usdc.approve(address(optimizerZapper), amount);

        uint256 expectedShares = optimizer.previewDeposit(amount);
        uint256 shares = optimizerZapper.swapAndDeposit(
            address(optimizer), false, swapAction, expectedShares, user2
        );
        vm.stopPrank();

        assertEq(
            shares, expectedShares, "Returned shares should match preview"
        );
        assertGt(shares, 0, "Should receive optimizer shares");
        assertEq(
            optimizer.balanceOf(user2), shares, "Receiver should hold shares"
        );
        assertEq(optimizer.balanceOf(user1), 0, "Sender should hold no shares");
        _assertOptimizerZapperHasNoResidue(address(optimizer));
    }

    // ─── Failure Cases ───────────────────────────────────────────────

    function testSwapAndDeposit_fail_ZeroReceiver() public {
        uint256 amount = 1000e6;
        _prepareUSDC(user1, amount);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = amount;
        swapAction.outputToken = _USDC_ADDRESS;

        vm.startPrank(user1);
        usdc.approve(address(optimizerZapper), amount);

        vm.expectRevert(
            OptimizerZapper.OptimizerZapper__ExecutionError.selector
        );
        optimizerZapper.swapAndDeposit(
            address(optimizer), false, swapAction, 1, address(0)
        );
        vm.stopPrank();
    }

    function testSwapAndDeposit_fail_ZeroExpectedShares() public {
        uint256 amount = 1000e6;
        _prepareUSDC(user1, amount);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = amount;
        swapAction.outputToken = _USDC_ADDRESS;

        vm.startPrank(user1);
        usdc.approve(address(optimizerZapper), amount);
        uint256 userBalanceBefore = usdc.balanceOf(user1);

        vm.expectRevert(
            OptimizerZapper.OptimizerZapper__ExecutionError.selector
        );
        optimizerZapper.swapAndDeposit(
            address(optimizer), false, swapAction, 0, user1
        );

        assertEq(usdc.balanceOf(user1), userBalanceBefore);
        assertEq(optimizer.balanceOf(user1), 0);
        _assertOptimizerZapperHasNoResidue(address(optimizer));
        vm.stopPrank();
    }

    function testSwapAndDeposit_fail_AssetMismatch() public {
        uint256 amount = 10 ether;
        _prepareDAI(user1, amount);

        // Output is DAI but optimizer's underlying is USDC.
        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _DAI_ADDRESS;
        swapAction.inputAmount = amount;
        swapAction.outputToken = _DAI_ADDRESS;

        vm.startPrank(user1);
        dai.approve(address(optimizerZapper), amount);

        vm.expectRevert(
            OptimizerZapper.OptimizerZapper__AssetMismatch.selector
        );
        optimizerZapper.swapAndDeposit(
            address(optimizer), false, swapAction, 1, user1
        );
        vm.stopPrank();
    }

    function testSwapAndDeposit_fail_AssetMismatchBeforeExternalSwap() public {
        uint256 amount = 10 ether;
        _prepareDAI(user1, amount);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _DAI_ADDRESS;
        swapAction.inputAmount = amount;
        swapAction.outputToken = _WETH_ADDRESS;
        swapAction.target = address(0xBEEF);
        swapAction.call = hex"deadbeef";

        vm.startPrank(user1);
        dai.approve(address(optimizerZapper), amount);

        uint256 userDaiBefore = dai.balanceOf(user1);
        uint256 optimizerSharesBefore = optimizer.balanceOf(user1);
        uint256 totalAssetsBefore = optimizer.totalAssets();

        vm.expectCall(
            _DAI_ADDRESS,
            abi.encodeWithSelector(
                IERC20.transferFrom.selector, user1, address(optimizerZapper), amount
            ),
            0
        );
        vm.expectCall(address(0xBEEF), swapAction.call, 0);
        vm.expectRevert(
            OptimizerZapper.OptimizerZapper__AssetMismatch.selector
        );
        optimizerZapper.swapAndDeposit(
            address(optimizer), false, swapAction, 1, user1
        );

        assertEq(dai.balanceOf(user1), userDaiBefore);
        assertEq(optimizer.balanceOf(user1), optimizerSharesBefore);
        assertEq(optimizer.totalAssets(), totalAssetsBefore);
        _assertOptimizerZapperHasNoResidue(address(optimizer));
        vm.stopPrank();
    }

    function testSwapAndDeposit_fail_InsufficientShares() public {
        uint256 amount = 1000e6;
        _prepareUSDC(user1, amount);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = amount;
        swapAction.outputToken = _USDC_ADDRESS;

        vm.startPrank(user1);
        usdc.approve(address(optimizerZapper), amount);

        // Expect revert because expectedShares is impossibly high.
        uint256 userUsdcBefore = usdc.balanceOf(user1);
        uint256 optimizerBalanceBefore = optimizer.balanceOf(user1);
        uint256 totalAssetsBefore = optimizer.totalAssets();

        vm.expectRevert(
            OptimizerZapper.OptimizerZapper__ExecutionError.selector
        );
        optimizerZapper.swapAndDeposit(
            address(optimizer), false, swapAction, type(uint256).max, user1
        );

        assertEq(usdc.balanceOf(user1), userUsdcBefore);
        assertEq(optimizer.balanceOf(user1), optimizerBalanceBefore);
        assertEq(optimizer.totalAssets(), totalAssetsBefore);
        _assertOptimizerZapperHasNoResidue(address(optimizer));
        vm.stopPrank();
    }

    function testSwapAndDeposit_fail_StaleExpectedSharesAfterOptimizerNavIncreaseRollsBack()
        public
    {
        uint256 amount = 1000e6;
        _prepareUSDC(user1, amount);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = amount;
        swapAction.outputToken = _USDC_ADDRESS;

        uint256 staleExpectedShares = optimizer.previewDeposit(amount);
        uint256 staleTotalAssets = optimizer.totalAssets();

        address donor = makeAddr("optimizerNavDonor");
        uint256 donationAssets = 100_000e6;
        _prepareUSDC(donor, donationAssets);
        vm.startPrank(donor);
        usdc.approve(address(borrowableCUSDC), donationAssets);
        uint256 donatedCTokenShares =
            borrowableCUSDC.deposit(donationAssets, donor);
        IERC20(address(borrowableCUSDC))
            .transfer(address(optimizer), donatedCTokenShares);
        vm.stopPrank();

        assertEq(
            optimizer.totalAssets(),
            staleTotalAssets,
            "precondition: optimizer NAV is stale after cToken donation"
        );

        uint256 userUsdcBefore = usdc.balanceOf(user1);
        uint256 optimizerSharesBefore = optimizer.balanceOf(user1);

        vm.startPrank(user1);
        usdc.approve(address(optimizerZapper), amount);
        vm.expectRevert(
            OptimizerZapper.OptimizerZapper__ExecutionError.selector
        );
        optimizerZapper.swapAndDeposit(
            address(optimizer), false, swapAction, staleExpectedShares, user1
        );
        vm.stopPrank();

        assertEq(usdc.balanceOf(user1), userUsdcBefore);
        assertEq(optimizer.balanceOf(user1), optimizerSharesBefore);
        assertEq(optimizer.totalAssets(), staleTotalAssets);
        _assertOptimizerZapperHasNoResidue(address(optimizer));

        optimizer.exchangeRateUpdated();
        assertGt(
            optimizer.totalAssets(),
            staleTotalAssets,
            "fresh accrual should absorb the donated cToken shares"
        );
        assertLt(
            optimizer.previewDeposit(amount),
            staleExpectedShares,
            "stale expected shares should exceed fresh mint amount"
        );
    }

    function testSwapAndDeposit_fail_ExternalSwapInsufficientSharesRollsBack()
        public
    {
        uint256 ethAmount = 3 ether;
        vm.deal(user1, ethAmount);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = SwapperLib.native;
        swapAction.inputAmount = ethAmount;
        swapAction.target = _UNISWAP_V3_SWAP_ROUTER;
        swapAction.outputToken = _USDC_ADDRESS;

        IUniswapV3Router.ExactInputSingleParams memory params;
        params.tokenIn = _WETH_ADDRESS;
        params.tokenOut = _USDC_ADDRESS;
        params.fee = 100;
        params.recipient = address(optimizerZapper);
        params.deadline = block.timestamp;
        params.amountIn = ethAmount;
        params.amountOutMinimum = 1;
        params.sqrtPriceLimitX96 = 0;
        swapAction.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector, params
        );

        uint256 userEthBefore = user1.balance;
        uint256 optimizerSharesBefore = optimizer.balanceOf(user1);
        uint256 totalAssetsBefore = optimizer.totalAssets();

        vm.prank(user1);
        vm.expectRevert(
            OptimizerZapper.OptimizerZapper__ExecutionError.selector
        );
        optimizerZapper.swapAndDeposit{value: ethAmount}(
            address(optimizer), false, swapAction, type(uint256).max, user1
        );

        assertEq(user1.balance, userEthBefore);
        assertEq(optimizer.balanceOf(user1), optimizerSharesBefore);
        assertEq(optimizer.totalAssets(), totalAssetsBefore);
        _assertOptimizerZapperHasNoResidue(address(optimizer));
    }

    function testSwapAndDeposit_fail_TightSwapSafeSlippage() public {
        uint256 amount = 1000e18;
        _prepareDAI(user1, amount);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _DAI_ADDRESS;
        swapAction.inputAmount = amount;
        swapAction.outputToken = _USDC_ADDRESS;
        swapAction.target = _UNISWAP_V3_SWAP_ROUTER;
        swapAction.slippage = 0;

        IUniswapV3Router.ExactInputSingleParams memory params;
        params.tokenIn = _DAI_ADDRESS;
        params.tokenOut = _USDC_ADDRESS;
        params.fee = 100;
        params.recipient = address(optimizerZapper);
        params.deadline = block.timestamp;
        params.amountIn = amount;
        params.amountOutMinimum = 0;
        params.sqrtPriceLimitX96 = 0;
        swapAction.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector, params
        );

        vm.startPrank(user1);
        dai.approve(address(optimizerZapper), amount);

        vm.expectPartialRevert(SwapperLib.SwapperLib__Slippage.selector);
        optimizerZapper.swapAndDeposit(
            address(optimizer), false, swapAction, 1, user1
        );
        vm.stopPrank();
    }

    function testSwapAndDeposit_fail_UnknownSwapTargetRollsBack() public {
        uint256 amount = 1000e18;
        _prepareDAI(user1, amount);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _DAI_ADDRESS;
        swapAction.inputAmount = amount;
        swapAction.outputToken = _USDC_ADDRESS;
        swapAction.target = address(0xBEEF);
        swapAction.call = hex"deadbeef";

        vm.startPrank(user1);
        dai.approve(address(optimizerZapper), amount);

        uint256 userDaiBefore = dai.balanceOf(user1);
        uint256 optimizerSharesBefore = optimizer.balanceOf(user1);
        uint256 totalAssetsBefore = optimizer.totalAssets();

        vm.expectRevert(SwapperLib.SwapperLib__UnknownCalldata.selector);
        optimizerZapper.swapAndDeposit(
            address(optimizer), false, swapAction, 1, user1
        );

        assertEq(dai.balanceOf(user1), userDaiBefore);
        assertEq(optimizer.balanceOf(user1), optimizerSharesBefore);
        assertEq(optimizer.totalAssets(), totalAssetsBefore);
        _assertOptimizerZapperHasNoResidue(address(optimizer));
        vm.stopPrank();
    }

    function testSwapAndDeposit_fail_OutputSentAwayRollsBackAtMaxSlippage()
        public
    {
        uint256 amount = 1000e18;
        _prepareDAI(user1, amount);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _DAI_ADDRESS;
        swapAction.inputAmount = amount;
        swapAction.outputToken = _USDC_ADDRESS;
        swapAction.target = _UNISWAP_V3_SWAP_ROUTER;
        swapAction.slippage = 0.999e18;

        IUniswapV3Router.ExactInputSingleParams memory params;
        params.tokenIn = _DAI_ADDRESS;
        params.tokenOut = _USDC_ADDRESS;
        params.fee = 100;
        params.recipient = user1;
        params.deadline = block.timestamp;
        params.amountIn = amount;
        params.amountOutMinimum = 0;
        params.sqrtPriceLimitX96 = 0;
        swapAction.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector, params
        );

        vm.startPrank(user1);
        dai.approve(address(optimizerZapper), amount);

        uint256 userDaiBefore = dai.balanceOf(user1);
        uint256 userUsdcBefore = usdc.balanceOf(user1);
        uint256 totalAssetsBefore = optimizer.totalAssets();

        vm.expectRevert(
            abi.encodeWithSelector(
                SwapperLib.SwapperLib__Slippage.selector, 1e18
            )
        );
        optimizerZapper.swapAndDeposit(
            address(optimizer), false, swapAction, 1, user1
        );

        assertEq(dai.balanceOf(user1), userDaiBefore);
        assertEq(usdc.balanceOf(user1), userUsdcBefore);
        assertEq(optimizer.totalAssets(), totalAssetsBefore);
        _assertOptimizerZapperHasNoResidue(address(optimizer));
        vm.stopPrank();
    }

    function testSwapAndDeposit_fail_UniswapCheckerRecipientMismatchRollsBack()
        public
    {
        centralRegistry.setExternalCalldataChecker(
            _UNISWAP_V3_SWAP_ROUTER,
            address(
                new TestUniswapV3ExactInputSingleChecker(
                    _UNISWAP_V3_SWAP_ROUTER,
                    _WETH_ADDRESS
                )
            )
        );

        uint256 amount = 1000e18;
        _prepareDAI(user1, amount);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _DAI_ADDRESS;
        swapAction.inputAmount = amount;
        swapAction.outputToken = _USDC_ADDRESS;
        swapAction.target = _UNISWAP_V3_SWAP_ROUTER;
        swapAction.slippage = 0.999e18;

        IUniswapV3Router.ExactInputSingleParams memory params;
        params.tokenIn = _DAI_ADDRESS;
        params.tokenOut = _USDC_ADDRESS;
        params.fee = 100;
        params.recipient = user1;
        params.deadline = block.timestamp;
        params.amountIn = amount;
        params.amountOutMinimum = 1;
        params.sqrtPriceLimitX96 = 0;
        swapAction.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector, params
        );

        uint256 userDaiBefore = dai.balanceOf(user1);
        uint256 userUsdcBefore = usdc.balanceOf(user1);
        uint256 totalAssetsBefore = optimizer.totalAssets();

        vm.startPrank(user1);
        dai.approve(address(optimizerZapper), amount);
        vm.expectRevert(
            BaseSwapChecker.CalldataChecker__RecipientError.selector
        );
        optimizerZapper.swapAndDeposit(
            address(optimizer), false, swapAction, 1, user1
        );
        vm.stopPrank();

        assertEq(dai.balanceOf(user1), userDaiBefore);
        assertEq(usdc.balanceOf(user1), userUsdcBefore);
        assertEq(optimizer.totalAssets(), totalAssetsBefore);
        _assertOptimizerZapperHasNoResidue(address(optimizer));
    }

    function testSwapAndDeposit_fail_MsgValueWithERC20() public {
        uint256 amount = 1000e6;
        _prepareUSDC(user1, amount);
        vm.deal(user1, 1 ether);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = amount;
        swapAction.outputToken = _USDC_ADDRESS;

        vm.startPrank(user1);
        usdc.approve(address(optimizerZapper), amount);

        vm.expectRevert(
            OptimizerZapper.OptimizerZapper__ExecutionError.selector
        );
        optimizerZapper.swapAndDeposit{value: 1 ether}(
            address(optimizer), false, swapAction, 1, user1
        );
        vm.stopPrank();
    }

    // ─── Multi-Market / Allocation Cap ───────────────────────────────

    function testSwapAndDeposit_fail_NativeValueMismatchRollsBack() public {
        uint256 amount = 3 ether;
        vm.deal(user1, amount);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
        swapAction.inputAmount = amount;
        swapAction.outputToken = _USDC_ADDRESS;

        vm.prank(user1);
        vm.expectRevert(
            OptimizerZapper.OptimizerZapper__ExecutionError.selector
        );
        optimizerZapper.swapAndDeposit{value: amount - 1}(
            address(optimizer), false, swapAction, 1, user1
        );

        assertEq(user1.balance, amount);
        assertEq(optimizer.balanceOf(user1), 0);
        _assertOptimizerZapperHasNoResidue(address(optimizer));
    }

    function testSwapAndDeposit_TwoMarkets_ExceedsCap() public {
        // Deploy a second isolated market for borrowableCUSDC2.
        MarketManagerIsolated mm2 = new MarketManagerIsolated(
            ICentralRegistry(address(centralRegistry)), 10e18, false
        );
        centralRegistry.addMarketManager(address(mm2));

        // Deploy borrowableCUSDC2 and a WETH collateral token in mm2.
        DynamicIRM irm2 = new DynamicIRM(
            ICentralRegistry(address(centralRegistry)),
            1000,
            1000,
            5000,
            1000,
            100,
            100000
        );
        BorrowableCToken borrowableCUSDC2 = new BorrowableCToken(
            ICentralRegistry(address(centralRegistry)),
            usdc,
            address(mm2),
            address(irm2)
        );
        irm2.setLinkedToken(address(borrowableCUSDC2));

        DynamicIRM irmWeth2 = new DynamicIRM(
            ICentralRegistry(address(centralRegistry)),
            1000,
            1000,
            5000,
            1000,
            100,
            100000
        );
        BorrowableCToken collateralWETH2 = new BorrowableCToken(
            ICentralRegistry(address(centralRegistry)),
            weth,
            address(mm2),
            address(irmWeth2)
        );
        irmWeth2.setLinkedToken(address(collateralWETH2));

        oracleManager.addCTokenSupport(address(borrowableCUSDC2));
        oracleManager.addCTokenSupport(address(collateralWETH2));

        // List and initialize deposits in mm2.
        _prepareWETH(address(this), 77777);
        _prepareUSDC(address(this), 77777);
        weth.approve(address(collateralWETH2), 77777);
        usdc.approve(address(borrowableCUSDC2), 77777);
        mm2.listTokens(address(collateralWETH2), address(borrowableCUSDC2));

        // Seed liquidity into borrowableCUSDC2.
        address lp2 = makeAddr("lp2");
        _prepareUSDC(lp2, 10_000e6);
        vm.startPrank(lp2);
        usdc.approve(address(borrowableCUSDC2), 10_000e6);
        borrowableCUSDC2.deposit(10_000e6, lp2);
        vm.stopPrank();

        // Deploy a fresh optimizer with two markets at 50% cap each.
        address[] memory cTokens = new address[](2);
        cTokens[0] = address(borrowableCUSDC);
        cTokens[1] = address(borrowableCUSDC2);
        uint256[] memory caps = new uint256[](2);
        caps[0] = 5000; // 50%
        caps[1] = 5000; // 50%

        LendingOptimizer optimizer2 = new LendingOptimizer(
            usdc,
            "Flagship",
            "Flag",
            ICentralRegistry(address(centralRegistry)),
            cTokens,
            caps,
            0
        );

        // Initialize the optimizer.
        _prepareUSDC(address(this), 77777);
        usdc.approve(address(optimizer2), 77777);
        optimizer2.initializeDeposits(address(borrowableCUSDC));

        // Deposit 1000 USDC entirely into market 0 — this pushes market 0
        // to ~100% of total assets, well above its 50% cap.
        // The deposit path does NOT enforce allocation caps (only rebalance
        // does), so this should succeed.
        uint256 amount = 1000e6;
        _prepareUSDC(user1, amount);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = amount;
        swapAction.outputToken = _USDC_ADDRESS;

        vm.startPrank(user1);
        usdc.approve(address(optimizerZapper), amount);

        uint256 shares = optimizerZapper.swapAndDeposit(
            address(optimizer2), false, swapAction, 1, user1
        );
        vm.stopPrank();

        // Deposit succeeds — caps are rebalancing constraints, not deposit gates.
        assertGt(
            shares, 0, "Should receive optimizer shares despite exceeding cap"
        );
        assertEq(
            optimizer2.balanceOf(user1),
            shares,
            "Balance should match returned shares"
        );
        _assertOptimizerZapperHasNoResidue(address(optimizer2));
    }

    // ─── Additional Coverage ─────────────────────────────────────────

    function testSwapAndDeposit_fail_OptimizerPaused() public {
        // Pause the optimizer.
        optimizer.setMintPaused(true);

        uint256 amount = 1000e6;
        _prepareUSDC(user1, amount);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = amount;
        swapAction.outputToken = _USDC_ADDRESS;

        vm.startPrank(user1);
        usdc.approve(address(optimizerZapper), amount);

        // Optimizer's deposit reverts with MintPaused — propagates through zapper.
        vm.expectRevert(LendingOptimizer.LendingOptimizer__MintPaused.selector);
        optimizerZapper.swapAndDeposit(
            address(optimizer), false, swapAction, 1, user1
        );
        assertEq(usdc.balanceOf(address(optimizerZapper)), 0);
        vm.stopPrank();
    }

    function _assertOptimizerZapperHasNoResidue(address optimizer_)
        internal
        view
    {
        address optimizerAsset = LendingOptimizer(optimizer_).asset();
        assertEq(address(optimizerZapper).balance, 0, "zapper native residue");
        assertEq(
            usdc.balanceOf(address(optimizerZapper)), 0, "zapper USDC residue"
        );
        assertEq(
            dai.balanceOf(address(optimizerZapper)), 0, "zapper DAI residue"
        );
        assertEq(
            weth.balanceOf(address(optimizerZapper)), 0, "zapper WETH residue"
        );
        assertEq(
            LendingOptimizer(optimizer_).balanceOf(address(optimizerZapper)),
            0,
            "zapper optimizer share residue"
        );
        assertEq(
            IERC20(optimizerAsset).allowance(address(optimizerZapper), optimizer_),
            0,
            "zapper optimizer asset allowance residue"
        );
    }
}
