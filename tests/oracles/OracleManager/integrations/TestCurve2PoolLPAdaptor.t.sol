// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseOracleManager } from "../TestBaseOracleManager.sol";
import { Curve2PoolLPAdaptor } from "contracts/oracles/adaptors/curve/Curve2PoolLPAdaptor.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";

contract TestCurve2PoolLPAdaptor is TestBaseOracleManager {
    address internal _CHAINLINK_STETH_USD =
        0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8;
    address internal _CURVE_ETH_STETH =
        0x21E27a5E5513D6e65C4f830167390997aA84843a;
    address internal _STETH_ADDRESS =
        0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

    Curve2PoolLPAdaptor public adaptor;

    function setUp() public override {
        _fork(18031848);

        
        _deployCentralRegistry();
        _deployOracleManager();

        adaptor = new Curve2PoolLPAdaptor(
            ICentralRegistry(address(centralRegistry))
        );

        adaptor.setReentrancyConfig(2, 10000);
    }

    function testRevertWhenUnderlyingAssetPriceNotSet() public {
        Curve2PoolLPAdaptor.AdaptorData memory data;
        data.pool = 0x21E27a5E5513D6e65C4f830167390997aA84843a;
        data.underlying0 = _ETH_ADDRESS;
        data.underlying1 = _STETH_ADDRESS;
        data.divideRate0 = true;
        data.divideRate1 = true;
        data.isCorrelated = true;
        data.upperBound = 10200;
        data.lowerBound = 10000;
        vm.expectRevert(
            Curve2PoolLPAdaptor
                .Curve2PoolLPAdaptor__QuoteAssetIsNotSupported
                .selector
        );
        adaptor.addAsset(_CURVE_ETH_STETH, data);
    }

    function testRevertWhenUnderlyingAssetPriceNotSet2() public {
        chainlinkAdaptor = new ChainlinkAdaptor(
            ICentralRegistry(address(centralRegistry))
        );
        chainlinkAdaptor.addAsset(_ETH_ADDRESS, _CHAINLINK_ETH_USD, 0, true);
        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));
        oracleManager.addAssetPriceFeed(
            _ETH_ADDRESS,
            address(chainlinkAdaptor)
        );

        Curve2PoolLPAdaptor.AdaptorData memory data;
        data.pool = 0x21E27a5E5513D6e65C4f830167390997aA84843a;
        data.underlying0 = _ETH_ADDRESS;
        data.underlying1 = _STETH_ADDRESS;
        data.divideRate0 = true;
        data.divideRate1 = true;
        data.isCorrelated = true;
        data.upperBound = 10200;
        data.lowerBound = 10000;
        vm.expectRevert(
            Curve2PoolLPAdaptor
                .Curve2PoolLPAdaptor__QuoteAssetIsNotSupported
                .selector
        );
        adaptor.addAsset(_CURVE_ETH_STETH, data);
    }

    function testReturnsCorrectPrice() public {
        chainlinkAdaptor = new ChainlinkAdaptor(
            ICentralRegistry(address(centralRegistry))
        );
        chainlinkAdaptor.addAsset(_ETH_ADDRESS, _CHAINLINK_ETH_USD, 0, true);
        chainlinkAdaptor.addAsset(
            _STETH_ADDRESS,
            _CHAINLINK_STETH_USD,
            0,
            true
        );
        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));
        oracleManager.addAssetPriceFeed(
            _ETH_ADDRESS,
            address(chainlinkAdaptor)
        );
        oracleManager.addAssetPriceFeed(
            _STETH_ADDRESS,
            address(chainlinkAdaptor)
        );

        Curve2PoolLPAdaptor.AdaptorData memory data;
        data.pool = 0x21E27a5E5513D6e65C4f830167390997aA84843a;
        data.underlying0 = _ETH_ADDRESS;
        data.underlying1 = _STETH_ADDRESS;
        data.divideRate0 = true;
        data.divideRate1 = true;
        data.isCorrelated = true;
        data.upperBound = 10200;
        data.lowerBound = 10000;
        adaptor.addAsset(_CURVE_ETH_STETH, data);

        oracleManager.addApprovedAdaptor(address(adaptor));
        oracleManager.addAssetPriceFeed(_CURVE_ETH_STETH, address(adaptor));
        (uint256 ethPrice, ) = oracleManager.getPrice(
            _ETH_ADDRESS,
            true,
            false
        );

        (uint256 price, uint256 errorCode) = oracleManager.getPrice(
            _CURVE_ETH_STETH,
            true,
            false
        );
        assertEq(errorCode, 0);
        assertApproxEqRel(price, ethPrice, 0.02 ether);
    }

    function testRevertAfterAssetRemove() public {
        testReturnsCorrectPrice();
        adaptor.removeAsset(_CURVE_ETH_STETH);

        vm.expectRevert(OracleManager.OracleManager__NotSupported.selector);
        oracleManager.getPrice(_CURVE_ETH_STETH, true, false);
    }

    // function testRevertAddAsset__UnsupportedPool() public {
    //     adaptor.setReentrancyConfig(2, 6000);

    //     Curve2PoolLPAdaptor.AdaptorData memory data;
    //     data.pool = 0x21E27a5E5513D6e65C4f830167390997aA84843a;
    //     data.underlying0 = _ETH_ADDRESS;
    //     data.underlying1 = _STETH_ADDRESS;
    //     data.divideRate0 = true;
    //     data.divideRate1 = true;
    //     data.isCorrelated = true;
    //     data.upperBound = 10200;
    //     data.lowerBound = 10000;

    //     vm.expectRevert(
    //         Curve2PoolLPAdaptor.Curve2PoolLPAdaptor__UnsupportedPool.selector
    //     );
    //     adaptor.addAsset(_STETH_ADDRESS, data);
    // }

    function testRevertAddAsset__QuoteAssetIsNotSupported() public {
        Curve2PoolLPAdaptor.AdaptorData memory data;
        data.pool = 0x21E27a5E5513D6e65C4f830167390997aA84843a;
        data.underlying0 = _ETH_ADDRESS;
        data.underlying1 = _STETH_ADDRESS;
        data.divideRate0 = true;
        data.divideRate1 = true;
        data.isCorrelated = true;
        data.upperBound = 10200;
        data.lowerBound = 10000;

        vm.expectRevert(
            Curve2PoolLPAdaptor
                .Curve2PoolLPAdaptor__QuoteAssetIsNotSupported
                .selector
        );
        adaptor.addAsset(_CURVE_ETH_STETH, data);
    }

    function testRevertAddAsset__InvalidBounds() public {
        chainlinkAdaptor = new ChainlinkAdaptor(
            ICentralRegistry(address(centralRegistry))
        );
        chainlinkAdaptor.addAsset(_ETH_ADDRESS, _CHAINLINK_ETH_USD, 0, true);
        chainlinkAdaptor.addAsset(
            _STETH_ADDRESS,
            _CHAINLINK_STETH_USD,
            0,
            true
        );
        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));
        oracleManager.addAssetPriceFeed(
            _ETH_ADDRESS,
            address(chainlinkAdaptor)
        );
        oracleManager.addAssetPriceFeed(
            _STETH_ADDRESS,
            address(chainlinkAdaptor)
        );

        Curve2PoolLPAdaptor.AdaptorData memory data;
        data.pool = 0x21E27a5E5513D6e65C4f830167390997aA84843a;
        data.underlying0 = _ETH_ADDRESS;
        data.underlying1 = _STETH_ADDRESS;
        data.divideRate0 = true;
        data.divideRate1 = true;
        data.isCorrelated = true;
        data.upperBound = 10200;
        data.lowerBound = 10201;

        vm.expectRevert(
            Curve2PoolLPAdaptor.Curve2PoolLPAdaptor__InvalidBounds.selector
        );
        adaptor.addAsset(_CURVE_ETH_STETH, data);
    }

    function testRevertAddAsset__UnsupportedPool_Underlying() public {
        chainlinkAdaptor = new ChainlinkAdaptor(
            ICentralRegistry(address(centralRegistry))
        );
        chainlinkAdaptor.addAsset(address(0), _CHAINLINK_ETH_USD, 0, true);
        chainlinkAdaptor.addAsset(_ETH_ADDRESS, _CHAINLINK_ETH_USD, 0, true);
        chainlinkAdaptor.addAsset(
            _STETH_ADDRESS,
            _CHAINLINK_STETH_USD,
            0,
            true
        );
        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));
        oracleManager.addAssetPriceFeed(address(0), address(chainlinkAdaptor));
        oracleManager.addAssetPriceFeed(
            _ETH_ADDRESS,
            address(chainlinkAdaptor)
        );
        oracleManager.addAssetPriceFeed(
            _STETH_ADDRESS,
            address(chainlinkAdaptor)
        );

        Curve2PoolLPAdaptor.AdaptorData memory data;
        data.pool = 0x21E27a5E5513D6e65C4f830167390997aA84843a;
        data.underlying0 = address(0);
        data.underlying1 = _STETH_ADDRESS;
        data.divideRate0 = true;
        data.divideRate1 = true;
        data.isCorrelated = true;
        data.upperBound = 10200;
        data.lowerBound = 10000;

        vm.expectRevert(
            Curve2PoolLPAdaptor.Curve2PoolLPAdaptor__UnsupportedPool.selector
        );
        adaptor.addAsset(_CURVE_ETH_STETH, data);
    }

    function testUpdateAsset() public {
        chainlinkAdaptor = new ChainlinkAdaptor(
            ICentralRegistry(address(centralRegistry))
        );
        chainlinkAdaptor.addAsset(_ETH_ADDRESS, _CHAINLINK_ETH_USD, 0, true);
        chainlinkAdaptor.addAsset(
            _STETH_ADDRESS,
            _CHAINLINK_STETH_USD,
            0,
            true
        );
        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));
        oracleManager.addAssetPriceFeed(
            _ETH_ADDRESS,
            address(chainlinkAdaptor)
        );
        oracleManager.addAssetPriceFeed(
            _STETH_ADDRESS,
            address(chainlinkAdaptor)
        );

        Curve2PoolLPAdaptor.AdaptorData memory data;
        data.pool = 0x21E27a5E5513D6e65C4f830167390997aA84843a;
        data.underlying0 = _ETH_ADDRESS;
        data.underlying1 = _STETH_ADDRESS;
        data.divideRate0 = true;
        data.divideRate1 = true;
        data.isCorrelated = true;
        data.upperBound = 10200;
        data.lowerBound = 10000;
        adaptor.addAsset(_CURVE_ETH_STETH, data);
        adaptor.addAsset(_CURVE_ETH_STETH, data);
    }

    function testRevertRemoveAsset__AssetIsNotSupported() public {
        vm.expectRevert(
            Curve2PoolLPAdaptor
                .Curve2PoolLPAdaptor__AssetIsNotSupported
                .selector
        );
        adaptor.removeAsset(_CURVE_ETH_STETH);
    }

    function testRevertGetPrice__Curve2PoolLPAdaptor__BoundsExceeded() public {
        chainlinkAdaptor = new ChainlinkAdaptor(
            ICentralRegistry(address(centralRegistry))
        );
        chainlinkAdaptor.addAsset(_ETH_ADDRESS, _CHAINLINK_ETH_USD, 0, true);
        chainlinkAdaptor.addAsset(
            _STETH_ADDRESS,
            _CHAINLINK_STETH_USD,
            0,
            true
        );
        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));
        oracleManager.addAssetPriceFeed(
            _ETH_ADDRESS,
            address(chainlinkAdaptor)
        );
        oracleManager.addAssetPriceFeed(
            _STETH_ADDRESS,
            address(chainlinkAdaptor)
        );

        Curve2PoolLPAdaptor.AdaptorData memory data;
        data.pool = 0x21E27a5E5513D6e65C4f830167390997aA84843a;
        data.underlying0 = _ETH_ADDRESS;
        data.underlying1 = _STETH_ADDRESS;
        data.divideRate0 = true;
        data.divideRate1 = true;
        data.isCorrelated = true;
        data.upperBound = 10001;
        data.lowerBound = 10000;

        vm.expectRevert(
            Curve2PoolLPAdaptor.Curve2PoolLPAdaptor__BoundsExceeded.selector
        );
        adaptor.addAsset(_CURVE_ETH_STETH, data);
    }

    function testRevertGetPrice__Curve2PoolLPAdaptor__InvalidBounds2() public {
        chainlinkAdaptor = new ChainlinkAdaptor(
            ICentralRegistry(address(centralRegistry))
        );
        chainlinkAdaptor.addAsset(_ETH_ADDRESS, _CHAINLINK_ETH_USD, 0, true);
        chainlinkAdaptor.addAsset(
            _STETH_ADDRESS,
            _CHAINLINK_STETH_USD,
            0,
            true
        );
        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));
        oracleManager.addAssetPriceFeed(
            _ETH_ADDRESS,
            address(chainlinkAdaptor)
        );
        oracleManager.addAssetPriceFeed(
            _STETH_ADDRESS,
            address(chainlinkAdaptor)
        );

        Curve2PoolLPAdaptor.AdaptorData memory data;
        data.pool = 0x21E27a5E5513D6e65C4f830167390997aA84843a;
        data.underlying0 = _ETH_ADDRESS;
        data.underlying1 = _STETH_ADDRESS;
        data.divideRate0 = true;
        data.divideRate1 = true;
        data.isCorrelated = true;
        data.upperBound = 10501;
        data.lowerBound = 10000;

        vm.expectRevert(
            Curve2PoolLPAdaptor.Curve2PoolLPAdaptor__InvalidBounds.selector
        );
        adaptor.addAsset(_CURVE_ETH_STETH, data);
    }

    function testRaiseBounds() public {
        chainlinkAdaptor = new ChainlinkAdaptor(
            ICentralRegistry(address(centralRegistry))
        );
        chainlinkAdaptor.addAsset(_ETH_ADDRESS, _CHAINLINK_ETH_USD, 0, true);
        chainlinkAdaptor.addAsset(
            _STETH_ADDRESS,
            _CHAINLINK_STETH_USD,
            0,
            true
        );
        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));
        oracleManager.addAssetPriceFeed(
            _ETH_ADDRESS,
            address(chainlinkAdaptor)
        );
        oracleManager.addAssetPriceFeed(
            _STETH_ADDRESS,
            address(chainlinkAdaptor)
        );

        Curve2PoolLPAdaptor.AdaptorData memory data;
        data.pool = 0x21E27a5E5513D6e65C4f830167390997aA84843a;
        data.underlying0 = _ETH_ADDRESS;
        data.underlying1 = _STETH_ADDRESS;
        data.divideRate0 = true;
        data.divideRate1 = true;
        data.isCorrelated = true;
        data.upperBound = 10200;
        data.lowerBound = 10000;
        adaptor.addAsset(_CURVE_ETH_STETH, data);

        vm.expectRevert(
            Curve2PoolLPAdaptor.Curve2PoolLPAdaptor__InvalidBounds.selector
        );
        adaptor.raiseBounds(_CURVE_ETH_STETH, 10000, 10000);

        vm.expectRevert(
            Curve2PoolLPAdaptor.Curve2PoolLPAdaptor__InvalidBounds.selector
        );
        adaptor.raiseBounds(_CURVE_ETH_STETH, 10000, 10600);

        vm.expectRevert(
            Curve2PoolLPAdaptor.Curve2PoolLPAdaptor__InvalidBounds.selector
        );
        adaptor.raiseBounds(_CURVE_ETH_STETH, 10000, 10100);

        vm.expectRevert(
            Curve2PoolLPAdaptor.Curve2PoolLPAdaptor__InvalidBounds.selector
        );
        adaptor.raiseBounds(_CURVE_ETH_STETH, 10100, 10200);

        vm.expectRevert(
            Curve2PoolLPAdaptor.Curve2PoolLPAdaptor__InvalidBounds.selector
        );
        adaptor.raiseBounds(_CURVE_ETH_STETH, 10300, 10400);

        vm.expectRevert(
            Curve2PoolLPAdaptor.Curve2PoolLPAdaptor__InvalidBounds.selector
        );
        adaptor.raiseBounds(_CURVE_ETH_STETH, 10100, 10500);

        vm.expectRevert(
            Curve2PoolLPAdaptor.Curve2PoolLPAdaptor__BoundsExceeded.selector
        );
        adaptor.raiseBounds(_CURVE_ETH_STETH, 10100, 10300);

        adaptor.raiseBounds(_CURVE_ETH_STETH, 10050, 10300);
    }
}
