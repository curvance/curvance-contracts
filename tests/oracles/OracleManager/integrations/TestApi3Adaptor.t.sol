// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { Api3Adaptor } from "contracts/oracles/adaptors/api3/Api3Adaptor.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { BaseOracleAdaptor } from "contracts/oracles/adaptors/BaseOracleAdaptor.sol";
import { IOracleAdaptor } from "contracts/interfaces/IOracleAdaptor.sol";
import { IProxy } from "contracts/interfaces/external/api3/IProxy.sol";

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

        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));

        oracleManager.addApprovedAdaptor(address(adaptor));
        
        adaptor.addAsset(
            _ARB_ADDRESS,
            true,
            _DAPI_PROXY_ARB_USD,
            0,
            _ARB_TICKER
        );

        oracleManager.addAssetPricingAdaptor(_ARB_ADDRESS, address(adaptor), 100, 50, 100, 50);
    }

    function testReturnsCorrectPrice() public view {
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

    function testRevertAddAsset__ZeroAddress() public {
        vm.expectRevert(BaseOracleAdaptor.BaseOracleAdaptor__InvalidConfig.selector);
        adaptor.addAsset(address(0), true, _DAPI_PROXY_ARB_USD, 0, _ARB_TICKER);
    }

    /// @notice Pre-fix `_getPrice` skipped `_adjustPrice`, leaving any
    ///         configured PriceGuard inert. Verify clamp now binds.
    function test_getPrice_clampsAbovePriceGuardBasePrice() public {
        vm.mockCall(
            _DAPI_PROXY_ARB_USD,
            abi.encodeWithSelector(IProxy.read.selector),
            abi.encode(int224(100e18), uint32(block.timestamp))
        );

        // Static guard: timestampStart and ips both 0.
        adaptor.setGuardedPriceConfig(_ARB_ADDRESS, true, 0, 0, 80e18, 50e18);

        IOracleAdaptor.PricingResult memory result =
            adaptor.getPrice(_ARB_ADDRESS, true, false);

        assertFalse(result.hadError, "expected no error within guarded band");
        assertEq(result.price, 80e18, "expected price clamped to basePrice");
    }

    /// @notice Sub-floor price MUST surface as `hadError=true`, `price=0`.
    ///         Pre-fix the inert guard returned the raw sub-floor price.
    function test_getPrice_signalsErrorBelowPriceGuardMinPrice() public {
        // Mock above minPrice first so setGuardedPriceConfig's write-time
        // `minPrice <= currentPrice` probe passes.
        vm.mockCall(
            _DAPI_PROXY_ARB_USD,
            abi.encodeWithSelector(IProxy.read.selector),
            abi.encode(int224(100e18), uint32(block.timestamp))
        );

        adaptor.setGuardedPriceConfig(_ARB_ADDRESS, true, 0, 0, 200e18, 50e18);

        // Drop below minPrice: _adjustPrice returns 0 → hadError=true.
        vm.mockCall(
            _DAPI_PROXY_ARB_USD,
            abi.encodeWithSelector(IProxy.read.selector),
            abi.encode(int224(30e18), uint32(block.timestamp))
        );

        IOracleAdaptor.PricingResult memory result =
            adaptor.getPrice(_ARB_ADDRESS, true, false);

        assertTrue(result.hadError, "expected hadError=true below minPrice");
        assertEq(result.price, 0, "expected price=0 below minPrice");
    }

    /// @notice In-band prices pass through unchanged. Pins the
    ///         no-perturbation contract for future refactors.
    function test_getPrice_returnsRawPriceWithinPriceGuardBand() public {
        vm.mockCall(
            _DAPI_PROXY_ARB_USD,
            abi.encodeWithSelector(IProxy.read.selector),
            abi.encode(int224(100e18), uint32(block.timestamp))
        );

        adaptor.setGuardedPriceConfig(_ARB_ADDRESS, true, 0, 0, 200e18, 50e18);

        // Pin live feed inside [50e18, 200e18].
        vm.mockCall(
            _DAPI_PROXY_ARB_USD,
            abi.encodeWithSelector(IProxy.read.selector),
            abi.encode(int224(75e18), uint32(block.timestamp))
        );

        IOracleAdaptor.PricingResult memory result =
            adaptor.getPrice(_ARB_ADDRESS, true, false);

        assertFalse(result.hadError, "expected no error within guarded band");
        assertEq(result.price, 75e18, "expected raw price within guarded band");
    }
}
