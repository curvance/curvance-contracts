// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IChainlink } from "contracts/interfaces/external/chainlink/IChainlink.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";

contract TwoAssetsDeviationTest is TestBaseMarketIsolated {
    function setUp() public override {
        super.setUp();

        // USDC: caution 1.30%, bad 1.80%
        vm.prank(centralRegistry.daoAddress());
        oracleManager.setDeviationBounds(_USDC_ADDRESS, 180, 130);

        // WETH: caution 1.40%, bad 2.00%
        vm.prank(centralRegistry.daoAddress());
        oracleManager.setDeviationBounds(_WETH_ADDRESS, 200, 140);
    }

    function test_assetBoundsAreIndependent() public {

        (uint16 badUSDCBefore, uint16 cautionUSDCBefore) = oracleManager.assetPricingConfig(_USDC_ADDRESS);
        (uint16 badWETHBefore, uint16 cautionWETHBefore) = oracleManager.assetPricingConfig(_WETH_ADDRESS);

        // Update adaptor deviation for USDC, WETH should be unchanged
        uint256 newDeviationThresholdUSDC = 120; // 1.20%
        vm.prank(address(dualChainlinkAdaptor));
        oracleManager.notifyDeviationUpdated(_USDC_ADDRESS, newDeviationThresholdUSDC);

        (uint16 badUSDCAfter, uint16 cautionUSDCAfter) = oracleManager.assetPricingConfig(_USDC_ADDRESS);
        (uint16 badWETHAfter, uint16 cautionWETHAfter) = oracleManager.assetPricingConfig(_WETH_ADDRESS);

        // USDC new caution bound = 120 + 20 = 140
        // USDC new bad bound = 140 + 50 = 190
        assertEq(uint256(cautionUSDCAfter), 10140);
        assertEq(uint256(badUSDCAfter), 10190);

        // WETH bounds should be unchanged
        assertEq(badWETHAfter, badWETHBefore);
        assertEq(cautionWETHAfter, cautionWETHBefore);
    }

    function test_replaceAdaptor_validatesAgainstLargestDeviationThreshold() public {
        
        // Create a new adaptor with a larger deviation threshold for WETH
        ChainlinkAdaptor newAdaptor = new ChainlinkAdaptor(ICentralRegistry(address(centralRegistry)));
        vm.prank(centralRegistry.daoAddress());
        oracleManager.addApprovedAdaptor(address(newAdaptor));

        // set a larger deviation threshold of 1.50%
        newAdaptor.addAsset(_WETH_ADDRESS, true, address(mockWethFeed), 0, 150);

        // Replace the second adaptor for WETH with the looser adaptor
        vm.prank(centralRegistry.daoAddress());

        // min caution bound = largestDeviation (150) + min deviation buffer (20) = 170
        oracleManager.replaceAssetPricingAdaptor(
            _WETH_ADDRESS,
            address(dualChainlinkAdaptor),
            address(newAdaptor),
            225, // setting to caution + 50 
            175
        );

        // attempting to set caution below 170 should revert
        address dao = centralRegistry.daoAddress();
        vm.expectRevert(OracleManager.OracleManager__InvalidParameter.selector);
        vm.prank(dao);
        oracleManager.setDeviationBounds(_WETH_ADDRESS, 225, 165);

        // Try another valid set of bounds which should succeed
        vm.prank(centralRegistry.daoAddress());
        oracleManager.setDeviationBounds(_WETH_ADDRESS, 241, 176);
        (uint16 badAfter, uint16 cautionAfter) = oracleManager.assetPricingConfig(_WETH_ADDRESS);
        assertEq(uint256(badAfter), 10000 + 241);
        assertEq(uint256(cautionAfter), 10000 + 176);
    }

    function test_dualFeedErrorCodes() public {

        // USDC: set second adaptor USD feed to deviate into CAUTION then BAD_SOURCE
        MockV3Aggregator mockedUsdc = new MockV3Aggregator(8, 1e8);
        dualChainlinkAdaptor.addAsset(_USDC_ADDRESS, true, address(mockedUsdc), 0, 100);

        // USDC: caution 1.30%, bad 1.80%

        // under caution
        mockedUsdc.updateAnswer(1.01e8);
        (, uint256 errUsdc) = oracleManager.getPrice(_USDC_ADDRESS, true, true);
        assertEq(errUsdc, 0);

        // Within caution and below bad (1.31%)
        mockedUsdc.updateAnswer(1.0131e8);
        (, errUsdc) = oracleManager.getPrice(_USDC_ADDRESS, true, true);
        assertEq(errUsdc, 1);

        // Above BAD_SOURCE (1.90%)
        mockedUsdc.updateAnswer(1.0190e8);
        (, errUsdc) = oracleManager.getPrice(_USDC_ADDRESS, true, true);
        assertEq(errUsdc, 2);

        (, int256 baseEthPrice, , , ) = IChainlink(_CHAINLINK_ETH_USD).latestRoundData();
        MockV3Aggregator mockedEthUsd = new MockV3Aggregator(8, baseEthPrice);
        dualChainlinkAdaptor.addAsset(_WETH_ADDRESS, true, address(mockedEthUsd), 0, 100);

        // WETH: caution 1.40%, bad 2.00%

        // Update price to 1.31% of base price, under caution
        mockedEthUsd.updateAnswer((baseEthPrice * int256(10131)) / int256(10000));
        (, uint256 errEth) = oracleManager.getPrice(_WETH_ADDRESS, true, true);
        assertEq(errEth, 0);

        // Update price to 1.41% of base price, above caution and below bad
        mockedEthUsd.updateAnswer((baseEthPrice * int256(10141)) / int256(10000));
        (, errEth) = oracleManager.getPrice(_WETH_ADDRESS, true, true);
        assertEq(errEth, 1);

        // Update price to 2.1% of base price, above bad
        mockedEthUsd.updateAnswer((baseEthPrice * int256(10210)) / int256(10000));
        (, errEth) = oracleManager.getPrice(_WETH_ADDRESS, true, true);
        assertEq(errEth, 2);
    }

}