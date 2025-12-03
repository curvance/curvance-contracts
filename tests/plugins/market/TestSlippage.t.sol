// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { SimplePositionManager } from "contracts/market/position-management/SimplePositionManager.sol";
import { KyberSwapChecker } from "contracts/calldata-checker/swap-checker/KyberSwapChecker.sol";
import { KuruCalldataChecker } from "contracts/calldata-checker/swap-checker/KuruCalldataChecker.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { ICToken } from "contracts/interfaces/ICToken.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";
import { ProtocolReader } from "contracts/views/ProtocolReader.sol";

contract TestSlippage is TestBaseMarketIsolated {

    address public constant KYBER_SWAP_ROUTER = 0x6131B5fae19EA4f9D964eAc0408E4408b66337b5;
    address public constant KYBER_SWAP_EXECUTOR = 0x63242A4Ea82847b20E506b63B0e2e2eFF0CC6cB0;
    address public constant KURU_ROUTER = 0xb3e6778480b2E488385E8205eA05E20060B813cb;
    address public constant WMON_ADDRESS = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;

    SimplePositionManager internal positionManager;
    KyberSwapChecker internal kyberSwapChecker;
    KuruCalldataChecker internal kuruSwapChecker;

    BorrowableCToken internal borrowableCWMON;

    function setUp() public override {

        _fork("MON_NODE_URI_MONAD_MAINNET");

        _initMainConstantVariables();
        _deployCentralRegistry();
        _deployCVE();
        _deployRewardManager();
        _deployVeCVE();
        _deployGaugeManager();
        _deployMarketManager();
        _deployOracleManager();

        kyberSwapChecker = new KyberSwapChecker(KYBER_SWAP_ROUTER, KYBER_SWAP_EXECUTOR);
        centralRegistry.setExternalCalldataChecker(KYBER_SWAP_ROUTER, address(kyberSwapChecker));
        kuruSwapChecker = new KuruCalldataChecker(
            KURU_ROUTER,
            address(KURU_ROUTER), // fee collector
            address(centralRegistry.daoAddress())
        );
        centralRegistry.setExternalCalldataChecker(KURU_ROUTER, address(kuruSwapChecker));

        borrowableCUSDC = _deployBorrowableCUSDC();
        borrowableCWMON = _deployBorrowableCToken(WMON_ADDRESS);

        MockV3Aggregator chainlinkUSDC_MONAD = new MockV3Aggregator(8, 1e8);

        ChainlinkAdaptor adaptor = new ChainlinkAdaptor(ICentralRegistry(address(centralRegistry)));
        oracleManager.addApprovedAdaptor(address(adaptor));
        adaptor.addAsset(_USDC_ADDRESS, true, address(chainlinkUSDC_MONAD), 0);
        adaptor.addAsset(WMON_ADDRESS, true, 0x9a7FAe39f78f7711d46F28E9fd2271ECdca58f9a, 0);
        oracleManager.addAssetPricingAdaptor(_USDC_ADDRESS, address(adaptor), 100, 50, 100, 50);
        oracleManager.addAssetPricingAdaptor(WMON_ADDRESS, address(adaptor), 100, 50, 100, 50);
        oracleManager.addCTokenSupport(address(borrowableCUSDC));
        oracleManager.addCTokenSupport(address(borrowableCWMON));

        deal(_USDC_ADDRESS, address(this), 77777 + 1_000_000e6);
        IERC20(_USDC_ADDRESS).approve(address(borrowableCUSDC), 77777);
        deal(WMON_ADDRESS, address(this), 77777 + 1_000_000e18);
        IERC20(WMON_ADDRESS).approve(address(borrowableCWMON), 77777);

        marketManagerIsolated.listTokens(address(borrowableCWMON), address(borrowableCUSDC));
        _setCTokenConfigBasic(address(borrowableCWMON), 1_000_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 0, 1_000_000e6);

        // deposit directly to the contract to avoid extra deal and reduce rpc calls
        IERC20(_USDC_ADDRESS).approve(address(borrowableCUSDC), type(uint256).max);
        borrowableCUSDC.deposit(1_000_000e6, address(this));
        IERC20(WMON_ADDRESS).approve(address(borrowableCWMON), type(uint256).max);
        borrowableCWMON.deposit(1_000_000e18, address(this));

        positionManager = new SimplePositionManager(ICentralRegistry(address(centralRegistry)), address(marketManagerIsolated), WMON_ADDRESS);
        marketManagerIsolated.addPositionManager(address(positionManager));
        protocolReader = new ProtocolReader(ICentralRegistry(address(centralRegistry)));
    }

    function test_slippage_fail_whenExcessiveSlippage() public {
        
        uint256 wmonToDeposit = 10000e18;
        deal(WMON_ADDRESS, user1, wmonToDeposit);
        vm.startPrank(user1);
        IERC20(WMON_ADDRESS).approve(address(borrowableCWMON), wmonToDeposit);
        borrowableCWMON.depositAsCollateral(wmonToDeposit, user1);
        vm.stopPrank();

        // Attempt leverage with very tight slippage tolerance
        (,,, uint256 maxDebtBorrowable,,) = protocolReader.hypotheticalLeverageOf(
            user1, address(borrowableCWMON), address(borrowableCUSDC), 0, 0
        );
        uint256 borrowAmount = (maxDebtBorrowable * 50) / 100;

        SimplePositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCUSDC));
        leverageAction.borrowAssets = borrowAmount;
        leverageAction.cToken = ICToken(address(borrowableCWMON));
        leverageAction.swapAction.inputToken = _USDC_ADDRESS;
        leverageAction.swapAction.inputAmount = borrowAmount;
        leverageAction.swapAction.outputToken = WMON_ADDRESS;
        leverageAction.swapAction.target = KYBER_SWAP_ROUTER;
        // Force extremely tight slippage to guarantee revert
        leverageAction.swapAction.slippage = 1e10; // 0.00001% allowed
        leverageAction.swapAction.call = _getKyberCalldata(
            block.chainid,
            _USDC_ADDRESS,
            WMON_ADDRESS,
            borrowAmount,
            address(positionManager),
            500
        );

        vm.startPrank(user1);
        // Only match error selector
        // use expectPartialRevert for custom errors with args
        // (https://getfoundry.sh/reference/cheatcodes/expect-revert/#:~:text=Custom,with)
        vm.expectPartialRevert(SwapperLib.SwapperLib__Slippage.selector);
        try positionManager.leverage(leverageAction, 0.5e18) {
        } catch {
            leverageAction.swapAction.target = KURU_ROUTER;
            leverageAction.swapAction.call = _getKuruCalldata(
                address(positionManager),
                _USDC_ADDRESS,
                WMON_ADDRESS,
                borrowAmount
            );
            positionManager.leverage(leverageAction, 0.5e18);
        }
        vm.stopPrank();
    }
}


