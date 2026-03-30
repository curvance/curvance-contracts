// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { ProtocolManagerDeployment } from "contracts/architecture/ProtocolManagerDeployment.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

contract TestProtocolManagerDeployment is TestBaseMarketIsolated {
    ProtocolManagerDeployment public deploymentManager;

    address public constant WMON_ADDRESS =
        0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;

    BorrowableCToken public borrowableCUSDC_MONAD;
    BorrowableCToken public borrowableCWMON;

    uint256 constant BASE_UNDERLYING_RESERVE = 77777;

    /// @dev Sets up cTokens and oracles but does NOT list tokens.
    ///      Listing is the deployment manager's job.
    function setUp() public virtual override {
        _fork("MON_NODE_URI_MONAD_MAINNET");

        _initMainConstantVariables();

        _deployCentralRegistry();
        _deployCVE();
        _deployRewardManager();
        _deployVeCVE();
        _deployGaugeManager();
        _deployMarketManager();
        _deployOracleManager();

        borrowableCUSDC_MONAD = _deployBorrowableCToken(_USDC_ADDRESS);
        borrowableCWMON = _deployBorrowableCToken(WMON_ADDRESS);

        MockV3Aggregator chainlinkUSDC_USD = new MockV3Aggregator(8, 1e8);
        address chainlinkWMON_USD =
            0xBcD78f76005B7515837af6b50c7C52BCf73822fb;

        ChainlinkAdaptor chainlinkAdaptor = new ChainlinkAdaptor(
            ICentralRegistry(address(centralRegistry))
        );

        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));

        chainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            true,
            address(chainlinkUSDC_USD),
            0
        );
        chainlinkAdaptor.addAsset(
            WMON_ADDRESS,
            true,
            chainlinkWMON_USD,
            0
        );

        oracleManager.addAssetPricingAdaptor(
            _USDC_ADDRESS,
            address(chainlinkAdaptor),
            100,
            50,
            100,
            50
        );
        oracleManager.addAssetPricingAdaptor(
            WMON_ADDRESS,
            address(chainlinkAdaptor),
            100,
            50,
            100,
            50
        );

        oracleManager.addCTokenSupport(address(borrowableCUSDC_MONAD));
        oracleManager.addCTokenSupport(address(borrowableCWMON));

        // Deploy the deployment manager with address(this) as owner.
        deploymentManager = new ProtocolManagerDeployment(
            ICentralRegistry(address(centralRegistry)),
            address(this)
        );

        // Grant market permissions to the deployment manager.
        centralRegistry.addMarketPermissions(address(deploymentManager));

        // Fund this contract with underlying assets for initialization.
        deal(_USDC_ADDRESS, address(this), BASE_UNDERLYING_RESERVE);
        deal(WMON_ADDRESS, address(this), BASE_UNDERLYING_RESERVE);

        // Approve the deployment manager to pull underlying.
        IERC20(_USDC_ADDRESS).approve(
            address(deploymentManager),
            BASE_UNDERLYING_RESERVE
        );
        IERC20(WMON_ADDRESS).approve(
            address(deploymentManager),
            BASE_UNDERLYING_RESERVE
        );
    }

    /// HELPER FUNCTIONS ///

    function _getBasicTokenConfig(
        address cToken,
        uint256 collateralCap,
        uint256 debtCap
    ) internal pure returns (MarketManagerIsolated.TokenConfig memory config) {
        config.cToken = cToken;
        config.collRatio = 7000;
        config.collReqSoft = 4000;
        config.collReqHard = 3000;
        config.liqIncBase = 1000;
        config.liqIncHard = 1500;
        config.liqIncMin = 10;
        config.liqIncMax = 2000;
        config.closeFactorBase = 2000;
        config.closeFactorMin = 2000;
        config.closeFactorMax = 5000;
        config.collateralCap = collateralCap;
        config.debtCap = debtCap;
    }

    /// TESTS ///

    function test_deployMarket_success() public {
        MarketManagerIsolated.TokenConfig memory config0 = _getBasicTokenConfig(
            address(borrowableCWMON),
            1_000_000e18,
            0
        );
        MarketManagerIsolated.TokenConfig memory config1 = _getBasicTokenConfig(
            address(borrowableCUSDC_MONAD),
            0,
            1_000_000e6
        );

        deploymentManager.deployMarket(
            address(marketManagerIsolated),
            address(borrowableCWMON),
            address(borrowableCUSDC_MONAD),
            config0,
            config1
        );

        // Verify tokens are listed.
        assertTrue(marketManagerIsolated.isListed(address(borrowableCWMON)));
        assertTrue(
            marketManagerIsolated.isListed(address(borrowableCUSDC_MONAD))
        );

        // Verify minting is paused on both tokens.
        (bool mintPaused0, , ) = marketManagerIsolated.actionsPaused(
            address(borrowableCWMON)
        );
        assertTrue(mintPaused0, "token0 mint should be paused");

        (bool mintPaused1, , ) = marketManagerIsolated.actionsPaused(
            address(borrowableCUSDC_MONAD)
        );
        assertTrue(mintPaused1, "token1 mint should be paused");

        // Verify token configs were set (check collateral caps as proxy).
        assertEq(
            marketManagerIsolated.collateralCaps(address(borrowableCWMON)),
            1_000_000e18
        );
        assertEq(
            marketManagerIsolated.debtCaps(address(borrowableCUSDC_MONAD)),
            1_000_000e6
        );

        // Verify underlying was consumed (this contract should have 0 left).
        assertEq(IERC20(_USDC_ADDRESS).balanceOf(address(this)), 0);
        assertEq(IERC20(WMON_ADDRESS).balanceOf(address(this)), 0);
    }

    function test_deployMarket_revertsUnauthorized() public {
        MarketManagerIsolated.TokenConfig memory config0 = _getBasicTokenConfig(
            address(borrowableCWMON),
            1_000_000e18,
            0
        );
        MarketManagerIsolated.TokenConfig memory config1 = _getBasicTokenConfig(
            address(borrowableCUSDC_MONAD),
            0,
            1_000_000e6
        );

        address unauthorized = address(0xdead);
        vm.prank(unauthorized);
        vm.expectRevert(
            ProtocolManagerDeployment
                .ProtocolManagerDeployment__Unauthorized
                .selector
        );
        deploymentManager.deployMarket(
            address(marketManagerIsolated),
            address(borrowableCWMON),
            address(borrowableCUSDC_MONAD),
            config0,
            config1
        );
    }

    function test_deployMarket_revertsMismatchedConfig() public {
        MarketManagerIsolated.TokenConfig memory config0 = _getBasicTokenConfig(
            address(borrowableCWMON),
            1_000_000e18,
            0
        );
        // config1 has wrong cToken address.
        MarketManagerIsolated.TokenConfig memory config1 = _getBasicTokenConfig(
            address(0xbeef),
            0,
            1_000_000e6
        );

        vm.expectRevert(
            ProtocolManagerDeployment
                .ProtocolManagerDeployment__Unauthorized
                .selector
        );
        deploymentManager.deployMarket(
            address(marketManagerIsolated),
            address(borrowableCWMON),
            address(borrowableCUSDC_MONAD),
            config0,
            config1
        );
    }

    function test_deployMarket_correctTokensListedArray() public {
        MarketManagerIsolated.TokenConfig memory config0 = _getBasicTokenConfig(
            address(borrowableCWMON),
            1_000_000e18,
            0
        );
        MarketManagerIsolated.TokenConfig memory config1 = _getBasicTokenConfig(
            address(borrowableCUSDC_MONAD),
            0,
            1_000_000e6
        );

        deploymentManager.deployMarket(
            address(marketManagerIsolated),
            address(borrowableCWMON),
            address(borrowableCUSDC_MONAD),
            config0,
            config1
        );

        address[] memory listed = marketManagerIsolated.queryTokensListed();
        assertEq(listed.length, 2);
        assertEq(listed[0], address(borrowableCWMON));
        assertEq(listed[1], address(borrowableCUSDC_MONAD));
    }
}
