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
    uint256 constant FORK_BLOCK = 67913438;

    address public constant KYBER_SWAP_ROUTER = 0x6131B5fae19EA4f9D964eAc0408E4408b66337b5;
    address public constant KYBER_SWAP_EXECUTOR = 0x63242A4Ea82847b20E506b63B0e2e2eFF0CC6cB0;
    address public constant KURU_ROUTER = 0xb3e6778480b2E488385E8205eA05E20060B813cb;
    address public constant WMON_ADDRESS = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;

    SimplePositionManager internal positionManager;
    KyberSwapChecker internal kyberSwapChecker;
    KuruCalldataChecker internal kuruSwapChecker;

    BorrowableCToken internal borrowableCWMON;

    function setUp() public override {

        _fork("MON_NODE_URI_MONAD_ARCHIVE", FORK_BLOCK);

        _initMainConstantVariables();
        _deployCentralRegistry();
        _deployCVE();
        _deployRewardManager();
        _deployVeCVE();
        _deployGaugeManager();
        _deployMarketManager();
        _deployOracleManager();

        address[] memory kyberSwapExecutors = new address[](1);
        kyberSwapExecutors[0] = KYBER_SWAP_EXECUTOR;
        kyberSwapChecker = new KyberSwapChecker(KYBER_SWAP_ROUTER, kyberSwapExecutors, address(centralRegistry));
        centralRegistry.setExternalCalldataChecker(KYBER_SWAP_ROUTER, address(kyberSwapChecker));
        kuruSwapChecker = new KuruCalldataChecker(
            KURU_ROUTER,
            address(KURU_ROUTER),
            address(centralRegistry.daoAddress())
        );
        centralRegistry.setExternalCalldataChecker(KURU_ROUTER, address(kuruSwapChecker));

        borrowableCUSDC = _deployBorrowableCUSDC();
        borrowableCWMON = _deployBorrowableCToken(WMON_ADDRESS);

        MockV3Aggregator chainlinkUSDC_MONAD = new MockV3Aggregator(8, 2e8);

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

        uint256 borrowAmount = 100e6;

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

        leverageAction.swapAction.call = _usdcToWmonCalldata();

        vm.startPrank(user1);

        // Only match error selector
        // use expectPartialRevert for custom errors with args
        // (https://getfoundry.sh/reference/cheatcodes/expect-revert/#:~:text=Custom,with)
        vm.expectPartialRevert(SwapperLib.SwapperLib__Slippage.selector);
        positionManager.leverage(leverageAction, 0.5e18);

        vm.stopPrank();
    }

    // ================================================================
    // Pre-fetched swap calldata (KyberSwap API, block ~67913438)
    // feeAmount=4, isInBps=true, chargeFeeBy=currency_in, feeReceiver=DAO
    // ================================================================

    function _usdcToWmonCalldata() internal pure returns (bytes memory) {
        return hex"e21fd0e9000000000000000000000000000000000000000000000000000000000000002000000000000000000000000063242a4ea82847b20e506b63b0e2e2eff0cc6cb0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000880000000000000000000000000000000000000000000000000000000000000054000000000000000000000000005f544c000000000000000000000000005f544c0000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000e000000000000000000000000000000000000000000000000000000000000000410f29242b74c5de8447188c8b8f0c1507856a3833ad8fa05eae4ff2dd4db4b3f0510dbdc5aff8bebc7df3bbacb4d4964af18d0c58daf694500e726b773eb6b4a01b000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000440000000000000000000000000db25a7b768311de128bbda7b8426c3f9c74f3240000000000000000000000000000000000000000000000000000000000000014000000000000000000000000000000000000000000000000000000000000001a000000000000000000000000005a901500000000000000000000000000641883000000000000000000000000005f544c0000000000000009ccc655a09df080000000000000000000000000000000000000a46a417a938ce0000000f42400000000000000000000000000000004f82e73edb06d29ff62c91ec8f5ff06571bdeb2900000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000069dd50c40000000000000000000000000000000000000000000000000000000000000420000000000000000000000000000000000000000000000000000000000000000261f598cd000000000000000029443467522688c0d201d27e37a32f56c83d107b2164c94f000000000000000029443467522688c0d201d27e37a32f56c83d107b0000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000001e0000000000000000000000000754704bc059f8c67012fed69bc8a327a5aafb6038000000000000000000000000000006300000000000000000000000005f544c00000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000005f544c0a357fd2d0000000000000001fe25d210dfe5cdff81917aa7067bac446ecac27c000000000000000000000000000000000000000000000000000000000000008000000000000000000000000063242a4ea82847b20e506b63b0e2e2eff0cc6cb00000000000000000000000000000000000000000000000000000000000000060000000000000000000000000fa32f9ec28787d1f9c5ba5c39e54e59984fef3f000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000148b2e2fe293329a6dbf4dc0b100000000000000000000000003bd359c1119da7da1d913d1c4d2b7c461115433a8000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000754704bc059f8c67012fed69bc8a327a5aafb6030000000000000000000000003bd359c1119da7da1d913d1c4d2b7c461115433a000000000000000000000000000000000000000000000000000000000000016000000000000000000000000000000000000000000000000000000000000001a000000000000000000000000000000000000000000000000000000000000001e00000000000000000000000000000000000000000000000000000000000000220000000000000000000000000db25a7b768311de128bbda7b8426c3f9c74f32400000000000000000000000000000000000000000000000000000000005f5e100000000000000000000000000000000000000000000000099a99686515a92147a00000000000000000000000000000000000000000000000000000000000002800000000000000000000000000000000000000000000000000000000000000260000000000000000000000000000000000000000000000000000000000000000100000000000000000000000063242a4ea82847b20e506b63b0e2e2eff0cc6cb000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000005f544c000000000000000000000000000000000000000000000000000000000000000010000000000000000000000007fa9385be102ac3eac297483dd6233d62b3e149600000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000be7b22536f75726365223a2243757276616e636550726f746f636f6c222c22416d6f756e74496e555344223a223130302e393036363338222c22416d6f756e744f7574555344223a223130302e393138303937222c22416d6f756e744f7574223a2232383932343230333532363533353138313736323536222c22526f7574654944223a2263343939616435316463354c686241563a32383961393164663977644550627348222c2254696d657374616d70223a313737363131303631327d0000";
    }
}
