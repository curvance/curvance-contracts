// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { ProtocolManager } from "contracts/architecture/ProtocolManager.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { RemoveMarketPermissions } from "script/deployment/RemoveMarketPermissions.s.sol";
import { RemoveProtocolManagerMarkets } from "script/deployment/RemoveProtocolManagerMarkets.s.sol";
import { TestProtocolManagerBase } from "tests/architecture/ProtocolManager/TestProtocolManagerBase.t.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

contract RemoveMarketPermissionsHarness is RemoveMarketPermissions {
    address internal immutable broadcastCaller;

    constructor(address broadcastCaller_) {
        broadcastCaller = broadcastCaller_;
    }

    modifier recordEvents() override {
        vm.startPrank(broadcastCaller);
        _;
        vm.stopPrank();
    }
}

contract RemoveProtocolManagerMarketsHarness is RemoveProtocolManagerMarkets {
    address internal immutable broadcastCaller;

    constructor(address broadcastCaller_) {
        broadcastCaller = broadcastCaller_;
    }

    modifier recordEvents() override {
        vm.startPrank(broadcastCaller);
        _;
        vm.stopPrank();
    }
}

contract TestProtocolManagerRunbookScripts is TestProtocolManagerBase {
    function setUp() public override {
        super.setUp();

        address[] memory managedAddresses = new address[](2);
        managedAddresses[0] = address(marketManagerIsolated);
        managedAddresses[1] = address(borrowableCWMON);

        ProtocolManager.PeriodLimits[] memory limits =
            new ProtocolManager.PeriodLimits[](2);
        limits[0] = _getValidLimits();
        limits[1] = _getValidLimits();

        protocolManager = new ProtocolManager(
            ICentralRegistry(address(centralRegistry)),
            address(this),
            _getDefaultPermsConfig(),
            managedAddresses,
            limits
        );
    }

    function test_protocolManagerCleanupScriptsPreventAuthorityResurrection()
        public
    {
        RemoveMarketPermissionsHarness removeMarketPermissions =
            new RemoveMarketPermissionsHarness(address(this));
        RemoveProtocolManagerMarketsHarness removeProtocolManagerMarkets =
            new RemoveProtocolManagerMarketsHarness(address(this));

        address[] memory managedAddresses = new address[](2);
        managedAddresses[0] = address(marketManagerIsolated);
        managedAddresses[1] = address(borrowableCWMON);

        centralRegistry.addMarketPermissions(address(protocolManager));
        protocolManager.setPaused(
            address(marketManagerIsolated),
            address(borrowableCWMON),
            3,
            true
        );

        (bool mintPaused, , ) = marketManagerIsolated.actionsPaused(
            address(borrowableCWMON)
        );
        assertTrue(mintPaused, "manager should pause before cleanup");

        removeProtocolManagerMarkets.run(
            address(protocolManager),
            managedAddresses
        );
        removeMarketPermissions.run(
            address(centralRegistry),
            address(protocolManager)
        );

        (bool managerHasAuthority, ) =
            protocolManager.config(address(marketManagerIsolated));
        (bool tokenHasAuthority, ProtocolManager.PeriodLimits memory storedLimits) =
            protocolManager.config(address(borrowableCWMON));
        assertFalse(
            managerHasAuthority,
            "local manager authority must be cleared"
        );
        assertFalse(tokenHasAuthority, "local token authority must be cleared");
        assertEq(storedLimits.collRatioLimit, 0, "local limits must be cleared");
        assertFalse(
            centralRegistry.hasMarketPermissions(address(protocolManager)),
            "global market permission must be cleared"
        );

        centralRegistry.addMarketPermissions(address(protocolManager));

        vm.expectRevert(ProtocolManager.ProtocolManager__Unauthorized.selector);
        protocolManager.setPaused(
            address(marketManagerIsolated),
            address(borrowableCWMON),
            3,
            false
        );
    }

    function test_removeMarketPermissionsAloneLeavesResurrectableLocalAuthority()
        public
    {
        RemoveMarketPermissionsHarness removeMarketPermissions =
            new RemoveMarketPermissionsHarness(address(this));

        centralRegistry.addMarketPermissions(address(protocolManager));
        removeMarketPermissions.run(
            address(centralRegistry),
            address(protocolManager)
        );

        vm.expectRevert(MarketManagerIsolated.MarketManager__Unauthorized.selector);
        protocolManager.setPaused(
            address(marketManagerIsolated),
            address(borrowableCWMON),
            3,
            true
        );

        centralRegistry.addMarketPermissions(address(protocolManager));
        protocolManager.setPaused(
            address(marketManagerIsolated),
            address(borrowableCWMON),
            3,
            true
        );

        (bool mintPaused, , ) = marketManagerIsolated.actionsPaused(
            address(borrowableCWMON)
        );
        assertTrue(
            mintPaused,
            "global-only cleanup can be resurrected by re-grant"
        );
    }
}
