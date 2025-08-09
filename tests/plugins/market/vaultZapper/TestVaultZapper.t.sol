// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

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

contract TestVaultZapperWithTokens is TestBaseMarketIsolated {

    address internal _UNISWAP_V3_SWAP_ROUTER =
        0xE592427A0AEce92De3Edee1F18E0157C05861564;

    address internal _SFRAX_ADDRESS = 0xA663B02CF0a4b149d2aD41910CB81e23e1c41c32;

    VaultZapper public vaultZapper;

    SimpleCToken public simpleCSFRAX;

    function setUp() public override {
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

    function test_vaultZapper_success_swapAndDeposit() public {

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

    function test_vaultZapper_success_redeemAndSwap() public {

        test_vaultZapper_success_swapAndDeposit();

        uint256 cTokenShares = simpleCSFRAX.balanceOf(user1);
        assertGt(cTokenShares, 0, "Should have cToken shares after deposit");

        vm.startPrank(user1);

        simpleCSFRAX.setDelegateApproval(address(vaultZapper), true);

        BaseZapper.RedeemAction memory redeemAction;
        redeemAction.cToken = address(simpleCSFRAX);
        redeemAction.shares = cTokenShares;
        redeemAction.forceRedeemCollateral = false;

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _FRAX_ADDRESS;
        swapAction.inputAmount = cTokenShares;
        swapAction.target = _UNISWAP_V3_SWAP_ROUTER;
        swapAction.outputToken = address(usdc);

        // Multi-hop swap FRAX -> WETH -> USDC  
        IUniswapV3Router.ExactInputParams memory params;
        params.path = abi.encodePacked(
            _FRAX_ADDRESS,
            uint24(3000),
            _WETH_ADDRESS,
            uint24(500),
            address(usdc)
        );
        params.recipient = address(vaultZapper);
        params.deadline = block.timestamp + 1 hours;

        // Get the expected redemption amounts
        uint256 expectedSFRAXAmount = simpleCSFRAX.previewRedeem(cTokenShares);
        uint256 expectedFRAXAmount = IVault(address(simpleCSFRAX)).previewRedeem(expectedSFRAXAmount);
        params.amountIn = expectedFRAXAmount;

        params.amountOutMinimum = 0;
        
        swapAction.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInput.selector,
            params
        );

        uint256 usdcBalanceBefore = usdc.balanceOf(user1);

        vaultZapper.redeemAndSwap(
            redeemAction,
            swapAction,
            user1
        );

        vm.stopPrank();

        assertEq(simpleCSFRAX.balanceOf(user1), 0, "Should have no cToken shares left");
        assertGt(usdc.balanceOf(user1), usdcBalanceBefore, "Should have received USDC");
    
    }

    function test_vaultZapper_success_redeemSwapAndDeposit() public {
        test_vaultZapper_success_swapAndDeposit();

        uint256 cTokenShares = simpleCSFRAX.balanceOf(user1);
        assertGt(cTokenShares, 0, "Should have cToken shares after deposit");

        vm.startPrank(user1);

        simpleCSFRAX.setDelegateApproval(address(vaultZapper), true);

        BaseZapper.RedeemAction memory redeemAction;
        redeemAction.cToken = address(simpleCSFRAX);
        redeemAction.shares = cTokenShares;
        redeemAction.forceRedeemCollateral = false;

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _SFRAX_ADDRESS; // will be updated by VaultZapper after redemption
        swapAction.inputAmount = cTokenShares; // This will be updated by VaultZapper after redemption
        swapAction.target = _UNISWAP_V3_SWAP_ROUTER;
        swapAction.outputToken = address(usdc); // USDC for borrowableCUSDC

        // Multi-hop swap FRAX -> WETH -> USDC
        IUniswapV3Router.ExactInputParams memory params;
        params.path = abi.encodePacked(
            _FRAX_ADDRESS,
            uint24(3000),
            _WETH_ADDRESS,
            uint24(500),
            address(usdc)
        );
        params.recipient = address(vaultZapper);
        params.deadline = block.timestamp + 1 hours;

        uint256 expectedSFRAXAmount = simpleCSFRAX.previewRedeem(cTokenShares);
        uint256 expectedFRAXAmount = IVault(address(simpleCSFRAX)).previewRedeem(expectedSFRAXAmount);
        params.amountIn = expectedFRAXAmount;
        params.amountOutMinimum = 0;
        
        swapAction.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInput.selector,
            params
        );

        uint256 borrowableCUSDCBalanceBefore = borrowableCUSDC.balanceOf(user1);

        // Execute redeemSwapAndDeposit simpleCSFRAX -> FRAX -> USDC -> borrowableCUSDC
        vaultZapper.redeemSwapAndDeposit(
            address(borrowableCUSDC),
            redeemAction,
            swapAction,
            0,
            false,
            user1 
        );

        vm.stopPrank();

        assertEq(simpleCSFRAX.balanceOf(user1), 0, "Should have no simpleCSFRAX shares left");
        assertGt(borrowableCUSDC.balanceOf(user1), borrowableCUSDCBalanceBefore, "Should have received borrowableCUSDC shares");
        
    }

    // NO-SWAP TESTS

    function test_vaultZapper_success_swapAndDeposit_noSwap() public {
        
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

    function test_vaultZapper_success_redeemAndSwap_noSwap() public {

        test_vaultZapper_success_swapAndDeposit_noSwap();

        uint256 cTokenShares = simpleCSFRAX.balanceOf(user1);
        assertGt(cTokenShares, 0, "Should have cToken shares after deposit");

        vm.startPrank(user1);

        simpleCSFRAX.setDelegateApproval(address(vaultZapper), true);

        BaseZapper.RedeemAction memory redeemAction;
        redeemAction.cToken = address(simpleCSFRAX);
        redeemAction.shares = cTokenShares;
        redeemAction.forceRedeemCollateral = false;

        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _FRAX_ADDRESS;
        swapAction.inputAmount = cTokenShares;
        swapAction.target = _UNISWAP_V3_SWAP_ROUTER;
        swapAction.outputToken = _FRAX_ADDRESS;
        swapAction.call = "";

        uint256 fraxBalanceBefore = IERC20(_FRAX_ADDRESS).balanceOf(user1);

        vaultZapper.redeemAndSwap(
            redeemAction,
            swapAction,
            user1
        );

        vm.stopPrank();

        assertEq(simpleCSFRAX.balanceOf(user1), 0, "Should have no cToken shares left");
        assertGt(IERC20(_FRAX_ADDRESS).balanceOf(user1), fraxBalanceBefore, "Should have received FRAX");
    }

}