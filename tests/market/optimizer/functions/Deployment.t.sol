// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { TestBaseLendingOptimizer } from "../TestBaseLendingOptimizer.sol";
import { LendingOptimizer } from "contracts/market/optimizer/LendingOptimizer.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IERC165 } from "contracts/interfaces/IERC165.sol";
import { IPluginDelegable } from "contracts/interfaces/IPluginDelegable.sol";
import { ERC4626 } from "contracts/libraries/external/ERC4626.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { WAD, BPS } from "contracts/libraries/ConstantsLib.sol";

contract TestLendingOptimizerDeployment is TestBaseLendingOptimizer {

    LendingOptimizer optimizer;

    function setUp() public override {
        super.setUp();
    }

    function test_lendingOptimizer_deployment_success_singleMarket() public {
        address[] memory approvedCTokens = new address[](1);
        approvedCTokens[0] = cUSDC_WMON_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](1);
        allocationCapsBps[0] = 10_000; // 100% allocation

        uint256 feeBps = 2_000; // 20% fee

        optimizer = new LendingOptimizer(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            feeBps
        );

        // Verify immutable state
        assertEq(address(optimizer.centralRegistry()), address(liveCentralRegistry));
        assertEq(optimizer.asset(), USDC_MONAD);

        // Verify ERC20 metadata
        assertEq(optimizer.name(), "Curvance USDC Optimizer");
        assertEq(optimizer.symbol(), "cUSDC OPTI");
        assertEq(optimizer.decimals(), IERC20(USDC_MONAD).decimals());

        // Verify constants
        assertEq(optimizer.MAX_FEE_BPS(), 5000);
        assertEq(optimizer.MAX_MARKETS(), 6);

        // Verify storage state
        assertEq(optimizer.fee(), feeBps * 1e14);
        assertEq(optimizer.exchangeRateHighWatermark(), WAD);
        assertEq(optimizer.numApprovedMarkets(), 1);

        // Verify approved markets
        address[] memory markets = optimizer.getApprovedMarkets();
        assertEq(markets.length, 1);
        assertEq(markets[0], cUSDC_WMON_MARKET);
        assertEq(optimizer.approvedCTokensList(0), cUSDC_WMON_MARKET);

        // Verify allocation caps (10000 BPS = 1e18 WAD)
        assertEq(optimizer.allocationCaps(cUSDC_WMON_MARKET), 10_000 * 1e14);

        // Verify ERC4626 state (before initialization)
        assertEq(optimizer.totalSupply(), 0);
        assertEq(optimizer.totalAssets(), 0);

        // Verify not initialized yet (implicit check via totalSupply)
        assertEq(optimizer.totalSupply(), 0);

        // Verify ERC165 interface support
        assertTrue(optimizer.supportsInterface(type(IERC165).interfaceId));
        assertTrue(optimizer.supportsInterface(type(IPluginDelegable).interfaceId));
        assertTrue(optimizer.supportsInterface(type(ERC4626).interfaceId));
    }

    function test_deployment_success_multipleMarkets() public {
        address[] memory approvedCTokens = new address[](3);
        approvedCTokens[0] = cUSDC_WMON_MARKET;
        approvedCTokens[1] = cUSDC_WBTC_MARKET;
        approvedCTokens[2] = cUSDC_WETH_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](3);
        allocationCapsBps[0] = 6_000; // 60%
        allocationCapsBps[1] = 5_000; // 50%
        allocationCapsBps[2] = 2_000; // 20%
        // Total = 130% which is valid (>= 100%)

        uint256 feeBps = 1_000; // 10% fee

        optimizer = new LendingOptimizer(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            feeBps
        );

        // Verify storage state
        assertEq(optimizer.fee(), feeBps * 1e14);
        assertEq(optimizer.numApprovedMarkets(), 3);

        // Verify all approved markets
        address[] memory markets = optimizer.getApprovedMarkets();
        assertEq(markets.length, 3);
        assertEq(markets[0], cUSDC_WMON_MARKET);
        assertEq(markets[1], cUSDC_WBTC_MARKET);
        assertEq(markets[2], cUSDC_WETH_MARKET);

        // Verify allocation caps
        assertEq(optimizer.allocationCaps(cUSDC_WMON_MARKET), 6_000 * 1e14);
        assertEq(optimizer.allocationCaps(cUSDC_WBTC_MARKET), 5_000 * 1e14);
        assertEq(optimizer.allocationCaps(cUSDC_WETH_MARKET), 2_000 * 1e14);

        // Verify non-approved market has 0 cap
        assertEq(optimizer.allocationCaps(address(1)), 0);
    }

    function test_deployment_success_zeroFee() public {
        address[] memory approvedCTokens = new address[](1);
        approvedCTokens[0] = cUSDC_WMON_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](1);
        allocationCapsBps[0] = 10_000;

        uint256 feeBps = 0; // No fee

        optimizer = new LendingOptimizer(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            feeBps
        );

        assertEq(optimizer.fee(), 0);
    }

    function test_deployment_success_maxFee() public {
        address[] memory approvedCTokens = new address[](1);
        approvedCTokens[0] = cUSDC_WMON_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](1);
        allocationCapsBps[0] = 10_000;

        uint256 feeBps = 5_000; // 50% max fee

        optimizer = new LendingOptimizer(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            feeBps
        );

        assertEq(optimizer.fee(), 5_000 * 1e14);
    }

    function test_deployment_fail_whenFeeTooHigh() public {
        address[] memory approvedCTokens = new address[](1);
        approvedCTokens[0] = cUSDC_WMON_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](1);
        allocationCapsBps[0] = 10_000;

        uint256 feeBps = 5_001; // 50.01% - exceeds max

        vm.expectRevert(LendingOptimizer.LendingOptimizer__FeeTooHigh.selector);
        new LendingOptimizer(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            feeBps
        );
    }

    function test_deployment_fail_whenArrayLengthMismatch() public {
        address[] memory approvedCTokens = new address[](2);
        approvedCTokens[0] = cUSDC_WMON_MARKET;
        approvedCTokens[1] = cUSDC_WBTC_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](1);
        allocationCapsBps[0] = 10_000;

        vm.expectRevert(LendingOptimizer.LendingOptimizer__ArrayLengthMismatch.selector);
        new LendingOptimizer(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            1_000
        );
    }

    function test_deployment_fail_whenTooManyMarkets() public {
        address[] memory approvedCTokens = new address[](7);
        for (uint256 i = 0; i < 7; i++) {
            approvedCTokens[i] = cUSDC_WMON_MARKET;
        }

        uint256[] memory allocationCapsBps = new uint256[](7);
        for (uint256 i = 0; i < 7; i++) {
            allocationCapsBps[i] = 2_000;
        }

        vm.expectRevert(LendingOptimizer.LendingOptimizer__TooManyMarkets.selector);
        new LendingOptimizer(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            1_000
        );
    }

    function test_deployment_fail_whenInsufficientAllocationCaps() public {
        address[] memory approvedCTokens = new address[](2);
        approvedCTokens[0] = cUSDC_WMON_MARKET;
        approvedCTokens[1] = cUSDC_WBTC_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](2);
        allocationCapsBps[0] = 4_000; // 40%
        allocationCapsBps[1] = 5_000; // 50%
        // Total = 90% which is < 100%

        vm.expectRevert(LendingOptimizer.LendingOptimizer__InsufficientAllocationCaps.selector);
        new LendingOptimizer(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            1_000
        );
    }

    function test_deployment_fail_whenInvalidUnderlying() public {
        // Try to deploy with WETH as underlying but using USDC markets
        address WETH_MONAD = 0xEE8c0E9f1BFFb4Eb878d8f15f368A02a35481242;

        address[] memory approvedCTokens = new address[](1);
        approvedCTokens[0] = cUSDC_WMON_MARKET; // This is a USDC market

        uint256[] memory allocationCapsBps = new uint256[](1);
        allocationCapsBps[0] = 10_000;

        vm.expectRevert(LendingOptimizer.LendingOptimizer__InvalidUnderlying.selector);
        new LendingOptimizer(
            IERC20(WETH_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            1_000
        );
    }

    function test_deployment_fail_whenInvalidMarketManager() public {
        // Create a mock cToken with invalid market manager
        // This would require deploying a mock - skipping for now
        // as it requires more complex setup
    }

    function test_deployment_verifyPluginDelegableInherited() public {
        address[] memory approvedCTokens = new address[](1);
        approvedCTokens[0] = cUSDC_WMON_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](1);
        allocationCapsBps[0] = 10_000;

        optimizer = new LendingOptimizer(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            1_000
        );

        // Verify PluginDelegable functions are available
        address testDelegate = address(0x1234);

        // Initially should not be a delegate
        assertFalse(optimizer.isDelegate(address(this), testDelegate));

        // Check delegation is not disabled by default for this address
        bool delegationDisabled = optimizer.checkNewDelegationDisabled(address(this));

        // Set delegate approval (if delegation not disabled)
        if (!delegationDisabled) {
            optimizer.setDelegateApproval(testDelegate, true);
            assertTrue(optimizer.isDelegate(address(this), testDelegate));

            // Remove delegate approval
            optimizer.setDelegateApproval(testDelegate, false);
            assertFalse(optimizer.isDelegate(address(this), testDelegate));
        }
    }

    function test_deployment_verifyExchangeRateFunctions() public {
        address[] memory approvedCTokens = new address[](1);
        approvedCTokens[0] = cUSDC_WMON_MARKET;

        uint256[] memory allocationCapsBps = new uint256[](1);
        allocationCapsBps[0] = 10_000;

        optimizer = new LendingOptimizer(
            IERC20(USDC_MONAD),
            liveCentralRegistry,
            approvedCTokens,
            allocationCapsBps,
            1_000
        );

        // With no deposits, exchange rate should be WAD (1e18)
        assertEq(optimizer.exchangeRate(), WAD);
        assertEq(optimizer.exchangeRateUpdated(), WAD);
    }
}
