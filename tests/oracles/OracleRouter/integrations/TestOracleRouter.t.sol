// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { VelodromeVolatileLPAdaptor } from "contracts/oracles/adaptors/velodrome/VelodromeVolatileLPAdaptor.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { OracleRouter } from "contracts/oracles/OracleRouter.sol";
import { DToken } from "contracts/market/collateral/DToken.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { TestBaseOracleRouter } from "../TestBaseOracleRouter.sol";

contract TestOracleRouter is TestBaseOracleRouter {
    address internal _VELODROME_WETH_USDC =
        0x0493Bf8b6DBB159Ce2Db2E0E8403E753Abd1235b;

    VelodromeVolatileLPAdaptor adapter;

    function setUp() public override {
        _fork("ETH_NODE_URI_OPTIMISM", 110333246);

        _deployCentralRegistry();
        _deployMarketManager();
        _deployDynamicInterestRateModel();

        oracleRouter = new OracleRouter(
            ICentralRegistry(address(centralRegistry))
        );
        centralRegistry.setOracleRouter(address(oracleRouter));

        chainlinkAdaptor = new ChainlinkAdaptor(
            ICentralRegistry(address(centralRegistry))
        );
        chainlinkAdaptor.addAsset(_ETH_ADDRESS, _CHAINLINK_ETH_USD, 0, true);
        chainlinkAdaptor.addAsset(_USDC_ADDRESS, _CHAINLINK_USDC_USD, 0, true);
        chainlinkAdaptor.addAsset(_WETH_ADDRESS, _CHAINLINK_ETH_USD, 0, true);
        oracleRouter.addApprovedAdaptor(address(chainlinkAdaptor));
        oracleRouter.addAssetPriceFeed(
            _ETH_ADDRESS,
            address(chainlinkAdaptor)
        );
        oracleRouter.addAssetPriceFeed(
            _USDC_ADDRESS,
            address(chainlinkAdaptor)
        );
        oracleRouter.addAssetPriceFeed(
            _WETH_ADDRESS,
            address(chainlinkAdaptor)
        );

        adapter = new VelodromeVolatileLPAdaptor(
            ICentralRegistry(address(centralRegistry))
        );
        adapter.addAsset(_VELODROME_WETH_USDC);

        oracleRouter.addApprovedAdaptor(address(adapter));
        oracleRouter.addAssetPriceFeed(_VELODROME_WETH_USDC, address(adapter));
    }

    function testReturnsCorrectPrice() public {
        uint256 higherPrice;
        uint256 lowerPrice;
        uint256 errorCode;

        (higherPrice, errorCode) = oracleRouter.getPrice(
            _VELODROME_WETH_USDC,
            true,
            false
        );
        assertEq(errorCode, 0);
        assertGt(higherPrice, 0);

        (lowerPrice, errorCode) = oracleRouter.getPrice(
            _VELODROME_WETH_USDC,
            true,
            true
        );
        assertEq(errorCode, 0);
        assertGt(lowerPrice, 0);
        assertEq(higherPrice, lowerPrice);

        (higherPrice, errorCode) = oracleRouter.getPrice(
            _VELODROME_WETH_USDC,
            false,
            false
        );
        assertEq(errorCode, 0);
        assertGt(higherPrice, 0);

        (lowerPrice, errorCode) = oracleRouter.getPrice(
            _VELODROME_WETH_USDC,
            false,
            true
        );
        assertEq(errorCode, 0);
        assertGt(lowerPrice, 0);
        assertEq(higherPrice, lowerPrice);
    }

    function testRevertAfterAssetRemove() public {
        adapter.removeAsset(_VELODROME_WETH_USDC);
        vm.expectRevert(OracleRouter.OracleRouter__NotSupported.selector);
        oracleRouter.getPrice(_VELODROME_WETH_USDC, true, false);
    }

    function testReturnsCorrectPriceForMTokens() public {
        DToken dUSDC = new DToken(
            ICentralRegistry(address(centralRegistry)),
            _USDC_ADDRESS,
            address(marketManager),
            address(interestRateModel)
        );
        // support market
        deal(_USDC_ADDRESS, address(this), 200000e6);
        usdc.approve(address(dUSDC), 200000e6);
        marketManager.listToken(address(dUSDC));

        oracleRouter.addMTokenSupport(address(dUSDC));

        uint256 dUSDCPrice;
        uint256 usdcPrice;
        uint256 errorCode;

        (dUSDCPrice, errorCode) = oracleRouter.getPrice(
            address(dUSDC),
            true,
            false
        );
        assertEq(errorCode, 0);
        assertApproxEqRel(dUSDCPrice, 1 ether, 0.01 ether);

        (usdcPrice, errorCode) = oracleRouter.getPrice(
            _USDC_ADDRESS,
            true,
            false
        );
        assertEq(errorCode, 0);
        assertEq(dUSDCPrice, usdcPrice);
    }

    function testRevertWhenAdaptorNotApproved() public {
        oracleRouter.removeApprovedAdaptor(address(adapter));

        vm.expectRevert(
            OracleRouter.OracleRouter__AdaptorIsNotApproved.selector
        );
        oracleRouter.getPrice(_VELODROME_WETH_USDC, true, false);
    }
}
