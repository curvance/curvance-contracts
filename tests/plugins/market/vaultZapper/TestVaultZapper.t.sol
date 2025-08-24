// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { VaultZapper } from "contracts/plugins/market/VaultZapper.sol";
import { BaseZapper } from "contracts/plugins/BaseZapper.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";

import { SimpleCToken } from "contracts/market/token/SimpleCToken.sol";
import { IUniswapV3Router } from "contracts/interfaces/external/uniswap/IUniswapV3Router.sol";
import { IVault } from "contracts/interfaces/IVault.sol";

// 1. For this test's deposit functions, we use simpleCSFRAX-borrowableCUSDC market since there is liquidity for FRAX which is the underlying asset for sFRAX,
//    and sFRAX is an erc4626 token.
// 2. We use simpleCUSDC-borrowableCDAI market for redeemAndSwap/swapAndRepay functions since there is no liquidity for sFRAX, and
//    there is liquidity for USDC and DAI.

contract TestVaultZapperWithTokens is TestBaseMarketIsolated {

    address internal _UNISWAP_V3_SWAP_ROUTER =
        0xE592427A0AEce92De3Edee1F18E0157C05861564;

    address internal _SFRAX_ADDRESS = 0xA663B02CF0a4b149d2aD41910CB81e23e1c41c32;

    VaultZapper public vaultZapper;

    SimpleCToken public simpleCSFRAX;

    function setUp() public override {
    }

    function test_vaultZapper_success_swapAndDeposit() public {
        _setUpSimpleCSFRAX_borrowableCUSDC();
        
        _prepareUSDC(user1, 100e6);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = address(usdc);
        swapAction.inputAmount = 100e6;
        swapAction.target = _UNISWAP_V3_SWAP_ROUTER;
        swapAction.outputToken = _FRAX_ADDRESS;

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
            IUniswapV3Router.exactInput.selector,
            params
        );
        
        vm.startPrank(user1);
        usdc.approve(address(vaultZapper), 100e6);

        vaultZapper.swapAndDeposit(
            address(simpleCSFRAX),
            false,
            swapAction,
            0,
            false,
            user1
        );

        vm.stopPrank();

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

        // swap ETH -> FRAX
        IUniswapV3Router.ExactInputParams memory params;
        params.path = abi.encodePacked(
            _WETH_ADDRESS,
            uint24(3000),
            _FRAX_ADDRESS
        );
        params.recipient = address(vaultZapper);
        params.deadline = block.timestamp + 1 hours;
        params.amountIn = ethAmount;
        params.amountOutMinimum = 0;
        
        swapAction.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInput.selector,
            params
        );
        
        vm.startPrank(user1);

        vaultZapper.swapAndDeposit{ value: ethAmount }(
            address(simpleCSFRAX),
            true,  // depositAsWrappedNative=true
            swapAction,
            0,
            false,
            user1
        );

        vm.stopPrank();

        // Verify user received some cToken shares
        assertGt(simpleCSFRAX.balanceOf(user1), 0, "User should have received cToken shares");
    }

    function test_vaultZapper_success_swapAndDeposit_withETH_noWrapping() public {

        _setUpSimpleCSFRAX_borrowableCUSDC();

        uint256 ethAmount = 1 ether;
        vm.deal(user1, ethAmount);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
        swapAction.inputAmount = ethAmount;
        swapAction.target = _UNISWAP_V3_SWAP_ROUTER;
        swapAction.outputToken = _FRAX_ADDRESS;

        // swap ETH -> FRAX
        IUniswapV3Router.ExactInputParams memory params;
        params.path = abi.encodePacked(
            _WETH_ADDRESS,
            uint24(3000),
            _FRAX_ADDRESS
        );
        params.recipient = address(vaultZapper);
        params.deadline = block.timestamp + 1 hours;
        params.amountIn = ethAmount;
        params.amountOutMinimum = 0;
        
        swapAction.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInput.selector,
            params
        );
        
        vm.startPrank(user1);

        vaultZapper.swapAndDeposit{ value: ethAmount }(
            address(simpleCSFRAX),
            false, // depositAsWrappedNative=false
            swapAction,
            0,
            false,
            user1
        );

        vm.stopPrank();

        // Verify user received some cToken shares
        assertGt(simpleCSFRAX.balanceOf(user1), 0, "User should have received cToken shares");
    }

    function testSwapAndRepay() external {
        _setUpSimpleCUSDC_borrowableCDAI();

        _prepareUSDC(user1, 2000e6);

        vm.startPrank(user1);
        usdc.approve(address(simpleCUSDC), 2000e6);
        simpleCUSDC.depositAsCollateral(2000e6, user1);

        simpleCUSDC.setDelegateApproval(address(vaultZapper), true);

        // try borrow()
        borrowableCDAI.borrow(500 ether, user1);
        vm.stopPrank();

        assertEq(dai.balanceOf(user1), 500 ether);
        assertApproxEqAbs(borrowableCDAI.debtBalance(user1), 500 ether, 1 ether);

        // skip min hold period
        skip(20 minutes);

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 500e6;
        swapAction.outputToken = _DAI_ADDRESS;
        swapAction.target = _UNISWAP_V3_SWAP_ROUTER;

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
            IUniswapV3Router.exactInputSingle.selector,
            params
        );

        _prepareUSDC(user1, 500e6);
        vm.startPrank(user1);
        usdc.approve(address(vaultZapper), 500e6);
        vaultZapper.swapAndRepay(
            address(borrowableCDAI),
            false,
            swapAction,
            450e18,
            user1
        );
        vm.stopPrank();

        assertApproxEqAbs(dai.balanceOf(user1), 550 ether, 1 ether);
        assertApproxEqAbs(borrowableCDAI.debtBalance(user1), 50 ether, 1 ether);
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
            IUniswapV3Router.exactInputSingle.selector,
            params
        );

        vm.prank(user1);
        vaultZapper.redeemAndSwap(redeemAction, swapAction, user1);

        assertGt(weth.balanceOf(user1), 0);
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
            IUniswapV3Router.exactInputSingle.selector,
            params
        );

        vaultZapper.redeemAndSwap(redeemAction, swapAction, user1);

        assertGt(usdc.balanceOf(user1), 9.99e6); // 10e6 - fees

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
            IUniswapV3Router.exactInputSingle.selector,
            params
        );

        vm.startPrank(user1);

        vaultZapper.redeemSwapAndDeposit(
            address(simpleCUSDC),
            redeemAction,
            swapAction,
            0,
            false,
            user1
        );
        vm.stopPrank();

        assertGt(simpleCUSDC.balanceOf(user1), 99e6);
    }

    // NO-SWAP TESTS

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

        vaultZapper.swapAndDeposit(
            address(simpleCSFRAX),
            false,
            swapAction,
            0,
            false,
            user1
        );

        vm.stopPrank();

        uint256 balanceAfter = simpleCSFRAX.balanceOf(user1);
        assertGt(balanceAfter, balanceBefore, "User should have received cToken shares");
    }

    // Market setup

    function _setUpSimpleCSFRAX_borrowableCUSDC() internal {
        _fork(21000000); // Use a more recent block where sFRAX exists
        
        _init();

        vaultZapper = new VaultZapper(ICentralRegistry(address(centralRegistry)), _WETH_ADDRESS);

        centralRegistry.setExternalCalldataChecker(
            _UNISWAP_V3_SWAP_ROUTER,
            address(new MockCalldataChecker(_UNISWAP_V3_SWAP_ROUTER))
        );

        simpleCSFRAX = new SimpleCToken(
            ICentralRegistry(address(centralRegistry)), 
            IERC20(_SFRAX_ADDRESS), 
            address(marketManagerIsolated));

        chainlinkAdaptor.addAsset(
            _SFRAX_ADDRESS,
            true,
            _CHAINLINK_FRAX_USD,
            0
        );
        oracleManager.addAssetPriceFeed(_SFRAX_ADDRESS, address(chainlinkAdaptor));
        oracleManager.addCTokenSupport(address(simpleCSFRAX));

        deal(_SFRAX_ADDRESS, address(this), 77777);
        _prepareUSDC(address(this), 77777);

        IERC20(_SFRAX_ADDRESS).approve(address(simpleCSFRAX), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);

        marketManagerIsolated.listTokens(address(simpleCSFRAX), address(borrowableCUSDC));

        _setCTokenConfigBasic(address(simpleCSFRAX), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 100_000e18, 100_000e18);
    }

    function _setUpSimpleCUSDC_borrowableCDAI() internal {
        super.setUp();

        oracleManager.addCTokenSupport(address(simpleCUSDC));

        vaultZapper = new VaultZapper(
            ICentralRegistry(address(centralRegistry)),
            _WETH_ADDRESS
        );

        centralRegistry.setExternalCalldataChecker(
            _UNISWAP_V3_SWAP_ROUTER,
            address(new MockCalldataChecker(_UNISWAP_V3_SWAP_ROUTER))
        );

        _prepareDAI(address(this), 200000e18);
        dai.approve(address(borrowableCDAI), 200000e18);

        _prepareUSDC(address(this), 100e6);
        usdc.approve(address(simpleCUSDC), 100e6);

        marketManagerIsolated.listTokens(address(simpleCUSDC), address(borrowableCDAI));
        
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