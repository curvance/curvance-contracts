// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {
    AddRedstoneSupport
} from "script/deployment/AddRedstoneSupport.s.sol";
import {
    AddStaticPriceAggregator
} from "script/deployment/AddStaticPriceAggregator.s.sol";
import {
    AddChainlinkFeeds
} from "script/deployment/oracle-migration/AddChainlinkFeeds.s.sol";
import {
    AddCTokenSupport
} from "script/deployment/oracle-migration/AddCTokenSupport.s.sol";
import {
    AddRedstoneClassicFeeds
} from "script/deployment/oracle-migration/AddRedstoneClassicFeeds.s.sol";
import {
    ApproveOracleAdaptor
} from "script/deployment/oracle-migration/ApproveOracleAdaptor.s.sol";
import {
    DeployChainlinkAdaptor
} from "script/deployment/oracle-migration/DeployChainlinkAdaptor.s.sol";
import {
    DeployChainlinkAdaptorOnly
} from "script/deployment/oracle-migration/DeployChainlinkAdaptorOnly.s.sol";
import {
    DeployOracleManager
} from "script/deployment/oracle-migration/DeployOracleManager.s.sol";
import {
    DeployRedstoneClassicAdaptor
} from "script/deployment/oracle-migration/DeployRedstoneClassicAdaptor.s.sol";
import {
    DeployRedstoneClassicAdaptorOnly
} from "script/deployment/oracle-migration/DeployRedstoneClassicAdaptorOnly.s.sol";
import {
    SetCombinedAggregatorGuards
} from "script/deployment/oracle-migration/SetCombinedAggregatorGuards.s.sol";
import {
    OracleDeploymentPreflight
} from "script/utils/OracleDeploymentPreflight.sol";
import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";

contract AddRedstoneSupportHarness is AddRedstoneSupport {
    modifier recordEvents() override {
        _;
    }
}

contract AddStaticPriceAggregatorHarness is AddStaticPriceAggregator {
    modifier recordEvents() override {
        _;
    }
}

contract AddChainlinkFeedsHarness is AddChainlinkFeeds {
    modifier recordEvents() override {
        _;
    }
}

contract AddRedstoneClassicFeedsHarness is AddRedstoneClassicFeeds {
    modifier recordEvents() override {
        _;
    }
}

contract AddCTokenSupportHarness is AddCTokenSupport {
    modifier recordEvents() override {
        _;
    }
}

contract SetCombinedAggregatorGuardsHarness is SetCombinedAggregatorGuards {
    modifier recordEvents() override {
        _;
    }
}

contract ApproveOracleAdaptorHarness is ApproveOracleAdaptor {
    modifier recordEvents() override {
        _;
    }
}

contract DeployChainlinkAdaptorHarness is DeployChainlinkAdaptor {
    modifier recordEvents() override {
        _;
    }
}

contract DeployChainlinkAdaptorOnlyHarness is DeployChainlinkAdaptorOnly {
    modifier recordEvents() override {
        _;
    }
}

contract DeployOracleManagerHarness is DeployOracleManager {
    modifier recordEvents() override {
        _;
    }
}

contract DeployRedstoneClassicAdaptorHarness is DeployRedstoneClassicAdaptor {
    modifier recordEvents() override {
        _;
    }
}

contract DeployRedstoneClassicAdaptorOnlyHarness is
    DeployRedstoneClassicAdaptorOnly
{
    modifier recordEvents() override {
        _;
    }
}

contract OracleMigrationRegistry {
    function supportsInterface(bytes4 interfaceId)
        external
        pure
        returns (bool)
    {
        return interfaceId == type(ICentralRegistry).interfaceId
            || interfaceId == 0x01ffc9a7;
    }
}

contract OracleMigrationManager {
    address public immutable centralRegistry;
    uint256 public addAssetPricingAdaptorCalls;
    uint256 public addCTokenSupportCalls;
    uint256 public addApprovedAdaptorCalls;
    bool public revertAddAssetPricingAdaptor;
    mapping(address asset => address[] adaptors) internal _pricingAdaptors;

    constructor(address centralRegistry_) {
        centralRegistry = centralRegistry_;
    }

    function addAssetPricingAdaptor(
        address,
        address,
        uint256,
        uint256,
        uint256,
        uint256
    ) external {
        if (revertAddAssetPricingAdaptor) {
            revert("MANAGER_REVERT");
        }
        ++addAssetPricingAdaptorCalls;
    }

    function setRevertAddAssetPricingAdaptor(bool value) external {
        revertAddAssetPricingAdaptor = value;
    }

    function setPricingAdaptorCount(address asset, uint256 count) external {
        delete _pricingAdaptors[asset];

        for (uint256 i; i < count; ++i) {
            _pricingAdaptors[asset].push(address(uint160(i + 1)));
        }
    }

    function getPricingAdaptors(address asset)
        external
        view
        returns (address[] memory)
    {
        return _pricingAdaptors[asset];
    }

    function addCTokenSupport(address) external {
        ++addCTokenSupportCalls;
    }

    function addApprovedAdaptor(address) external {
        ++addApprovedAdaptorCalls;
    }
}

contract OracleMigrationChainlinkAdaptor {
    uint256 public addAssetCalls;
    uint256 public removeAssetCalls;
    uint256 public guardCalls;
    bool public revertGuard;

    function addAsset(address, bool, address, uint256) external {
        ++addAssetCalls;
    }

    function setGuardedPriceConfig(
        address,
        bool,
        uint256,
        uint256,
        uint256,
        uint256
    ) external {
        if (revertGuard) {
            revert("GUARD_REVERT");
        }

        ++guardCalls;
    }

    function removeAsset(address) external {
        ++removeAssetCalls;
    }

    function setRevertGuard(bool value) external {
        revertGuard = value;
    }
}

contract OracleMigrationRedstoneAdaptor {
    uint256 public addAssetCalls;
    uint256 public removeAssetCalls;
    uint256 public guardCalls;
    bool public revertGuard;

    function addAsset(address, bool, address, uint256, string memory)
        external
    {
        ++addAssetCalls;
    }

    function setGuardedPriceConfig(
        address,
        bool,
        uint256,
        uint256,
        uint256,
        uint256
    ) external {
        if (revertGuard) {
            revert("GUARD_REVERT");
        }

        ++guardCalls;
    }

    function removeAsset(address) external {
        ++removeAssetCalls;
    }

    function setRevertGuard(bool value) external {
        revertGuard = value;
    }
}

contract OracleMigrationCombinedAggregator {
    uint256 public guardCalls;

    function setGuardedPriceConfig(uint256, uint256, uint256, uint256)
        external
    {
        ++guardCalls;
    }
}

contract OracleMigrationRevertingCombinedAggregator {
    function setGuardedPriceConfig(uint256, uint256, uint256, uint256)
        external
        pure
    {
        revert("GUARD_SHOULD_NOT_BE_CALLED");
    }
}

contract OracleMigrationFeed {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function getDataFeedId() external pure returns (bytes32) {
        return bytes32("ASSET");
    }
}

contract OracleMigrationCToken {}

contract OracleMigrationAdaptor {}

contract TestOracleMigrationPreflight is Test {
    function test_addChainlinkFeeds_rejectsInvalidLaterFeedBeforeFirstMutation()
        public
    {
        AddChainlinkFeedsHarness script = new AddChainlinkFeedsHarness();
        OracleMigrationManager manager =
            new OracleMigrationManager(address(new OracleMigrationRegistry()));
        OracleMigrationChainlinkAdaptor adaptor =
            new OracleMigrationChainlinkAdaptor();
        OracleMigrationFeed feed = new OracleMigrationFeed();

        AddChainlinkFeeds.ChainlinkFeed[] memory feeds =
            new AddChainlinkFeeds.ChainlinkFeed[](2);
        feeds[0] = AddChainlinkFeeds.ChainlinkFeed({
            asset: address(1),
            inUSD: true,
            aggregator: address(feed),
            heartbeat: 6 hours,
            bounds: _chainlinkBounds(),
            guard: _chainlinkGuard()
        });
        feeds[1] = AddChainlinkFeeds.ChainlinkFeed({
            asset: address(2),
            inUSD: true,
            aggregator: address(0xBEEF),
            heartbeat: 6 hours,
            bounds: _chainlinkBounds(),
            guard: _chainlinkGuard()
        });

        vm.expectRevert(
            OracleDeploymentPreflight.OracleDeploymentPreflight__InvalidPreflight
                .selector
        );
        script.run(address(manager), address(adaptor), feeds);

        assertEq(adaptor.addAssetCalls(), 0);
        assertEq(manager.addAssetPricingAdaptorCalls(), 0);
    }

    function test_addRedstoneClassicFeeds_rejectsInvalidLaterFeedBeforeFirstMutation()
        public
    {
        AddRedstoneClassicFeedsHarness script =
            new AddRedstoneClassicFeedsHarness();
        OracleMigrationManager manager =
            new OracleMigrationManager(address(new OracleMigrationRegistry()));
        OracleMigrationRedstoneAdaptor adaptor =
            new OracleMigrationRedstoneAdaptor();
        OracleMigrationFeed feed = new OracleMigrationFeed();

        AddRedstoneClassicFeeds.RedstoneClassicFeed[] memory feeds =
            new AddRedstoneClassicFeeds.RedstoneClassicFeed[](2);
        feeds[0] = AddRedstoneClassicFeeds.RedstoneClassicFeed({
            asset: address(1),
            inUSD: true,
            feedProxy: address(feed),
            heartbeat: 6 hours,
            dataFeedId: "ASSET",
            bounds: _redstoneBounds(),
            guard: _redstoneGuard()
        });
        feeds[1] = AddRedstoneClassicFeeds.RedstoneClassicFeed({
            asset: address(2),
            inUSD: true,
            feedProxy: address(0xBEEF),
            heartbeat: 6 hours,
            dataFeedId: "ASSET",
            bounds: _redstoneBounds(),
            guard: _redstoneGuard()
        });

        vm.expectRevert(
            OracleDeploymentPreflight.OracleDeploymentPreflight__InvalidPreflight
                .selector
        );
        script.run(address(manager), address(adaptor), feeds);

        assertEq(adaptor.addAssetCalls(), 0);
        assertEq(manager.addAssetPricingAdaptorCalls(), 0);
    }

    function test_addChainlinkFeeds_allowsDisabledGuardWithIgnoredFields()
        public
    {
        AddChainlinkFeedsHarness script = new AddChainlinkFeedsHarness();
        OracleMigrationManager manager =
            new OracleMigrationManager(address(new OracleMigrationRegistry()));
        OracleMigrationChainlinkAdaptor adaptor =
            new OracleMigrationChainlinkAdaptor();
        OracleMigrationFeed feed = new OracleMigrationFeed();

        AddChainlinkFeeds.ChainlinkFeed[] memory feeds =
            new AddChainlinkFeeds.ChainlinkFeed[](1);
        feeds[0] = AddChainlinkFeeds.ChainlinkFeed({
            asset: address(1),
            inUSD: true,
            aggregator: address(feed),
            heartbeat: 6 hours,
            bounds: _chainlinkBounds(),
            guard: _chainlinkDisabledGuardWithIgnoredFields()
        });

        script.run(address(manager), address(adaptor), feeds);

        assertEq(adaptor.addAssetCalls(), 1);
        assertEq(adaptor.guardCalls(), 0);
        assertEq(manager.addAssetPricingAdaptorCalls(), 1);
    }

    function test_addRedstoneClassicFeeds_allowsDisabledGuardWithIgnoredFields()
        public
    {
        AddRedstoneClassicFeedsHarness script =
            new AddRedstoneClassicFeedsHarness();
        OracleMigrationManager manager =
            new OracleMigrationManager(address(new OracleMigrationRegistry()));
        OracleMigrationRedstoneAdaptor adaptor =
            new OracleMigrationRedstoneAdaptor();
        OracleMigrationFeed feed = new OracleMigrationFeed();

        AddRedstoneClassicFeeds.RedstoneClassicFeed[] memory feeds =
            new AddRedstoneClassicFeeds.RedstoneClassicFeed[](1);
        feeds[0] = AddRedstoneClassicFeeds.RedstoneClassicFeed({
            asset: address(1),
            inUSD: true,
            feedProxy: address(feed),
            heartbeat: 6 hours,
            dataFeedId: "ASSET",
            bounds: _redstoneBounds(),
            guard: _redstoneDisabledGuardWithIgnoredFields()
        });

        script.run(address(manager), address(adaptor), feeds);

        assertEq(adaptor.addAssetCalls(), 1);
        assertEq(adaptor.guardCalls(), 0);
        assertEq(manager.addAssetPricingAdaptorCalls(), 1);
    }

    function test_addChainlinkFeeds_allowsUnusedZeroBoundsForFirstAdaptor()
        public
    {
        AddChainlinkFeedsHarness script = new AddChainlinkFeedsHarness();
        OracleMigrationManager manager =
            new OracleMigrationManager(address(new OracleMigrationRegistry()));
        OracleMigrationChainlinkAdaptor adaptor =
            new OracleMigrationChainlinkAdaptor();
        OracleMigrationFeed feed = new OracleMigrationFeed();

        AddChainlinkFeeds.ChainlinkFeed[] memory feeds =
            new AddChainlinkFeeds.ChainlinkFeed[](1);
        feeds[0] = AddChainlinkFeeds.ChainlinkFeed({
            asset: address(1),
            inUSD: true,
            aggregator: address(feed),
            heartbeat: 6 hours,
            bounds: _zeroChainlinkBounds(),
            guard: _chainlinkGuard()
        });

        script.run(address(manager), address(adaptor), feeds);

        assertEq(adaptor.addAssetCalls(), 1);
        assertEq(manager.addAssetPricingAdaptorCalls(), 1);
    }

    function test_addRedstoneClassicFeeds_allowsUnusedZeroBoundsForFirstAdaptor()
        public
    {
        AddRedstoneClassicFeedsHarness script =
            new AddRedstoneClassicFeedsHarness();
        OracleMigrationManager manager =
            new OracleMigrationManager(address(new OracleMigrationRegistry()));
        OracleMigrationRedstoneAdaptor adaptor =
            new OracleMigrationRedstoneAdaptor();
        OracleMigrationFeed feed = new OracleMigrationFeed();

        AddRedstoneClassicFeeds.RedstoneClassicFeed[] memory feeds =
            new AddRedstoneClassicFeeds.RedstoneClassicFeed[](1);
        feeds[0] = AddRedstoneClassicFeeds.RedstoneClassicFeed({
            asset: address(1),
            inUSD: true,
            feedProxy: address(feed),
            heartbeat: 6 hours,
            dataFeedId: "ASSET",
            bounds: _zeroRedstoneBounds(),
            guard: _redstoneGuard()
        });

        script.run(address(manager), address(adaptor), feeds);

        assertEq(adaptor.addAssetCalls(), 1);
        assertEq(manager.addAssetPricingAdaptorCalls(), 1);
    }

    function test_addChainlinkFeeds_rejectsBadBoundsOnlyWhenAddingSecondAdaptor()
        public
    {
        AddChainlinkFeedsHarness script = new AddChainlinkFeedsHarness();
        OracleMigrationManager manager =
            new OracleMigrationManager(address(new OracleMigrationRegistry()));
        OracleMigrationChainlinkAdaptor adaptor =
            new OracleMigrationChainlinkAdaptor();
        OracleMigrationFeed feed = new OracleMigrationFeed();

        manager.setPricingAdaptorCount(address(1), 1);

        AddChainlinkFeeds.ChainlinkFeed[] memory feeds =
            new AddChainlinkFeeds.ChainlinkFeed[](1);
        feeds[0] = AddChainlinkFeeds.ChainlinkFeed({
            asset: address(1),
            inUSD: true,
            aggregator: address(feed),
            heartbeat: 6 hours,
            bounds: _zeroChainlinkBounds(),
            guard: _chainlinkGuard()
        });

        vm.expectRevert(
            OracleDeploymentPreflight.OracleDeploymentPreflight__InvalidPreflight
                .selector
        );
        script.run(address(manager), address(adaptor), feeds);

        assertEq(adaptor.addAssetCalls(), 0);
        assertEq(manager.addAssetPricingAdaptorCalls(), 0);
    }

    function test_addChainlinkFeeds_removesCurrentAssetWhenManagerRegistrationFails()
        public
    {
        AddChainlinkFeedsHarness script = new AddChainlinkFeedsHarness();
        OracleMigrationManager manager =
            new OracleMigrationManager(address(new OracleMigrationRegistry()));
        manager.setRevertAddAssetPricingAdaptor(true);
        OracleMigrationChainlinkAdaptor adaptor =
            new OracleMigrationChainlinkAdaptor();
        OracleMigrationFeed feed = new OracleMigrationFeed();

        AddChainlinkFeeds.ChainlinkFeed[] memory feeds =
            new AddChainlinkFeeds.ChainlinkFeed[](1);
        feeds[0] = AddChainlinkFeeds.ChainlinkFeed({
            asset: address(1),
            inUSD: true,
            aggregator: address(feed),
            heartbeat: 6 hours,
            bounds: _chainlinkBounds(),
            guard: _chainlinkGuard()
        });

        vm.expectCall(
            address(adaptor),
            abi.encodeWithSignature("removeAsset(address)", address(1))
        );
        vm.expectRevert("MANAGER_REVERT");
        script.run(address(manager), address(adaptor), feeds);
    }

    function test_addRedstoneClassicFeeds_removesCurrentAssetWhenGuardRegistrationFails()
        public
    {
        AddRedstoneClassicFeedsHarness script =
            new AddRedstoneClassicFeedsHarness();
        OracleMigrationManager manager =
            new OracleMigrationManager(address(new OracleMigrationRegistry()));
        OracleMigrationRedstoneAdaptor adaptor =
            new OracleMigrationRedstoneAdaptor();
        adaptor.setRevertGuard(true);
        OracleMigrationFeed feed = new OracleMigrationFeed();

        AddRedstoneClassicFeeds.RedstoneClassicFeed[] memory feeds =
            new AddRedstoneClassicFeeds.RedstoneClassicFeed[](1);
        feeds[0] = AddRedstoneClassicFeeds.RedstoneClassicFeed({
            asset: address(1),
            inUSD: true,
            feedProxy: address(feed),
            heartbeat: 6 hours,
            dataFeedId: "ASSET",
            bounds: _redstoneBounds(),
            guard: AddRedstoneClassicFeeds.PriceGuard({
                enabled: true,
                inUSD: true,
                timestampStart: 0,
                ips: 0,
                basePrice: 1e18,
                minPrice: 0
            })
        });

        vm.expectCall(
            address(adaptor),
            abi.encodeWithSignature("removeAsset(address)", address(1))
        );
        vm.expectRevert("GUARD_REVERT");
        script.run(address(manager), address(adaptor), feeds);
    }

    function test_addCTokenSupport_rejectsInvalidLaterCTokenBeforeFirstMutation()
        public
    {
        AddCTokenSupportHarness script = new AddCTokenSupportHarness();
        OracleMigrationManager manager =
            new OracleMigrationManager(address(new OracleMigrationRegistry()));

        address[] memory cTokens = new address[](2);
        cTokens[0] = address(new OracleMigrationCToken());
        cTokens[1] = address(0xBEEF);

        vm.expectRevert(
            OracleDeploymentPreflight.OracleDeploymentPreflight__InvalidPreflight
                .selector
        );
        script.run(address(manager), cTokens);

        assertEq(manager.addCTokenSupportCalls(), 0);
    }

    function test_setCombinedAggregatorGuards_rejectsInvalidLaterAggregatorBeforeFirstMutation()
        public
    {
        SetCombinedAggregatorGuardsHarness script =
            new SetCombinedAggregatorGuardsHarness();
        OracleMigrationCombinedAggregator aggregator =
            new OracleMigrationCombinedAggregator();

        SetCombinedAggregatorGuards.CombinedAggregatorGuard[] memory guards =
            new SetCombinedAggregatorGuards.CombinedAggregatorGuard[](2);
        guards[0] = SetCombinedAggregatorGuards.CombinedAggregatorGuard({
            aggregator: address(aggregator),
            guard: SetCombinedAggregatorGuards.PriceGuard({
                enabled: true,
                timestampStart: 0,
                ips: 0,
                basePrice: 1e18,
                minPrice: 0
            })
        });
        guards[1] = SetCombinedAggregatorGuards.CombinedAggregatorGuard({
            aggregator: address(0xBEEF),
            guard: SetCombinedAggregatorGuards.PriceGuard({
                enabled: true,
                timestampStart: 0,
                ips: 0,
                basePrice: 1e18,
                minPrice: 0
            })
        });

        vm.expectRevert(
            OracleDeploymentPreflight.OracleDeploymentPreflight__InvalidPreflight
                .selector
        );
        script.run(guards);

        assertEq(aggregator.guardCalls(), 0);
    }

    function test_setCombinedAggregatorGuards_allowsDisabledGuardWithIgnoredFields()
        public
    {
        SetCombinedAggregatorGuardsHarness script =
            new SetCombinedAggregatorGuardsHarness();
        OracleMigrationRevertingCombinedAggregator aggregator =
            new OracleMigrationRevertingCombinedAggregator();

        SetCombinedAggregatorGuards.CombinedAggregatorGuard[] memory guards =
            new SetCombinedAggregatorGuards.CombinedAggregatorGuard[](1);
        guards[0] = SetCombinedAggregatorGuards.CombinedAggregatorGuard({
            aggregator: address(aggregator),
            guard: SetCombinedAggregatorGuards.PriceGuard({
                enabled: false,
                timestampStart: block.timestamp + 1 days,
                ips: type(uint256).max,
                basePrice: type(uint256).max,
                minPrice: type(uint256).max
            })
        });

        script.run(guards);
    }

    function test_addRedstoneSupport_rejectsNonContractClassicFeedBeforeMutation()
        public
    {
        AddRedstoneSupportHarness script = new AddRedstoneSupportHarness();
        OracleMigrationManager manager =
            new OracleMigrationManager(address(new OracleMigrationRegistry()));
        OracleMigrationRedstoneAdaptor adaptor =
            new OracleMigrationRedstoneAdaptor();

        AddRedstoneSupport.PushFeed memory feed = AddRedstoneSupport.PushFeed({
            inUSD: true,
            feed: address(0xBEEF),
            heartbeat: 6 hours,
            id: "ASSET"
        });

        vm.expectRevert(
            OracleDeploymentPreflight.OracleDeploymentPreflight__InvalidPreflight
                .selector
        );
        script.run(
            address(1),
            address(adaptor),
            address(manager),
            feed,
            _redstoneSupportGuard()
        );

        assertEq(adaptor.addAssetCalls(), 0);
        assertEq(manager.addAssetPricingAdaptorCalls(), 0);
    }

    function test_addStaticPriceAggregator_rejectsNonContractAdaptorBeforeMutation()
        public
    {
        AddStaticPriceAggregatorHarness script =
            new AddStaticPriceAggregatorHarness();
        OracleMigrationManager manager =
            new OracleMigrationManager(address(new OracleMigrationRegistry()));

        vm.expectRevert(
            OracleDeploymentPreflight.OracleDeploymentPreflight__InvalidPreflight
                .selector
        );
        script.run(
            address(1),
            1e18,
            address(0xBEEF),
            address(manager),
            6 hours,
            true,
            _staticAggregatorGuard()
        );

        assertEq(manager.addAssetPricingAdaptorCalls(), 0);
    }

    function test_approveOracleAdaptor_rejectsNonContractAdaptorBeforeManagerMutation()
        public
    {
        ApproveOracleAdaptorHarness script = new ApproveOracleAdaptorHarness();
        OracleMigrationManager manager =
            new OracleMigrationManager(address(new OracleMigrationRegistry()));

        vm.expectRevert(
            OracleDeploymentPreflight.OracleDeploymentPreflight__InvalidPreflight
                .selector
        );
        script.run(address(manager), address(0xBEEF));

        assertEq(manager.addApprovedAdaptorCalls(), 0);
    }

    function test_deployOracleManager_rejectsNonContractRegistryBeforeDeployment()
        public
    {
        DeployOracleManagerHarness script = new DeployOracleManagerHarness();

        vm.expectRevert(
            OracleDeploymentPreflight.OracleDeploymentPreflight__InvalidPreflight
                .selector
        );
        script.run(address(0xBEEF));
    }

    function test_deployAdaptorOnly_rejectsNonContractRegistryBeforeDeployment()
        public
    {
        DeployChainlinkAdaptorOnlyHarness chainlinkScript =
            new DeployChainlinkAdaptorOnlyHarness();
        DeployRedstoneClassicAdaptorOnlyHarness redstoneScript =
            new DeployRedstoneClassicAdaptorOnlyHarness();

        vm.expectRevert(
            OracleDeploymentPreflight.OracleDeploymentPreflight__InvalidPreflight
                .selector
        );
        chainlinkScript.run(address(0xBEEF));

        vm.expectRevert(
            OracleDeploymentPreflight.OracleDeploymentPreflight__InvalidPreflight
                .selector
        );
        redstoneScript.run(address(0xBEEF));
    }

    function test_deployAndApproveAdaptor_rejectsManagerRegistryMismatchBeforeDeployment()
        public
    {
        DeployChainlinkAdaptorHarness chainlinkScript =
            new DeployChainlinkAdaptorHarness();
        DeployRedstoneClassicAdaptorHarness redstoneScript =
            new DeployRedstoneClassicAdaptorHarness();
        OracleMigrationRegistry registry = new OracleMigrationRegistry();
        OracleMigrationManager manager =
            new OracleMigrationManager(address(new OracleMigrationRegistry()));

        vm.expectRevert(
            OracleDeploymentPreflight.OracleDeploymentPreflight__InvalidPreflight
                .selector
        );
        chainlinkScript.run(address(registry), address(manager));

        vm.expectRevert(
            OracleDeploymentPreflight.OracleDeploymentPreflight__InvalidPreflight
                .selector
        );
        redstoneScript.run(address(registry), address(manager));

        assertEq(manager.addApprovedAdaptorCalls(), 0);
    }

    function _chainlinkBounds()
        internal
        pure
        returns (AddChainlinkFeeds.DeviationBounds memory)
    {
        return AddChainlinkFeeds.DeviationBounds({
            badSourceUSD: 250,
            cautionUSD: 220,
            badSourceNative: 250,
            cautionNative: 220
        });
    }

    function _redstoneBounds()
        internal
        pure
        returns (AddRedstoneClassicFeeds.DeviationBounds memory)
    {
        return AddRedstoneClassicFeeds.DeviationBounds({
            badSourceUSD: 250,
            cautionUSD: 220,
            badSourceNative: 250,
            cautionNative: 220
        });
    }

    function _zeroChainlinkBounds()
        internal
        pure
        returns (AddChainlinkFeeds.DeviationBounds memory)
    {
        return AddChainlinkFeeds.DeviationBounds({
            badSourceUSD: 0,
            cautionUSD: 0,
            badSourceNative: 0,
            cautionNative: 0
        });
    }

    function _zeroRedstoneBounds()
        internal
        pure
        returns (AddRedstoneClassicFeeds.DeviationBounds memory)
    {
        return AddRedstoneClassicFeeds.DeviationBounds({
            badSourceUSD: 0,
            cautionUSD: 0,
            badSourceNative: 0,
            cautionNative: 0
        });
    }

    function _chainlinkGuard()
        internal
        pure
        returns (AddChainlinkFeeds.PriceGuard memory)
    {
        return AddChainlinkFeeds.PriceGuard({
            enabled: false,
            inUSD: true,
            timestampStart: 0,
            ips: 0,
            basePrice: 0,
            minPrice: 0
        });
    }

    function _redstoneGuard()
        internal
        pure
        returns (AddRedstoneClassicFeeds.PriceGuard memory)
    {
        return AddRedstoneClassicFeeds.PriceGuard({
            enabled: false,
            inUSD: true,
            timestampStart: 0,
            ips: 0,
            basePrice: 0,
            minPrice: 0
        });
    }

    function _chainlinkDisabledGuardWithIgnoredFields()
        internal
        view
        returns (AddChainlinkFeeds.PriceGuard memory)
    {
        return AddChainlinkFeeds.PriceGuard({
            enabled: false,
            inUSD: true,
            timestampStart: block.timestamp + 1 days,
            ips: type(uint256).max,
            basePrice: type(uint256).max,
            minPrice: type(uint256).max
        });
    }

    function _redstoneDisabledGuardWithIgnoredFields()
        internal
        view
        returns (AddRedstoneClassicFeeds.PriceGuard memory)
    {
        return AddRedstoneClassicFeeds.PriceGuard({
            enabled: false,
            inUSD: true,
            timestampStart: block.timestamp + 1 days,
            ips: type(uint256).max,
            basePrice: type(uint256).max,
            minPrice: type(uint256).max
        });
    }

    function _redstoneSupportGuard()
        internal
        pure
        returns (AddRedstoneSupport.PriceGuard memory)
    {
        return AddRedstoneSupport.PriceGuard({
            enabled: false,
            inUSD: true,
            timestampSubtract: 0,
            ips: 0,
            basePrice: 0,
            minPrice: 0
        });
    }

    function _staticAggregatorGuard()
        internal
        pure
        returns (AddStaticPriceAggregator.PriceGuard memory)
    {
        return AddStaticPriceAggregator.PriceGuard({
            enabled: false,
            inUSD: true,
            timestampSubtract: 0,
            ips: 0,
            basePrice: 0,
            minPrice: 0
        });
    }
}
