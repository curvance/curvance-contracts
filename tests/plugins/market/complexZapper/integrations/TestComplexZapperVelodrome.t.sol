// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IMToken } from "contracts/market/LiquidityManager.sol";
import { ComplexZapper } from "contracts/plugins/market/ComplexZapper.sol";
import { ZapperBase } from "contracts/plugins/ZapperBase.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { VelodromeVolatileLPAdaptor } from "contracts/oracles/adaptors/velodrome/VelodromeVolatileLPAdaptor.sol";
import { VelodromeVolatilePToken, IVeloGauge, IVeloRouter, IVeloPairFactory } from "contracts/market/token/VelodromeVolatilePToken.sol";

import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";

contract TestComplexZapperVelodrome is TestBaseMarket {
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

    VelodromeVolatilePToken public pToken;
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

        complexZapper = new ComplexZapper(
            ICentralRegistry(address(centralRegistry)),
            _WETH
        );

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

        pToken = new VelodromeVolatilePToken(
            ICentralRegistry(address(centralRegistry)),
            IERC20(_VELODROME_WETH_USDC),
            address(marketManager),
            IVeloGauge(_VELODROME_GAUGE),
            IVeloPairFactory(_VELODROME_FACTORY),
            IVeloRouter(_VELODROME_ROUTER)
        );
        oracleManager.addMTokenSupport(address(pToken));

        deal(_VELODROME_WETH_USDC, address(this), 1 ether);
        IERC20(_VELODROME_WETH_USDC).approve(address(pToken), 1 ether);
        marketManager.listToken(address(pToken));

        marketManager.updatePositionToken(
            IMToken(address(pToken)),
            7000,
            4000,
            3000,
            200,
            400,
            10,
            1000
        );

        address[] memory tokens = new address[](1);
        tokens[0] = address(pToken);
        uint256[] memory caps = new uint256[](1);
        caps[0] = 100_000e18;

        marketManager.setPTokenCollateralCaps(tokens, caps);
    }

    function testEnterVelodrome() public {
        uint256 ethAmount = 3 ether;
        vm.deal(user1, ethAmount);

        vm.prank(user1);
        complexZapper.enterVelodrome{ value: ethAmount }(
            address(0),
            ComplexZapper.ZapperData(
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

        assertEq(user1.balance, 0);
        assertGt(IERC20(_VELODROME_WETH_USDC).balanceOf(user1), 0);
    }

    function testExitVelodrome() public {
        testEnterVelodrome();

        uint256 withdrawAmount = IERC20(_VELODROME_WETH_USDC).balanceOf(user1);

        vm.startPrank(user1);
        IERC20(_VELODROME_WETH_USDC).approve(
            address(complexZapper),
            withdrawAmount
        );
        complexZapper.exitVelodrome(
            _VELODROME_ROUTER,
            ComplexZapper.ZapperData(
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

    function testEnterVelodromeWithPToken() public {
        uint256 ethAmount = 3 ether;
        vm.deal(user1, ethAmount);

        vm.prank(user1);
        complexZapper.enterVelodrome{ value: ethAmount }(
            address(pToken),
            ComplexZapper.ZapperData(
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

        assertEq(user1.balance, 0);
        (uint256 balance, uint256 borrowed, ) = pToken.getSnapshot(user1);
        assertApproxEqRel(balance, 0.00006 ether, 0.01 ether);
        assertEq(borrowed, 0);
    }

    function testEnterVelodromeWithPTokenWithCollateralize() public {
        uint256 ethAmount = 3 ether;
        vm.deal(user1, ethAmount);

        vm.prank(user1);
        complexZapper.enterVelodrome{ value: ethAmount }(
            address(pToken),
            ComplexZapper.ZapperData(
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

        assertEq(user1.balance, 0);
        (uint256 balance, uint256 borrowed, ) = pToken.getSnapshot(user1);
        assertApproxEqRel(balance, 0.00006 ether, 0.01 ether);
        assertEq(borrowed, 0);
    }

    function testEnterVelodromeWithDelegation() public {
        uint256 ethAmount = 3 ether;
        vm.deal(user2, ethAmount);

        vm.prank(user1);
        pToken.setDelegateApproval(user2, true);

        vm.prank(user2);
        complexZapper.enterVelodrome{ value: ethAmount }(
            address(pToken),
            ComplexZapper.ZapperData(
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

        assertEq(user1.balance, 0);
        (uint256 balance, uint256 borrowed, ) = pToken.getSnapshot(user1);
        assertApproxEqRel(balance, 0.00006 ether, 0.01 ether);
        assertEq(borrowed, 0);
    }

    function testRedeemAndExitVelodrome() public {
        testEnterVelodromeWithPToken();

        vm.prank(user1);
        pToken.setDelegateApproval(address(complexZapper), true);

        ZapperBase.RedemptionData memory redemptionData;
        redemptionData.mToken = address(pToken);
        redemptionData.shares = 0.00006 ether;
        redemptionData.forceRedeemCollateral = false;

        vm.startPrank(user1);
        IERC20(_VELODROME_WETH_USDC).approve(address(complexZapper), 3 ether);
        complexZapper.redeemAndExitVelodrome(
            redemptionData,
            _VELODROME_ROUTER,
            ComplexZapper.ZapperData(
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
