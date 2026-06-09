// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { VelodromeStableCToken } from "contracts/market/token/VelodromeStableCToken.sol";
import { VelodromeStableLPAdaptor } from "contracts/oracles/adaptors/velodrome/VelodromeStableLPAdaptor.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { VelodromePositionManager } from "contracts/market/position-management/VelodromePositionManager.sol";

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { BPS } from "contracts/libraries/ConstantsLib.sol";

import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";

import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";

import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { ICToken, AccountSnapshot } from "contracts/interfaces/ICToken.sol";

import { IVeloGauge } from "contracts/interfaces/external/velodrome/IVeloGauge.sol";
import { IVeloRouter } from "contracts/interfaces/external/velodrome/IVeloRouter.sol";
import { IVeloPairFactory } from "contracts/interfaces/external/velodrome/IVeloPairFactory.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

contract TestPositionManagerFeeEnabled is TestBaseMarketIsolated {
    address internal _VELODROME_DAI_USDC =
        0x19715771E30c93915A5bbDa134d782b81A820076;
    // KyberSwap MetaAggregationRouterV2 (same address across chains, incl. OP).
    address public kyberRouter = 0x6131B5fae19EA4f9D964eAc0408E4408b66337b5;
    IVeloGauge public gauge =
        IVeloGauge(0x6998089F6bDd9c74C7D8d01b99d7e379ccCcb02D);
    IVeloPairFactory public veloPairFactory =
        IVeloPairFactory(0xF1046053aa5682b4F9a81b5481394DA16BE5FF5a);
    IVeloRouter public veloRouter =
        IVeloRouter(0xa062aE8A9c5e11aaA026fc2670B0D65cCc8B2858);

    VelodromeStableCToken public strategyCTokenUSDCDAI;
    VelodromeStableLPAdaptor public adaptor;
    VelodromePositionManager public positionManager;

    address public owner;
    address public user;

    receive() external payable {}
    fallback() external payable {}

    // Kyber swap calldata recorded against the pinned block: DAI->USDC for
    // leverage, USDC->DAI for deleverage, plus the deleverage min-out. Fee-free
    // so balances reflect only the protocol leverage fee. Regenerate with
    // getKyberSwapData.js for the same amounts/recipient if the pin changes.
    bytes constant _LEV_CALLDATA = hex"e21fd0e900000000000000000000000000000000000000000000000000000000000000200000000000000000000000008f10b468b06c6fd214b65f87778827f7d113f996000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000005a000000000000000000000000000000000000000000000000000000000000007e000000000000000000000000000000000000000000000000000000000000004e00000000000000003983c45cea10f70bd0000000000000003983c45cea10f70bd000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000e000000000000000000000000000000000000000000000000000000000000000414a8413ecd7046216e35fc257475bada20ca34c42a95361950f77325b1acac81c0cbcfe88d9f4bae2168bf6a847969fdc7c2588f68fcc8b3f4d22275aa991bb8f1c0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003e000000000000000000000000013aa49bac059d709dd0a18d6bb63290076a702d70000000000000000000000000000000000000000000000000000000000000140000000000000000000000000000000000000000000000000000000000000018000000000000000036a3942511901e0000000000000000003c63f494c291d20000000000000000003983c45cea10f70bd00000000000000000000000003f3124c00000000000000000000000000000000000000000000420000000f42400000000000000000000000000000004f82e73edb06d29ff62c91ec8f5ff06571bdeb290000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006a277d3200000000000000000000000000000000000000000000000000000000000003c0000000000000000000000000000000000000000000000000000000000000000161f598cd0000000000000000768d1c7ba0a48f026a8d35ba2cb86c7ef562e39d0000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000001a0000000000000000000000000da10009cbd5d07dd0cecc66161fc93d7c9000da1800000000000000000003c4efd1ec2e00000000000000003983c45cea10f70bd000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000003983c45cea10f70bd08fce00900000000000000015455c918e405a2831fbff8595c0aae35ee3db9d100000000000000000000000000000000000000000000000000000000000000800000000000000000000000008f10b468b06c6fd214b65f87778827f7d113f99600000000000000000000000000000000000000000000000000000000000000200000000000000000000000011337bedc9d22ecbe766df105c9623922a27963ec0000000000000000000000007f5c764cbc14f9669b88837ca1490cca17c316078000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000da10009cbd5d07dd0cecc66161fc93d7c9000da10000000000000000000000007f5c764cbc14f9669b88837ca1490cca17c31607000000000000000000000000000000000000000000000000000000000000016000000000000000000000000000000000000000000000000000000000000001a000000000000000000000000000000000000000000000000000000000000001e0000000000000000000000000000000000000000000000000000000000000020000000000000000000000000013aa49bac059d709dd0a18d6bb63290076a702d7000000000000000000000000000000000000000000000003983c45cea10f70bd0000000000000000000000000000000000000000000000000000000003ee041f0000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000022000000000000000000000000000000000000000000000000000000000000000010000000000000000000000008f10b468b06c6fd214b65f87778827f7d113f9960000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000003983c45cea10f70bd00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000ae7b22536f75726365223a2243757276616e636550726f746f636f6c222c22416d6f756e74496e555344223a2236362e333733363531222c22416d6f756e744f7574555344223a2236362e333733303538222c22416d6f756e744f7574223a223636323631353739222c22526f7574654944223a223831343937616232644a424f553452753a6435633662633261655939504b4a3542222c2254696d657374616d70223a313738303937313635307d000000000000000000000000000000000000";
    bytes constant _DELEV_CALLDATA = hex"e21fd0e900000000000000000000000000000000000000000000000000000000000000200000000000000000000000008f10b468b06c6fd214b65f87778827f7d113f996000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000008200000000000000000000000000000000000000000000000000000000000000a6000000000000000000000000000000000000000000000000000000000000007600000000000000000000000000199dd0a0000000000000000000000000199dd0a000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000e00000000000000000000000000000000000000000000000000000000000000041702cbf5e0c8c80f2c24436f31d034fe189b1cb2f2b05fa91f456f40fb6ca91ec63415a95a43b80ab8b20719d752766f55c7ebdb93f05d3d8d3ead920a784196b1b00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000066000000000000000000000000013aa49bac059d709dd0a18d6bb63290076a702d70000000000000000000000000000000000000000000000000000000000000140000000000000000000000000000000000000000000000000000000000000018000000000000000000000000001855ec900000000000000000000000001ae5b4a0000000000000000000000000199dd0a0000000000000001750adb169ee1e000000000000000000000000000000000000018729cee86b30000000f42400000000000000000000000000000004f82e73edb06d29ff62c91ec8f5ff06571bdeb290000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006a277d330000000000000000000000000000000000000000000000000000000000000640000000000000000000000000000000000000000000000000000000000000000161f598cd0000000000000000768d1c7ba0a48f026a8d35ba2cb86c7ef562e39d0000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000004200000000000000000000000007f5c764cbc14f9669b88837ca1490cca17c316078000000000000000000000000000001a0000000000000000000000000199dd0a000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000199dd0a4f2d31ea00000000000000015455c918e405a2831fbff8595c0aae35ee3db9d100000000000000000000000000000000000000000000000000000000000000800000000000000000000000008f10b468b06c6fd214b65f87778827f7d113f99600000000000000000000000000000000000000000000000000000000000002a00000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000001750adb169ee1e0000000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000120000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000000c008fce00900000000000000005455c918e405a2831fbff8595c0aae35ee3db9d1000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000200000000000000000000001001337bedc9d22ecbe766df105c9623922a27963ec0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000000e03b9d6e0900000000000000005455c918e405a2831fbff8595c0aae35ee3db9d100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000040000000000000000000000000bf16ef186e715668aa29cef57e2fd7f9d48adfe600000000000000000000000000000000000000000000000000000001000276a40000000000000000000000000000000000000000000000000000000000000000000000000000000000000000da10009cbd5d07dd0cecc66161fc93d7c9000da180000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000007f5c764cbc14f9669b88837ca1490cca17c31607000000000000000000000000da10009cbd5d07dd0cecc66161fc93d7c9000da1000000000000000000000000000000000000000000000000000000000000016000000000000000000000000000000000000000000000000000000000000001a000000000000000000000000000000000000000000000000000000000000001e0000000000000000000000000000000000000000000000000000000000000020000000000000000000000000013aa49bac059d709dd0a18d6bb63290076a702d7000000000000000000000000000000000000000000000000000000000199dd0a000000000000000000000000000000000000000000000001732d5c8d8c2afc500000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000022000000000000000000000000000000000000000000000000000000000000000010000000000000000000000008f10b468b06c6fd214b65f87778827f7d113f9960000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000199dd0a00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000b97b22536f75726365223a2243757276616e636550726f746f636f6c222c22416d6f756e74496e555344223a2232362e393036303031222c22416d6f756e744f7574555344223a2232362e3930363336222c22416d6f756e744f7574223a223236383830353338323136313135353933323135222c22526f7574654944223a2262643463303765384942524c614a55613a333231383461396144534a5079626d70222c2254696d657374616d70223a313738303937313635317d00000000000000";
    uint256 constant _DELEV_MIN_OUT = 26880538216115593216;

    function setUp() public override {
        // Pinned so the inlined Kyber calldata matches on-chain state.
        _fork("ETH_NODE_URI_OPTIMISM", 152686184);

        _deployCentralRegistry();
        _deployCVE();
        _deployRewardManager();
        _deployVeCVE();
        _deployGaugeManager();
        _deployMarketManager();
        _deployOracleManager();

        chainlinkAdaptor = new ChainlinkAdaptor(
            ICentralRegistry(address(centralRegistry))
        );
        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));

        chainlinkDaiUsd = new MockV3Aggregator(8, 1e8);
        chainlinkAdaptor.addAsset(
            _DAI_ADDRESS,
            true,
            address(chainlinkDaiUsd),
            0
        );
        oracleManager.addAssetPricingAdaptor(
            _DAI_ADDRESS,
            address(chainlinkAdaptor),
            100,
            50,
            100,
            50
        );
        chainlinkUsdcUsd = new MockV3Aggregator(8, 1e8);
        chainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            true,
            address(chainlinkUsdcUsd),
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

        adaptor = new VelodromeStableLPAdaptor(
            ICentralRegistry(address(centralRegistry))
        );
        adaptor.addAsset(_VELODROME_DAI_USDC);
        oracleManager.addApprovedAdaptor(address(adaptor));
        oracleManager.addAssetPricingAdaptor(_VELODROME_DAI_USDC, address(adaptor), 100, 50, 100, 50);

        owner = address(this);
        user = user1;

        // Setup borrowable cDAI.
        {
            _deployBorrowableCDAI();
            // Add cToken support on Oracle Manager.
            oracleManager.addCTokenSupport(address(borrowableCDAI));

            _prepareDAI(owner, 200000e18);
            dai.approve(address(borrowableCDAI), 200000e18);

        }

        // Setup strategyCTokenUSDCDAI.
        {
            strategyCTokenUSDCDAI = new VelodromeStableCToken(
                ICentralRegistry(address(centralRegistry)),
                IERC20(_VELODROME_DAI_USDC),
                address(marketManagerIsolated),
                gauge,
                veloPairFactory,
                veloRouter,
                1 days
            );
            // Add cToken support on Oracle Manager.
            oracleManager.addCTokenSupport(address(strategyCTokenUSDCDAI));

            deal(_VELODROME_DAI_USDC, owner, 1 ether);
            IERC20(_VELODROME_DAI_USDC).approve(address(strategyCTokenUSDCDAI), 1 ether);


        }

        marketManagerIsolated.listTokens(address(strategyCTokenUSDCDAI),address(borrowableCDAI));

         _setCTokenConfigBasic(address(strategyCTokenUSDCDAI), 100_000e18, 0);
         _setCTokenConfigBasic(address(borrowableCDAI), 100_000e18, 100_000e18);

        positionManager = new VelodromePositionManager(
            ICentralRegistry(address(centralRegistry)),
            address(marketManagerIsolated),
            _WETH_ADDRESS,
            address(veloRouter),
            address(veloPairFactory)
        );
        marketManagerIsolated.addPositionManager(address(positionManager));

        _provideEnoughLiquidityForLeverage();

        centralRegistry.setExternalCalldataChecker(
            kyberRouter,
            address(new MockCalldataChecker(kyberRouter))
        );
        centralRegistry.setExternalCalldataChecker(
            address(veloRouter),
            address(new MockCalldataChecker(address(veloRouter)))
        );
    }

    function testLeverageWithFeeEnabled() public {
        // 1% leverage fee
        centralRegistry.setProtocolLeverageFee(100);

        vm.startPrank(user);

        deal(_VELODROME_DAI_USDC, user, 0.0001 ether);
        IERC20(_VELODROME_DAI_USDC).approve(address(strategyCTokenUSDCDAI), 0.0001 ether);

        // Mint strategyCTokenUSDCDAI.
        assertGt(strategyCTokenUSDCDAI.deposit(0.0001 ether, user), 0);
        strategyCTokenUSDCDAI.postCollateral(0.0001 ether);
        assertEq(strategyCTokenUSDCDAI.balanceOf(user), 0.0001 ether);

        uint256 balanceBeforeBorrow = dai.balanceOf(user);
        
        // Borrow borrowable cDAI.
        borrowableCDAI.borrow(100 ether, user);
        assertEq(balanceBeforeBorrow + 100 ether, dai.balanceOf(user));

        // Try leveraging with 50% of limit.
        uint256 amountForLeverage =_maxRemainingLeverageOfHelper(
            user,
            address(borrowableCDAI)
        ) / 2;
        uint256 protocolBalanceBeforeLeverage = dai.balanceOf(
            centralRegistry.daoAddress()
        );
        uint256 leverageFee = FixedPointMathLib.mulDivUp(
            amountForLeverage,
            centralRegistry.protocolLeverageFee(),
            BPS
        );
        uint256 swapInputAmount = amountForLeverage - leverageFee;
        bytes memory kyberCallData = _LEV_CALLDATA;

        VelodromePositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCDAI));
        leverageAction.borrowAssets = amountForLeverage;
        leverageAction.cToken = ICToken(address(strategyCTokenUSDCDAI));
        leverageAction.swapAction.inputToken = _DAI_ADDRESS;
        leverageAction.swapAction.inputAmount = swapInputAmount;
        leverageAction.swapAction.outputToken = _USDC_ADDRESS;
        leverageAction.swapAction.target = kyberRouter;
        leverageAction.swapAction.slippage = 0.005e18; // 0.5%
        leverageAction.swapAction.call = kyberCallData;
        leverageAction.auxData = abi.encode(0);
        positionManager.leverage(leverageAction, 0.05e18);

        AccountSnapshot memory borrowableCDAISnapshot = borrowableCDAI.getSnapshot(user);
        assertEq(borrowableCDAI.balanceOf(user), 0);
        assertEq(borrowableCDAISnapshot.debtBalance, 100 ether + amountForLeverage);

        AccountSnapshot memory strategyCTokenUSDCDAISnapshot = strategyCTokenUSDCDAI.getSnapshot(user);
        assertGt(strategyCTokenUSDCDAI.balanceOf(user), 0.00013 ether);
        assertEq(strategyCTokenUSDCDAISnapshot.collateralPosted, strategyCTokenUSDCDAI.balanceOf(user));

        uint256 protocolBalanceAfterLeverage = dai.balanceOf(
            centralRegistry.daoAddress()
        );
        assertEq(
            protocolBalanceAfterLeverage,
            protocolBalanceBeforeLeverage + leverageFee
        );

        vm.stopPrank();
    }

    function testDeLeverageWithFeeEnabled() public {
        testLeverageWithFeeEnabled();

        // Warp until collateralization cooldown period ends.
        vm.warp(block.timestamp + 20 minutes);
        borrowableCDAI.accrueIfNeeded();

        vm.startPrank(user);

        VelodromePositionManager.DeleverageAction memory deleverageAction;

        AccountSnapshot memory borrowableCDAISnapshotBefore = borrowableCDAI.getSnapshot(user);
        uint256 strategyCTokenUSDCDAIBalanceBefore = strategyCTokenUSDCDAI.balanceOf(user);

        uint256 collateralAmount = 0.00003 ether;
        uint256 leverageFee = FixedPointMathLib.mulDivUp(
            collateralAmount,
            centralRegistry.protocolLeverageFee(),
            BPS
        );
        uint256 collateralWithoutFee = collateralAmount - leverageFee;
        uint256 protocolBalanceBeforeDeLeverage = IERC20(_VELODROME_DAI_USDC)
            .balanceOf(centralRegistry.daoAddress());

        {
            (uint256 usdcOutAmount, uint256 daiOutAmount) = veloRouter
                .quoteRemoveLiquidity(
                    _USDC_ADDRESS,
                    _DAI_ADDRESS,
                    true,
                    address(veloPairFactory),
                    collateralWithoutFee
                );
            bytes memory kyberCallData = _DELEV_CALLDATA;
            uint256 minDaiOut = _DELEV_MIN_OUT;

            deleverageAction.cToken = ICToken(address(strategyCTokenUSDCDAI));
            deleverageAction.collateralAssets = collateralAmount;
            deleverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCDAI));
            deleverageAction.swapActions = new SwapperLib.Swap[](1);
            deleverageAction.swapActions[0].inputToken = _USDC_ADDRESS;
            deleverageAction.swapActions[0].inputAmount = usdcOutAmount;
            deleverageAction.swapActions[0].outputToken = _DAI_ADDRESS;
            deleverageAction.swapActions[0].target = kyberRouter;
            deleverageAction.swapActions[0].slippage = 0.005e18; // 0.5%
            deleverageAction.swapActions[0].call = kyberCallData;
            deleverageAction.repayAssets = daiOutAmount + (minDaiOut / 10) * 9;
        }

        strategyCTokenUSDCDAI.approve(address(positionManager), type(uint256).max);
        positionManager.deleverage(deleverageAction, 0.05e18);

        AccountSnapshot memory borrowableCDAISnapshot = borrowableCDAI.getSnapshot(user);
        assertEq(borrowableCDAI.balanceOf(user), 0);

        uint256 repaid =
            borrowableCDAISnapshotBefore.debtBalance -
            borrowableCDAISnapshot.debtBalance;
        assertLe(repaid, borrowableCDAISnapshotBefore.debtBalance);
        assertGe(repaid, deleverageAction.repayAssets);

        AccountSnapshot memory strategyCTokenUSDCDAISnapshot = strategyCTokenUSDCDAI.getSnapshot(user);
        assertEq(
            strategyCTokenUSDCDAI.balanceOf(user),
            strategyCTokenUSDCDAIBalanceBefore - deleverageAction.collateralAssets,
            "balance of mismatch"
        );
        assertEq(
            strategyCTokenUSDCDAISnapshot.collateralPosted,
            strategyCTokenUSDCDAIBalanceBefore - deleverageAction.collateralAssets,
            "collateral posted mismatch"
        );

        uint256 protocolBalanceAfterDeLeverage = IERC20(_VELODROME_DAI_USDC)
            .balanceOf(centralRegistry.daoAddress());
        assertEq(
            protocolBalanceAfterDeLeverage,
            protocolBalanceBeforeDeLeverage + leverageFee
        );

        vm.stopPrank();
    }

    function _provideEnoughLiquidityForLeverage() internal {
        address liquidityProvider = makeAddr("liquidityProvider");

        deal(_VELODROME_DAI_USDC, liquidityProvider, 1 ether);
        _prepareDAI(liquidityProvider, 20000000e18);

        vm.startPrank(liquidityProvider);

        // Deposit borrowable cDAI.
        dai.approve(address(borrowableCDAI), 20000000 ether);
        borrowableCDAI.deposit(20000000 ether, liquidityProvider);

        // Deposit strategyCTokenUSDCDAI.
        IERC20(_VELODROME_DAI_USDC).approve(address(strategyCTokenUSDCDAI), 1 ether);
        strategyCTokenUSDCDAI.deposit(1 ether, liquidityProvider);

        vm.stopPrank();
    }
}
