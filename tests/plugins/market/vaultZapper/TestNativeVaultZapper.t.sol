// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { NativeVaultZapper } from "contracts/plugins/market/NativeVaultZapper.sol";
import { BaseZapper } from "contracts/plugins/BaseZapper.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";

import { SimpleCToken } from "contracts/market/token/SimpleCToken.sol";
import { IUniswapV3Router } from "contracts/interfaces/external/uniswap/IUniswapV3Router.sol";
import { IVault } from "contracts/interfaces/IVault.sol";

import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";

contract TestNativeVaultZapperWith is TestBaseMarketIsolated {

    NativeVaultZapper public vaultZapper;
    address public SHMON_ADDRESS = 0x3a98250F98Dd388C211206983453837C8365BDc1;
    address public WMON_ADDRESS = 0x760AfE86e5de5fa0Ee542fc7B7B713e1c5425701;
    
    SimpleCToken public simpleCSHMON;

    address public _CHAINLINK_ETH_USD_MONAD = 0x0c76859E85727683Eeba0C70Bc2e0F5781337818;
    address public _CHAINLINK_USDC_USD_MONAD = 0x70BB0758a38ae43418ffcEd9A25273dd4e804D15;

    address internal _UNISWAP_V3_SWAP_ROUTER =
        0xE592427A0AEce92De3Edee1F18E0157C05861564;

    function setUp() public override {
        _fork("ETH_NODE_URI_MONAD");
        
        _deployCentralRegistry();
        _deployCVE();
        _deployRewardManager();
        _deployVeCVE();
        _deployGaugeManager();
        _deployMarketManager();
        _deployOracleManager();
        _deployBorrowableCUSDC();

        vaultZapper = new NativeVaultZapper(ICentralRegistry(address(centralRegistry)), WMON_ADDRESS);

        centralRegistry.setExternalCalldataChecker(
            _UNISWAP_V3_SWAP_ROUTER,
            address(new MockCalldataChecker(_UNISWAP_V3_SWAP_ROUTER))
        );

        simpleCSHMON = new SimpleCToken(
            ICentralRegistry(address(centralRegistry)), 
            IERC20(SHMON_ADDRESS), 
            address(marketManagerIsolated)
        );

        chainlinkAdaptor = new ChainlinkAdaptor(
            ICentralRegistry(address(centralRegistry))
        );

        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));

        chainlinkAdaptor.addAsset(
            SHMON_ADDRESS,
            true,
            _CHAINLINK_ETH_USD_MONAD,
            0
        );
        oracleManager.addAssetPriceFeed(SHMON_ADDRESS, address(chainlinkAdaptor));
        oracleManager.addCTokenSupport(address(simpleCSHMON));

        chainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            true,
            _CHAINLINK_USDC_USD_MONAD,
            0
        );
        oracleManager.addAssetPriceFeed(_USDC_ADDRESS, address(chainlinkAdaptor));
        oracleManager.addCTokenSupport(address(borrowableCUSDC));

        deal(SHMON_ADDRESS, address(this), 77777 ether);
        IERC20(SHMON_ADDRESS).approve(address(simpleCSHMON), 77777 ether);
        deal(_USDC_ADDRESS, address(this), 77777 ether);
        IERC20(_USDC_ADDRESS).approve(address(borrowableCUSDC), 77777 ether);

        marketManagerIsolated.listTokens(address(simpleCSHMON), address(borrowableCUSDC));

        _setCTokenConfigBasic(address(simpleCSHMON), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 100_000e18, 100_000e18);
    }

    function test_vaultZapper_success_swapAndDeposit_NoSwap_DirectNative() public {

        // No swap in this test

        deal(user1, 100 ether);

        uint256 previewDepositAmount = IVault(simpleCSHMON.asset()).previewDeposit(100 ether);
        uint256 initialEthBalance = user1.balance;

        SwapperLib.Swap memory swapAction;
        swapAction.inputAmount = 100 ether;
        swapAction.outputToken = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
        swapAction.inputToken = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

        vm.startPrank(user1);

        uint256 returnedShares = vaultZapper.swapAndDeposit{value: 100 ether}
        (
            address(simpleCSHMON),
            false,
            swapAction,
            0,
            false,
            user1
        );

        vm.stopPrank();

        assertEq(user1.balance, initialEthBalance - 100 ether, "User ETH balance should decrease by input amount");
        assertEq(simpleCSHMON.balanceOf(user1), previewDepositAmount, "User cToken balance should increase, cToken exchange rate is 1:1 in this test");
        assertEq(simpleCSHMON.balanceOf(user1), returnedShares, "Returned shares should match user balance");
        assertEq(IERC20(simpleCSHMON.asset()).balanceOf(address(simpleCSHMON)), previewDepositAmount + 77777, "Vault balance in cToken should increase");
        assertEq(simpleCSHMON.totalAssets(), previewDepositAmount + 77777, "cToken totalAssets should increase");
        assertEq(address(vaultZapper).balance, 0, "Zapper should not hold any ETH after operation");
    }

    function test_vaultZapper_success_swapAndDeposit_NoSwap_WrappedNative() public {

        deal(WMON_ADDRESS, user1, 100 ether);

        uint256 previewDepositAmount = IVault(simpleCSHMON.asset()).previewDeposit(100 ether);
        uint256 initialWMONBalance = IERC20(WMON_ADDRESS).balanceOf(user1);

        SwapperLib.Swap memory swapAction;
        swapAction.inputAmount = 100 ether;
        swapAction.outputToken = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
        swapAction.inputToken = address(WMON_ADDRESS);

        vm.startPrank(user1);

        IERC20(WMON_ADDRESS).approve(address(vaultZapper), 100 ether);

        uint256 returnedShares = vaultZapper.swapAndDeposit(
            address(simpleCSHMON),
            false,
            swapAction,
            0,
            false,
            user1
        );

        vm.stopPrank();

        assertEq(IERC20(WMON_ADDRESS).balanceOf(user1), initialWMONBalance - 100 ether, "User WMON balance should decrease by input amount");
        assertEq(simpleCSHMON.balanceOf(user1), previewDepositAmount, "User cToken balance should increase, cToken exchange rate is 1:1 in this test");
        assertEq(simpleCSHMON.balanceOf(user1), returnedShares, "Returned shares should match user balance");
        assertEq(IERC20(simpleCSHMON.asset()).balanceOf(address(simpleCSHMON)), previewDepositAmount + 77777, "Vault balance in cToken should increase");
        assertEq(simpleCSHMON.totalAssets(), previewDepositAmount + 77777, "cToken totalAssets should increase");
        assertEq(IERC20(WMON_ADDRESS).balanceOf(address(vaultZapper)), 0, "Zapper should not hold WMON after operation");
        assertEq(address(vaultZapper).balance, 0, "Zapper should not hold ETH after operation");
    }
}