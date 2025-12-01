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
import { IKuruFlowRouter } from "contracts/interfaces/external/kuru/IKuruRouter.sol";

// simpleZapper address: 0x15cF58144EF33af1e14b5208015d11F9143E27b9;

contract TestKuruCalldataChecker is TestBaseMarketIsolated {
    address public kuruRouter = 0xb3e6778480b2E488385E8205eA05E20060B813cb;
    address public constant WMON_ADDRESS = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;

    BorrowableCToken public borrowableCUSDC_MONAD;
    BorrowableCToken public borrowableCWMON;

    KuruCalldataChecker public checker;

    address public feeCollectorAddress = 0x62eE1b8D1EFdF8f73c78dB87b888406b194e266a;

    SwapperLib.Swap public swapAction;
    address public recipient;

    SimpleZapper public simpleZapper;

    receive() external payable {}

    fallback() external payable {}

    function setUp() public override {
		_fork("NODE_URI_MONAD_MAINNET");

        _initMainConstantVariables();

        _deployCentralRegistry();
        _deployCVE();
        _deployRewardManager();
        _deployVeCVE();
        _deployGaugeManager();
        _deployMarketManager();
        _deployOracleManager();

        checker = new KuruCalldataChecker(kuruRouter, feeCollectorAddress, address(centralRegistry.daoAddress()));
        centralRegistry.setExternalCalldataChecker(kuruRouter, address(checker));

        simpleZapper = new SimpleZapper(ICentralRegistry(address(centralRegistry)), WMON_ADDRESS);

        console2.log("simpleZapper address", address(simpleZapper));

        borrowableCUSDC_MONAD = _deployBorrowableCToken(_USDC_ADDRESS);
        borrowableCWMON = _deployBorrowableCToken(WMON_ADDRESS);

        MockV3Aggregator chainlinkUSDC_WMON = new MockV3Aggregator(18, 1e18);
        MockV3Aggregator chainlinkWMON = new MockV3Aggregator(18, 3.04e18);

        ChainlinkAdaptor chainlinkAdaptor = new ChainlinkAdaptor(ICentralRegistry(address(centralRegistry)));

        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));

        chainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            true,
            address(chainlinkUSDC_WMON),
            0
        );
        chainlinkAdaptor.addAsset(
            WMON_ADDRESS,
            true,
            address(chainlinkWMON),
            0
        );
        
        oracleManager.addAssetPricingAdaptor(
            _USDC_ADDRESS,
            address(chainlinkAdaptor),
            100,
            50,
            100,
            50
        );
        oracleManager.addAssetPricingAdaptor(
            WMON_ADDRESS,
            address(chainlinkAdaptor),
            100,
            50,
            100,
            50
        );

        oracleManager.addCTokenSupport(address(borrowableCUSDC_MONAD));
        oracleManager.addCTokenSupport(address(borrowableCWMON));

        deal(_USDC_ADDRESS, address(this), 77777);
        IERC20(_USDC_ADDRESS).approve(address(borrowableCUSDC_MONAD), type(uint256).max);

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
        swapAction.inputToken = _USDC_ADDRESS;
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
		swapAction.call = _getKuruCalldata(
			recipient,
			_USDC_ADDRESS,
			WMON_ADDRESS,
			5e6
		);

        vm.expectRevert(BaseSwapChecker.CalldataChecker__InputTokenError.selector);
        checker.checkCalldata(swapAction, recipient);
    }

    function testSwapUnpackCheckCallDataRevert__InputAmountError() public {
        recipient = address(this);
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 0;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kuruRouter;
		swapAction.call = _getKuruCalldata(
			recipient,
			_USDC_ADDRESS,
			WMON_ADDRESS,
			5e6
		);

        vm.expectRevert(BaseSwapChecker.CalldataChecker__InputAmountError.selector);
        checker.checkCalldata(swapAction, recipient);
    }

    function testSwapUnpackCheckCallDataRevert__OutputTokenError() public {
        recipient = address(this);
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = address(0);
        swapAction.target = kuruRouter;
		swapAction.call = _getKuruCalldata(
			recipient,
			_USDC_ADDRESS,
			WMON_ADDRESS,
			5e6
		);

        vm.expectRevert(BaseSwapChecker.CalldataChecker__OutputTokenError.selector);
        checker.checkCalldata(swapAction, recipient);
    }

    function testSwapUnpackCheckCallDataSuccess() public {
        recipient = address(this);
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kuruRouter;
		swapAction.call = _getKuruCalldata(address(this), _USDC_ADDRESS, WMON_ADDRESS, 5e6);

        console2.log("dao address", centralRegistry.daoAddress());
        console2.log("this address", address(this));

        deal(_USDC_ADDRESS, address(this), 5e6);
        IERC20(_USDC_ADDRESS).approve(address(simpleZapper), 5e6);

        checker.checkCalldata(swapAction, recipient);
    }

    function testSwapWithSimpleZapper() public {
        recipient = address(simpleZapper);
        swapAction.inputToken = _USDC_ADDRESS;
        swapAction.inputAmount = 5e6;
        swapAction.outputToken = WMON_ADDRESS;
        swapAction.target = kuruRouter;
        bytes memory ffiCalldata = _getKuruCalldata(
            recipient,
            _USDC_ADDRESS,
            WMON_ADDRESS,
            5e6
        );
        swapAction.call = ffiCalldata;

        deal(_USDC_ADDRESS, address(this), 5e6);
        IERC20(_USDC_ADDRESS).approve(address(simpleZapper), 5e6);

        borrowableCWMON.setDelegateApproval(address(simpleZapper), true);

        uint256 cWMONBalanceBefore = borrowableCWMON.balanceOf(address(this));

        simpleZapper.swapAndDeposit(address(borrowableCWMON), true, swapAction, 0, true, address(this));

        assertGt(borrowableCWMON.balanceOf(address(this)), cWMONBalanceBefore);
    }
}