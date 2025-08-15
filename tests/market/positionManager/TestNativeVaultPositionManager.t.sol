// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { NativeVaultPositionManager } from "contracts/market/position-management/NativeVaultPositionManager.sol";
import { SimpleCToken } from "contracts/market/token/SimpleCToken.sol";
import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { ICToken, AccountSnapshot } from "contracts/interfaces/ICToken.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IVault } from "contracts/interfaces/IVault.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { IUniswapV3Router } from "contracts/interfaces/external/uniswap/IUniswapV3Router.sol";
import { BasePositionManager } from "contracts/market/position-management/BasePositionManager.sol";

import { console2 } from "forge-std/console2.sol";

/// @dev
/// Test overview:
/// - This suite exercises NativeVaultPositionManager across two forks because swaps are enforced
///   during deleveraging and there is limited DEX support/liquidity on Monad.
///
/// Environments:
/// - Monad testnet (fork: "ETH_NODE_URI_MONAD"):
///   - Used for leverage flows that do not require swaps.
///   - Also used for revert tests against a SHMON/USDC market (stablecoin debt) to validate input checks.
/// - Ethereum mainnet (forked in super.setUp() from TestBaseMarketIsolated):
///   - Used for deleverage flows where swaps are required (has Uniswap V3 liquidity).
///
/// Markets and pricing:
/// - SHMON/WMON (Monad):
///   - Collateral: SimpleCToken(SHMON)
///   - Debt: BorrowableCToken(WMON)
///   - Pricing via Chainlink ETH/USD on Monad (_CHAINLINK_ETH_USD_MONAD).
/// - SHMON/USDC (Monad) - revert tests only:
///   - Debt: BorrowableCToken(USDC)
///   - Pricing via Chainlink USDC/USD on Monad (_CHAINLINK_USDC_USD_MONAD).
/// - USDC/DAI (Ethereum) - deleverage only:
///   - Swap path: USDC -> DAI via Uniswap V3
///
/// Why multiple forks/markets:
/// - Leverage without swaps works on Monad (no DEX dependency).
/// - Deleverage requires a swap, so we use Ethereum mainnet liquidity.
/// - Revert tests use a Monad SHMON/USDC market to isolate parameter validation from liquidity availability.
///
/// Test map:
/// - testLeverage_BorrowedWrappedNative_NoSwaps (Monad, SHMON/WMON): no-swap leverage path.
/// - testDepositAndLeverage_BorrowedWrappedNative (Monad, SHMON/WMON): deposit + leverage without swaps.
/// - testDeleverage (Ethereum, USDC/DAI): enforced swap via Uniswap V3 during deleveraging.
/// - test_Leverage_fail_... (Monad, SHMON/USDC): invalid swap params/targets/amounts to assert reverts.

contract TestNativeVaultPositionManager is TestBaseMarketIsolated {
    NativeVaultPositionManager public positionManager;

    address public constant SHMON_ADDRESS = 0x3a98250F98Dd388C211206983453837C8365BDc1;
    address public constant WMON_ADDRESS = 0x760AfE86e5de5fa0Ee542fc7B7B713e1c5425701;

    address public constant _CHAINLINK_ETH_USD_MONAD = 0x0c76859E85727683Eeba0C70Bc2e0F5781337818;

    address public constant _CHAINLINK_USDC_USD_MONAD = 0x70BB0758a38ae43418ffcEd9A25273dd4e804D15;

    address public constant _USDC_ADDRESS_MONAD = 0xf817257fed379853cDe0fa4F97AB987181B1E5Ea;

    SimpleCToken public simpleCSHMON;
    BorrowableCToken public borrowableCWMON;
    BorrowableCToken public borrowableCUSDC_monad;

    address internal _UNISWAP_V3_SWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    receive() external payable {}
    fallback() external payable {}

    function setUp() public override {
    }

    function testLeverage_BorrowedWrappedNative_NoSwaps() public {

        _setUpSHMON_WMON_Market();

        deal(SHMON_ADDRESS, user1, 500e18);
        vm.startPrank(user1);
        IERC20(SHMON_ADDRESS).approve(address(simpleCSHMON), type(uint256).max);
        uint256 depositShares = 500e18;
        simpleCSHMON.deposit(depositShares, user1);
        simpleCSHMON.postCollateral(depositShares);

        borrowableCWMON.borrow(1 ether, user1);

        uint256 amountForLeverage = positionManager.maxRemainingLeverageOf(
            user1,
            address(borrowableCWMON)
        ) / 2;

        console2.log("amountForLeverage", amountForLeverage);

        NativeVaultPositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCWMON));
        leverageAction.borrowAssets = amountForLeverage;
        leverageAction.cToken = ICToken(address(simpleCSHMON));

        positionManager.leverage(leverageAction, 0.5e18);

        AccountSnapshot memory debtSnap = borrowableCWMON.getSnapshot(user1);
        AccountSnapshot memory collSnap = simpleCSHMON.getSnapshot(user1);

        assertGt(debtSnap.debtBalance, 1 ether, "Debt should increase after leverage");
        assertGt(collSnap.collateralPosted, 0, "Collateral should be posted");

        vm.stopPrank();
    }

    function testDepositAndLeverage_BorrowedWrappedNative() public {

        _setUpSHMON_WMON_Market();

        vm.startPrank(user1);

        deal(SHMON_ADDRESS, user1, 500e18);
        IERC20(SHMON_ADDRESS).approve(address(positionManager), type(uint256).max);

        simpleCSHMON.setDelegateApproval(address(positionManager), true);

        uint256 amountForLeverage = 100 ether;

        NativeVaultPositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCWMON));
        leverageAction.borrowAssets = amountForLeverage;
        leverageAction.cToken = ICToken(address(simpleCSHMON));

        positionManager.depositAndLeverage(500e18, leverageAction, 0.05e18);

        AccountSnapshot memory collSnap = simpleCSHMON.getSnapshot(user1);
        AccountSnapshot memory debtSnap = borrowableCWMON.getSnapshot(user1);

        assertGt(collSnap.collateralPosted, 0, "Collateral should be posted");
        assertGt(debtSnap.debtBalance, 0, "Debt should be incurred");

        vm.stopPrank();
    }

    function testDeleverage() public {

        _setUpUSDC_DAIPool_Eth();

        deal(address(usdc), user1, 1000e6);

        vm.startPrank(user1);
        
        usdc.approve(address(borrowableCUSDC), 1000e6);

        borrowableCUSDC.depositAsCollateral(1000e6, user1);

        borrowableCDAI.borrow(600e18, user1);

        skip(20 minutes);
        borrowableCDAI.accrueIfNeeded();

        AccountSnapshot memory debtBefore = borrowableCDAI.getSnapshot(user1);
        AccountSnapshot memory collBefore = borrowableCUSDC.getSnapshot(user1);

        NativeVaultPositionManager.DeleverageAction memory deleverageAction;
        deleverageAction.cToken = ICToken(address(borrowableCUSDC));
        deleverageAction.collateralAssets = collBefore.collateralPosted / 5;
        deleverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCDAI));
        deleverageAction.repayAssets = debtBefore.debtBalance / 10;

        deleverageAction.swapActions = new SwapperLib.Swap[](1);
        deleverageAction.swapActions[0].inputToken = address(usdc);
        deleverageAction.swapActions[0].inputAmount = collBefore.collateralPosted / 5;
        deleverageAction.swapActions[0].outputToken = address(dai);
        deleverageAction.swapActions[0].target = _UNISWAP_V3_SWAP_ROUTER;

        IUniswapV3Router.ExactInputParams memory params;
        params.path = abi.encodePacked(
            address(usdc),
            uint24(3000),
            address(dai)
        );
        params.recipient = address(positionManager);
        params.deadline = block.timestamp + 1 hours;
        params.amountIn = collBefore.collateralPosted / 5;
        params.amountOutMinimum = 0;

        deleverageAction.swapActions[0].call = abi.encodeWithSelector(
            IUniswapV3Router.exactInput.selector,
            params
        );
        deleverageAction.swapActions[0].slippage = 0.5e18;

        borrowableCUSDC.approve(address(positionManager), type(uint256).max);

        positionManager.deleverage(deleverageAction, 0.5e18);

        AccountSnapshot memory debtAfter = borrowableCDAI.getSnapshot(user1);
        AccountSnapshot memory collAfter = borrowableCUSDC.getSnapshot(user1);

        assertLt(debtAfter.debtBalance, debtBefore.debtBalance, "Debt should be reduced after deleverage");
        assertLt(collAfter.collateralPosted, collBefore.collateralPosted, "Collateral should be reduced after deleverage");

        vm.stopPrank();
    }

    /// Revert tests ///

    function test_Leverage_fail_whenInvalidSwapCallEmpty() public {
        _setUpSHMON_USDC_Market();

        deal(SHMON_ADDRESS, user1, 500e18);

        vm.startPrank(user1);
        IERC20(SHMON_ADDRESS).approve(address(simpleCSHMON), type(uint256).max);
        simpleCSHMON.deposit(500e18, user1);
        simpleCSHMON.postCollateral(500e18);

        borrowableCUSDC_monad.borrow(50e6, user1);

        uint256 amountForLeverage = positionManager.maxRemainingLeverageOf(
            user1, address(borrowableCUSDC_monad)
        ) / 2;

        NativeVaultPositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCUSDC_monad));
        leverageAction.borrowAssets = amountForLeverage;
        leverageAction.cToken = ICToken(address(simpleCSHMON));
        
        leverageAction.swapAction.inputToken = _USDC_ADDRESS_MONAD;
        leverageAction.swapAction.inputAmount = amountForLeverage;
        leverageAction.swapAction.outputToken = _USDC_ADDRESS_MONAD;
        leverageAction.swapAction.target = _UNISWAP_V3_SWAP_ROUTER;
        leverageAction.swapAction.call = "";
        leverageAction.swapAction.slippage = 0.5e18;

        vm.expectRevert(BasePositionManager.BasePositionManager__InvalidParam.selector);
        positionManager.leverage(leverageAction, 0.5e18);
        vm.stopPrank();
    }

    function test_Leverage_fail_whenInvalidSwapTargetZero() public {
        _setUpSHMON_USDC_Market();

        deal(SHMON_ADDRESS, user1, 500e18);

        vm.startPrank(user1);
        IERC20(SHMON_ADDRESS).approve(address(simpleCSHMON), type(uint256).max);
        simpleCSHMON.deposit(500e18, user1);
        simpleCSHMON.postCollateral(500e18);

        borrowableCUSDC_monad.borrow(50e6, user1);

        uint256 amountForLeverage = positionManager.maxRemainingLeverageOf(
            user1, address(borrowableCUSDC_monad)
        ) / 2;

        NativeVaultPositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCUSDC_monad));
        leverageAction.borrowAssets = amountForLeverage;
        leverageAction.cToken = ICToken(address(simpleCSHMON));
        
        leverageAction.swapAction.inputToken = _USDC_ADDRESS_MONAD;
        leverageAction.swapAction.inputAmount = amountForLeverage;
        leverageAction.swapAction.outputToken = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
        leverageAction.swapAction.target = address(0);
        leverageAction.swapAction.call = "skibidi";
        leverageAction.swapAction.slippage = 0.5e18;

        vm.expectRevert(BasePositionManager.BasePositionManager__InvalidParam.selector);
        positionManager.leverage(leverageAction, 0.5e18);
        vm.stopPrank();
    }

    function test_Leverage_fail_whenInvalidOutputToken() public {
        _setUpSHMON_USDC_Market();

        deal(SHMON_ADDRESS, user1, 500e18);

        vm.startPrank(user1);
        IERC20(SHMON_ADDRESS).approve(address(simpleCSHMON), type(uint256).max);
        simpleCSHMON.deposit(500e18, user1);
        simpleCSHMON.postCollateral(500e18);

        borrowableCUSDC_monad.borrow(50e6, user1);

        uint256 amountForLeverage = positionManager.maxRemainingLeverageOf(
            user1, address(borrowableCUSDC_monad)
        ) / 2;

        NativeVaultPositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCUSDC_monad));
        leverageAction.borrowAssets = amountForLeverage;
        leverageAction.cToken = ICToken(address(simpleCSHMON));
        
        leverageAction.swapAction.inputToken = _USDC_ADDRESS_MONAD;
        leverageAction.swapAction.inputAmount = amountForLeverage;
        leverageAction.swapAction.outputToken = WMON_ADDRESS;
        leverageAction.swapAction.target = _UNISWAP_V3_SWAP_ROUTER;
        leverageAction.swapAction.call = "skibidi";
        leverageAction.swapAction.slippage = 0.5e18;

        vm.expectRevert(BasePositionManager.BasePositionManager__InvalidParam.selector);
        positionManager.leverage(leverageAction, 0.5e18);
        vm.stopPrank();
    }

    function test_Leverage_fail_whenInvalidInputAmount() public {
        _setUpSHMON_USDC_Market();

        deal(SHMON_ADDRESS, user1, 500e18);

        vm.startPrank(user1);
        IERC20(SHMON_ADDRESS).approve(address(simpleCSHMON), type(uint256).max);
        simpleCSHMON.deposit(500e18, user1);
        simpleCSHMON.postCollateral(500e18);

        borrowableCUSDC_monad.borrow(50e6, user1);

        uint256 amountForLeverage = positionManager.maxRemainingLeverageOf(
            user1, address(borrowableCUSDC_monad)
        ) / 2;

        NativeVaultPositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCUSDC_monad));
        leverageAction.borrowAssets = amountForLeverage;
        leverageAction.cToken = ICToken(address(simpleCSHMON));
        
        leverageAction.swapAction.inputToken = _USDC_ADDRESS_MONAD;
        leverageAction.swapAction.inputAmount = amountForLeverage - 1;
        leverageAction.swapAction.outputToken = WMON_ADDRESS;
        leverageAction.swapAction.target = _UNISWAP_V3_SWAP_ROUTER;
        leverageAction.swapAction.call = "skibidi";
        leverageAction.swapAction.slippage = 0.5e18;

        vm.expectRevert(BasePositionManager.BasePositionManager__InvalidParam.selector);
        positionManager.leverage(leverageAction, 0.5e18);
        vm.stopPrank();
    }

    /// Market setup helpers ///

    function _setUpSHMON_WMON_Market() internal {
        _fork("ETH_NODE_URI_MONAD");

        _deployCentralRegistry();
        _deployCVE();
        _deployRewardManager();
        _deployVeCVE();
        _deployGaugeManager();
        _deployMarketManager();
        _deployOracleManager();

        // Native vault position manager
        positionManager = new NativeVaultPositionManager(
            ICentralRegistry(address(centralRegistry)),
            address(marketManagerIsolated),
            WMON_ADDRESS
        );
        marketManagerIsolated.addPositionManager(address(positionManager));

        // deploy simpleCSHMON
        simpleCSHMON = new SimpleCToken(
            ICentralRegistry(address(centralRegistry)),
            IERC20(SHMON_ADDRESS),
            address(marketManagerIsolated)
        );

        ChainlinkAdaptor adaptor = new ChainlinkAdaptor(ICentralRegistry(address(centralRegistry)));
        oracleManager.addApprovedAdaptor(address(adaptor));

        adaptor.addAsset(SHMON_ADDRESS, true, _CHAINLINK_ETH_USD_MONAD, 0);
        oracleManager.addAssetPriceFeed(SHMON_ADDRESS, address(adaptor));
        oracleManager.addCTokenSupport(address(simpleCSHMON));

        adaptor.addAsset(WMON_ADDRESS, true, _CHAINLINK_ETH_USD_MONAD, 0);
        oracleManager.addAssetPriceFeed(WMON_ADDRESS, address(adaptor));

        borrowableCWMON = _deployBorrowableCToken(WMON_ADDRESS);
        oracleManager.addCTokenSupport(address(borrowableCWMON));

        deal(SHMON_ADDRESS, address(this), 77777 ether);
        IERC20(SHMON_ADDRESS).approve(address(simpleCSHMON), 77777 ether);
        deal(WMON_ADDRESS, address(this), 77777 ether);
        IERC20(WMON_ADDRESS).approve(address(borrowableCWMON), 77777 ether);

        marketManagerIsolated.listTokens(address(simpleCSHMON), address(borrowableCWMON));

        _setCTokenConfigBasic(address(simpleCSHMON), 1_000_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCWMON), 1_000_000e18, 1_000_000e18);

        // Provide WMON liquidity
        address liquidityProvider = makeAddr("liquidityProvider");
        deal(WMON_ADDRESS, liquidityProvider, 1_000_000 ether);
        vm.startPrank(liquidityProvider);
        IERC20(WMON_ADDRESS).approve(address(borrowableCWMON), type(uint256).max);
        borrowableCWMON.deposit(1_000_000 ether, liquidityProvider);
        vm.stopPrank();
    }

    function _setUpUSDC_DAIPool_Eth() internal {

        super.setUp();

        centralRegistry.setExternalCalldataChecker(
            _UNISWAP_V3_SWAP_ROUTER,
            address(new MockCalldataChecker(_UNISWAP_V3_SWAP_ROUTER))
        );

        _prepareUSDC(address(this), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);

        deal(_DAI_ADDRESS, address(this), 77777);
        IERC20(_DAI_ADDRESS).approve(address(borrowableCDAI), 77777);

        marketManagerIsolated.listTokens(address(borrowableCUSDC), address(borrowableCDAI));

        _setCTokenConfigBasic(address(borrowableCUSDC), 1_000_000e6, 1_000_000e6);
        _setCTokenConfigBasic(address(borrowableCDAI), 1_000_000e18, 1_000_000e18);

        positionManager = new NativeVaultPositionManager(
            ICentralRegistry(address(centralRegistry)),
            address(marketManagerIsolated),
            _WETH_ADDRESS
        );

        marketManagerIsolated.addPositionManager(address(positionManager));

        // Provide liquidity
        address liquidityProvider = makeAddr("liquidityProvider");
        deal(address(dai), liquidityProvider, 1_000_000e18);
        vm.startPrank(liquidityProvider);
        dai.approve(address(borrowableCDAI), type(uint256).max);
        borrowableCDAI.deposit(1_000_000e18, liquidityProvider);
        vm.stopPrank();
    }

    function _setUpSHMON_USDC_Market() internal {
        _fork("ETH_NODE_URI_MONAD");

        _deployCentralRegistry();
        _deployCVE();
        _deployRewardManager();
        _deployVeCVE();
        _deployGaugeManager();
        _deployMarketManager();
        _deployOracleManager();

        // Native vault position manager
        positionManager = new NativeVaultPositionManager(
            ICentralRegistry(address(centralRegistry)),
            address(marketManagerIsolated),
            WMON_ADDRESS
        );
        marketManagerIsolated.addPositionManager(address(positionManager));

        // deploy simpleCSHMON
        simpleCSHMON = new SimpleCToken(
            ICentralRegistry(address(centralRegistry)),
            IERC20(SHMON_ADDRESS),
            address(marketManagerIsolated)
        );

        ChainlinkAdaptor adaptor = new ChainlinkAdaptor(ICentralRegistry(address(centralRegistry)));
        oracleManager.addApprovedAdaptor(address(adaptor));

        adaptor.addAsset(SHMON_ADDRESS, true, _CHAINLINK_ETH_USD_MONAD, 0);
        oracleManager.addAssetPriceFeed(SHMON_ADDRESS, address(adaptor));
        oracleManager.addCTokenSupport(address(simpleCSHMON));

        adaptor.addAsset(_USDC_ADDRESS_MONAD, true, _CHAINLINK_USDC_USD_MONAD, 0);
        oracleManager.addAssetPriceFeed(_USDC_ADDRESS_MONAD, address(adaptor));

        borrowableCUSDC_monad = _deployBorrowableCToken(_USDC_ADDRESS_MONAD);
        oracleManager.addCTokenSupport(address(borrowableCUSDC_monad));

        deal(SHMON_ADDRESS, address(this), 77777 ether);
        IERC20(SHMON_ADDRESS).approve(address(simpleCSHMON), 77777 ether);
        deal(_USDC_ADDRESS_MONAD, address(this), 77777 ether);
        IERC20(_USDC_ADDRESS_MONAD).approve(address(borrowableCUSDC_monad), 77777 ether);

        marketManagerIsolated.listTokens(address(simpleCSHMON), address(borrowableCUSDC_monad));

        _setCTokenConfigBasic(address(simpleCSHMON), 1_000_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC_monad), 1_000_000e6, 1_000_000e6);

        // Provide WMON liquidity
        address liquidityProvider = makeAddr("liquidityProvider");
        deal(_USDC_ADDRESS_MONAD, liquidityProvider, 1_000_000 ether);
        vm.startPrank(liquidityProvider);
        IERC20(_USDC_ADDRESS_MONAD).approve(address(borrowableCUSDC_monad), type(uint256).max);
        borrowableCUSDC_monad.deposit(1_000_000 ether, liquidityProvider);
        vm.stopPrank();
    }


}
