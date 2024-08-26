// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { CamelotStableLPAdaptor } from "contracts/oracles/adaptors/camelot/CamelotStableLPAdaptor.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { OracleRouter } from "contracts/oracles/OracleRouter.sol";
import { BaseStableLPAdaptor } from "contracts/oracles/adaptors/uniV2Base/BaseStableLPAdaptor.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { TestBaseOracleRouter } from "../TestBaseOracleRouter.sol";

contract TestCamelotStableLPAdaptor is TestBaseOracleRouter {
    address internal _BRIDGED_USDC_ADDRESS =
        0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8;

    address internal _CAMELOT_DAI_USDC =
        0x01efEd58B534d7a7464359A6F8d14D986125816B;

    CamelotStableLPAdaptor public adaptor;

    function setUp() public override {
        _fork("ETH_NODE_URI_ARBITRUM", 148061500);

        _deployCentralRegistry();
        _deployOracleRouter();

        chainlinkAdaptor = new ChainlinkAdaptor(
            ICentralRegistry(address(centralRegistry))
        );

        adaptor = new CamelotStableLPAdaptor(
            ICentralRegistry(address(centralRegistry))
        );
        adaptor.addAsset(_CAMELOT_DAI_USDC);

        chainlinkAdaptor.addAsset(_ETH_ADDRESS, _CHAINLINK_ETH_USD, 0, true);
        chainlinkAdaptor.addAsset(_DAI_ADDRESS, _CHAINLINK_DAI_USD, 0, true);
        chainlinkAdaptor.addAsset(
            _BRIDGED_USDC_ADDRESS,
            _CHAINLINK_USDC_USD,
            0,
            true
        );

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
            _BRIDGED_USDC_ADDRESS,
            address(chainlinkAdaptor)
        );

        oracleRouter.addApprovedAdaptor(address(adaptor));
        oracleRouter.addAssetPriceFeed(_CAMELOT_DAI_USDC, address(adaptor));
    }

    function testRevertWhenUnderlyingChainAssetPriceNotSet() public {
        chainlinkAdaptor.removeAsset(_DAI_ADDRESS);

        vm.expectRevert(OracleRouter.OracleRouter__NotSupported.selector);
        oracleRouter.getPrice(_CAMELOT_DAI_USDC, true, false);
    }

    function testReturnsCorrectPrice() public {
        (uint256 price, uint256 errorCode) = oracleRouter.getPrice(
            _CAMELOT_DAI_USDC,
            true,
            false
        );
        assertEq(errorCode, 0);
        assertGt(price, 0);
    }

    function testRevertAfterAssetRemove() public {
        testReturnsCorrectPrice();

        adaptor.removeAsset(_CAMELOT_DAI_USDC);
        vm.expectRevert(OracleRouter.OracleRouter__NotSupported.selector);
        oracleRouter.getPrice(_CAMELOT_DAI_USDC, true, false);
    }

    function testRevertAddAsset__AssetIsNotStableLP() public {
        vm.expectRevert(
            CamelotStableLPAdaptor
                .CamelotStableLPAdaptor__AssetIsNotStableLP
                .selector
        );
        adaptor.addAsset(0x84652bb2539513BAf36e225c930Fdd8eaa63CE27);
    }

    function testCanUpdateAsset() public {
        adaptor.addAsset(_CAMELOT_DAI_USDC);
        adaptor.addAsset(_CAMELOT_DAI_USDC);
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
