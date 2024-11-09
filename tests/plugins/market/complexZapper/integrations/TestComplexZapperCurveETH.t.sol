// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IMToken } from "contracts/interfaces/market/IMToken.sol";
import { SimplePToken } from "contracts/market/token/SimplePToken.sol";
import { Curve2PoolLPAdaptor } from "contracts/oracles/adaptors/curve/Curve2PoolLPAdaptor.sol";
import { ComplexZapper } from "contracts/plugins/market/ComplexZapper.sol";

import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";

contract TestComplexZapperCurveETH is TestBaseMarket {
    address internal _CURVE_STETH_LP =
        0x21E27a5E5513D6e65C4f830167390997aA84843a;
    address internal _CURVE_STETH_MINTER =
        0x21E27a5E5513D6e65C4f830167390997aA84843a;
    address internal _STETH_ADDRESS =
        0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address internal _CHAINLINK_STETH_USD =
        0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8;

    SimplePToken pToken;
    Curve2PoolLPAdaptor public adaptor;

    receive() external payable {}

    fallback() external payable {}

    function testInitialize() public {
        assertEq(
            address(complexZapper.marketManager()),
            address(marketManager)
        );
    }

    function setUp() public override {
        super.setUp();

        pToken = new SimplePToken(
            ICentralRegistry(address(centralRegistry)),
            IERC20(_CURVE_STETH_LP),
            address(marketManager)
        );

        chainlinkAdaptor.addAsset(
            _STETH_ADDRESS,
            _CHAINLINK_STETH_USD,
            0,
            true
        );
        oracleManager.addAssetPriceFeed(
            _STETH_ADDRESS,
            address(chainlinkAdaptor)
        );

        adaptor = new Curve2PoolLPAdaptor(
            ICentralRegistry(address(centralRegistry))
        );
        adaptor.setReentrancyConfig(2, 10000);

        Curve2PoolLPAdaptor.AdaptorData memory data;
        data.pool = _CURVE_STETH_LP;
        data.underlying0 = _ETH_ADDRESS;
        data.underlying1 = _STETH_ADDRESS;
        data.divideRate0 = true;
        data.divideRate1 = true;
        data.isCorrelated = true;
        data.upperBound = 10200;
        data.lowerBound = 10000;
        adaptor.addAsset(_CURVE_STETH_LP, data);

        oracleManager.addApprovedAdaptor(address(adaptor));
        oracleManager.addAssetPriceFeed(_CURVE_STETH_LP, address(adaptor));
        oracleManager.addMTokenSupport(address(pToken));

        deal(_CURVE_STETH_LP, address(this), 1 ether);
        IERC20(_CURVE_STETH_LP).approve(address(pToken), 1 ether);
        marketManager.listToken(address(pToken));
        marketManager.updatePositionToken(
            IMToken(address(pToken)),
            7000,
            4000,
            3000,
            200,
            400,
            0,
            1000
        );
        address[] memory mTokens = new address[](1);
        mTokens[0] = address(pToken);
        uint256[] memory newCollateralCaps = new uint256[](1);
        newCollateralCaps[0] = 1000000 * 10 ** 18;
        marketManager.setPTokenCollateralCaps(mTokens, newCollateralCaps);
    }

    function testEnterCurveWithETH() public {
        uint256 ethAmount = 3 ether;
        vm.deal(user1, ethAmount);

        address[] memory tokens = new address[](2);
        tokens[0] = _ETH_ADDRESS;
        tokens[1] = _STETH_ADDRESS;

        vm.prank(user1);
        complexZapper.enterCurve{ value: ethAmount }(
            address(0),
            ComplexZapper.ZapperData(
                _ETH_ADDRESS,
                ethAmount,
                _CURVE_STETH_LP,
                1,
                false
            ),
            new SwapperLib.Swap[](0),
            _CURVE_STETH_MINTER,
            tokens,
            false,
            user1
        );

        assertEq(user1.balance, 0);
        assertGt(IERC20(_CURVE_STETH_LP).balanceOf(user1), 0);
    }

    function testExitCurve() public {
        testEnterCurveWithETH();

        uint256 withdrawAmount = IERC20(_CURVE_STETH_LP).balanceOf(user1);

        vm.startPrank(user1);
        address[] memory tokens = new address[](2);
        tokens[0] = _ETH_ADDRESS;
        tokens[1] = _STETH_ADDRESS;
        IERC20(_CURVE_STETH_LP).approve(
            address(complexZapper),
            withdrawAmount
        );
        complexZapper.exitCurve(
            _CURVE_STETH_MINTER,
            ComplexZapper.ZapperData(
                _CURVE_STETH_LP,
                withdrawAmount,
                _ETH_ADDRESS,
                0,
                false
            ),
            tokens,
            2,
            0,
            new SwapperLib.Swap[](0),
            user1
        );
        vm.stopPrank();

        assertApproxEqRel(user1.balance, 3 ether, 0.01 ether);
        assertEq(IERC20(_CURVE_STETH_LP).balanceOf(user1), 0);
    }

    function testEnterCurveWithPToken() public {
        uint256 ethAmount = 3 ether;
        vm.deal(user1, ethAmount);

        address[] memory tokens = new address[](2);
        tokens[0] = _ETH_ADDRESS;
        tokens[1] = _STETH_ADDRESS;

        vm.prank(user1);
        complexZapper.enterCurve{ value: ethAmount }(
            address(pToken),
            ComplexZapper.ZapperData(
                _ETH_ADDRESS,
                ethAmount,
                _CURVE_STETH_LP,
                1,
                false
            ),
            new SwapperLib.Swap[](0),
            _CURVE_STETH_MINTER,
            tokens,
            false,
            user1
        );

        assertEq(user1.balance, 0);

        (uint256 balance, uint256 borrowed, ) = pToken.getSnapshot(user1);
        assertApproxEqRel(balance, 3 ether, 0.01 ether);
        assertEq(borrowed, 0);
    }

    function testEnterCurveWithPTokenWithCollateralize() public {
        uint256 ethAmount = 3 ether;
        vm.deal(user1, ethAmount);

        address[] memory tokens = new address[](2);
        tokens[0] = _ETH_ADDRESS;
        tokens[1] = _STETH_ADDRESS;

        vm.prank(user1);
        complexZapper.enterCurve{ value: ethAmount }(
            address(pToken),
            ComplexZapper.ZapperData(
                _ETH_ADDRESS,
                ethAmount,
                _CURVE_STETH_LP,
                1,
                false
            ),
            new SwapperLib.Swap[](0),
            _CURVE_STETH_MINTER,
            tokens,
            true,
            user1
        );

        assertEq(user1.balance, 0);

        (uint256 balance, uint256 borrowed, ) = pToken.getSnapshot(user1);
        assertApproxEqRel(balance, 3 ether, 0.01 ether);
        assertEq(borrowed, 0);
    }

    function testEnterCurveWithDelegation() public {
        uint256 ethAmount = 3 ether;
        vm.deal(user2, ethAmount);

        vm.prank(user1);
        pToken.setDelegateApproval(user2, true);

        address[] memory tokens = new address[](2);
        tokens[0] = _ETH_ADDRESS;
        tokens[1] = _STETH_ADDRESS;

        vm.prank(user2);
        complexZapper.enterCurve{ value: ethAmount }(
            address(pToken),
            ComplexZapper.ZapperData(
                _ETH_ADDRESS,
                ethAmount,
                _CURVE_STETH_LP,
                1,
                false
            ),
            new SwapperLib.Swap[](0),
            _CURVE_STETH_MINTER,
            tokens,
            true,
            user1
        );

        assertEq(user2.balance, 0);

        (uint256 balance, uint256 borrowed, ) = pToken.getSnapshot(user1);
        assertApproxEqRel(balance, 3 ether, 0.01 ether);
        assertEq(borrowed, 0);
    }

    function testRedeemAndExitCurve() public {
        testEnterCurveWithPToken();

        vm.prank(user1);
        pToken.setDelegateApproval(address(complexZapper), true);

        ComplexZapper.RedemptionData memory redemptionData;
        redemptionData.pToken = address(pToken);
        redemptionData.shares = 2.9 ether;
        redemptionData.forceRedeemCollateral = false;

        vm.startPrank(user1);
        address[] memory tokens = new address[](2);
        tokens[0] = _ETH_ADDRESS;
        tokens[1] = _STETH_ADDRESS;
        IERC20(_CURVE_STETH_LP).approve(address(complexZapper), 3 ether);
        complexZapper.redeemAndExitCurve(
            redemptionData,
            _CURVE_STETH_MINTER,
            ComplexZapper.ZapperData(
                _CURVE_STETH_LP,
                2.9 ether,
                _ETH_ADDRESS,
                0,
                false
            ),
            tokens,
            2,
            0,
            new SwapperLib.Swap[](0),
            user1
        );
        vm.stopPrank();

        assertApproxEqRel(user1.balance, 3 ether, 0.1 ether);
        assertEq(IERC20(_CURVE_STETH_LP).balanceOf(user1), 0);
    }
}
