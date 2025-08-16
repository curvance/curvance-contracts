// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseOracleManager } from "../TestBaseOracleManager.sol";
import { BalancerStablePoolAdaptor } from "contracts/oracles/adaptors/balancer/BalancerStablePoolAdaptor.sol";
import { IVault } from "contracts/oracles/adaptors/balancer/BalancerBaseAdaptor.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { IBalancerPool } from "contracts/interfaces/external/balancer/IBalancerPool.sol";
import { console2 } from "forge-std/console2.sol";

contract TestBalancerStablePoolAdaptor is TestBaseOracleManager {
    uint256 internal _WETH_RETH_TVL_USD = 58_666_383e18; // from Balancer web UI at fork block
    BalancerStablePoolAdaptor public adaptor;

    function setUp() public override {
        _fork(19656276);

        _deployCentralRegistry();
        _deployOracleManager();

        adaptor = new BalancerStablePoolAdaptor(
            ICentralRegistry(address(centralRegistry)),
            IVault(_BAL_VAULT_ADDRESS)
        );
    }

    function testRevertWhenUnderlyingAssetPriceNotSet() public {
        BalancerStablePoolAdaptor.AssetConfig memory assetConfig;
        assetConfig.poolId = _BAL_WETH_RETH_POOLID;
        assetConfig.poolDecimals = 18;
        assetConfig.rateProviderDecimals[0] = 18;
        assetConfig.rateProviders[
            0
        ] = 0x1a8F81c256aee9C640e14bB0453ce247ea0DFE6F;
        assetConfig.underlyingOrConstituent[0] = _RETH_ADDRESS;
        assetConfig.underlyingOrConstituent[1] = _WETH_ADDRESS;
        vm.expectRevert(
            BalancerStablePoolAdaptor
                .BalancerStablePoolAdaptor__ConfigurationError
                .selector
        );
        adaptor.addAsset(_BAL_WETH_RETH_ADDRESS, assetConfig);
    }

    function testReturnsCorrectPrice() public {
        chainlinkAdaptor = new ChainlinkAdaptor(
            ICentralRegistry(address(centralRegistry))
        );
        chainlinkAdaptor.addAsset(
            _ETH_ADDRESS,
            true,
            _CHAINLINK_ETH_USD,
            0
        );
        chainlinkAdaptor.addAsset(
            _WETH_ADDRESS,
            true,
            _CHAINLINK_ETH_USD,
            0
        );
        chainlinkAdaptor.addAsset(
            _RETH_ADDRESS,
            false,
            _CHAINLINK_RETH_ETH,
            0
        );
        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));
        oracleManager.addAssetPriceFeed(
            _ETH_ADDRESS,
            address(chainlinkAdaptor)
        );
        oracleManager.addAssetPriceFeed(
            _WETH_ADDRESS,
            address(chainlinkAdaptor)
        );
        oracleManager.addAssetPriceFeed(
            _RETH_ADDRESS,
            address(chainlinkAdaptor)
        );

        BalancerStablePoolAdaptor.AssetConfig memory assetConfig;
        assetConfig.poolId = _BAL_WETH_RETH_POOLID;
        assetConfig.poolDecimals = 18;
        assetConfig.rateProviderDecimals[0] = 18;
        assetConfig.rateProviders[
            0
        ] = 0x1a8F81c256aee9C640e14bB0453ce247ea0DFE6F;
        assetConfig.underlyingOrConstituent[0] = _RETH_ADDRESS;
        assetConfig.underlyingOrConstituent[1] = _WETH_ADDRESS;
        adaptor.addAsset(_BAL_WETH_RETH_ADDRESS, assetConfig);

        oracleManager.addApprovedAdaptor(address(adaptor));
        oracleManager.addAssetPriceFeed(
            _BAL_WETH_RETH_ADDRESS,
            address(adaptor)
        );

        (uint256 wethPrice, ) = oracleManager.getPrice(
            _WETH_ADDRESS,
            true,
            false
        );
        console2.log("WETH price: ", wethPrice);

        (uint256 rethPrice, ) = oracleManager.getPrice(
            _RETH_ADDRESS,
            true,
            false
        );
        console2.log("RETH price: ", rethPrice);

        uint256 expectedPriceFromTvl = (_WETH_RETH_TVL_USD * 1e18) /
            balRETH.totalSupply();
        console2.log(
            "expected RETH/WETH price from TVL: ",
            expectedPriceFromTvl
        );

        uint256 expectedPriceFromRate = (IBalancerPool(_BAL_WETH_RETH_ADDRESS)
            .getRate() * wethPrice) / 1e18;
        console2.log(
            "expected RETH/WETH price from ETH rate: ",
            expectedPriceFromRate
        );

        (uint256 price, uint256 errorCode) = oracleManager.getPrice(
            _BAL_WETH_RETH_ADDRESS,
            true,
            false
        );

        console2.log("computed RETH/WETH price: ", price);

        assertEq(errorCode, 0);
        assertApproxEqRel(price, expectedPriceFromTvl, 0.002e18); // 0.2% error allowed
        assertApproxEqRel(price, expectedPriceFromRate, 0.002e18); // 0.2% error allowed
    }

    function testRevertAfterAssetRemove() public {
        testReturnsCorrectPrice();

        adaptor.removeAsset(_BAL_WETH_RETH_ADDRESS);
        vm.expectRevert(OracleManager.OracleManager__NotSupported.selector);
        oracleManager.getPrice(_BAL_WETH_RETH_ADDRESS, true, false);
    }
}
