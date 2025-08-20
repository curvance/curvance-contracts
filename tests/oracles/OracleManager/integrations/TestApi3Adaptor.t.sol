// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { Api3Adaptor } from "contracts/oracles/adaptors/api3/Api3Adaptor.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { BaseOracleAdaptor } from "contracts/oracles/adaptors/BaseOracleAdaptor.sol";

import { TestBaseOracleManager } from "../TestBaseOracleManager.sol";

contract TestApi3Adaptor is TestBaseOracleManager {
    address internal _DAPI_PROXY_ARB_USD =
        0x669bFFFAb8866d84F832abF90Dc9c1D73b7525Bc;
    string internal _ARB_TICKER = "ARB/USD";

    Api3Adaptor public adaptor;

    function setUp() public override {
        _fork("ETH_NODE_URI_ARBITRUM", 174096479);

        
        _deployCentralRegistry();
        _deployOracleManager();

        chainlinkAdaptor = new ChainlinkAdaptor(
            ICentralRegistry(address(centralRegistry))
        );

        adaptor = new Api3Adaptor(ICentralRegistry(
            address(centralRegistry))
        );
        adaptor.addAsset(
            _ARB_ADDRESS,
            true,
            _DAPI_PROXY_ARB_USD,
            0,
            _ARB_TICKER
        );

        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));

        oracleManager.addApprovedAdaptor(address(adaptor));
        oracleManager.addAssetPriceFeed(_ARB_ADDRESS, address(adaptor));
    }

    function testReturnsCorrectPrice() public {
        (uint256 price, uint256 errorCode) = oracleManager.getPrice(
            _ARB_ADDRESS,
            true,
            false
        );
        assertEq(errorCode, 0);
        assertGt(price, 0);
    }

    function testRevertGetPrice__AssetIsNotSupported() public {
        vm.expectRevert(BaseOracleAdaptor.BaseOracleAdaptor__AssetIsNotSupported.selector);
        adaptor.getPrice(_USDC_ADDRESS, true, false);
    }

    function testRevertAfterAssetRemove() public {
        testReturnsCorrectPrice();

        adaptor.removeAsset(_ARB_ADDRESS);
        vm.expectRevert(OracleManager.OracleManager__NotSupported.selector);
        oracleManager.getPrice(_ARB_ADDRESS, true, false);
    }

    function testRevertAddAsset__InvalidHeartbeat() public {
        // Should revert when heartbeat > DEFAULT_HEARTBEAT.
        uint256 invalidHeartbeat = adaptor.DEFAULT_HEARTBEAT() + 1;

        vm.expectRevert(Api3Adaptor.Api3Adaptor__InvalidHeartbeat.selector);
        adaptor.addAsset(
            _ARB_ADDRESS,
            true,
            _DAPI_PROXY_ARB_USD,
            invalidHeartbeat,
            _ARB_TICKER
        );
    }

    function testRevertAddAsset__DAPINameHashError() public {
        vm.expectRevert(Api3Adaptor.Api3Adaptor__DAPINameHashError.selector);
        adaptor.addAsset(
            _ARB_ADDRESS,
            true,
            _DAPI_PROXY_ARB_USD,
            0,
            "ARB/USDC"
        );
    }

    function testCanAddSameAsset() public {
        adaptor.addAsset(
            _ARB_ADDRESS,
            false,
            _DAPI_PROXY_ARB_USD,
            0,
            _ARB_TICKER
        );
    }

    function testRevertRemoveAsset__AssetIsNotSupported() public {
        vm.expectRevert(BaseOracleAdaptor.BaseOracleAdaptor__AssetIsNotSupported.selector);
        adaptor.removeAsset(address(0));
    }

    function testRevertGetPriceInETH__NotSupported() public {
        vm.expectRevert(OracleManager.OracleManager__NotSupported.selector);
        oracleManager.getPrice(_ARB_ADDRESS, false, false);
    }
}
