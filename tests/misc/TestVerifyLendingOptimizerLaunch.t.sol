// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {
    VerifyLendingOptimizerLaunch
} from "script/deployment/VerifyLendingOptimizerLaunch.s.sol";
import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";

contract VerifyLendingOptimizerLaunchMockRegistry {}

contract VerifyLendingOptimizerLaunchMockToken {}

contract VerifyLendingOptimizerLaunchMockCToken {
    address public asset;

    constructor(address asset_) {
        asset = asset_;
    }

    function setAsset(address asset_) external {
        asset = asset_;
    }
}

contract VerifyLendingOptimizerLaunchMockOptimizer {
    string public name;
    string public symbol;
    address public asset;
    ICentralRegistry public centralRegistry;
    uint256 public fee;
    address[] public approvedCTokensList;
    mapping(address => uint256) public allocationCaps;

    constructor(
        string memory name_,
        string memory symbol_,
        address asset_,
        ICentralRegistry centralRegistry_,
        uint256 fee_,
        address[] memory markets,
        uint256[] memory caps
    ) {
        name = name_;
        symbol = symbol_;
        asset = asset_;
        centralRegistry = centralRegistry_;
        fee = fee_;
        approvedCTokensList = markets;

        uint256 numMarkets = markets.length;
        for (uint256 i; i < numMarkets; ++i) {
            allocationCaps[markets[i]] = caps[i];
        }
    }

    function setName(string calldata name_) external {
        name = name_;
    }

    function setSymbol(string calldata symbol_) external {
        symbol = symbol_;
    }

    function setAsset(address asset_) external {
        asset = asset_;
    }

    function setCentralRegistry(ICentralRegistry centralRegistry_) external {
        centralRegistry = centralRegistry_;
    }

    function setFee(uint256 fee_) external {
        fee = fee_;
    }

    function setAllocationCap(address market, uint256 cap) external {
        allocationCaps[market] = cap;
    }

    function setApprovedMarket(uint256 index, address market) external {
        approvedCTokensList[index] = market;
    }

    function numApprovedMarkets() external view returns (uint256) {
        return approvedCTokensList.length;
    }
}

contract TestVerifyLendingOptimizerLaunch is Test {
    uint256 internal constant FIRST_CAP = 0.9e18;
    uint256 internal constant SECOND_CAP = 0.2e18;

    VerifyLendingOptimizerLaunch internal script;
    VerifyLendingOptimizerLaunchMockToken internal underlying;
    VerifyLendingOptimizerLaunchMockToken internal otherUnderlying;
    VerifyLendingOptimizerLaunchMockRegistry internal registry;
    VerifyLendingOptimizerLaunchMockRegistry internal otherRegistry;
    VerifyLendingOptimizerLaunchMockCToken internal firstMarket;
    VerifyLendingOptimizerLaunchMockCToken internal secondMarket;
    VerifyLendingOptimizerLaunchMockOptimizer internal optimizer;

    function setUp() public {
        script = new VerifyLendingOptimizerLaunch();
        underlying = new VerifyLendingOptimizerLaunchMockToken();
        otherUnderlying = new VerifyLendingOptimizerLaunchMockToken();
        registry = new VerifyLendingOptimizerLaunchMockRegistry();
        otherRegistry = new VerifyLendingOptimizerLaunchMockRegistry();
        firstMarket =
            new VerifyLendingOptimizerLaunchMockCToken(address(underlying));
        secondMarket =
            new VerifyLendingOptimizerLaunchMockCToken(address(underlying));

        optimizer = new VerifyLendingOptimizerLaunchMockOptimizer(
            "High Yield AUSD Vault",
            "hyAUSD",
            address(underlying),
            ICentralRegistry(address(registry)),
            0,
            _markets(),
            _caps()
        );
    }

    function test_verifyLendingOptimizerLaunch_acceptsExpectedConfig() public {
        script.verify(_config());
    }

    function test_verifyLendingOptimizerLaunch_rejectsWrongName() public {
        optimizer.setName("AUSD-Test");

        vm.expectRevert(
            VerifyLendingOptimizerLaunch.VerifyLendingOptimizerLaunch__InvalidConfig
                .selector
        );
        script.verify(_config());
    }

    function test_verifyLendingOptimizerLaunch_rejectsWrongSymbol() public {
        optimizer.setSymbol("badAUSD");

        vm.expectRevert(
            VerifyLendingOptimizerLaunch.VerifyLendingOptimizerLaunch__InvalidConfig
                .selector
        );
        script.verify(_config());
    }

    function test_verifyLendingOptimizerLaunch_rejectsWrongUnderlying()
        public
    {
        optimizer.setAsset(address(otherUnderlying));

        vm.expectRevert(
            VerifyLendingOptimizerLaunch.VerifyLendingOptimizerLaunch__InvalidConfig
                .selector
        );
        script.verify(_config());
    }

    function test_verifyLendingOptimizerLaunch_rejectsWrongRegistry() public {
        optimizer.setCentralRegistry(ICentralRegistry(address(otherRegistry)));

        vm.expectRevert(
            VerifyLendingOptimizerLaunch.VerifyLendingOptimizerLaunch__InvalidConfig
                .selector
        );
        script.verify(_config());
    }

    function test_verifyLendingOptimizerLaunch_rejectsFeeMismatch() public {
        optimizer.setFee(100);

        vm.expectRevert(
            VerifyLendingOptimizerLaunch.VerifyLendingOptimizerLaunch__InvalidConfig
                .selector
        );
        script.verify(_config());
    }

    function test_verifyLendingOptimizerLaunch_rejectsMarketCountMismatch()
        public
    {
        VerifyLendingOptimizerLaunch.Config memory config = _config();
        address[] memory markets = new address[](1);
        markets[0] = address(firstMarket);
        uint256[] memory caps = new uint256[](1);
        caps[0] = FIRST_CAP;
        config.expectedMarkets = markets;
        config.expectedAllocationCapsWad = caps;

        vm.expectRevert(
            VerifyLendingOptimizerLaunch.VerifyLendingOptimizerLaunch__InvalidConfig
                .selector
        );
        script.verify(config);
    }

    function test_verifyLendingOptimizerLaunch_rejectsMarketOrderMismatch()
        public
    {
        VerifyLendingOptimizerLaunch.Config memory config = _config();
        config.expectedMarkets[0] = address(secondMarket);
        config.expectedMarkets[1] = address(firstMarket);

        vm.expectRevert(
            VerifyLendingOptimizerLaunch.VerifyLendingOptimizerLaunch__InvalidConfig
                .selector
        );
        script.verify(config);
    }

    function test_verifyLendingOptimizerLaunch_rejectsAllocationCapMismatch()
        public
    {
        optimizer.setAllocationCap(address(firstMarket), FIRST_CAP - 1);

        vm.expectRevert(
            VerifyLendingOptimizerLaunch.VerifyLendingOptimizerLaunch__InvalidConfig
                .selector
        );
        script.verify(_config());
    }

    function test_verifyLendingOptimizerLaunch_rejectsMarketUnderlyingMismatch()
        public
    {
        firstMarket.setAsset(address(otherUnderlying));

        vm.expectRevert(
            VerifyLendingOptimizerLaunch.VerifyLendingOptimizerLaunch__InvalidConfig
                .selector
        );
        script.verify(_config());
    }

    function test_verifyLendingOptimizerLaunch_rejectsInsufficientExpectedCaps()
        public
    {
        optimizer.setAllocationCap(address(firstMarket), 0.4e18);
        optimizer.setAllocationCap(address(secondMarket), 0.5e18);

        VerifyLendingOptimizerLaunch.Config memory config = _config();
        config.expectedAllocationCapsWad[0] = 0.4e18;
        config.expectedAllocationCapsWad[1] = 0.5e18;

        vm.expectRevert(
            VerifyLendingOptimizerLaunch.VerifyLendingOptimizerLaunch__InvalidConfig
                .selector
        );
        script.verify(config);
    }

    function test_verifyLendingOptimizerLaunch_runReadsEnvTuple() public {
        vm.setEnv("LENDING_OPTIMIZER_ADDRESS", vm.toString(address(optimizer)));
        vm.setEnv("LENDING_OPTIMIZER_NAME", "High Yield AUSD Vault");
        vm.setEnv("LENDING_OPTIMIZER_SYMBOL", "hyAUSD");
        vm.setEnv(
            "LENDING_OPTIMIZER_UNDERLYING", vm.toString(address(underlying))
        );
        vm.setEnv(
            "LENDING_OPTIMIZER_CENTRAL_REGISTRY",
            vm.toString(address(registry))
        );
        vm.setEnv("LENDING_OPTIMIZER_FEE_BPS", "0");
        vm.setEnv(
            "LENDING_OPTIMIZER_MARKETS",
            string.concat(
                vm.toString(address(firstMarket)),
                ",",
                vm.toString(address(secondMarket))
            )
        );
        vm.setEnv(
            "LENDING_OPTIMIZER_ALLOCATION_CAPS_WAD",
            "900000000000000000,200000000000000000"
        );

        script.run();
    }

    function _config()
        internal
        view
        returns (VerifyLendingOptimizerLaunch.Config memory config)
    {
        config = VerifyLendingOptimizerLaunch.Config({
            optimizer: address(optimizer),
            expectedName: "High Yield AUSD Vault",
            expectedSymbol: "hyAUSD",
            expectedUnderlying: address(underlying),
            expectedCentralRegistry: address(registry),
            expectedFeeBps: 0,
            expectedMarkets: _markets(),
            expectedAllocationCapsWad: _caps()
        });
    }

    function _markets() internal view returns (address[] memory markets) {
        markets = new address[](2);
        markets[0] = address(firstMarket);
        markets[1] = address(secondMarket);
    }

    function _caps() internal pure returns (uint256[] memory caps) {
        caps = new uint256[](2);
        caps[0] = FIRST_CAP;
        caps[1] = SECOND_CAP;
    }
}
