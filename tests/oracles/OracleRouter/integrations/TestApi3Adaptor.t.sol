// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { Api3Adaptor } from "contracts/oracles/adaptors/api3/Api3Adaptor.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { OracleRouter } from "contracts/oracles/OracleRouter.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { TestBaseOracleRouter } from "../TestBaseOracleRouter.sol";

contract TestApi3Adaptor is TestBaseOracleRouter {
    address internal _DAPI_PROXY_ARB_USD =
        0x669bFFFAb8866d84F832abF90Dc9c1D73b7525Bc;
    string internal _ARB_TICKER = "ARB/USD";

    Api3Adaptor public adaptor;

    function setUp() public override {
        _fork("ETH_NODE_URI_ARBITRUM", 174096479);

        _deployCentralRegistry();
        chainlinkAdaptor = new ChainlinkAdaptor(
            ICentralRegistry(address(centralRegistry))
        );

        oracleRouter = new OracleRouter(
            ICentralRegistry(address(centralRegistry))
        );
        centralRegistry.setOracleRouter(address(oracleRouter));

        adaptor = new Api3Adaptor(ICentralRegistry(address(centralRegistry)));
        adaptor.addAsset(
            _ARB_ADDRESS,
            _ARB_TICKER,
            _DAPI_PROXY_ARB_USD,
            0,
            true
        );

        oracleRouter.addApprovedAdaptor(address(chainlinkAdaptor));

        oracleRouter.addApprovedAdaptor(address(adaptor));
        oracleRouter.addAssetPriceFeed(_ARB_ADDRESS, address(adaptor));
    }

    function testReturnsCorrectPrice() public {
        (uint256 price, uint256 errorCode) = oracleRouter.getPrice(
            _ARB_ADDRESS,
            true,
            false
        );
        assertEq(errorCode, 0);
        assertGt(price, 0);
    }

    function testRevertGetPrice__AssetIsNotSupported() public {
        vm.expectRevert(Api3Adaptor.Api3Adaptor__AssetIsNotSupported.selector);
        adaptor.getPrice(_USDC_ADDRESS, true, false);
    }

    function testRevertAfterAssetRemove() public {
        testReturnsCorrectPrice();

        adaptor.removeAsset(_ARB_ADDRESS);
        vm.expectRevert(OracleRouter.OracleRouter__NotSupported.selector);
        oracleRouter.getPrice(_ARB_ADDRESS, true, false);
    }

    function testRevertAddAsset__InvalidHeartbeat() public {
        vm.expectRevert(Api3Adaptor.Api3Adaptor__InvalidHeartbeat.selector);
        adaptor.addAsset(
            _ARB_ADDRESS,
            _ARB_TICKER,
            _DAPI_PROXY_ARB_USD,
            1 days + 1,
            true
        );
    }

    function testRevertAddAsset__DAPINameHashError() public {
        vm.expectRevert(Api3Adaptor.Api3Adaptor__DAPINameHashError.selector);
        adaptor.addAsset(
            _ARB_ADDRESS,
            "ARB/USDC",
            _DAPI_PROXY_ARB_USD,
            0,
            true
        );
    }

    function testCanAddSameAsset() public {
        adaptor.addAsset(
            _ARB_ADDRESS,
            _ARB_TICKER,
            _DAPI_PROXY_ARB_USD,
            0,
            false
        );
    }

    function testRevertRemoveAsset__AssetIsNotSupported() public {
        vm.expectRevert(Api3Adaptor.Api3Adaptor__AssetIsNotSupported.selector);
        adaptor.removeAsset(address(0));
    }

    function testRevertGetPriceInETH__NotSupported() public {
        vm.expectRevert(OracleRouter.OracleRouter__NotSupported.selector);
        oracleRouter.getPrice(_ARB_ADDRESS, false, false);
    }
}
