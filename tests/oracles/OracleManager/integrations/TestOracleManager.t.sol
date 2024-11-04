// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { VelodromeVolatileLPAdaptor } from "contracts/oracles/adaptors/velodrome/VelodromeVolatileLPAdaptor.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { EToken } from "contracts/market/token/EToken.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { TestBaseOracleManager } from "../TestBaseOracleManager.sol";

contract TestOracleManager is TestBaseOracleManager {
    address internal _VELODROME_WETH_USDC =
        0x0493Bf8b6DBB159Ce2Db2E0E8403E753Abd1235b;

    VelodromeVolatileLPAdaptor public adaptor;

    function setUp() public override {
        _fork("ETH_NODE_URI_OPTIMISM", 110333246);

        _deployCentralRegistry();
        _deployCVE();
        _deployRewardManager();
        _deployVeCVE();
        _deployOracleManager();
        _deployGaugeManager();
        _deployMarketManager();

        chainlinkAdaptor = new ChainlinkAdaptor(
            ICentralRegistry(address(centralRegistry))
        );

        adaptor = new VelodromeVolatileLPAdaptor(
            ICentralRegistry(address(centralRegistry))
        );
        adaptor.addAsset(_VELODROME_WETH_USDC);

        chainlinkAdaptor.addAsset(_ETH_ADDRESS, _CHAINLINK_ETH_USD, 0, true);
        chainlinkAdaptor.addAsset(_USDC_ADDRESS, _CHAINLINK_USDC_USD, 0, true);
        chainlinkAdaptor.addAsset(_WETH_ADDRESS, _CHAINLINK_ETH_USD, 0, true);
        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));
        oracleManager.addAssetPriceFeed(
            _ETH_ADDRESS,
            address(chainlinkAdaptor)
        );
        oracleManager.addAssetPriceFeed(
            _USDC_ADDRESS,
            address(chainlinkAdaptor)
        );
        oracleManager.addAssetPriceFeed(
            _WETH_ADDRESS,
            address(chainlinkAdaptor)
        );

        oracleManager.addApprovedAdaptor(address(adaptor));
        oracleManager.addAssetPriceFeed(
            _VELODROME_WETH_USDC,
            address(adaptor)
        );
    }

    function testReturnsCorrectPrice() public {
        uint256 higherPrice;
        uint256 lowerPrice;
        uint256 errorCode;

        (higherPrice, errorCode) = oracleManager.getPrice(
            _VELODROME_WETH_USDC,
            true,
            false
        );
        assertEq(errorCode, 0);
        assertGt(higherPrice, 0);

        (lowerPrice, errorCode) = oracleManager.getPrice(
            _VELODROME_WETH_USDC,
            true,
            true
        );
        assertEq(errorCode, 0);
        assertGt(lowerPrice, 0);
        assertEq(higherPrice, lowerPrice);

        (higherPrice, errorCode) = oracleManager.getPrice(
            _VELODROME_WETH_USDC,
            false,
            false
        );
        assertEq(errorCode, 0);
        assertGt(higherPrice, 0);

        (lowerPrice, errorCode) = oracleManager.getPrice(
            _VELODROME_WETH_USDC,
            false,
            true
        );
        assertEq(errorCode, 0);
        assertGt(lowerPrice, 0);
        assertEq(higherPrice, lowerPrice);
    }

    function testRevertAfterAssetRemove() public {
        adaptor.removeAsset(_VELODROME_WETH_USDC);
        vm.expectRevert(OracleManager.OracleManager__NotSupported.selector);
        oracleManager.getPrice(_VELODROME_WETH_USDC, true, false);
    }

    function testReturnsCorrectPriceForMTokens() public {
        EToken eUSDC = new EToken(
            ICentralRegistry(address(centralRegistry)),
            _USDC_ADDRESS,
            address(marketManager),
            address(interestRateModels[block.chainid][_USDC_ADDRESS])
        );
        // support market
        deal(_USDC_ADDRESS, address(this), 200000e6);
        usdc.approve(address(eUSDC), 200000e6);
        marketManager.listToken(address(eUSDC));

        oracleManager.addMTokenSupport(address(eUSDC));

        uint256 eUSDCPrice;
        uint256 usdcPrice;
        uint256 errorCode;

        (eUSDCPrice, errorCode) = oracleManager.getPrice(
            address(eUSDC),
            true,
            false
        );
        assertEq(errorCode, 0);
        assertApproxEqRel(eUSDCPrice, 1 ether, 0.01 ether);

        (usdcPrice, errorCode) = oracleManager.getPrice(
            _USDC_ADDRESS,
            true,
            false
        );
        assertEq(errorCode, 0);
        assertEq(eUSDCPrice, usdcPrice);
    }

    function testRevertWhenAdaptorNotApproved() public {
        oracleManager.removeApprovedAdaptor(address(adaptor));

        vm.expectRevert(
            OracleManager.OracleManager__AdaptorIsNotApproved.selector
        );
        oracleManager.getPrice(_VELODROME_WETH_USDC, true, false);
    }
}
