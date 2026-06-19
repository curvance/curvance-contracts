// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseOracleManager } from "../TestBaseOracleManager.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IChainlink } from "contracts/interfaces/external/chainlink/IChainlink.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { console2 } from "forge-std/console2.sol";
import { VaultAggregator } from "contracts/oracles/adaptors/wrappedAggregators/VaultAggregator.sol";
import { BaseWrappedAggregator } from "contracts/oracles/adaptors/wrappedAggregators/BaseWrappedAggregator.sol";
import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { BAD_SOURCE } from "contracts/libraries/ConstantsLib.sol";

// Can view tests in TestWstETHAggregator.t.sol, TestSavingsDaiAggregator.t.sol, TestStakedFraxAggregator.t.sol 
// that use vm.mockCall to set the decimals of the asset.

// The vault share's decimals is 18 while the asset's decimals (USDC) is 6.
contract MockVaultA is ERC4626 {
    constructor(address asset) ERC20("MockVault", "MVT") ERC4626(IERC20(asset)) {}


    function _decimalsOffset() internal view override returns (uint8) {
        return 12;
    }
}
contract TestVaultAggregatorDecimals is TestBaseOracleManager {
    MockVaultA vaultA;

    function setUp() public virtual override {
        super.setUp();
    }

    function test_checkPrice_VaultShareDecimals18AssetDecimal6() public {
        _deployVaultA();
        console2.log("==== test_checkPrice_VaultShareDecimals18AssetDecimal6 ====");
        console2.log("_CHAINLINK_USDC_USD = ", _CHAINLINK_USDC_USD);
        VaultAggregator vaultAgg = new VaultAggregator(address(vaultA), _USDC_ADDRESS, _CHAINLINK_USDC_USD, "100");
        console2.log("vaultAgg's decimals = ", vaultAgg.decimals());

        (, int256 price,, uint256 updatedAt, ) = vaultAgg.latestRoundData();
        console2.log("vaultAgg's price = ", price);

        // expected = assetPrice * exchangeRate / 10 ** assetDecimals
        (, int256 assetPrice, , , ) = IChainlink(_CHAINLINK_USDC_USD).latestRoundData();
        uint256 exchangeRate = vaultA.convertToAssets(10 ** vaultA.decimals());
        uint256 assetDecimals = ERC20(vaultA.asset()).decimals();
        int256 expected = int256((uint256(assetPrice) * exchangeRate) / (10 ** assetDecimals));

        assertEq(price, expected);
    }

    function test_checkPrice_VaultAggregatorZeroExchangeRateBubblesBadSource()
        public
    {
        VaultAggregator vaultAgg = _addVaultAggregatorSupport();

        vm.mockCall(
            address(vaultA),
            abi.encodeWithSelector(
                ERC4626.convertToAssets.selector,
                10 ** vaultA.decimals()
            ),
            abi.encode(uint256(0))
        );

        (uint256 price, uint256 errorCode) =
            oracleManager.getPrice(address(vaultA), true, false);

        assertEq(price, 0);
        assertEq(errorCode, BAD_SOURCE);
        assertEq(address(vaultAgg.vault()), address(vaultA));
    }

    function test_checkPrice_VaultAggregatorFutureUnderlyingBubblesBadSource()
        public
    {
        _addVaultAggregatorSupport();

        uint256 futureTimestamp = block.timestamp + 1;
        vm.mockCall(
            _CHAINLINK_USDC_USD,
            abi.encodeWithSelector(IChainlink.latestRoundData.selector),
            abi.encode(
                uint80(1),
                int256(1e8),
                futureTimestamp,
                futureTimestamp,
                uint80(1)
            )
        );

        (uint256 price, uint256 errorCode) =
            oracleManager.getPrice(address(vaultA), true, false);

        assertEq(price, 0);
        assertEq(errorCode, BAD_SOURCE);
    }

    function test_checkPrice_VaultAggregatorConvertToAssetsRevertFailsClosed()
        public
    {
        _addVaultAggregatorSupport();

        vm.mockCallRevert(
            address(vaultA),
            abi.encodeWithSelector(
                ERC4626.convertToAssets.selector,
                10 ** vaultA.decimals()
            ),
            abi.encode("convertToAssets failed")
        );

        vm.expectRevert();
        oracleManager.getPrice(address(vaultA), true, false);
    }

    function test_checkPrice_VaultAggregatorAssetDriftBubblesBadSource()
        public
    {
        VaultAggregator vaultAgg = _addVaultAggregatorSupport();

        vm.mockCall(
            address(vaultA),
            abi.encodeWithSelector(ERC4626.asset.selector),
            abi.encode(address(0x1234))
        );

        (, int256 directAnswer,,,) = vaultAgg.latestRoundData();
        assertEq(directAnswer, 0);

        (uint256 price, uint256 errorCode) =
            oracleManager.getPrice(address(vaultA), true, false);

        assertEq(price, 0);
        assertEq(errorCode, BAD_SOURCE);
    }

    function test_checkPrice_VaultAggregatorAssetDriftGetRoundDataReturnsZero()
        public
    {
        VaultAggregator vaultAgg = _addVaultAggregatorSupport();

        (uint80 latestRoundId,,,,) = vaultAgg.latestRoundData();

        vm.mockCall(
            address(vaultA),
            abi.encodeWithSelector(ERC4626.asset.selector),
            abi.encode(address(0x1234))
        );

        (uint80 roundId, int256 roundAnswer,,,) = vaultAgg.getRoundData(latestRoundId);
        assertEq(roundId, latestRoundId);
        assertEq(roundAnswer, 0);
    }

    function test_checkPrice_VaultAggregatorAssetDriftSkipsExchangeRate()
        public
    {
        VaultAggregator vaultAgg = _addVaultAggregatorSupport();

        vm.mockCall(
            address(vaultA),
            abi.encodeWithSelector(ERC4626.asset.selector),
            abi.encode(address(0x1234))
        );
        vm.mockCallRevert(
            address(vaultA),
            abi.encodeWithSelector(
                ERC4626.convertToAssets.selector,
                10 ** vaultA.decimals()
            ),
            abi.encode("convertToAssets should not be called")
        );

        (, int256 directAnswer,,,) = vaultAgg.latestRoundData();
        assertEq(directAnswer, 0);

        (uint256 price, uint256 errorCode) =
            oracleManager.getPrice(address(vaultA), true, false);

        assertEq(price, 0);
        assertEq(errorCode, BAD_SOURCE);
    }

    function test_constructor_VaultAggregatorRejectsInvalidVaultConfig()
        public
    {
        _deployVaultA();

        vm.expectRevert(BaseWrappedAggregator.BaseWrappedAggregator__InvalidConfig.selector);
        new VaultAggregator(address(vaultA), _DAI_ADDRESS, _CHAINLINK_USDC_USD, "100");
    }


    function _deployVaultA() internal {
        console2.log("==== _deployVaultA ====");
        // The vault A share's decimals is 18 while the asset's decimals (USDC) is 6.
        vaultA = new MockVaultA(address(usdc));
        console2.log("vault's decimals = ", vaultA.decimals());
        console2.log("vault's asset decimals = ", ERC20(vaultA.asset()).decimals());

        vm.startPrank(user1);
        _prepareUSDC(user1, 1000e6);
        usdc.approve(address(vaultA), 1000e6);
        vaultA.deposit(1000e6, user1);

        // Assume that the total assets of the vault increase from 1000 to 2000 due to earning
        _prepareUSDC(address(vaultA), 2000e6);
        vm.stopPrank();

        console2.log("user1's vault share balance = ", vaultA.balanceOf(user1)); // 1000e18
        console2.log("vault's total supply = ", vaultA.totalSupply());
        console2.log("vault's total asset = ", vaultA.totalAssets());
    }

    function _addVaultAggregatorSupport()
        internal
        returns (VaultAggregator vaultAgg)
    {
        _deployVaultA();

        vaultAgg = new VaultAggregator(
            address(vaultA),
            _USDC_ADDRESS,
            _CHAINLINK_USDC_USD,
            "100"
        );

        chainlinkAdaptor =
            new ChainlinkAdaptor(ICentralRegistry(address(centralRegistry)));
        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));
        chainlinkAdaptor.addAsset(address(vaultA), true, address(vaultAgg), 0);
        oracleManager.addAssetPricingAdaptor(
            address(vaultA),
            address(chainlinkAdaptor),
            100,
            50,
            100,
            50
        );
    }
}
