// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { VelodromeStableLPAdaptor } from "contracts/oracles/adaptors/velodrome/VelodromeStableLPAdaptor.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { OracleRouter } from "contracts/oracles/OracleRouter.sol";
import { BaseStableLPAdaptor } from "contracts/oracles/adaptors/uniV2Base/BaseStableLPAdaptor.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { VelodromeLib } from "contracts/libraries/VelodromeLib.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { TestBaseOracleRouter } from "../TestBaseOracleRouter.sol";

contract TestVelodromeStableLPAdaptor is TestBaseOracleRouter {
    address internal _VELO_ROUTER = 0xa062aE8A9c5e11aaA026fc2670B0D65cCc8B2858;
    address internal _VELODROME_DAI_USDC =
        0x19715771E30c93915A5bbDa134d782b81A820076;

    VelodromeStableLPAdaptor public adaptor;

    function setUp() public override {
        _fork("ETH_NODE_URI_OPTIMISM", 110333246);

        _deployCentralRegistry();
        chainlinkAdaptor = new ChainlinkAdaptor(
            ICentralRegistry(address(centralRegistry))
        );

        oracleRouter = new OracleRouter(
            ICentralRegistry(address(centralRegistry))
        );
        centralRegistry.setOracleRouter(address(oracleRouter));

        adaptor = new VelodromeStableLPAdaptor(
            ICentralRegistry(address(centralRegistry))
        );
        adaptor.addAsset(_VELODROME_DAI_USDC);

        chainlinkAdaptor.addAsset(_ETH_ADDRESS, _CHAINLINK_ETH_USD, 0, true);
        chainlinkAdaptor.addAsset(_DAI_ADDRESS, _CHAINLINK_DAI_USD, 0, true);
        chainlinkAdaptor.addAsset(_USDC_ADDRESS, _CHAINLINK_USDC_USD, 0, true);

        oracleRouter.addApprovedAdaptor(address(chainlinkAdaptor));
        oracleRouter.addAssetPriceFeed(
            _ETH_ADDRESS,
            address(chainlinkAdaptor)
        );
        oracleRouter.addAssetPriceFeed(
            _DAI_ADDRESS,
            address(chainlinkAdaptor)
        );
        oracleRouter.addAssetPriceFeed(
            _USDC_ADDRESS,
            address(chainlinkAdaptor)
        );

        oracleRouter.addApprovedAdaptor(address(adaptor));
        oracleRouter.addAssetPriceFeed(_VELODROME_DAI_USDC, address(adaptor));
    }

    function testRevertWhenUnderlyingChainAssetPriceNotSet() public {
        chainlinkAdaptor.removeAsset(_DAI_ADDRESS);

        vm.expectRevert(OracleRouter.OracleRouter__NotSupported.selector);
        oracleRouter.getPrice(_VELODROME_DAI_USDC, true, false);
    }

    function testReturnsCorrectPrice() public {
        (uint256 price, uint256 errorCode) = oracleRouter.getPrice(
            _VELODROME_DAI_USDC,
            true,
            false
        );
        assertEq(errorCode, 0);
        assertGt(price, 0);
    }

    function testRevertAfterAssetRemove() public {
        testReturnsCorrectPrice();

        adaptor.removeAsset(_VELODROME_DAI_USDC);
        vm.expectRevert(OracleRouter.OracleRouter__NotSupported.selector);
        oracleRouter.getPrice(_VELODROME_DAI_USDC, true, false);
    }

    function testRevertAddAsset__AssetIsNotStableLP() public {
        vm.expectRevert(
            VelodromeStableLPAdaptor
                .VelodromeStableLPAdaptor__AssetIsNotStableLP
                .selector
        );
        adaptor.addAsset(0x0493Bf8b6DBB159Ce2Db2E0E8403E753Abd1235b);
    }

    function testCanUpdateAsset() public {
        adaptor.addAsset(_VELODROME_DAI_USDC);
        adaptor.addAsset(_VELODROME_DAI_USDC);
    }

    function testPriceDoesNotChangeAfterLargeSwap() public {
        uint256 errorCode;
        uint256 priceBefore;
        (priceBefore, errorCode) = oracleRouter.getPrice(
            _VELODROME_DAI_USDC,
            true,
            false
        );
        assertEq(errorCode, 0);
        assertGt(priceBefore, 0);

        // try large swap (500K _USDC_ADDRESS)
        uint256 amount = 500000e6;
        deal(_USDC_ADDRESS, address(this), amount);
        VelodromeLib._swapExactTokensForTokens(
            _VELO_ROUTER,
            _VELODROME_DAI_USDC,
            _USDC_ADDRESS,
            _DAI_ADDRESS,
            amount,
            true
        );

        assertEq(IERC20(_USDC_ADDRESS).balanceOf(address(this)), 0);
        assertGt(IERC20(_DAI_ADDRESS).balanceOf(address(this)), 0);

        uint256 priceAfter;
        (priceAfter, errorCode) = oracleRouter.getPrice(
            _VELODROME_DAI_USDC,
            true,
            false
        );
        assertEq(errorCode, 0);
        assertApproxEqRel(priceBefore, priceAfter, 100000);
    }

    function testRevertGetPrice__AssetIsNotSupported() public {
        vm.expectRevert(
            BaseStableLPAdaptor
                .BaseStableLPAdaptor__AssetIsNotSupported
                .selector
        );
        adaptor.getPrice(address(0), true, false);
    }

    function testRevertRemoveAsset__AssetIsNotSupported() public {
        vm.expectRevert(
            BaseStableLPAdaptor
                .BaseStableLPAdaptor__AssetIsNotSupported
                .selector
        );
        adaptor.removeAsset(address(0));
    }
}
