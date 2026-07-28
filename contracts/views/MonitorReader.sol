// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {WAD, CAUTION, BAD_SOURCE} from "contracts/libraries/ConstantsLib.sol";

import {ICToken} from "contracts/interfaces/ICToken.sol";
import {IBorrowableCToken} from "contracts/interfaces/IBorrowableCToken.sol";
import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";
import {IERC20} from "contracts/interfaces/IERC20.sol";
import {ILendingOptimizer} from "contracts/interfaces/ILendingOptimizer.sol";
import {IMarketManager} from "contracts/interfaces/IMarketManager.sol";
import {IOracleManager} from "contracts/interfaces/IOracleManager.sol";

/// @title MonitorReader
/// @notice Stateless Curvance diagnostics encoded for Blockaid integer metrics.
/// @dev
/// HOW TO MONITOR
///
/// This contract is designed for two Blockaid contract-call monitors. Each
/// function returns exactly five integer metrics:
///
/// - `criticalSignals`:
///   [0] Wiring
///   [1] Token Accounting
///   [2] Reserve Backing
///   [3] Borrow Accounting
///   [4] Optimizer Critical
/// - `advisorySignals`:
///   [0] Oracle Price Zero
///   [1] Oracle Degraded
///   [2] Collateral or Cap Warning
///   [3] Optimizer Warning
///   [4] Monitor Reader Could Not Verify
///
/// Give each return field the human-readable name above and alert when any
/// selected value is nonzero. `criticalSignals` contains pause-eligible
/// invariant failures. `advisorySignals` is alert-only; its fifth field means
/// the reader could not complete a read, not that an invariant was proven
/// broken.
///
/// Pass the deployed CentralRegistry and the same explicit optimizer list to
/// both calls. MarketManagers, cTokens, and the OracleManager are discovered
/// from the registry. Optimizers are explicit because they have no central
/// registry. Duplicate optimizer inputs are ignored. Only the first 32 are
/// checked; advisory read-failure code 98 reports a longer input list.
///
/// Borrow-specific cToken reads run only when that cToken's debt cap is
/// nonzero. An empty registered MarketManager is treated as provisioning and
/// is not a monitor-facing critical failure. Optimizer allocation caps are
/// validated as configuration, but natural position drift above a cap is not
/// a warning because the optimizer enforces caps when applying a rebalance.
///
/// The critical scan omits advisory-only collateral and oracle-price reads.
/// The advisory scan still performs the full verification surface, but caches
/// one oracle result per underlying asset. Public diagnostic functions always
/// return the complete, uncached per-cToken status.
///
/// HOW A SIGNAL IS CONSTRUCTED
///
/// A return value of zero means that no finding was recorded for that return
/// field. A nonzero value summarizes one signal family. Scanning order is
/// deterministic: registry order, then each MarketManager's listed-token
/// order, followed by optimizer calldata order.
///
/// The signal stores the first recorded subject and finding code, plus the
/// total number of recorded findings in that family. If several findings are
/// present, only the first one is encoded in detail. `affectedCount` can
/// include more than one finding for the same address, so it should be read as
/// a finding count rather than a guaranteed count of unique addresses. The
/// count saturates at `type(uint16).max`.
///
/// When a status has several applicable mask bits, the family-specific helper
/// selects the first documented priority, or the lowest set bit for optimizer
/// families. Therefore `findingCode` always describes `firstSubject`, but does
/// not describe later findings counted by `affectedCount`.
///
/// PACKED LAYOUT AND DECODING
///
/// - bits   0..159: first subject address
/// - bits 160..167: family-specific finding code
/// - bits 168..175: signal family
/// - bits 176..191: recorded finding count
/// - bits 192..199: first subject type
/// - bits 200..207: encoding version
/// - bits 208..255: reserved, currently zero
///
/// Call `decodeSignal(signal)` with the exact integer shown in the incident.
/// The returned tuple is:
/// `(firstSubject, findingCode, family, affectedCount, subjectType,
/// encodingVersion)`.
///
/// The same fields can be decoded manually:
/// - `firstSubject = address(uint160(signal))`
/// - `findingCode = uint8(signal >> 160)`
/// - `family = uint8(signal >> 168)`
/// - `affectedCount = uint16(signal >> 176)`
/// - `subjectType = uint8(signal >> 192)`
/// - `encodingVersion = uint8(signal >> 200)`
///
/// A Foundry CLI example is:
/// `cast call <reader> "decodeSignal(uint256)(address,uint8,uint8,uint16,uint8,uint8)" <signal>`.
/// Use the ABI-decoded tuple rather than attempting to interpret the packed
/// integer as one severity number. Finding codes are scoped to their family;
/// for example, code 1 has a different meaning in families 2, 3, and 6.
///
/// SUBJECT TYPES
///
/// - 1: CentralRegistry
/// - 2: MarketManager
/// - 3: cToken
/// - 4: underlying oracle asset
/// - 5: LendingOptimizer
///
/// SIGNAL FAMILIES AND FINDING CODES
///
/// Family 1, Critical Wiring:
/// - 1 registry argument is zero
/// - 2 registry OracleManager is zero
/// - 3 registry has no MarketManagers
/// - 16 MarketManager is zero
/// - 18 listed cToken is zero
/// - 19 duplicate cToken in a MarketManager list
/// - 20 duplicate MarketManager in the registry
/// - 32 cToken MarketManager is zero
/// - 33 cToken underlying asset is zero
/// - 34 cToken is not listed by its MarketManager
/// - 35 cToken points to a different MarketManager
/// - 36 OracleManager cToken-to-underlying binding is wrong
///
/// Family 2, Critical Token Accounting:
/// - 1 total supply is zero
/// - 2 total assets is zero
/// - 3 exchange rate is zero
/// - 4 converting total supply does not reproduce total assets
///
/// Family 3, Critical Reserve Backing:
/// - 1 debt plus the base reserve exceeds total assets
/// - 2 underlying cash is below assets held plus the base reserve
///
/// Family 4, Critical Borrow Accounting:
/// - 1 last vesting claim is after vesting end
/// - 2 debt index is below 1e18
///
/// Family 5, Critical Optimizer:
/// - 1 optimizer address is zero
/// - 2 underlying asset is zero
/// - 3 approved-market count is zero or above the supported limit
/// - 4 approved cToken is zero
/// - 5 approved cToken is duplicated
/// - 6 allocation cap is zero or above 100%
/// - 7 allocation-cap sum is below 100%
/// - 8 approved cToken is not borrowable
/// - 9 approved cToken underlying differs from optimizer underlying
/// - 10 approved cToken is not listed
/// - 11 optimizer total assets exceed summed positions
/// - 12 total supply is zero
/// - 13 dead shares are zero
/// - 14 exchange rate is zero
/// - 15 converting total supply does not reproduce total assets
///
/// Family 6, Advisory Oracle Price Zero:
/// - 1 price is zero
///
/// Family 7, Advisory Oracle Degraded:
/// - 1 price reports BAD_SOURCE
/// - 2 price reports an unknown error
/// - 3 price reports CAUTION, including PriceGuard
///
/// Family 8, Advisory Collateral or Cap:
/// - 1 posted collateral exceeds live shares
/// - 2 collateral cap is exceeded
/// - 3 debt cap is exceeded
///
/// Family 9, Advisory Optimizer:
/// - 1 exchange rate is below the high-water mark
/// - 2 optimizer minting is paused
///
/// Family 10, Advisory Read Failure:
/// - 1 registry argument is zero
/// - 2 registry MarketManager list could not be read
/// - 3 registry OracleManager could not be read
/// - 16 MarketManager cToken list could not be read
/// - 32 cToken `isBorrowable` could not be read
/// - 33 cToken MarketManager could not be read
/// - 34 cToken underlying asset could not be read
/// - 35 MarketManager listing status could not be read
/// - 36 cToken total supply could not be read
/// - 37 cToken total assets could not be read
/// - 38 cToken dead shares could not be read
/// - 39 cToken posted collateral could not be read
/// - 40 cToken exchange rate could not be read
/// - 41 cToken conversion could not be read
/// - 42 OracleManager cToken binding could not be read
/// - 43 cToken underlying balance could not be read
/// - 44 cToken outstanding debt could not be read
/// - 45 cToken assets held could not be read
/// - 46 cToken yield information could not be read
/// - 47 oracle price could not be read
/// - 48 collateral cap could not be read
/// - 49 debt cap could not be read
/// - 64 optimizer underlying asset could not be read
/// - 65 optimizer approved-market count could not be read
/// - 66 optimizer approved-market configuration could not be read
/// - 67 optimizer allocation cap could not be read
/// - 68 optimizer total assets could not be read
/// - 69 optimizer total supply could not be read
/// - 70 optimizer dead shares could not be read
/// - 71 optimizer exchange rate could not be read
/// - 72 optimizer high-water mark could not be read
/// - 73 optimizer conversion could not be read
/// - 74 optimizer mint-paused state could not be read
/// - 75 optimizer market position could not be read
/// - 96 cToken tracking limit was reached
/// - 97 oracle-asset tracking limit was reached
/// - 98 more optimizer inputs were supplied than can be checked
///
/// MANUAL DIAGNOSTICS
///
/// `checkOracle`, `checkCToken`, `checkMarketCToken`, `checkMarket`, and
/// `checkOptimizer` expose the complete status structs. Their `brokenMask`,
/// `warningMask`, and `readErrorMask` values are bitmasks, not packed signals.
/// Test a condition with `mask & NAMED_CONSTANT != 0`; the public constants
/// below define every bit. The monitor-facing functions intentionally filter
/// and group those masks, so a manual status bit does not always become a
/// Blockaid signal. Use the manual functions when `affectedCount > 1` or when
/// investigating a reader-health alert.
contract MonitorReader {
    /// TYPES ///
    struct OracleStatus {
        uint256 brokenMask;
        uint256 warningMask;
        uint256 readErrorMask;
        uint256 price;
        uint256 errorCode;
    }

    struct CTokenStatus {
        uint256 brokenMask;
        uint256 warningMask;
        uint256 readErrorMask;
        bool isBorrowable;
        address marketManager;
        address underlying;
        uint256 totalSupply;
        uint256 totalAssets;
        uint256 deadShares;
        uint256 marketCollateralPosted;
        uint256 exchangeRate;
        uint256 convertedTotalSupply;
        uint256 underlyingBalance;
        uint256 marketOutstandingDebt;
        uint256 assetsHeld;
        uint256 collateralCap;
        uint256 debtCap;
        uint256 vestingRate;
        uint256 vestingEnd;
        uint256 lastVestingClaim;
        uint256 debtIndex;
        OracleStatus oraclePrice;
    }

    struct MarketStatus {
        uint256 brokenMask;
        uint256 warningMask;
        uint256 readErrorMask;
        address[] cTokens;
        CTokenStatus[] tokenStatus;
    }

    struct OptimizerMarketStatus {
        uint256 brokenMask;
        uint256 warningMask;
        uint256 readErrorMask;
        address cToken;
        address underlying;
        address marketManager;
        uint256 allocationCap;
        uint256 positionShares;
        uint256 positionAssets;
    }

    struct OptimizerStatus {
        uint256 brokenMask;
        uint256 warningMask;
        uint256 readErrorMask;
        address underlying;
        uint256 totalAssets;
        uint256 totalSupply;
        uint256 deadShares;
        uint256 exchangeRate;
        uint256 exchangeRateHighWatermark;
        uint256 convertedTotalSupply;
        uint256 totalPositionAssets;
        uint256 totalAllocationCaps;
        OptimizerMarketStatus[] markets;
    }

    struct SignalAccumulator {
        address firstSubject;
        uint16 affectedCount;
        uint8 findingCode;
        uint8 subjectType;
    }

    struct AdvisoryScanState {
        address[] seenCTokens;
        address[] seenAssets;
        uint256[] oracleCache;
        uint256 seenCTokenCount;
        uint256 seenAssetCount;
        bool cTokenLimitReported;
        bool assetLimitReported;
    }

    /// CONSTANTS ///

    uint256 public constant VERSION = 2;
    uint256 public constant BASE_UNDERLYING_RESERVE = 77_777;
    uint256 public constant CONVERSION_TOLERANCE = 1;
    uint256 public constant MAX_OPTIMIZER_MARKETS = 32;
    uint256 public constant MAX_INPUT_OPTIMIZERS = 32;
    uint256 public constant MAX_TRACKED_CTOKENS = 512;
    uint256 public constant MAX_TRACKED_ORACLE_ASSETS = 512;

    // Packed signal layout:
    // bits   0..159: first affected subject address
    // bits 160..167: family-specific finding code
    // bits 168..175: signal family
    // bits 176..191: number of affected subjects
    // bits 192..199: first subject type
    // bits 200..207: signal encoding version
    // bits 208..255: reserved
    uint8 public constant SIGNAL_ENCODING_VERSION = 1;

    uint8 public constant SUBJECT_CENTRAL_REGISTRY = 1;
    uint8 public constant SUBJECT_MARKET_MANAGER = 2;
    uint8 public constant SUBJECT_CTOKEN = 3;
    uint8 public constant SUBJECT_ASSET = 4;
    uint8 public constant SUBJECT_OPTIMIZER = 5;

    uint8 public constant FAMILY_CRITICAL_WIRING = 1;
    uint8 public constant FAMILY_CRITICAL_TOKEN_ACCOUNTING = 2;
    uint8 public constant FAMILY_CRITICAL_BACKING = 3;
    uint8 public constant FAMILY_CRITICAL_BORROW_ACCOUNTING = 4;
    uint8 public constant FAMILY_CRITICAL_OPTIMIZER = 5;
    uint8 public constant FAMILY_ADVISORY_ORACLE_ZERO = 6;
    uint8 public constant FAMILY_ADVISORY_ORACLE_DEGRADED = 7;
    uint8 public constant FAMILY_ADVISORY_COLLATERAL_OR_CAP = 8;
    uint8 public constant FAMILY_ADVISORY_OPTIMIZER = 9;
    uint8 public constant FAMILY_ADVISORY_READ_FAILURE = 10;

    // cToken broken-mask bits.
    uint256 public constant CTOKEN_BROKEN_MANAGER_ZERO = 1 << 0;
    uint256 public constant CTOKEN_BROKEN_ASSET_ZERO = 1 << 1;
    uint256 public constant CTOKEN_BROKEN_NOT_LISTED = 1 << 2;
    uint256 public constant CTOKEN_BROKEN_MANAGER_MISMATCH = 1 << 3;
    uint256 public constant CTOKEN_BROKEN_ORACLE_BINDING = 1 << 4;
    uint256 public constant CTOKEN_BROKEN_COLLATERAL_SHARES = 1 << 5;
    uint256 public constant CTOKEN_BROKEN_SUPPLY_ZERO = 1 << 6;
    uint256 public constant CTOKEN_BROKEN_TOTAL_ASSETS_ZERO = 1 << 7;
    uint256 public constant CTOKEN_BROKEN_EXCHANGE_RATE_ZERO = 1 << 8;
    uint256 public constant CTOKEN_BROKEN_CONVERSION = 1 << 9;
    uint256 public constant CTOKEN_BROKEN_RESERVE = 1 << 10;
    uint256 public constant CTOKEN_BROKEN_CASH = 1 << 11;
    uint256 public constant CTOKEN_BROKEN_VESTING_CLOCK = 1 << 12;
    uint256 public constant CTOKEN_BROKEN_DEBT_INDEX = 1 << 13;
    uint256 public constant CTOKEN_BROKEN_ORACLE = 1 << 14;

    // cToken warning-mask bits.
    uint256 public constant CTOKEN_WARNING_ORACLE = 1 << 0;
    uint256 public constant CTOKEN_WARNING_COLLATERAL_CAP = 1 << 1;
    uint256 public constant CTOKEN_WARNING_DEBT_CAP = 1 << 2;

    // cToken read-error-mask bits.
    uint256 public constant CTOKEN_READ_IS_BORROWABLE = 1 << 0;
    uint256 public constant CTOKEN_READ_MANAGER = 1 << 1;
    uint256 public constant CTOKEN_READ_ASSET = 1 << 2;
    uint256 public constant CTOKEN_READ_LISTED = 1 << 3;
    uint256 public constant CTOKEN_READ_SUPPLY = 1 << 4;
    uint256 public constant CTOKEN_READ_TOTAL_ASSETS = 1 << 5;
    uint256 public constant CTOKEN_READ_DEAD_SHARES = 1 << 6;
    uint256 public constant CTOKEN_READ_COLLATERAL = 1 << 7;
    uint256 public constant CTOKEN_READ_EXCHANGE_RATE = 1 << 8;
    uint256 public constant CTOKEN_READ_CONVERSION = 1 << 9;
    uint256 public constant CTOKEN_READ_ORACLE_BINDING = 1 << 10;
    uint256 public constant CTOKEN_READ_UNDERLYING_BALANCE = 1 << 11;
    uint256 public constant CTOKEN_READ_DEBT = 1 << 12;
    uint256 public constant CTOKEN_READ_ASSETS_HELD = 1 << 13;
    uint256 public constant CTOKEN_READ_YIELD = 1 << 14;
    uint256 public constant CTOKEN_READ_ORACLE_PRICE = 1 << 15;
    uint256 public constant CTOKEN_READ_COLLATERAL_CAP = 1 << 16;
    uint256 public constant CTOKEN_READ_DEBT_CAP = 1 << 17;

    // Oracle masks.
    uint256 public constant ORACLE_BROKEN_PRICE_ZERO = 1 << 0;
    uint256 public constant ORACLE_BROKEN_BAD_SOURCE = 1 << 1;
    uint256 public constant ORACLE_BROKEN_UNKNOWN_ERROR = 1 << 2;
    uint256 public constant ORACLE_WARNING_CAUTION = 1 << 0;
    uint256 public constant ORACLE_READ_PRICE = 1 << 0;

    // Market masks.
    uint256 public constant MARKET_BROKEN_MANAGER_ZERO = 1 << 0;
    uint256 public constant MARKET_BROKEN_NO_TOKENS = 1 << 1;
    uint256 public constant MARKET_BROKEN_TOKEN_ZERO = 1 << 2;
    uint256 public constant MARKET_BROKEN_DUPLICATE_TOKEN = 1 << 3;
    uint256 public constant MARKET_BROKEN_TOKEN_INVARIANT = 1 << 4;
    uint256 public constant MARKET_WARNING_TOKEN = 1 << 0;
    uint256 public constant MARKET_READ_TOKEN_LIST = 1 << 0;
    uint256 public constant MARKET_READ_TOKEN = 1 << 1;

    // Optimizer broken-mask bits.
    uint256 public constant OPTIMIZER_BROKEN_ADDRESS_ZERO = 1 << 0;
    uint256 public constant OPTIMIZER_BROKEN_ASSET_ZERO = 1 << 1;
    uint256 public constant OPTIMIZER_BROKEN_MARKET_COUNT = 1 << 2;
    uint256 public constant OPTIMIZER_BROKEN_MARKET_ZERO = 1 << 3;
    uint256 public constant OPTIMIZER_BROKEN_DUPLICATE_MARKET = 1 << 4;
    uint256 public constant OPTIMIZER_BROKEN_CAP = 1 << 5;
    uint256 public constant OPTIMIZER_BROKEN_CAP_SUM = 1 << 6;
    uint256 public constant OPTIMIZER_BROKEN_NOT_BORROWABLE = 1 << 7;
    uint256 public constant OPTIMIZER_BROKEN_UNDERLYING = 1 << 8;
    uint256 public constant OPTIMIZER_BROKEN_NOT_LISTED = 1 << 9;
    uint256 public constant OPTIMIZER_BROKEN_ACCOUNTING = 1 << 10;
    uint256 public constant OPTIMIZER_BROKEN_SUPPLY_ZERO = 1 << 11;
    uint256 public constant OPTIMIZER_BROKEN_DEAD_SHARES = 1 << 12;
    uint256 public constant OPTIMIZER_BROKEN_EXCHANGE_RATE = 1 << 13;
    uint256 public constant OPTIMIZER_BROKEN_CONVERSION = 1 << 14;

    // Optimizer warning-mask bits.
    uint256 public constant OPTIMIZER_WARNING_BELOW_HIGH_WATERMARK = 1 << 0;
    uint256 public constant OPTIMIZER_WARNING_MINT_PAUSED = 1 << 1;

    // Optimizer read-error-mask bits.
    uint256 public constant OPTIMIZER_READ_ASSET = 1 << 0;
    uint256 public constant OPTIMIZER_READ_MARKET_COUNT = 1 << 1;
    uint256 public constant OPTIMIZER_READ_MARKET = 1 << 2;
    uint256 public constant OPTIMIZER_READ_CAP = 1 << 3;
    uint256 public constant OPTIMIZER_READ_TOTAL_ASSETS = 1 << 4;
    uint256 public constant OPTIMIZER_READ_SUPPLY = 1 << 5;
    uint256 public constant OPTIMIZER_READ_DEAD_SHARES = 1 << 6;
    uint256 public constant OPTIMIZER_READ_EXCHANGE_RATE = 1 << 7;
    uint256 public constant OPTIMIZER_READ_HIGH_WATERMARK = 1 << 8;
    uint256 public constant OPTIMIZER_READ_CONVERSION = 1 << 9;
    uint256 public constant OPTIMIZER_READ_MINT_PAUSED = 1 << 10;
    uint256 public constant OPTIMIZER_READ_POSITION = 1 << 11;

    /// BLOCKAID FUNCTIONS ///

    /// @notice Returns five packed signals for pause-eligible invariants.
    /// @dev Suggested metric names, in return order:
    ///      Wiring; Token Accounting; Reserve Backing; Borrow Accounting;
    ///      Optimizer Critical. A monitor should alert when any value is > 0.
    function criticalSignals(
        address centralRegistry,
        address[] calldata optimizers
    )
        external
        view
        returns (
            uint256 wiring,
            uint256 tokenAccounting,
            uint256 backing,
            uint256 borrowAccounting,
            uint256 optimizerCritical
        )
    {
        SignalAccumulator[5] memory signals;
        _scanCriticalMarkets(centralRegistry, signals);
        _scanCriticalOptimizers(optimizers, signals[4]);

        wiring = _packSignal(signals[0], FAMILY_CRITICAL_WIRING);
        tokenAccounting =
            _packSignal(signals[1], FAMILY_CRITICAL_TOKEN_ACCOUNTING);
        backing = _packSignal(signals[2], FAMILY_CRITICAL_BACKING);
        borrowAccounting =
            _packSignal(signals[3], FAMILY_CRITICAL_BORROW_ACCOUNTING);
        optimizerCritical = _packSignal(signals[4], FAMILY_CRITICAL_OPTIMIZER);
    }

    /// @notice Returns five packed alert-only and reader-health signals.
    /// @dev Suggested metric names, in return order:
    ///      Oracle Price Zero; Oracle Degraded; Collateral or Cap Warning;
    ///      Optimizer Warning; Monitor Reader Could Not Verify.
    function advisorySignals(
        address centralRegistry,
        address[] calldata optimizers
    )
        external
        view
        returns (
            uint256 oracleZero,
            uint256 oracleDegraded,
            uint256 collateralOrCap,
            uint256 optimizerWarning,
            uint256 readFailure
        )
    {
        SignalAccumulator[5] memory signals;
        _scanAdvisoryMarkets(centralRegistry, signals);
        _scanAdvisoryOptimizers(optimizers, signals[3], signals[4]);

        oracleZero = _packSignal(signals[0], FAMILY_ADVISORY_ORACLE_ZERO);
        oracleDegraded =
            _packSignal(signals[1], FAMILY_ADVISORY_ORACLE_DEGRADED);
        collateralOrCap =
            _packSignal(signals[2], FAMILY_ADVISORY_COLLATERAL_OR_CAP);
        optimizerWarning = _packSignal(signals[3], FAMILY_ADVISORY_OPTIMIZER);
        readFailure = _packSignal(signals[4], FAMILY_ADVISORY_READ_FAILURE);
    }

    /// @notice Decodes a packed value returned by either signal function.
    /// @param signal The exact nonzero uint256 shown by the Blockaid metric.
    function decodeSignal(uint256 signal)
        external
        pure
        returns (
            address firstSubject,
            uint8 findingCode,
            uint8 family,
            uint16 affectedCount,
            uint8 subjectType,
            uint8 encodingVersion
        )
    {
        // Each narrowing cast intentionally selects its documented bit field.
        // forge-lint: disable-next-line(unsafe-typecast)
        firstSubject = address(uint160(signal));
        // forge-lint: disable-next-line(unsafe-typecast)
        findingCode = uint8(signal >> 160);
        // forge-lint: disable-next-line(unsafe-typecast)
        family = uint8(signal >> 168);
        // forge-lint: disable-next-line(unsafe-typecast)
        affectedCount = uint16(signal >> 176);
        // forge-lint: disable-next-line(unsafe-typecast)
        subjectType = uint8(signal >> 192);
        // forge-lint: disable-next-line(unsafe-typecast)
        encodingVersion = uint8(signal >> 200);
    }

    /// DIAGNOSTIC FUNCTIONS ///

    function checkOracle(address oracleManager, address asset, bool inUSD)
        public
        view
        returns (OracleStatus memory status)
    {
        if (oracleManager.code.length == 0) {
            status.readErrorMask |= ORACLE_READ_PRICE;
            return status;
        }

        try IOracleManager(oracleManager)
            .getPrice(asset, inUSD, true) returns (
            uint256 price, uint256 errorCode
        ) {
            status.price = price;
            status.errorCode = errorCode;
            if (price == 0) {
                status.brokenMask |= ORACLE_BROKEN_PRICE_ZERO;
            }
            if (errorCode == CAUTION) {
                status.warningMask |= ORACLE_WARNING_CAUTION;
            } else if (errorCode == BAD_SOURCE) {
                status.brokenMask |= ORACLE_BROKEN_BAD_SOURCE;
            } else if (errorCode > BAD_SOURCE) {
                status.brokenMask |= ORACLE_BROKEN_UNKNOWN_ERROR;
            }
        } catch {
            status.readErrorMask |= ORACLE_READ_PRICE;
        }
    }

    function checkCToken(address cToken, address oracleManager)
        public
        view
        returns (CTokenStatus memory status)
    {
        status = _checkCToken(cToken, oracleManager, address(0), true, true);
    }

    /// @notice Checks a cToken against its expected MarketManager.
    function checkMarketCToken(
        address cToken,
        address marketManager,
        address oracleManager
    ) public view returns (CTokenStatus memory status) {
        status = _checkCToken(cToken, oracleManager, marketManager, true, true);
        _addCapWarnings(status);
    }

    function checkMarket(address marketManager, address oracleManager)
        public
        view
        returns (MarketStatus memory status)
    {
        return _checkMarket(marketManager, oracleManager, true, true);
    }

    function _checkMarket(
        address marketManager,
        address oracleManager,
        bool readOraclePrice,
        bool readAdvisoryAccounting
    ) internal view returns (MarketStatus memory status) {
        if (marketManager == address(0)) {
            status.brokenMask |= MARKET_BROKEN_MANAGER_ZERO;
            return status;
        }
        if (marketManager.code.length == 0) {
            status.readErrorMask |= MARKET_READ_TOKEN_LIST;
            return status;
        }

        try IMarketManager(marketManager).queryTokensListed() returns (
            address[] memory cTokens
        ) {
            status.cTokens = cTokens;
        } catch {
            status.readErrorMask |= MARKET_READ_TOKEN_LIST;
            return status;
        }

        uint256 length = status.cTokens.length;
        if (length == 0) {
            status.brokenMask |= MARKET_BROKEN_NO_TOKENS;
            return status;
        }

        status.tokenStatus = new CTokenStatus[](length);
        for (uint256 i; i < length; ++i) {
            address cToken = status.cTokens[i];
            if (cToken == address(0)) {
                status.brokenMask |= MARKET_BROKEN_TOKEN_ZERO;
                continue;
            }
            for (uint256 j; j < i; ++j) {
                if (status.cTokens[j] == cToken) {
                    status.brokenMask |= MARKET_BROKEN_DUPLICATE_TOKEN;
                    break;
                }
            }

            CTokenStatus memory tokenStatus = _checkCToken(
                cToken,
                oracleManager,
                marketManager,
                readOraclePrice,
                readAdvisoryAccounting
            );
            if (readAdvisoryAccounting) _addCapWarnings(tokenStatus);
            status.tokenStatus[i] = tokenStatus;
            if (tokenStatus.brokenMask != 0) {
                status.brokenMask |= MARKET_BROKEN_TOKEN_INVARIANT;
            }
            if (tokenStatus.warningMask != 0) {
                status.warningMask |= MARKET_WARNING_TOKEN;
            }
            if (tokenStatus.readErrorMask != 0) {
                status.readErrorMask |= MARKET_READ_TOKEN;
            }
        }
    }

    function checkOptimizer(address optimizer)
        public
        view
        returns (OptimizerStatus memory status)
    {
        if (optimizer == address(0)) {
            status.brokenMask |= OPTIMIZER_BROKEN_ADDRESS_ZERO;
            return status;
        }
        if (optimizer.code.length == 0) {
            status.readErrorMask = OPTIMIZER_READ_ASSET
                | OPTIMIZER_READ_MARKET_COUNT | OPTIMIZER_READ_MARKET
                | OPTIMIZER_READ_CAP | OPTIMIZER_READ_TOTAL_ASSETS
                | OPTIMIZER_READ_SUPPLY | OPTIMIZER_READ_DEAD_SHARES
                | OPTIMIZER_READ_EXCHANGE_RATE | OPTIMIZER_READ_HIGH_WATERMARK
                | OPTIMIZER_READ_CONVERSION | OPTIMIZER_READ_MINT_PAUSED
                | OPTIMIZER_READ_POSITION;
            return status;
        }

        _readOptimizerTopLevel(status, optimizer);
        uint256 marketCount = _optimizerMarketCount(status, optimizer);
        if (marketCount == 0) return status;

        status.markets = new OptimizerMarketStatus[](marketCount);
        for (uint256 i; i < marketCount; ++i) {
            _readOptimizerMarket(status, optimizer, i);
        }

        if (
            status.totalAllocationCaps < WAD
                && status.readErrorMask
                        & (OPTIMIZER_READ_MARKET | OPTIMIZER_READ_CAP) == 0
        ) {
            status.brokenMask |= OPTIMIZER_BROKEN_CAP_SUM;
        }
        if (
            status.readErrorMask
                        & (OPTIMIZER_READ_TOTAL_ASSETS
                            | OPTIMIZER_READ_POSITION) == 0
                && status.totalAssets > status.totalPositionAssets
        ) {
            status.brokenMask |= OPTIMIZER_BROKEN_ACCOUNTING;
        }
        if (
            status.readErrorMask
                        & (OPTIMIZER_READ_TOTAL_ASSETS
                            | OPTIMIZER_READ_SUPPLY
                            | OPTIMIZER_READ_CONVERSION) == 0
                && status.totalSupply != 0
                && !_withinTolerance(
                    status.convertedTotalSupply,
                    status.totalAssets,
                    CONVERSION_TOLERANCE
                )
        ) {
            status.brokenMask |= OPTIMIZER_BROKEN_CONVERSION;
        }
        if (
            status.readErrorMask
                        & (OPTIMIZER_READ_EXCHANGE_RATE
                            | OPTIMIZER_READ_HIGH_WATERMARK) == 0
                && status.exchangeRateHighWatermark != 0
                && status.exchangeRate < status.exchangeRateHighWatermark
        ) {
            status.warningMask |= OPTIMIZER_WARNING_BELOW_HIGH_WATERMARK;
        }
    }

    /// SIGNAL SCANNING ///

    function _scanCriticalMarkets(
        address centralRegistry,
        SignalAccumulator[5] memory signals
    ) internal view {
        if (centralRegistry == address(0)) {
            _record(signals[0], centralRegistry, SUBJECT_CENTRAL_REGISTRY, 1);
            return;
        }
        if (centralRegistry.code.length == 0) return;

        address[] memory markets;
        try ICentralRegistry(centralRegistry).marketManagers() returns (
            address[] memory value
        ) {
            markets = value;
        } catch {
            // The advisory reader-health metric reports this failed read.
            return;
        }

        address oracleManager;
        try ICentralRegistry(centralRegistry).oracleManager() returns (
            address value
        ) {
            oracleManager = value;
            if (value == address(0)) {
                _record(
                    signals[0], centralRegistry, SUBJECT_CENTRAL_REGISTRY, 2
                );
            }
        } catch {
            // The advisory reader-health metric reports this failed read.
        }

        if (markets.length == 0) {
            _record(signals[0], centralRegistry, SUBJECT_CENTRAL_REGISTRY, 3);
        }

        address[] memory seenCTokens = new address[](MAX_TRACKED_CTOKENS);
        uint256 seenCount;
        for (uint256 i; i < markets.length; ++i) {
            if (_contains(markets, i, markets[i])) {
                _record(signals[0], markets[i], SUBJECT_MARKET_MANAGER, 20);
                continue;
            }

            MarketStatus memory status =
                _checkMarket(markets[i], oracleManager, false, false);
            uint8 marketCode = _criticalMarketWiringCode(status.brokenMask);
            if (marketCode != 0) {
                _record(
                    signals[0], markets[i], SUBJECT_MARKET_MANAGER, marketCode
                );
            }

            for (uint256 j; j < status.tokenStatus.length; ++j) {
                address cToken = status.cTokens[j];
                if (cToken == address(0)) continue;

                CTokenStatus memory token = status.tokenStatus[j];
                uint8 wiringCode = _criticalCTokenWiringCode(token.brokenMask);
                if (wiringCode != 0) {
                    _record(signals[0], cToken, SUBJECT_CTOKEN, wiringCode);
                }

                if (_contains(seenCTokens, seenCount, cToken)) continue;
                if (seenCount == MAX_TRACKED_CTOKENS) continue;
                seenCTokens[seenCount++] = cToken;

                uint8 code = _criticalTokenAccountingCode(token.brokenMask);
                if (code != 0) {
                    _record(signals[1], cToken, SUBJECT_CTOKEN, code);
                }

                code = _criticalBackingCode(token.brokenMask);
                if (code != 0) {
                    _record(signals[2], cToken, SUBJECT_CTOKEN, code);
                }

                code = _criticalBorrowCode(token.brokenMask);
                if (code != 0) {
                    _record(signals[3], cToken, SUBJECT_CTOKEN, code);
                }
            }
        }
    }

    function _scanCriticalOptimizers(
        address[] calldata optimizers,
        SignalAccumulator memory signal
    ) internal view {
        uint256 length = optimizers.length;
        if (length > MAX_INPUT_OPTIMIZERS) {
            length = MAX_INPUT_OPTIMIZERS;
        }

        for (uint256 i; i < length; ++i) {
            address optimizer = optimizers[i];
            if (_containsCalldata(optimizers, i, optimizer)) continue;

            OptimizerStatus memory status = checkOptimizer(optimizer);
            if (status.brokenMask != 0) {
                _record(
                    signal,
                    optimizer,
                    SUBJECT_OPTIMIZER,
                    _bitCode(status.brokenMask)
                );
            }
        }
    }

    function _scanAdvisoryMarkets(
        address centralRegistry,
        SignalAccumulator[5] memory signals
    ) internal view {
        if (centralRegistry == address(0)) {
            _record(signals[4], centralRegistry, SUBJECT_CENTRAL_REGISTRY, 1);
            return;
        }
        if (centralRegistry.code.length == 0) {
            _record(signals[4], centralRegistry, SUBJECT_CENTRAL_REGISTRY, 2);
            return;
        }

        address[] memory markets;
        try ICentralRegistry(centralRegistry).marketManagers() returns (
            address[] memory value
        ) {
            markets = value;
        } catch {
            _record(signals[4], centralRegistry, SUBJECT_CENTRAL_REGISTRY, 2);
            return;
        }

        address oracleManager;
        try ICentralRegistry(centralRegistry).oracleManager() returns (
            address value
        ) {
            oracleManager = value;
        } catch {
            _record(signals[4], centralRegistry, SUBJECT_CENTRAL_REGISTRY, 3);
        }

        AdvisoryScanState memory state;
        state.seenCTokens = new address[](MAX_TRACKED_CTOKENS);
        state.seenAssets = new address[](MAX_TRACKED_ORACLE_ASSETS);
        state.oracleCache = new uint256[](MAX_TRACKED_ORACLE_ASSETS);

        for (uint256 i; i < markets.length; ++i) {
            _processAdvisoryMarket(
                centralRegistry, oracleManager, markets[i], signals, state
            );
        }
    }

    function _processAdvisoryMarket(
        address centralRegistry,
        address oracleManager,
        address market,
        SignalAccumulator[5] memory signals,
        AdvisoryScanState memory state
    ) internal view {
        MarketStatus memory status = _checkMarket(
            market, oracleManager, false, true
        );
        if (status.readErrorMask & MARKET_READ_TOKEN_LIST != 0) {
            _record(signals[4], market, SUBJECT_MARKET_MANAGER, 16);
        }

        for (uint256 i; i < status.tokenStatus.length; ++i) {
            address cToken = status.cTokens[i];
            if (cToken == address(0)) continue;
            _processAdvisoryToken(
                centralRegistry,
                oracleManager,
                cToken,
                status.tokenStatus[i],
                signals,
                state
            );
        }
    }

    function _processAdvisoryToken(
        address centralRegistry,
        address oracleManager,
        address cToken,
        CTokenStatus memory token,
        SignalAccumulator[5] memory signals,
        AdvisoryScanState memory state
    ) internal view {
        if (_contains(state.seenCTokens, state.seenCTokenCount, cToken)) return;
        if (state.seenCTokenCount == MAX_TRACKED_CTOKENS) {
            if (!state.cTokenLimitReported) {
                _record(
                    signals[4], centralRegistry, SUBJECT_CENTRAL_REGISTRY, 96
                );
                state.cTokenLimitReported = true;
            }
            return;
        }
        state.seenCTokens[state.seenCTokenCount++] = cToken;

        uint8 collateralCode = _advisoryCollateralCode(token);
        if (collateralCode != 0) {
            _record(signals[2], cToken, SUBJECT_CTOKEN, collateralCode);
        }

        uint256 readErrorMask = token.readErrorMask;
        address asset = token.underlying;
        if (oracleManager != address(0) && asset != address(0)) {
            uint256 assetIndex;
            bool seenAsset;
            for (uint256 i; i < state.seenAssetCount; ++i) {
                if (state.seenAssets[i] == asset) {
                    assetIndex = i;
                    seenAsset = true;
                    break;
                }
            }

            if (!seenAsset) {
                if (state.seenAssetCount == MAX_TRACKED_ORACLE_ASSETS) {
                    if (readErrorMask != 0) {
                        _record(
                            signals[4],
                            cToken,
                            SUBJECT_CTOKEN,
                            uint8(32 + _firstBitIndex(readErrorMask))
                        );
                    }
                    if (!state.assetLimitReported) {
                        _record(
                            signals[4],
                            centralRegistry,
                            SUBJECT_CENTRAL_REGISTRY,
                            97
                        );
                        state.assetLimitReported = true;
                    }
                    return;
                }

                assetIndex = state.seenAssetCount++;
                state.seenAssets[assetIndex] = asset;
                uint256 cached = _readOracleCache(oracleManager, asset);
                state.oracleCache[assetIndex] = cached;

                // Safe: the cache reserves bits 0..7 for the uint8 zero code.
                // forge-lint: disable-next-line(unsafe-typecast)
                uint8 oracleCode = uint8(cached);
                if (oracleCode != 0) {
                    _record(signals[0], asset, SUBJECT_ASSET, oracleCode);
                }

                // Safe: the cache reserves bits 8..15 for the uint8 warning code.
                // forge-lint: disable-next-line(unsafe-typecast)
                oracleCode = uint8(cached >> 8);
                if (oracleCode != 0) {
                    _record(signals[1], asset, SUBJECT_ASSET, oracleCode);
                }
            }

            uint256 oracleCache = state.oracleCache[assetIndex];
            if (oracleCache & (1 << 16) != 0) {
                readErrorMask |= CTOKEN_READ_ORACLE_PRICE;
            }
        }

        if (readErrorMask != 0) {
            _record(
                signals[4],
                cToken,
                SUBJECT_CTOKEN,
                uint8(32 + _firstBitIndex(readErrorMask))
            );
        }
    }

    function _readOracleCache(address oracleManager, address asset)
        internal
        view
        returns (uint256 cached)
    {
        OracleStatus memory price = checkOracle(oracleManager, asset, true);
        cached = uint256(_oracleZeroCode(price));
        cached |= uint256(_oracleDegradedCode(price)) << 8;
        if (price.readErrorMask != 0) cached |= 1 << 16;
    }

    function _scanAdvisoryOptimizers(
        address[] calldata optimizers,
        SignalAccumulator memory warningSignal,
        SignalAccumulator memory readSignal
    ) internal view {
        uint256 length = optimizers.length;
        if (length > MAX_INPUT_OPTIMIZERS) {
            _record(readSignal, address(0), SUBJECT_OPTIMIZER, 98);
            length = MAX_INPUT_OPTIMIZERS;
        }

        for (uint256 i; i < length; ++i) {
            address optimizer = optimizers[i];
            if (_containsCalldata(optimizers, i, optimizer)) continue;

            OptimizerStatus memory status = checkOptimizer(optimizer);
            if (status.warningMask != 0) {
                _record(
                    warningSignal,
                    optimizer,
                    SUBJECT_OPTIMIZER,
                    _bitCode(status.warningMask)
                );
            }
            if (status.readErrorMask != 0) {
                _record(
                    readSignal,
                    optimizer,
                    SUBJECT_OPTIMIZER,
                    uint8(64 + _firstBitIndex(status.readErrorMask))
                );
            }
        }
    }

    /// SIGNAL ENCODING ///

    function _record(
        SignalAccumulator memory signal,
        address subject,
        uint8 subjectType,
        uint8 findingCode
    ) internal pure {
        if (findingCode == 0) return;
        if (signal.affectedCount == 0) {
            signal.firstSubject = subject;
            signal.findingCode = findingCode;
            signal.subjectType = subjectType;
        }
        if (signal.affectedCount != type(uint16).max) {
            ++signal.affectedCount;
        }
    }

    function _packSignal(SignalAccumulator memory signal, uint8 family)
        internal
        pure
        returns (uint256 packed)
    {
        if (signal.affectedCount == 0) return 0;
        packed = uint256(uint160(signal.firstSubject));
        packed |= uint256(signal.findingCode) << 160;
        packed |= uint256(family) << 168;
        packed |= uint256(signal.affectedCount) << 176;
        packed |= uint256(signal.subjectType) << 192;
        packed |= uint256(SIGNAL_ENCODING_VERSION) << 200;
    }

    // Critical wiring finding codes:
    // 1 registry argument is zero; 2 registry OracleManager is zero;
    // 3 registry has no MarketManagers;
    // 16 MarketManager zero; 18 listed cToken zero;
    // 19 duplicate listed cToken. An empty registered MarketManager is treated
    // as provisioning and remains available through `checkMarket`, but does
    // not trigger the monitor-facing critical signal.
    // 20 duplicate MarketManager in the CentralRegistry;
    // 32..36 cToken manager-zero/asset-zero/not-listed/manager-mismatch/
    // oracle-binding-mismatch.
    function _criticalMarketWiringCode(uint256 mask)
        internal
        pure
        returns (uint8)
    {
        uint256 selected = mask
            & (MARKET_BROKEN_MANAGER_ZERO
                | MARKET_BROKEN_TOKEN_ZERO
                | MARKET_BROKEN_DUPLICATE_TOKEN);
        if (selected == 0) return 0;
        return uint8(16 + _firstBitIndex(selected));
    }

    function _criticalCTokenWiringCode(uint256 mask)
        internal
        pure
        returns (uint8)
    {
        uint256 selected = mask
            & (CTOKEN_BROKEN_MANAGER_ZERO
                | CTOKEN_BROKEN_ASSET_ZERO
                | CTOKEN_BROKEN_NOT_LISTED
                | CTOKEN_BROKEN_MANAGER_MISMATCH
                | CTOKEN_BROKEN_ORACLE_BINDING);
        if (selected == 0) return 0;
        return uint8(32 + _firstBitIndex(selected));
    }

    // Token-accounting codes: 1 supply zero; 2 total assets zero;
    // 3 exchange rate zero; 4 converted supply mismatch.
    function _criticalTokenAccountingCode(uint256 mask)
        internal
        pure
        returns (uint8)
    {
        if (mask & CTOKEN_BROKEN_SUPPLY_ZERO != 0) return 1;
        if (mask & CTOKEN_BROKEN_TOTAL_ASSETS_ZERO != 0) return 2;
        if (mask & CTOKEN_BROKEN_EXCHANGE_RATE_ZERO != 0) return 3;
        if (mask & CTOKEN_BROKEN_CONVERSION != 0) return 4;
        return 0;
    }

    // Backing codes: 1 debt plus reserve exceeds total assets;
    // 2 cash is below assets held plus reserve.
    function _criticalBackingCode(uint256 mask) internal pure returns (uint8) {
        if (mask & CTOKEN_BROKEN_RESERVE != 0) return 1;
        if (mask & CTOKEN_BROKEN_CASH != 0) return 2;
        return 0;
    }

    // Borrow-accounting codes: 1 vesting clock; 2 debt index.
    function _criticalBorrowCode(uint256 mask) internal pure returns (uint8) {
        if (mask & CTOKEN_BROKEN_VESTING_CLOCK != 0) return 1;
        if (mask & CTOKEN_BROKEN_DEBT_INDEX != 0) return 2;
        return 0;
    }

    // Oracle-zero code: 1 price zero.
    function _oracleZeroCode(OracleStatus memory price)
        internal
        pure
        returns (uint8)
    {
        if (price.brokenMask & ORACLE_BROKEN_PRICE_ZERO != 0) {
            return 1;
        }
        return 0;
    }

    // Oracle-degraded codes: 1 BAD_SOURCE; 2 unknown error;
    // 3 CAUTION (including PriceGuard).
    function _oracleDegradedCode(OracleStatus memory price)
        internal
        pure
        returns (uint8)
    {
        if (price.brokenMask & ORACLE_BROKEN_BAD_SOURCE != 0) {
            return 1;
        }
        if (price.brokenMask & ORACLE_BROKEN_UNKNOWN_ERROR != 0) {
            return 2;
        }
        if (price.warningMask & ORACLE_WARNING_CAUTION != 0) {
            return 3;
        }
        return 0;
    }

    // Collateral/cap codes: 1 posted collateral exceeds live shares;
    // 2 collateral cap exceeded; 3 debt cap exceeded.
    function _advisoryCollateralCode(CTokenStatus memory token)
        internal
        pure
        returns (uint8)
    {
        if (token.brokenMask & CTOKEN_BROKEN_COLLATERAL_SHARES != 0) {
            return 1;
        }
        if (token.warningMask & CTOKEN_WARNING_COLLATERAL_CAP != 0) return 2;
        if (token.warningMask & CTOKEN_WARNING_DEBT_CAP != 0) return 3;
        return 0;
    }

    // Optimizer critical and warning codes are the corresponding public-mask
    // bit index plus one. Read-failure codes are:
    // 1 zero registry argument; 2 registry market list; 3 registry oracle;
    // 16 MarketManager token list; 32..50 cToken read-mask bit index;
    // 64..75 optimizer read-mask bit index; 96 cToken tracking limit;
    // 97 oracle-asset tracking limit; 98 optimizer-input tracking limit.
    function _bitCode(uint256 mask) internal pure returns (uint8) {
        if (mask == 0) return 0;
        return uint8(_firstBitIndex(mask) + 1);
    }

    function _firstBitIndex(uint256 value)
        internal
        pure
        returns (uint8 index)
    {
        if (value == 0) return 0;
        while (value & 1 == 0) {
            value >>= 1;
            ++index;
        }
    }

    function _contains(address[] memory values, uint256 length, address value)
        internal
        pure
        returns (bool)
    {
        for (uint256 i; i < length; ++i) {
            if (values[i] == value) return true;
        }
        return false;
    }

    function _containsCalldata(
        address[] calldata values,
        uint256 length,
        address value
    ) internal pure returns (bool) {
        for (uint256 i; i < length; ++i) {
            if (values[i] == value) return true;
        }
        return false;
    }

    /// CTOKEN CHECKS ///

    function _checkCToken(
        address cToken,
        address oracleManager,
        address expectedManager,
        bool readOraclePrice,
        bool readAdvisoryAccounting
    ) internal view returns (CTokenStatus memory status) {
        if (cToken.code.length == 0) {
            status.readErrorMask = CTOKEN_READ_MANAGER | CTOKEN_READ_ASSET
                | CTOKEN_READ_LISTED | CTOKEN_READ_SUPPLY
                | CTOKEN_READ_TOTAL_ASSETS | CTOKEN_READ_EXCHANGE_RATE
                | CTOKEN_READ_CONVERSION | CTOKEN_READ_ORACLE_BINDING
                | CTOKEN_READ_UNDERLYING_BALANCE | CTOKEN_READ_DEBT
                | CTOKEN_READ_ASSETS_HELD | CTOKEN_READ_YIELD
                | CTOKEN_READ_DEBT_CAP;
            if (readAdvisoryAccounting) {
                status.readErrorMask |= CTOKEN_READ_IS_BORROWABLE
                    | CTOKEN_READ_DEAD_SHARES | CTOKEN_READ_COLLATERAL
                    | CTOKEN_READ_COLLATERAL_CAP;
            }
            if (readOraclePrice) {
                status.readErrorMask |= CTOKEN_READ_ORACLE_PRICE;
            }
            return status;
        }

        _readCTokenIdentity(
            status, cToken, expectedManager, readAdvisoryAccounting
        );
        _readCTokenAccounting(status, cToken, readAdvisoryAccounting);
        _readTokenCaps(
            status,
            cToken,
            expectedManager == address(0)
                ? status.marketManager
                : expectedManager,
            readAdvisoryAccounting
        );

        // A nonzero debt cap is the market-level activation signal for
        // borrowing. `isBorrowable()` identifies the cToken implementation,
        // but does not mean borrowing is currently enabled.
        if (
            status.readErrorMask & CTOKEN_READ_DEBT_CAP == 0
                && status.debtCap != 0
        ) {
            _readBorrowableAccounting(status, cToken);
        }

        if (oracleManager != address(0) && status.underlying != address(0)) {
            _readOracleBinding(status, cToken, oracleManager);
            if (readOraclePrice) {
                _readOraclePrice(status, oracleManager);
            }
        }
    }

    function _readCTokenIdentity(
        CTokenStatus memory status,
        address cToken,
        address expectedManager,
        bool readIsBorrowable
    ) internal view {
        if (readIsBorrowable) {
            try ICToken(cToken).isBorrowable() returns (bool value) {
                status.isBorrowable = value;
            } catch {
                status.readErrorMask |= CTOKEN_READ_IS_BORROWABLE;
            }
        }

        try ICToken(cToken).marketManager() returns (IMarketManager value) {
            status.marketManager = address(value);
            if (address(value) == address(0)) {
                status.brokenMask |= CTOKEN_BROKEN_MANAGER_ZERO;
            } else {
                if (
                    expectedManager != address(0)
                        && address(value) != expectedManager
                ) {
                    status.brokenMask |= CTOKEN_BROKEN_MANAGER_MISMATCH;
                }
                if (address(value).code.length == 0) {
                    status.readErrorMask |= CTOKEN_READ_LISTED;
                } else {
                    try value.isListed(cToken) returns (bool listed) {
                        if (!listed) {
                            status.brokenMask |= CTOKEN_BROKEN_NOT_LISTED;
                        }
                    } catch {
                        status.readErrorMask |= CTOKEN_READ_LISTED;
                    }
                }
            }
        } catch {
            status.readErrorMask |= CTOKEN_READ_MANAGER;
        }

        try ICToken(cToken).asset() returns (address value) {
            status.underlying = value;
            if (value == address(0)) {
                status.brokenMask |= CTOKEN_BROKEN_ASSET_ZERO;
            }
        } catch {
            status.readErrorMask |= CTOKEN_READ_ASSET;
        }
    }

    function _readCTokenAccounting(
        CTokenStatus memory status,
        address cToken,
        bool readCollateralAccounting
    ) internal view {
        try ICToken(cToken).totalSupply() returns (uint256 value) {
            status.totalSupply = value;
            if (value == 0) {
                status.brokenMask |= CTOKEN_BROKEN_SUPPLY_ZERO;
            }
        } catch {
            status.readErrorMask |= CTOKEN_READ_SUPPLY;
        }

        try ICToken(cToken).totalAssets() returns (uint256 value) {
            status.totalAssets = value;
            if (value == 0) {
                status.brokenMask |= CTOKEN_BROKEN_TOTAL_ASSETS_ZERO;
            }
        } catch {
            status.readErrorMask |= CTOKEN_READ_TOTAL_ASSETS;
        }

        if (readCollateralAccounting) {
            _readCollateralAccounting(status, cToken);
        }

        try ICToken(cToken).exchangeRate() returns (uint256 value) {
            status.exchangeRate = value;
            if (value == 0) {
                status.brokenMask |= CTOKEN_BROKEN_EXCHANGE_RATE_ZERO;
            }
        } catch {
            status.readErrorMask |= CTOKEN_READ_EXCHANGE_RATE;
        }

        if (
            status.readErrorMask
                        & (CTOKEN_READ_SUPPLY | CTOKEN_READ_TOTAL_ASSETS) == 0
                && status.totalSupply != 0
        ) {
            try ICToken(cToken).convertToAssets(status.totalSupply) returns (
                uint256 value
            ) {
                status.convertedTotalSupply = value;
                if (!_withinTolerance(
                        value, status.totalAssets, CONVERSION_TOLERANCE
                    )) {
                    status.brokenMask |= CTOKEN_BROKEN_CONVERSION;
                }
            } catch {
                status.readErrorMask |= CTOKEN_READ_CONVERSION;
            }
        }
    }

    function _readCollateralAccounting(
        CTokenStatus memory status,
        address cToken
    ) internal view {
        try ICToken(cToken).balanceOf(address(0)) returns (uint256 value) {
            status.deadShares = value;
        } catch {
            status.readErrorMask |= CTOKEN_READ_DEAD_SHARES;
        }

        try ICToken(cToken).marketCollateralPosted() returns (uint256 value) {
            status.marketCollateralPosted = value;
            uint256 requiredReads =
                CTOKEN_READ_SUPPLY | CTOKEN_READ_DEAD_SHARES;
            requiredReads |= CTOKEN_READ_COLLATERAL;
            if (
                status.readErrorMask & requiredReads == 0
                    && (value > status.totalSupply
                        || status.deadShares > status.totalSupply - value)
            ) {
                status.brokenMask |= CTOKEN_BROKEN_COLLATERAL_SHARES;
            }
        } catch {
            status.readErrorMask |= CTOKEN_READ_COLLATERAL;
        }
    }

    function _readBorrowableAccounting(
        CTokenStatus memory status,
        address cToken
    ) internal view {
        try IBorrowableCToken(cToken).marketOutstandingDebt() returns (
            uint256 value
        ) {
            status.marketOutstandingDebt = value;
        } catch {
            status.readErrorMask |= CTOKEN_READ_DEBT;
        }

        bool reserveReadable = status.readErrorMask
                & (CTOKEN_READ_TOTAL_ASSETS | CTOKEN_READ_DEBT) == 0;
        bool reserveHealthy = reserveReadable
            && status.totalAssets >= BASE_UNDERLYING_RESERVE
            && status.marketOutstandingDebt
                <= status.totalAssets - BASE_UNDERLYING_RESERVE;
        if (reserveReadable && !reserveHealthy) {
            status.brokenMask |= CTOKEN_BROKEN_RESERVE;
        } else if (reserveHealthy) {
            try IBorrowableCToken(cToken).assetsHeld() returns (
                uint256 value
            ) {
                status.assetsHeld = value;
            } catch {
                status.readErrorMask |= CTOKEN_READ_ASSETS_HELD;
            }
        }

        if (
            status.underlying != address(0)
                && status.underlying.code.length != 0
        ) {
            try IERC20(status.underlying).balanceOf(cToken) returns (
                uint256 value
            ) {
                status.underlyingBalance = value;
                if (
                    reserveHealthy
                        && status.readErrorMask & CTOKEN_READ_ASSETS_HELD == 0
                        && (value < BASE_UNDERLYING_RESERVE
                            || status.assetsHeld
                                > value - BASE_UNDERLYING_RESERVE)
                ) {
                    status.brokenMask |= CTOKEN_BROKEN_CASH;
                }
            } catch {
                status.readErrorMask |= CTOKEN_READ_UNDERLYING_BALANCE;
            }
        } else if (status.underlying != address(0)) {
            status.readErrorMask |= CTOKEN_READ_UNDERLYING_BALANCE;
        }

        try IBorrowableCToken(cToken).getYieldInformation() returns (
            uint256 vestingRate,
            uint256 vestingEnd,
            uint256 lastVestingClaim,
            uint256 debtIndex
        ) {
            status.vestingRate = vestingRate;
            status.vestingEnd = vestingEnd;
            status.lastVestingClaim = lastVestingClaim;
            status.debtIndex = debtIndex;
            if (lastVestingClaim > vestingEnd) {
                status.brokenMask |= CTOKEN_BROKEN_VESTING_CLOCK;
            }
            if (debtIndex < WAD) {
                status.brokenMask |= CTOKEN_BROKEN_DEBT_INDEX;
            }
        } catch {
            status.readErrorMask |= CTOKEN_READ_YIELD;
        }
    }

    function _readOracleBinding(
        CTokenStatus memory status,
        address cToken,
        address oracleManager
    ) internal view {
        if (oracleManager.code.length == 0) {
            status.readErrorMask |= CTOKEN_READ_ORACLE_BINDING;
            return;
        }

        try IOracleManager(oracleManager).cTokens(cToken) returns (
            address value
        ) {
            if (value != status.underlying) {
                status.brokenMask |= CTOKEN_BROKEN_ORACLE_BINDING;
            }
        } catch {
            status.readErrorMask |= CTOKEN_READ_ORACLE_BINDING;
        }
    }

    function _readOraclePrice(
        CTokenStatus memory status,
        address oracleManager
    ) internal view {
        if (oracleManager.code.length == 0) {
            status.readErrorMask |= CTOKEN_READ_ORACLE_PRICE;
            return;
        }
        status.oraclePrice =
            checkOracle(oracleManager, status.underlying, true);
        if (status.oraclePrice.brokenMask != 0) {
            status.brokenMask |= CTOKEN_BROKEN_ORACLE;
        }
        if (status.oraclePrice.warningMask != 0) {
            status.warningMask |= CTOKEN_WARNING_ORACLE;
        }
        if (status.oraclePrice.readErrorMask != 0) {
            status.readErrorMask |= CTOKEN_READ_ORACLE_PRICE;
        }
    }

    function _readTokenCaps(
        CTokenStatus memory status,
        address cToken,
        address marketManager,
        bool readCollateralCap
    ) internal view {
        if (marketManager == address(0)) return;
        if (marketManager.code.length == 0) {
            status.readErrorMask |= CTOKEN_READ_DEBT_CAP;
            if (readCollateralCap) {
                status.readErrorMask |= CTOKEN_READ_COLLATERAL_CAP;
            }
            return;
        }

        if (readCollateralCap) {
            try IMarketManager(marketManager).collateralCaps(cToken) returns (
                uint256 cap
            ) {
                status.collateralCap = cap;
            } catch {
                status.readErrorMask |= CTOKEN_READ_COLLATERAL_CAP;
            }
        }

        try IMarketManager(marketManager).debtCaps(cToken) returns (
            uint256 cap
        ) {
            status.debtCap = cap;
        } catch {
            status.readErrorMask |= CTOKEN_READ_DEBT_CAP;
        }
    }

    function _addCapWarnings(CTokenStatus memory status) internal pure {
        if (
            status.readErrorMask
                        & (CTOKEN_READ_COLLATERAL | CTOKEN_READ_COLLATERAL_CAP)
                    == 0
                && status.marketCollateralPosted > status.collateralCap
        ) {
            status.warningMask |= CTOKEN_WARNING_COLLATERAL_CAP;
        }

        if (
            status.debtCap != 0
                && status.readErrorMask
                        & (CTOKEN_READ_DEBT | CTOKEN_READ_DEBT_CAP) == 0
                && status.marketOutstandingDebt > status.debtCap
        ) {
            status.warningMask |= CTOKEN_WARNING_DEBT_CAP;
        }
    }

    /// OPTIMIZER CHECKS ///

    function _readOptimizerTopLevel(
        OptimizerStatus memory status,
        address optimizer
    ) internal view {
        try ILendingOptimizer(optimizer).asset() returns (address value) {
            status.underlying = value;
            if (value == address(0)) {
                status.brokenMask |= OPTIMIZER_BROKEN_ASSET_ZERO;
            }
        } catch {
            status.readErrorMask |= OPTIMIZER_READ_ASSET;
        }

        try ILendingOptimizer(optimizer).totalAssets() returns (
            uint256 value
        ) {
            status.totalAssets = value;
        } catch {
            status.readErrorMask |= OPTIMIZER_READ_TOTAL_ASSETS;
        }

        try IERC20(optimizer).totalSupply() returns (uint256 value) {
            status.totalSupply = value;
            if (value == 0) {
                status.brokenMask |= OPTIMIZER_BROKEN_SUPPLY_ZERO;
            }
        } catch {
            status.readErrorMask |= OPTIMIZER_READ_SUPPLY;
        }

        try ILendingOptimizer(optimizer).balanceOf(address(0)) returns (
            uint256 value
        ) {
            status.deadShares = value;
            if (value == 0) {
                status.brokenMask |= OPTIMIZER_BROKEN_DEAD_SHARES;
            }
        } catch {
            status.readErrorMask |= OPTIMIZER_READ_DEAD_SHARES;
        }

        try ILendingOptimizer(optimizer).exchangeRate() returns (
            uint256 value
        ) {
            status.exchangeRate = value;
            if (value == 0) {
                status.brokenMask |= OPTIMIZER_BROKEN_EXCHANGE_RATE;
            }
        } catch {
            status.readErrorMask |= OPTIMIZER_READ_EXCHANGE_RATE;
        }

        try ILendingOptimizer(optimizer).exchangeRateHighWatermark() returns (
            uint256 value
        ) {
            status.exchangeRateHighWatermark = value;
        } catch {
            status.readErrorMask |= OPTIMIZER_READ_HIGH_WATERMARK;
        }

        if (status.totalSupply != 0) {
            try ILendingOptimizer(optimizer)
                .convertToAssets(status.totalSupply) returns (
                uint256 value
            ) {
                status.convertedTotalSupply = value;
            } catch {
                status.readErrorMask |= OPTIMIZER_READ_CONVERSION;
            }
        }

        try ILendingOptimizer(optimizer).mintPaused() returns (uint8 value) {
            if (value == 2) {
                status.warningMask |= OPTIMIZER_WARNING_MINT_PAUSED;
            }
        } catch {
            status.readErrorMask |= OPTIMIZER_READ_MINT_PAUSED;
        }
    }

    function _optimizerMarketCount(
        OptimizerStatus memory status,
        address optimizer
    ) internal view returns (uint256 marketCount) {
        try ILendingOptimizer(optimizer).numApprovedMarkets() returns (
            uint256 value
        ) {
            marketCount = value;
            if (value == 0 || value > MAX_OPTIMIZER_MARKETS) {
                status.brokenMask |= OPTIMIZER_BROKEN_MARKET_COUNT;
                if (value > MAX_OPTIMIZER_MARKETS) {
                    marketCount = MAX_OPTIMIZER_MARKETS;
                }
            }
        } catch {
            status.readErrorMask |= OPTIMIZER_READ_MARKET_COUNT;
        }
    }

    function _readOptimizerMarket(
        OptimizerStatus memory status,
        address optimizer,
        uint256 index
    ) internal view {
        OptimizerMarketStatus memory market;
        try ILendingOptimizer(optimizer).approvedCTokensList(index) returns (
            address value
        ) {
            market.cToken = value;
        } catch {
            market.readErrorMask |= OPTIMIZER_READ_MARKET;
            status.readErrorMask |= OPTIMIZER_READ_MARKET;
            status.markets[index] = market;
            return;
        }

        if (market.cToken == address(0)) {
            market.brokenMask |= OPTIMIZER_BROKEN_MARKET_ZERO;
        }
        for (uint256 j; j < index; ++j) {
            if (status.markets[j].cToken == market.cToken) {
                market.brokenMask |= OPTIMIZER_BROKEN_DUPLICATE_MARKET;
                break;
            }
        }
        if (market.cToken == address(0)) {
            status.brokenMask |= market.brokenMask;
            status.markets[index] = market;
            return;
        }
        if (market.cToken.code.length == 0) {
            market.readErrorMask |= OPTIMIZER_READ_MARKET
                | OPTIMIZER_READ_POSITION;
            status.readErrorMask |= market.readErrorMask;
            status.markets[index] = market;
            return;
        }

        _readOptimizerMarketConfig(status, market, optimizer);
        _readOptimizerMarketPosition(status, market, optimizer);
        status.brokenMask |= market.brokenMask;
        status.warningMask |= market.warningMask;
        status.readErrorMask |= market.readErrorMask;
        status.markets[index] = market;
    }

    function _readOptimizerMarketConfig(
        OptimizerStatus memory status,
        OptimizerMarketStatus memory market,
        address optimizer
    ) internal view {
        try ILendingOptimizer(optimizer)
            .allocationCaps(market.cToken) returns (
            uint256 value
        ) {
            market.allocationCap = value;
            if (value == 0 || value > WAD) {
                market.brokenMask |= OPTIMIZER_BROKEN_CAP;
            } else {
                // At most 32 caps no larger than WAD are added, so this sum
                // cannot approach uint256 overflow.
                status.totalAllocationCaps += value;
            }
        } catch {
            market.readErrorMask |= OPTIMIZER_READ_CAP;
            status.readErrorMask |= OPTIMIZER_READ_CAP;
        }

        try ICToken(market.cToken).isBorrowable() returns (bool value) {
            if (!value) {
                market.brokenMask |= OPTIMIZER_BROKEN_NOT_BORROWABLE;
            }
        } catch {
            market.readErrorMask |= OPTIMIZER_READ_MARKET;
        }

        try ICToken(market.cToken).asset() returns (address value) {
            market.underlying = value;
            if (value != status.underlying) {
                market.brokenMask |= OPTIMIZER_BROKEN_UNDERLYING;
            }
        } catch {
            market.readErrorMask |= OPTIMIZER_READ_MARKET;
        }

        try ICToken(market.cToken).marketManager() returns (
            IMarketManager value
        ) {
            market.marketManager = address(value);
            if (address(value).code.length == 0) {
                market.readErrorMask |= OPTIMIZER_READ_MARKET;
            } else {
                try value.isListed(market.cToken) returns (bool listed) {
                    if (!listed) {
                        market.brokenMask |= OPTIMIZER_BROKEN_NOT_LISTED;
                    }
                } catch {
                    market.readErrorMask |= OPTIMIZER_READ_MARKET;
                }
            }
        } catch {
            market.readErrorMask |= OPTIMIZER_READ_MARKET;
        }
    }

    function _readOptimizerMarketPosition(
        OptimizerStatus memory status,
        OptimizerMarketStatus memory market,
        address optimizer
    ) internal view {
        try IBorrowableCToken(market.cToken).balanceOf(optimizer) returns (
            uint256 value
        ) {
            market.positionShares = value;
        } catch {
            market.readErrorMask |= OPTIMIZER_READ_POSITION;
            return;
        }

        try IBorrowableCToken(market.cToken)
            .convertToAssets(market.positionShares) returns (
            uint256 value
        ) {
            market.positionAssets = value;
            if (status.totalPositionAssets > type(uint256).max - value) {
                market.brokenMask |= OPTIMIZER_BROKEN_ACCOUNTING;
            } else {
                status.totalPositionAssets += value;
            }
        } catch {
            market.readErrorMask |= OPTIMIZER_READ_POSITION;
        }
    }

    function _withinTolerance(uint256 a, uint256 b, uint256 tolerance)
        internal
        pure
        returns (bool)
    {
        return a > b ? a - b <= tolerance : b - a <= tolerance;
    }
}
