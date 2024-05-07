// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseOracleRouter } from "../TestBaseOracleRouter.sol";
import { BalancerStablePoolAdaptor } from "contracts/oracles/adaptors/balancer/BalancerStablePoolAdaptor.sol";
import { IVault } from "contracts/oracles/adaptors/balancer/BalancerBaseAdaptor.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { OracleRouter } from "contracts/oracles/OracleRouter.sol";

contract TestBalancerStablePoolAdaptor is TestBaseOracleRouter {
    BalancerStablePoolAdaptor adaptor;

    function setUp() public override {
        _fork(18031848);

        _deployCentralRegistry();
        _deployOracleRouter();

        adaptor = new BalancerStablePoolAdaptor(
            ICentralRegistry(address(centralRegistry)),
            IVault(_BAL_VAULT_ADDRESS)
        );
    }

    function testRevertWhenUnderlyingAssetPriceNotSet() public {
        BalancerStablePoolAdaptor.AdaptorData memory adaptorData;
        adaptorData.poolId = _BAL_WETH_RETH_POOLID;
        adaptorData.poolDecimals = 18;
        adaptorData.rateProviderDecimals[0] = 18;
        adaptorData.rateProviders[
            0
        ] = 0x1a8F81c256aee9C640e14bB0453ce247ea0DFE6F;
        adaptorData.underlyingOrConstituent[0] = _RETH_ADDRESS;
        adaptorData.underlyingOrConstituent[1] = _WETH_ADDRESS;
        vm.expectRevert(
            BalancerStablePoolAdaptor
                .BalancerStablePoolAdaptor__ConfigurationError
                .selector
        );
        adaptor.addAsset(_BAL_WETH_RETH_ADDRESS, adaptorData);
    }

    function testReturnsCorrectPrice() public {
        chainlinkAdaptor = new ChainlinkAdaptor(
            ICentralRegistry(address(centralRegistry))
        );
        chainlinkAdaptor.addAsset(_ETH_ADDRESS, _CHAINLINK_ETH_USD, 0, true);
        chainlinkAdaptor.addAsset(_WETH_ADDRESS, _CHAINLINK_ETH_USD, 0, true);
        chainlinkAdaptor.addAsset(
            _RETH_ADDRESS,
            _CHAINLINK_RETH_ETH,
            0,
            false
        );
        oracleRouter.addApprovedAdaptor(address(chainlinkAdaptor));
        oracleRouter.addAssetPriceFeed(
            _ETH_ADDRESS,
            address(chainlinkAdaptor)
        );
        oracleRouter.addAssetPriceFeed(
            _WETH_ADDRESS,
            address(chainlinkAdaptor)
        );
        oracleRouter.addAssetPriceFeed(
            _RETH_ADDRESS,
            address(chainlinkAdaptor)
        );

        BalancerStablePoolAdaptor.AdaptorData memory adaptorData;
        adaptorData.poolId = _BAL_WETH_RETH_POOLID;
        adaptorData.poolDecimals = 18;
        adaptorData.rateProviderDecimals[0] = 18;
        adaptorData.rateProviders[
            0
        ] = 0x1a8F81c256aee9C640e14bB0453ce247ea0DFE6F;
        adaptorData.underlyingOrConstituent[0] = _RETH_ADDRESS;
        adaptorData.underlyingOrConstituent[1] = _WETH_ADDRESS;
        adaptor.addAsset(_BAL_WETH_RETH_ADDRESS, adaptorData);

        oracleRouter.addApprovedAdaptor(address(adaptor));
        oracleRouter.addAssetPriceFeed(
            _BAL_WETH_RETH_ADDRESS,
            address(adaptor)
        );

        (uint256 price, uint256 errorCode) = oracleRouter.getPrice(
            _BAL_WETH_RETH_ADDRESS,
            true,
            false
        );
        assertEq(errorCode, 0);
        assertGt(price, 0);
    }

    function testRevertAfterAssetRemove() public {
        testReturnsCorrectPrice();

        adaptor.removeAsset(_BAL_WETH_RETH_ADDRESS);
        vm.expectRevert(OracleRouter.OracleRouter__NotSupported.selector);
        oracleRouter.getPrice(_BAL_WETH_RETH_ADDRESS, true, false);
    }
}
