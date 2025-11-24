// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IChainlink } from "contracts/interfaces/external/chainlink/IChainlink.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { console2 } from "forge-std/console2.sol";
import { VaultAggregator } from "contracts/oracles/adaptors/wrappedAggregators/VaultAggregator.sol";
import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

// Can view tests in TestWstETHAggregator.t.sol, TestSavingsDaiAggregator.t.sol, TestStakedFraxAggregator.t.sol 
// that use vm.mockCall to set the decimals of the asset.

// The vault share's decimals is 18 while the asset's decimals (USDC) is 6.
contract MockVaultA is ERC4626 {
    constructor(address asset) ERC20("MockVault", "MVT") ERC4626(IERC20(asset)) {}


    function _decimalsOffset() internal view override returns (uint8) {
        return 12;
    }
}
contract TestVaultAggregatorDecimals is TestBaseMarketIsolated {
    MockVaultA vaultA;

    function setUp() public virtual override {
        _fork(18031848);
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

        console2.log("user1's vault share balance = ", vaultA.balanceOf(user1)); // 1000e18
        console2.log("vault's total supply = ", vaultA.totalSupply());
        console2.log("vault's total asset = ", vaultA.totalAssets());
    }
}