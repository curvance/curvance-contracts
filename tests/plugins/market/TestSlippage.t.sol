// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { SimpleZapper } from "contracts/plugins/market/SimpleZapper.sol";
import { SimplePositionManager } from "contracts/market/position-management/SimplePositionManager.sol";
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

    address public constant KURU_ROUTER = 0x96eaC98928437496DdD0Cd2080E54Fe78BaC99b6;
    address public constant WMON_ADDRESS = 0x760AfE86e5de5fa0Ee542fc7B7B713e1c5425701;
    address public constant USDC_ADDRESS = 0xf817257fed379853cDe0fa4F97AB987181B1E5Ea;

    address public constant KURU_FEE_COLLECTOR = 0xe661C9435ad0365E9274df9C1D142fbA004E5Ad1;

    SimpleZapper internal simpleZapper;
    SimplePositionManager internal positionManager;
    KuruCalldataChecker internal kuruChecker;

    BorrowableCToken internal borrowableCWMON;

    function setUp() public override {

        _fork("ETH_NODE_URI_MONAD");

        _initMainConstantVariables();
        _deployCentralRegistry();
        _deployCVE();
        _deployRewardManager();
        _deployVeCVE();
        _deployGaugeManager();
        _deployMarketManager();
        _deployOracleManager();

        kuruChecker = new KuruCalldataChecker(KURU_ROUTER, KURU_FEE_COLLECTOR, address(centralRegistry.daoAddress()));
        centralRegistry.setExternalCalldataChecker(KURU_ROUTER, address(kuruChecker));

        borrowableCUSDC = _deployBorrowableCUSDC();
        borrowableCWMON = _deployBorrowableCToken(WMON_ADDRESS);

        MockV3Aggregator chainlinkUSDC_WMON = new MockV3Aggregator(18, 1e18);
        MockV3Aggregator chainlinkWMON = new MockV3Aggregator(18, 3.25e18);

        ChainlinkAdaptor adaptor = new ChainlinkAdaptor(ICentralRegistry(address(centralRegistry)));
        oracleManager.addApprovedAdaptor(address(adaptor));
        adaptor.addAsset(USDC_ADDRESS, true, address(chainlinkUSDC_WMON), 0);
        adaptor.addAsset(WMON_ADDRESS, true, address(chainlinkWMON), 0);
        oracleManager.addAssetPricingAdaptor(USDC_ADDRESS, address(adaptor), 100, 50, 100, 50);
        oracleManager.addAssetPricingAdaptor(WMON_ADDRESS, address(adaptor), 100, 50, 100, 50);
        oracleManager.addCTokenSupport(address(borrowableCUSDC));
        oracleManager.addCTokenSupport(address(borrowableCWMON));

        deal(USDC_ADDRESS, address(this), 77777 + 1_000_000e6);
        IERC20(USDC_ADDRESS).approve(address(borrowableCUSDC), 77777);
        deal(WMON_ADDRESS, address(this), 77777 + 1_000_000e18);
        IERC20(WMON_ADDRESS).approve(address(borrowableCWMON), 77777);

        marketManagerIsolated.listTokens(address(borrowableCWMON), address(borrowableCUSDC));
        _setCTokenConfigBasic(address(borrowableCWMON), 1_000_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 0, 1_000_000e6);

        // deposit directly to the contract to avoid extra deal and reduce rpc calls
        IERC20(USDC_ADDRESS).approve(address(borrowableCUSDC), type(uint256).max);
        borrowableCUSDC.deposit(1_000_000e6, address(this));
        IERC20(WMON_ADDRESS).approve(address(borrowableCWMON), type(uint256).max);
        borrowableCWMON.deposit(1_000_000e18, address(this));

        simpleZapper = new SimpleZapper(ICentralRegistry(address(centralRegistry)), WMON_ADDRESS);
        positionManager = new SimplePositionManager(ICentralRegistry(address(centralRegistry)), address(marketManagerIsolated), WMON_ADDRESS);
        marketManagerIsolated.addPositionManager(address(positionManager));
        protocolReader = new ProtocolReader(ICentralRegistry(address(centralRegistry)));
    }

    function test_slippage_fail_whenExcessiveSlippage() public {
        
        uint256 wmonToDeposit = 50_000e18;
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
        if (borrowAmount == 0) {
            borrowAmount = 10_000e6;
        }
        // Cap borrow amount to avoid aggregator mid-swap failures
        if (borrowAmount > 1_000e6) {
            borrowAmount = 1_000e6;
        }

        SimplePositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCUSDC));
        leverageAction.borrowAssets = borrowAmount;
        leverageAction.cToken = ICToken(address(borrowableCWMON));
        leverageAction.swapAction.inputToken = USDC_ADDRESS;
        leverageAction.swapAction.inputAmount = borrowAmount;
        leverageAction.swapAction.outputToken = WMON_ADDRESS;
        leverageAction.swapAction.target = KURU_ROUTER;
        // Force extremely tight slippage to guarantee revert
        leverageAction.swapAction.slippage = 1e14; // 0.01% allowed
        leverageAction.swapAction.call = _getKuruCalldata(
            address(positionManager),
            USDC_ADDRESS,
            WMON_ADDRESS,
            borrowAmount
        );

        vm.startPrank(user1);
        // Expect excess slippage revert
        // match selector only
        vm.expectRevert(bytes4(keccak256("SwapperLib__Slippage(uint256)")));
        positionManager.leverage(leverageAction, 0.5e18);
        vm.stopPrank();
    }
}


