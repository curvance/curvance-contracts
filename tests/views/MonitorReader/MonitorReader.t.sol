// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {MonitorReader} from "contracts/views/MonitorReader.sol";

contract MonitorMockUnderlying {
    mapping(address => uint256) public balanceOf;

    function setBalance(address account, uint256 amount) external {
        balanceOf[account] = amount;
    }
}

contract MonitorMockMarketManager {
    address[] internal _tokens;
    mapping(address => bool) public isListed;
    mapping(address => uint256) public collateralCaps;
    mapping(address => uint256) public debtCaps;
    bool public revertTokenList;

    function addToken(address cToken) external {
        _tokens.push(cToken);
        isListed[cToken] = true;
    }

    function setListed(address cToken, bool value) external {
        isListed[cToken] = value;
    }

    function setCaps(address cToken, uint256 collateralCap, uint256 debtCap)
        external
    {
        collateralCaps[cToken] = collateralCap;
        debtCaps[cToken] = debtCap;
    }

    function setRevertTokenList(bool value) external {
        revertTokenList = value;
    }

    function queryTokensListed() external view returns (address[] memory) {
        if (revertTokenList) revert();
        return _tokens;
    }
}

contract MonitorMockOracleManager {
    mapping(address => address) public cTokens;
    uint256 public price = 1e18;
    uint256 public errorCode;
    uint256 public upperPrice = 1e18;
    uint256 public upperErrorCode;
    bool public shouldRevert;
    bool public lowerShouldRevert;
    bool public upperShouldRevert;

    function setCToken(address cToken, address underlying) external {
        cTokens[cToken] = underlying;
    }

    function setPrice(uint256 newPrice, uint256 newErrorCode) external {
        price = newPrice;
        errorCode = newErrorCode;
        upperPrice = newPrice;
        upperErrorCode = newErrorCode;
    }

    function setDirectionalPrices(
        uint256 newLowerPrice,
        uint256 newLowerErrorCode,
        uint256 newUpperPrice,
        uint256 newUpperErrorCode
    ) external {
        price = newLowerPrice;
        errorCode = newLowerErrorCode;
        upperPrice = newUpperPrice;
        upperErrorCode = newUpperErrorCode;
    }

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function setDirectionalReverts(bool lower, bool upper) external {
        lowerShouldRevert = lower;
        upperShouldRevert = upper;
    }

    function getPrice(address, bool, bool getLower)
        external
        view
        returns (uint256, uint256)
    {
        if (
            shouldRevert || (getLower && lowerShouldRevert)
                || (!getLower && upperShouldRevert)
        ) revert();
        return getLower ? (price, errorCode) : (upperPrice, upperErrorCode);
    }
}

contract MonitorMockCToken {
    bool public isBorrowable = true;
    address public marketManager;
    address public asset;
    uint256 public totalSupply;
    uint256 internal _totalAssets;
    uint256 public marketCollateralPosted;
    uint256 public exchangeRate = 1e18;
    uint256 internal _marketOutstandingDebt;
    uint256 internal _assetsHeld;
    uint256 public vestingRate;
    uint256 public vestingEnd;
    uint256 public lastVestingClaim;
    uint256 public debtIndex = 1e18;
    mapping(address => uint256) public balanceOf;
    bool public revertBorrowReads;
    bool public revertTotalAssets;

    constructor(address underlying, address manager) {
        asset = underlying;
        marketManager = manager;
    }

    function setBorrowable(bool value) external {
        isBorrowable = value;
    }

    function setShareData(
        uint256 supply,
        uint256 assets,
        uint256 deadShares,
        uint256 collateral
    ) external {
        totalSupply = supply;
        _totalAssets = assets;
        balanceOf[address(0)] = deadShares;
        marketCollateralPosted = collateral;
    }

    function setBorrowData(
        uint256 debt,
        uint256 held,
        uint256 end,
        uint256 lastClaim,
        uint256 index
    ) external {
        _marketOutstandingDebt = debt;
        _assetsHeld = held;
        vestingEnd = end;
        lastVestingClaim = lastClaim;
        debtIndex = index;
    }

    function setBalance(address account, uint256 amount) external {
        balanceOf[account] = amount;
    }

    function setRevertBorrowReads(bool value) external {
        revertBorrowReads = value;
    }

    function setRevertTotalAssets(bool value) external {
        revertTotalAssets = value;
    }

    function totalAssets() external view returns (uint256) {
        if (revertTotalAssets) revert();
        return _totalAssets;
    }

    function marketOutstandingDebt() external view returns (uint256) {
        if (revertBorrowReads) revert();
        return _marketOutstandingDebt;
    }

    function assetsHeld() external view returns (uint256) {
        if (revertBorrowReads) revert();
        return _assetsHeld;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        if (totalSupply == 0) return 0;
        return shares * _totalAssets / totalSupply;
    }

    function getYieldInformation()
        external
        view
        returns (uint256, uint256, uint256, uint256)
    {
        if (revertBorrowReads) revert();
        return (vestingRate, vestingEnd, lastVestingClaim, debtIndex);
    }
}

contract MonitorMockOptimizer {
    address public asset;
    address[] public approvedCTokensList;
    mapping(address => uint256) public allocationCaps;
    mapping(address => uint256) public balanceOf;
    uint256 public totalAssets;
    uint256 public totalSupply;
    uint256 public exchangeRate = 1e18;
    uint256 public exchangeRateHighWatermark = 1e18;
    uint8 public mintPaused = 1;

    constructor(address underlying) {
        asset = underlying;
    }

    function addMarket(address cToken, uint256 cap) external {
        approvedCTokensList.push(cToken);
        allocationCaps[cToken] = cap;
    }

    function setAccounting(uint256 assets, uint256 supply, uint256 deadShares)
        external
    {
        totalAssets = assets;
        totalSupply = supply;
        balanceOf[address(0)] = deadShares;
    }

    function setMintPaused(uint8 value) external {
        mintPaused = value;
    }

    function numApprovedMarkets() external view returns (uint256) {
        return approvedCTokensList.length;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        if (totalSupply == 0) return 0;
        return shares * totalAssets / totalSupply;
    }
}

contract MonitorMockCentralRegistry {
    address[] internal _markets;
    address internal _oracleManager;
    bool public revertMarkets;
    bool public revertOracleManager;

    function addMarket(address market) external {
        _markets.push(market);
    }

    function setOracleManager(address value) external {
        _oracleManager = value;
    }

    function setRevertMarkets(bool value) external {
        revertMarkets = value;
    }

    function setRevertOracleManager(bool value) external {
        revertOracleManager = value;
    }

    function marketManagers() external view returns (address[] memory) {
        if (revertMarkets) revert();
        return _markets;
    }

    function oracleManager() external view returns (address) {
        if (revertOracleManager) revert();
        return _oracleManager;
    }
}

contract MonitorReaderTest is Test {
    uint256 internal constant RESERVE = 77_777;
    uint256 internal constant TOTAL_ASSETS = 1_000_077_777;
    uint256 internal constant DEBT = 400_000_000;
    uint256 internal constant HELD = 600_000_000;

    MonitorReader internal reader;
    MonitorMockCentralRegistry internal registry;
    MonitorMockUnderlying internal underlying;
    MonitorMockMarketManager internal manager;
    MonitorMockOracleManager internal oracleManager;
    MonitorMockCToken internal cToken;

    function setUp() public virtual {
        reader = new MonitorReader();
        registry = new MonitorMockCentralRegistry();
        underlying = new MonitorMockUnderlying();
        manager = new MonitorMockMarketManager();
        oracleManager = new MonitorMockOracleManager();
        cToken = new MonitorMockCToken(address(underlying), address(manager));

        registry.addMarket(address(manager));
        registry.setOracleManager(address(oracleManager));
        manager.addToken(address(cToken));
        manager.setCaps(address(cToken), type(uint256).max, type(uint256).max);
        oracleManager.setCToken(address(cToken), address(underlying));
        _configureHealthyCToken(cToken, underlying);
    }

    function test_healthyProtocolReturnsTenZeroSignals() public view {
        address[] memory optimizers = new address[](0);

        (
            uint256 wiring,
            uint256 tokenAccounting,
            uint256 backing,
            uint256 borrowAccounting,
            uint256 optimizerCritical
        ) = reader.criticalSignals(address(registry), optimizers);
        assertEq(wiring, 0);
        assertEq(tokenAccounting, 0);
        assertEq(backing, 0);
        assertEq(borrowAccounting, 0);
        assertEq(optimizerCritical, 0);

        (
            uint256 oracleZero,
            uint256 oracleDegraded,
            uint256 collateralOrCap,
            uint256 optimizerWarning,
            uint256 readFailure
        ) = reader.advisorySignals(address(registry), optimizers);
        assertEq(oracleZero, 0);
        assertEq(oracleDegraded, 0);
        assertEq(collateralOrCap, 0);
        assertEq(optimizerWarning, 0);
        assertEq(readFailure, 0);
    }

    function test_backingSignalDecodesToExactCToken() public {
        underlying.setBalance(address(cToken), HELD + RESERVE - 1);
        address[] memory optimizers = new address[](0);

        (
            uint256 wiring,
            uint256 tokenAccounting,
            uint256 backing,
            uint256 borrowAccounting,
            uint256 optimizerCritical
        ) = reader.criticalSignals(address(registry), optimizers);

        assertEq(wiring, 0);
        assertEq(tokenAccounting, 0);
        assertGt(backing, 0);
        assertEq(borrowAccounting, 0);
        assertEq(optimizerCritical, 0);
        _assertDecoded(
            backing,
            address(cToken),
            2,
            reader.FAMILY_CRITICAL_BACKING(),
            1,
            reader.SUBJECT_CTOKEN()
        );
    }

    function test_collateralShareMismatchIsAdvisoryOnly() public {
        cToken.setShareData(
            TOTAL_ASSETS, TOTAL_ASSETS, RESERVE, TOTAL_ASSETS - RESERVE + 1
        );
        address[] memory optimizers = new address[](0);

        (, uint256 tokenAccounting, uint256 backing,,) =
            reader.criticalSignals(address(registry), optimizers);
        assertEq(tokenAccounting, 0);
        assertEq(backing, 0);

        (,, uint256 collateralOrCap,, uint256 readFailure) =
            reader.advisorySignals(address(registry), optimizers);
        assertGt(collateralOrCap, 0);
        assertEq(readFailure, 0);
        _assertDecoded(
            collateralOrCap,
            address(cToken),
            1,
            reader.FAMILY_ADVISORY_COLLATERAL_OR_CAP(),
            1,
            reader.SUBJECT_CTOKEN()
        );
    }

    function test_multipleZeroPricesReturnFirstAssetAndAffectedCount() public {
        (
            MonitorMockUnderlying secondUnderlying,
            MonitorMockCToken secondCToken
        ) = _addHealthyCToken();
        oracleManager.setPrice(0, 0);
        address[] memory optimizers = new address[](0);

        (uint256 oracleZero, uint256 oracleDegraded,,, uint256 readFailure) =
            reader.advisorySignals(address(registry), optimizers);

        assertGt(oracleZero, 0);
        assertEq(oracleDegraded, 0);
        assertEq(readFailure, 0);
        _assertDecoded(
            oracleZero,
            address(underlying),
            1,
            reader.FAMILY_ADVISORY_ORACLE_ZERO(),
            2,
            reader.SUBJECT_ASSET()
        );

        // Keep both references live so the test proves distinct subjects.
        assertTrue(address(secondUnderlying) != address(underlying));
        assertTrue(address(secondCToken) != address(cToken));
    }

    function test_oracleCautionIsAdvisoryNotCritical() public {
        oracleManager.setPrice(1e18, 1);
        address[] memory optimizers = new address[](0);

        (uint256 wiring, uint256 accounting, uint256 backing,,) =
            reader.criticalSignals(address(registry), optimizers);
        assertEq(wiring, 0);
        assertEq(accounting, 0);
        assertEq(backing, 0);

        (, uint256 oracleDegraded,,, uint256 readFailure) =
            reader.advisorySignals(address(registry), optimizers);
        assertEq(readFailure, 0);
        _assertDecoded(
            oracleDegraded,
            address(underlying),
            5,
            reader.FAMILY_ADVISORY_ORACLE_DEGRADED(),
            1,
            reader.SUBJECT_ASSET()
        );
    }

    function test_zeroDebtCapSkipsBorrowSpecificChecks() public {
        manager.setCaps(address(cToken), type(uint256).max, 0);
        cToken.setRevertBorrowReads(true);
        address[] memory optimizers = new address[](0);

        (,, uint256 backing, uint256 borrowAccounting,) =
            reader.criticalSignals(address(registry), optimizers);
        assertEq(backing, 0);
        assertEq(borrowAccounting, 0);

        (,,,, uint256 readFailure) =
            reader.advisorySignals(address(registry), optimizers);
        assertEq(readFailure, 0);

        MonitorReader.CTokenStatus memory status = reader.checkMarketCToken(
            address(cToken), address(manager), address(oracleManager)
        );
        assertEq(status.debtCap, 0);
        assertEq(status.marketOutstandingDebt, 0);
        assertEq(
            status.readErrorMask
                & (reader.CTOKEN_READ_DEBT()
                    | reader.CTOKEN_READ_ASSETS_HELD()
                    | reader.CTOKEN_READ_YIELD()),
            0
        );
    }

    function test_nonBorrowableFlagDoesNotSuppressEnabledBorrowChecks()
        public
    {
        cToken.setBorrowable(false);
        cToken.setBorrowData(DEBT, HELD, 100, 101, 1e18 - 1);
        address[] memory optimizers = new address[](0);

        (,,, uint256 borrowAccounting,) =
            reader.criticalSignals(address(registry), optimizers);
        _assertDecoded(
            borrowAccounting,
            address(cToken),
            1,
            reader.FAMILY_CRITICAL_BORROW_ACCOUNTING(),
            1,
            reader.SUBJECT_CTOKEN()
        );
    }

    function test_registryReadFailureUsesFifthAdvisorySignal() public {
        registry.setRevertMarkets(true);
        address[] memory optimizers = new address[](0);

        (
            uint256 oracleZero,
            uint256 degraded,
            uint256 collateral,,
            uint256 readFailure
        ) = reader.advisorySignals(address(registry), optimizers);
        assertEq(oracleZero, 0);
        assertEq(degraded, 0);
        assertEq(collateral, 0);
        _assertDecoded(
            readFailure,
            address(registry),
            2,
            reader.FAMILY_ADVISORY_READ_FAILURE(),
            1,
            reader.SUBJECT_CENTRAL_REGISTRY()
        );
    }

    function test_emptyRegisteredMarketIsProvisioningNotCritical() public {
        MonitorMockMarketManager provisioningMarket =
            new MonitorMockMarketManager();
        registry.addMarket(address(provisioningMarket));
        address[] memory optimizers = new address[](0);

        (uint256 wiring,,,,) =
            reader.criticalSignals(address(registry), optimizers);
        assertEq(wiring, 0);

        MonitorReader.MarketStatus memory status = reader.checkMarket(
            address(provisioningMarket), address(oracleManager)
        );
        assertTrue(status.brokenMask & reader.MARKET_BROKEN_NO_TOKENS() != 0);
    }

    function test_emptyRegistryIsCriticalWiringNotHealthy() public {
        MonitorMockCentralRegistry emptyRegistry =
            new MonitorMockCentralRegistry();
        emptyRegistry.setOracleManager(address(oracleManager));
        address[] memory optimizers = new address[](0);

        (uint256 wiring,,,,) =
            reader.criticalSignals(address(emptyRegistry), optimizers);
        _assertDecoded(
            wiring,
            address(emptyRegistry),
            3,
            reader.FAMILY_CRITICAL_WIRING(),
            1,
            reader.SUBJECT_CENTRAL_REGISTRY()
        );
    }

    function test_oracleReadFailureDoesNotInventOracleCondition() public {
        oracleManager.setShouldRevert(true);
        address[] memory optimizers = new address[](0);

        (uint256 oracleZero, uint256 degraded,,, uint256 readFailure) =
            reader.advisorySignals(address(registry), optimizers);
        assertEq(oracleZero, 0);
        assertEq(degraded, 0);
        _assertDecoded(
            readFailure,
            address(cToken),
            47,
            reader.FAMILY_ADVISORY_READ_FAILURE(),
            1,
            reader.SUBJECT_CTOKEN()
        );
    }

    function test_optimizerSignalsUseExplicitArgumentsAndDeduplicate() public {
        MonitorMockOptimizer optimizer = _healthyOptimizer();
        optimizer.setMintPaused(2);

        address[] memory optimizers = new address[](2);
        optimizers[0] = address(optimizer);
        optimizers[1] = address(optimizer);

        (,,, uint256 optimizerWarning, uint256 readFailure) =
            reader.advisorySignals(address(registry), optimizers);
        assertEq(readFailure, 0);
        _assertDecoded(
            optimizerWarning,
            address(optimizer),
            2,
            reader.FAMILY_ADVISORY_OPTIMIZER(),
            1,
            reader.SUBJECT_OPTIMIZER()
        );

        optimizer.setAccounting(600_000_000, 600_000_000, RESERVE);
        (,,,, uint256 optimizerCritical) =
            reader.criticalSignals(address(registry), optimizers);
        _assertDecoded(
            optimizerCritical,
            address(optimizer),
            11,
            reader.FAMILY_CRITICAL_OPTIMIZER(),
            1,
            reader.SUBJECT_OPTIMIZER()
        );
    }

    function test_optimizerPositionAboveAllocationCapIsNotAWarning() public {
        MonitorMockCToken secondCToken =
            new MonitorMockCToken(address(underlying), address(manager));
        manager.addToken(address(secondCToken));
        manager.setCaps(
            address(secondCToken), type(uint256).max, type(uint256).max
        );
        oracleManager.setCToken(address(secondCToken), address(underlying));
        _configureHealthyCToken(secondCToken, underlying);

        MonitorMockOptimizer optimizer =
            new MonitorMockOptimizer(address(underlying));
        optimizer.addMarket(address(cToken), 0.5e18);
        optimizer.addMarket(address(secondCToken), 0.5e18);
        optimizer.setAccounting(1_000_000_000, 1_000_000_000, RESERVE);
        cToken.setBalance(address(optimizer), 600_000_000);
        secondCToken.setBalance(address(optimizer), 400_000_000);

        MonitorReader.OptimizerStatus memory status =
            reader.checkOptimizer(address(optimizer));
        assertEq(status.brokenMask, 0);
        assertEq(status.warningMask, 0);
        assertEq(status.readErrorMask, 0);

        address[] memory optimizers = new address[](1);
        optimizers[0] = address(optimizer);
        (,,, uint256 optimizerWarning,) =
            reader.advisorySignals(address(registry), optimizers);
        assertEq(optimizerWarning, 0);
    }

    function test_multipleBackingFailuresReturnDeterministicFirstAndCount()
        public
    {
        (
            MonitorMockUnderlying secondUnderlying,
            MonitorMockCToken secondCToken
        ) = _addHealthyCToken();
        underlying.setBalance(address(cToken), HELD + RESERVE - 1);
        secondUnderlying.setBalance(address(secondCToken), HELD + RESERVE - 1);
        address[] memory optimizers = new address[](0);

        (,, uint256 backing,,) =
            reader.criticalSignals(address(registry), optimizers);
        _assertDecoded(
            backing,
            address(cToken),
            2,
            reader.FAMILY_CRITICAL_BACKING(),
            2,
            reader.SUBJECT_CTOKEN()
        );
    }

    function test_readFailureDoesNotInventAccountingBreak() public {
        cToken.setRevertTotalAssets(true);

        MonitorReader.CTokenStatus memory status =
            reader.checkCToken(address(cToken), address(oracleManager));
        assertTrue(
            status.readErrorMask & reader.CTOKEN_READ_TOTAL_ASSETS() != 0
        );
        assertEq(status.brokenMask & reader.CTOKEN_BROKEN_RESERVE(), 0);
        assertEq(status.brokenMask & reader.CTOKEN_BROKEN_CONVERSION(), 0);
    }

    function _addHealthyCToken()
        internal
        returns (
            MonitorMockUnderlying newUnderlying,
            MonitorMockCToken newCToken
        )
    {
        newUnderlying = new MonitorMockUnderlying();
        newCToken =
            new MonitorMockCToken(address(newUnderlying), address(manager));
        manager.addToken(address(newCToken));
        manager.setCaps(
            address(newCToken), type(uint256).max, type(uint256).max
        );
        oracleManager.setCToken(address(newCToken), address(newUnderlying));
        _configureHealthyCToken(newCToken, newUnderlying);
    }

    function _configureHealthyCToken(
        MonitorMockCToken token,
        MonitorMockUnderlying tokenUnderlying
    ) internal {
        token.setShareData(TOTAL_ASSETS, TOTAL_ASSETS, RESERVE, 100_000_000);
        token.setBorrowData(DEBT, HELD, 200, 100, 1e18);
        tokenUnderlying.setBalance(address(token), HELD + RESERVE);
    }

    function _healthyOptimizer()
        internal
        returns (MonitorMockOptimizer optimizer)
    {
        optimizer = new MonitorMockOptimizer(address(underlying));
        optimizer.addMarket(address(cToken), 1e18);
        optimizer.setAccounting(500_000_000, 500_000_000, RESERVE);
        cToken.setBalance(address(optimizer), 500_000_000);
    }

    function _assertDecoded(
        uint256 signal,
        address expectedSubject,
        uint8 expectedCode,
        uint8 expectedFamily,
        uint16 expectedCount,
        uint8 expectedSubjectType
    ) internal view {
        (
            address subject,
            uint8 findingCode,
            uint8 family,
            uint16 affectedCount,
            uint8 subjectType,
            uint8 encodingVersion
        ) = reader.decodeSignal(signal);

        assertEq(subject, expectedSubject);
        assertEq(findingCode, expectedCode);
        assertEq(family, expectedFamily);
        assertEq(affectedCount, expectedCount);
        assertEq(subjectType, expectedSubjectType);
        assertEq(encodingVersion, reader.SIGNAL_ENCODING_VERSION());
    }
}
