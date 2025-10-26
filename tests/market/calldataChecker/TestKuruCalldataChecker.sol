// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { KuruCalldataChecker } from "contracts/calldata-checker/swap-checker/KuruCalldataChecker.sol";
import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { BaseSwapChecker } from "contracts/calldata-checker/swap-checker/BaseSwapChecker.sol";
import { SimpleZapper } from "contracts/plugins/market/SimpleZapper.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { console2 } from "forge-std/console2.sol";

// simpleZapper address: 0x15cF58144EF33af1e14b5208015d11F9143E27b9;

contract TestKuruCalldataChecker is TestBaseMarketIsolated {
    address public kuruRouter = 0x1B61Fab9544FF34735B2d7A0f7ff3544D8aa6536;
    address public constant WMON_ADDRESS = 0x760AfE86e5de5fa0Ee542fc7B7B713e1c5425701;
    address public constant USDC_ADDRESS = 0xf817257fed379853cDe0fa4F97AB987181B1E5Ea;

    BorrowableCToken public borrowableCUSDC_MONAD;
    BorrowableCToken public borrowableCWMON;

    KuruCalldataChecker public checker;

    SwapperLib.Swap public swapAction;
    address public recipient;

    SimpleZapper public simpleZapper;

    bytes public callData = hex"ce1e7030000000000000000000000000760afe86e5de5fa0ee542fc7b7b713e1c542570100000000000000000000000000000000000000000000000014b292ba662a6b6d000000000000000000000000f817257fed379853cde0fa4f97ab987181b1e5ea00000000000000000000000000000000000000000000000000000000004c4b40000000000000000000000000c45f0add4981076928537490f8c0e24944288947000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000f39fd6e51aad88f6f4ce6ab8827279cfffb92266000000000000000000000000000000000000000000000000000000000000006400000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000140000000000000000000000000000000000000000000000000000000000000004e02f817257fed379853cde0fa4f97ab987181b1e5ea01ffff04cd5455b24f3622a1cfece944615ae5bc8f36ee18010000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000";

    receive() external payable {}

    fallback() external payable {}

    function setUp() public override {
        // _fork("ETH_NODE_URI_MONAD", 41450292);

        uint256 forkId = vm.createSelectFork("https://monad-testnet.drpc.org", 41450292);

        _initMainConstantVariables();

        _deployCentralRegistry();
        _deployCVE();
        _deployRewardManager();
        _deployVeCVE();
        _deployGaugeManager();
        _deployMarketManager();
        _deployOracleManager();

        checker = new KuruCalldataChecker(kuruRouter);
        centralRegistry.setExternalCalldataChecker(kuruRouter, address(checker));

        simpleZapper = new SimpleZapper(ICentralRegistry(address(centralRegistry)), WMON_ADDRESS);

        console2.log("simpleZapper address", address(simpleZapper));

        borrowableCUSDC_MONAD = _deployBorrowableCToken(USDC_ADDRESS);
        borrowableCWMON = _deployBorrowableCToken(WMON_ADDRESS);

        MockV3Aggregator chainlinkUSDC_WMON = new MockV3Aggregator(18, 1e18);
        MockV3Aggregator chainlinkWMON = new MockV3Aggregator(18, 3.04e18);

        ChainlinkAdaptor chainlinkAdaptor = new ChainlinkAdaptor(ICentralRegistry(address(centralRegistry)));

        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));

        chainlinkAdaptor.addAsset(
            USDC_ADDRESS,
            true,
            address(chainlinkUSDC_WMON),
            0,
            100
        );
        chainlinkAdaptor.addAsset(
            WMON_ADDRESS,
            true,
            address(chainlinkWMON),
            0,
            100
        );
        
        oracleManager.addAssetPricingAdaptor(
            USDC_ADDRESS,
            address(chainlinkAdaptor),
            100,
            50
        );
        oracleManager.addAssetPricingAdaptor(
            WMON_ADDRESS,
            address(chainlinkAdaptor),
            100,
            50
        );

        oracleManager.addCTokenSupport(address(borrowableCUSDC_MONAD));
        oracleManager.addCTokenSupport(address(borrowableCWMON));

        deal(USDC_ADDRESS, address(this), 77777);
        IERC20(USDC_ADDRESS).approve(address(borrowableCUSDC_MONAD), type(uint256).max);

        deal(WMON_ADDRESS, address(this), 77777);
        IERC20(WMON_ADDRESS).approve(address(borrowableCWMON), type(uint256).max);

        marketManagerIsolated.listTokens(address(borrowableCUSDC_MONAD), address(borrowableCWMON));

        _setCTokenConfigBasic(address(borrowableCUSDC_MONAD), 1_000_000e6, 1_000_000e6);
        _setCTokenConfigBasic(address(borrowableCWMON), 1_000_000e18, 1_000_000e18);
    }

    function testCheckCalldataRevert__TargetError() public {
        swapAction.target = address(0);

        vm.expectRevert(BaseSwapChecker.CalldataChecker__TargetError.selector);
        checker.checkCalldata(swapAction, recipient);
    }

    function testCheckCalldataRevert__InvalidFuncSig() public {
        recipient = address(this);
        bytes memory invalidCallData = hex"d7ada2f3000000000000000000000000760afe86e5de5fa0ee542fc7b7b713e1c542570100000000000000000000000000000000000000000000000014b292ba662a6b6d000000000000000000000000f817257fed379853cde0fa4f97ab987181b1e5ea00000000000000000000000000000000000000000000000000000000004c4b40000000000000000000000000c45f0add4981076928537490f8c0e24944288947000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000f39fd6e51aad88f6f4ce6ab8827279cfffb92266000000000000000000000000000000000000000000000000000000000000006400000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000140000000000000000000000000000000000000000000000000000000000000004e02f817257fed379853cde0fa4f97ab987181b1e5ea01ffff04cd5455b24f3622a1cfece944615ae5bc8f36ee18010000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000";
        recipient = address(simpleZapper);
        swapAction.inputToken = USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kuruRouter;
        swapAction.call = invalidCallData;

        vm.expectRevert(BaseSwapChecker.CalldataChecker__InvalidFuncSig.selector);
        checker.checkCalldata(swapAction, address(simpleZapper));
    }

    function testSwapUnpackCheckCallDataRevert__InputTokenError() public {
        recipient = address(this);
        swapAction.inputToken = address(0);
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kuruRouter;
        swapAction.call = callData;

        vm.expectRevert(BaseSwapChecker.CalldataChecker__InputTokenError.selector);
        checker.checkCalldata(swapAction, recipient);
    }

    function testSwapUnpackCheckCallDataRevert__InputAmountError() public {
        recipient = address(this);
        swapAction.inputToken = USDC_ADDRESS;
        swapAction.inputAmount = 0;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kuruRouter;
        swapAction.call = callData;

        vm.expectRevert(BaseSwapChecker.CalldataChecker__InputAmountError.selector);
        checker.checkCalldata(swapAction, recipient);
    }

    function testSwapUnpackCheckCallDataRevert__OutputTokenError() public {
        recipient = address(this);
        swapAction.inputToken = USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = address(0);
        swapAction.target = kuruRouter;
        swapAction.call = callData;

        vm.expectRevert(BaseSwapChecker.CalldataChecker__OutputTokenError.selector);
        checker.checkCalldata(swapAction, recipient);
    }

    function testSwapUnpackCheckCallDataSuccess() public {
        recipient = address(this);
        swapAction.inputToken = USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kuruRouter;
        swapAction.call = callData;

        deal(USDC_ADDRESS, address(this), 5e6);
        IERC20(USDC_ADDRESS).approve(address(simpleZapper), 5e6);

        checker.checkCalldata(swapAction, recipient);
    }

    function testSwapWithSimpleZapper() public {
        recipient = address(simpleZapper);
        swapAction.inputToken = USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kuruRouter;
        swapAction.call = callData;

        deal(USDC_ADDRESS, address(this), 5e6);
        IERC20(USDC_ADDRESS).approve(address(simpleZapper), 5e6);

        borrowableCWMON.setDelegateApproval(address(simpleZapper), true);

        simpleZapper.swapAndDeposit(address(borrowableCWMON), true, swapAction, 0, true, address(this));

        assertEq(borrowableCWMON.balanceOf(address(this)), 1523425731895223420);
    }
}