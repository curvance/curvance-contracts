// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { ProtocolManager } from "contracts/architecture/ProtocolManager.sol";
import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

contract TestProtocolManagerBase is TestBaseMarketIsolated {

    ProtocolManager public protocolManager;

    address public constant WMON_ADDRESS = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;

    BorrowableCToken public borrowableCUSDC_MONAD;
    BorrowableCToken public borrowableCWMON;
    
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
        // use the real Chainlink feed on Monad mainnet
        address chainlinkWMON_USD = 0xBcD78f76005B7515837af6b50c7C52BCf73822fb;

        ChainlinkAdaptor chainlinkAdaptor = new ChainlinkAdaptor(ICentralRegistry(address(centralRegistry)));

        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));

        chainlinkAdaptor.addAsset(_USDC_ADDRESS, true, address(chainlinkUSDC_USD), 0);
        chainlinkAdaptor.addAsset(WMON_ADDRESS, true, chainlinkWMON_USD, 0);

        oracleManager.addAssetPricingAdaptor(_USDC_ADDRESS, address(chainlinkAdaptor), 100, 50, 100, 50);
        oracleManager.addAssetPricingAdaptor(WMON_ADDRESS, address(chainlinkAdaptor), 100, 50, 100, 50);

        oracleManager.addCTokenSupport(address(borrowableCUSDC_MONAD));
        oracleManager.addCTokenSupport(address(borrowableCWMON));

        deal(_USDC_ADDRESS, address(this), 77777);
        IERC20(_USDC_ADDRESS).approve(address(borrowableCUSDC_MONAD), type(uint256).max);

        deal(WMON_ADDRESS, address(this), 77777);
        IERC20(WMON_ADDRESS).approve(address(borrowableCWMON), type(uint256).max);

        marketManagerIsolated.listTokens(address(borrowableCUSDC_MONAD), address(borrowableCWMON));

        _setCTokenConfigBasic(address(borrowableCWMON), 1_000_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC_MONAD), 0, 1_000_000e6);

    }

    /// HELPER FUNCTIONS ///

    /// @notice Returns a valid PeriodLimits struct with values within bounds
    /// @dev Price guard limits are set to 1e17 ($0.10 or 10%) which is reasonable for
    ///      adjustments to existing stablecoin/ratio guards. Initial guards are expected
    ///      to be set by admin before ProtocolManager takes control.
    function _getValidLimits() internal pure returns (ProtocolManager.PeriodLimits memory) {
        return ProtocolManager.PeriodLimits({
            collRatioLimit: 100,
            marginSoftLimit: 50,
            marginHardLimit: 100,
            collateralCapLimit: 1_000_000e18,
            baseInterestRateLimit: 200,
            debtCapLimit: 1_000_000e18,
            vertexInterestRateLimit: 300,
            vertexStartLimit: 400,
            adjustmentVelocityLimit: 50,
            decayPerAdjustmentLimit: 10,
            vertexMultiplierMaxLimit: 10000,
            basePriceUSDLimit: 1e17,
            minPriceUSDLimit: 1e17,
            basePriceNativeLimit: 1e17,
            minPriceNativeLimit: 1e17
        });
    }

    /// @notice Returns a default PermsConfig with all permissions enabled
    function _getDefaultPermsConfig() internal pure returns (ProtocolManager.PermsConfig memory) {
        return ProtocolManager.PermsConfig({
            canModifyPriceGuards: true,
            canModifyTokenConfig: true,
            canModifyIRM: true,
            canUnpause: true,
            canModifyMintStatus: true,
            canModifyCollateralizationStatus: true,
            canModifyBorrowStatus: true,
            canModifyLiquidationStatus: true,
            canModifyRedeemStatus: true,
            canModifyTransferStatus: true,
            canModifyPositionManagers: true
        });
    }

    /// @notice Warps to the final 1/3 of the current period where updateManagementConfig is allowed
    /// @dev Period duration is 604800 seconds (1 week), 2/3 of that is 403200 seconds
    function _warpToValidManagementConfigWindow() internal {
        uint256 unixStartTimestamp = 1766966400;
        uint256 periodDuration = 604800;
        uint256 currentPeriod = (block.timestamp - unixStartTimestamp) / periodDuration;
        uint256 periodStart = unixStartTimestamp + (currentPeriod * periodDuration);
        uint256 validTime = periodStart + (periodDuration * 2) / 3 + 1;
        vm.warp(validTime);
    }
}