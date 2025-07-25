// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { VelodromeZapper } from "contracts/plugins/market/VelodromeZapper.sol";
import { VelodromeVolatileLPAdaptor } from "contracts/oracles/adaptors/velodrome/VelodromeVolatileLPAdaptor.sol";
import { VelodromeVolatileCToken } from "contracts/market/token/VelodromeVolatileCToken.sol";
import { IVeloRouter } from "contracts/interfaces/external/velodrome/IVeloRouter.sol";
import { IVeloPairFactory } from "contracts/interfaces/external/velodrome/IVeloPairFactory.sol";
import { IVeloGauge } from "contracts/interfaces/external/velodrome/IVeloGauge.sol";

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { AccountSnapshot } from "contracts/interfaces/ICToken.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { ZapperBase } from "contracts/plugins/ZapperBase.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";

import { console2 } from "forge-std/console2.sol";

contract TestVelodromeZapper is TestBaseMarketIsolated {
    address internal _VELODROME_FACTORY =
        0xF1046053aa5682b4F9a81b5481394DA16BE5FF5a;
    address internal _VELODROME_ROUTER =
        0xa062aE8A9c5e11aaA026fc2670B0D65cCc8B2858;
    address internal _VELODROME_GAUGE =
        0xE7630c9560C59CCBf5EEd8f33dd0ccA2E67a3981;
    address internal _VELODROME_WETH_USDC =
        0x0493Bf8b6DBB159Ce2Db2E0E8403E753Abd1235b;
    address internal _WETH = 0x4200000000000000000000000000000000000006;
    address internal _USDC = 0x7F5c764cBc14f9669B88837ca1490cCa17c31607;
    bool internal _IS_STABLE = false;

    VelodromeVolatileCToken public veloCTokenWETHUSDC;
    VelodromeVolatileLPAdaptor public adaptor;

    receive() external payable {}

    fallback() external payable {}

    function setUp() public override {
        _fork("ETH_NODE_URI_OPTIMISM", 109095500);

        _deployCentralRegistry();
        _deployCVE();
        _deployRewardManager();
        _deployVeCVE();
        _deployGaugeManager();
        _deployMarketManager();
        _deployOracleManager();
        _deployBorrowableCUSDC();

        _deployVelodromeZapper();

        console2.log("velodromeZapper address:", address(velodromeZapper));

        chainlinkAdaptor = new ChainlinkAdaptor(
            ICentralRegistry(address(centralRegistry))
        );
        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));

        chainlinkUsdcUsd = new MockV3Aggregator(8, 1e8, 1e50, 1e6);
        chainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            address(chainlinkUsdcUsd),
            0,
            true
        );
        oracleManager.addAssetPriceFeed(
            _USDC_ADDRESS,
            address(chainlinkAdaptor)
        );
        chainlinkEthUsd = new MockV3Aggregator(8, 2700e8, 1e50, 1e6);
        chainlinkAdaptor.addAsset(
            _ETH_ADDRESS,
            address(chainlinkEthUsd),
            0,
            true
        );
        chainlinkAdaptor.addAsset(
            _WETH_ADDRESS,
            address(chainlinkEthUsd),
            0,
            true
        );
        oracleManager.addAssetPriceFeed(
            _ETH_ADDRESS,
            address(chainlinkAdaptor)
        );
        oracleManager.addAssetPriceFeed(
            _WETH_ADDRESS,
            address(chainlinkAdaptor)
        );

        adaptor = new VelodromeVolatileLPAdaptor(
            ICentralRegistry(address(centralRegistry))
        );
        adaptor.addAsset(_VELODROME_WETH_USDC);
        oracleManager.addApprovedAdaptor(address(adaptor));
        oracleManager.addAssetPriceFeed(
            _VELODROME_WETH_USDC,
            address(adaptor)
        );

        veloCTokenWETHUSDC = new VelodromeVolatileCToken(
            ICentralRegistry(address(centralRegistry)),
            IERC20(_VELODROME_WETH_USDC),
            address(marketManagerIsolated),
            IVeloGauge(_VELODROME_GAUGE),
            IVeloPairFactory(_VELODROME_FACTORY),
            IVeloRouter(_VELODROME_ROUTER),
            1 days
        );
        oracleManager.addCTokenSupport(address(veloCTokenWETHUSDC));
        oracleManager.addCTokenSupport(address(borrowableCUSDC));

        _prepareUSDC(address(this), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);

        deal(_VELODROME_WETH_USDC, address(this), 1 ether);
        IERC20(_VELODROME_WETH_USDC).approve(address(veloCTokenWETHUSDC), 1 ether);

        marketManagerIsolated.listTokens(address(veloCTokenWETHUSDC), address(borrowableCUSDC));

        _setCTokenConfigBasic(address(veloCTokenWETHUSDC), 100_000e18, 0);
        _setCTokenConfigHighValues(address(borrowableCUSDC), 100_000e18, 100_000e18);
    }

    function testEnterVelodrome() public {
        uint256 ethAmount = 3 ether;
        vm.deal(user1, ethAmount);

        console2.log("velodromeZapper address:", address(velodromeZapper));

        vm.startPrank(user1);
        velodromeZapper.enterVelodrome{ value: ethAmount }(
            address(veloCTokenWETHUSDC),
            VelodromeZapper.ZapperData(
                address(0),
                ethAmount,
                _VELODROME_WETH_USDC,
                1,
                true
            ),
            new SwapperLib.Swap[](0),
            _VELODROME_ROUTER,
            _VELODROME_FACTORY,
            6e13,
            false,
            user1
        );

        vm.stopPrank();

        assertEq(user1.balance, 0, "user1 eth balance is not 0");
        assertGt(IERC20(address(veloCTokenWETHUSDC)).balanceOf(user1), 0, "user1 veloCTokenWETHUSDC balance is not greater than 0");
    }

    function testExitVelodrome() public {

        deal(_VELODROME_WETH_USDC, user1, 0.05 ether);
        IERC20(_VELODROME_WETH_USDC).approve(address(velodromeZapper), 1 ether);

        uint256 withdrawAmount = IERC20(_VELODROME_WETH_USDC).balanceOf(user1);
        console2.log("withdrawAmount", withdrawAmount);

        vm.startPrank(user1);
        IERC20(_VELODROME_WETH_USDC).approve(
            address(velodromeZapper),
            withdrawAmount
        );
        velodromeZapper.exitVelodrome(
            _VELODROME_ROUTER,
            VelodromeZapper.ZapperData(
                _VELODROME_WETH_USDC,
                withdrawAmount,
                _WETH,
                0,
                false
            ),
            new SwapperLib.Swap[](0),
            user1
        );
        vm.stopPrank();

        assertGt(IERC20(_WETH).balanceOf(user1), 0);
        // assertGt(IERC20(_USDC).balanceOf(user1), 0);
        assertEq(IERC20(_VELODROME_WETH_USDC).balanceOf(user1), 0);
    }

    function testEnterVelodromeWithCToken() public {
        uint256 ethAmount = 3 ether;
        vm.deal(user1, ethAmount);

        vm.startPrank(user1);
        velodromeZapper.enterVelodrome{ value: ethAmount }(
            address(veloCTokenWETHUSDC),
            VelodromeZapper.ZapperData(
                address(0),
                ethAmount,
                _VELODROME_WETH_USDC,
                1,
                true
            ),
            new SwapperLib.Swap[](0),
            _VELODROME_ROUTER,
            _VELODROME_FACTORY,
            6e13,
            false,
            user1
        );

        vm.stopPrank();

        AccountSnapshot memory veloCTokenWETHUSDCSnapshot = veloCTokenWETHUSDC.getSnapshot(
            user1
        );

        assertApproxEqRel(veloCTokenWETHUSDC.balanceOf(user1), 0.00006 ether, 0.01 ether);
        assertEq(veloCTokenWETHUSDCSnapshot.debtBalance, 0);
        assertEq(user1.balance, 0);
    }

    function testEnterVelodromeWithCTokenWithCollateralize() public {
        uint256 ethAmount = 3 ether;
        vm.deal(user1, ethAmount);

        vm.startPrank(user1);

        veloCTokenWETHUSDC.setDelegateApproval(address(velodromeZapper), true);

        velodromeZapper.enterVelodrome{ value: ethAmount }(
            address(veloCTokenWETHUSDC),
            VelodromeZapper.ZapperData(
                address(0),
                ethAmount,
                _VELODROME_WETH_USDC,
                1,
                true
            ),
            new SwapperLib.Swap[](0),
            _VELODROME_ROUTER,
            _VELODROME_FACTORY,
            6e13,
            true,
            user1
        );

        vm.stopPrank();

        
        AccountSnapshot memory veloCTokenWETHUSDCSnapshot = veloCTokenWETHUSDC.getSnapshot(
            user1
        );

        assertApproxEqRel(veloCTokenWETHUSDC.balanceOf(user1), 0.00006 ether, 0.01 ether);
        assertEq(veloCTokenWETHUSDCSnapshot.debtBalance, 0);
        assertEq(user1.balance, 0);
    }

    function testEnterVelodromeWithDelegation() public {
        uint256 ethAmount = 3 ether;
        vm.deal(user2, ethAmount);

        vm.startPrank(user1);
        veloCTokenWETHUSDC.setDelegateApproval(user2, true);
        veloCTokenWETHUSDC.setDelegateApproval(address(velodromeZapper), true);
        vm.stopPrank();

        vm.startPrank(user2);
        velodromeZapper.enterVelodrome{ value: ethAmount }(
            address(veloCTokenWETHUSDC),
            VelodromeZapper.ZapperData(
                address(0),
                ethAmount,
                _VELODROME_WETH_USDC,
                1,
                true
            ),
            new SwapperLib.Swap[](0),
            _VELODROME_ROUTER,
            _VELODROME_FACTORY,
            6e13,
            true,
            user1
        );

        vm.stopPrank();

        AccountSnapshot memory veloCTokenWETHUSDCSnapshot = veloCTokenWETHUSDC.getSnapshot(
            user1
        );

        assertApproxEqRel(veloCTokenWETHUSDC.balanceOf(user1), 0.00006 ether, 0.01 ether);
        assertEq(veloCTokenWETHUSDCSnapshot.debtBalance, 0);
        assertEq(user1.balance, 0);
    }

    function testRedeemAndExitVelodrome() public {
        testEnterVelodromeWithCToken();

        ZapperBase.RedemptionData memory redemptionData;
        redemptionData.cToken = address(veloCTokenWETHUSDC);
        redemptionData.shares = 0.00006 ether;
        redemptionData.forceRedeemCollateral = false;

        vm.startPrank(user1);

        veloCTokenWETHUSDC.setDelegateApproval(address(velodromeZapper), true);
        IERC20(_VELODROME_WETH_USDC).approve(
            address(velodromeZapper),
            3 ether
        );
        velodromeZapper.redeemAndExitVelodrome(
            redemptionData,
            _VELODROME_ROUTER,
            VelodromeZapper.ZapperData(
                _VELODROME_WETH_USDC,
                0.00006 ether,
                _WETH,
                0,
                false
            ),
            new SwapperLib.Swap[](0),
            user1
        );

        vm.stopPrank();

        assertGt(IERC20(_WETH).balanceOf(user1), 0);
        assertEq(IERC20(_VELODROME_WETH_USDC).balanceOf(user1), 0);
    }
}
