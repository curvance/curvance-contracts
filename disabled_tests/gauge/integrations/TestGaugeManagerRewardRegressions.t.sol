// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";
import { CVEBase } from "contracts/token/CVEBase.sol";

contract TestGaugeManagerRewardRegressions is TestBaseMarketIsolated {
    MockGaugeMarketManager internal mockGaugeMarketManager;
    MockGaugeToken internal mockGaugeToken;

    function setUp() public override {
        super.setUp();
        _skipRestrictionDuration();

        mockGaugeMarketManager = new MockGaugeMarketManager();
        centralRegistry.addMarketManager(address(mockGaugeMarketManager));
        mockGaugeToken = new MockGaugeToken(address(mockGaugeMarketManager));
    }

    function test_updatePool_doesNotRewardNextDepositorForIdleInterval()
        public
    {
        address token = address(mockGaugeToken);
        uint256 amount = 100e18;

        address[] memory tokens = new address[](1);
        tokens[0] = token;

        uint256[] memory weights = new uint256[](1);
        weights[0] = 100e18;

        vm.prank(address(messagingHub));
        gaugeManager.setEmissionRates(0, tokens, weights);

        vm.prank(token);
        gaugeManager.deposit(token, user1, amount);

        _skipEpochDuration(1);

        vm.prank(token);
        gaugeManager.withdraw(token, user1, amount);

        _skipEpochDuration(1);

        vm.prank(token);
        gaugeManager.deposit(token, user2, amount);

        assertEq(gaugeManager.pendingRewards(token, user2), 0);
    }

    function test_delegatedClaimPaysRewardOwner() public {
        address token = address(mockGaugeToken);
        uint256 amount = 100e18;
        address delegate = user2;

        address[] memory tokens = new address[](1);
        tokens[0] = token;

        uint256[] memory weights = new uint256[](1);
        weights[0] = 100e18;

        vm.prank(address(messagingHub));
        gaugeManager.setEmissionRates(0, tokens, weights);

        vm.prank(token);
        gaugeManager.deposit(token, user1, amount);

        _skipEpochDuration(1);

        uint256 pending = gaugeManager.pendingRewards(token, user1);
        assertGt(pending, 0);
        deal(address(cve), address(gaugeManager), pending);

        vm.prank(user1);
        gaugeManager.setDelegateApproval(delegate, true);

        vm.prank(delegate);
        gaugeManager.claim(tokens, user1);

        assertEq(cve.balanceOf(user1), pending);
        assertEq(cve.balanceOf(delegate), 0);
        assertEq(gaugeManager.pendingRewards(token, user1), 0);
    }

    function test_setEmissionRatesAccumulatesIncrementalDeliveriesForEpoch()
        public
    {
        address token = address(mockGaugeToken);

        address[] memory tokens = new address[](1);
        tokens[0] = token;

        uint256[] memory weights = new uint256[](1);
        weights[0] = 100e18;

        vm.prank(address(messagingHub));
        gaugeManager.setEmissionRates(0, tokens, weights);

        weights[0] = 250e18;

        vm.prank(address(messagingHub));
        gaugeManager.setEmissionRates(0, tokens, weights);

        (uint256 totalWeight, uint256 tokenWeight) = gaugeManager.gaugeWeight(
            0,
            token
        );

        assertEq(totalWeight, 350e18);
        assertEq(tokenWeight, 350e18);
    }

    function test_mintLockBoostRejectsNonGaugeLockingPermission() public {
        uint256 amount = 100e18;

        centralRegistry.addLockingPermissions(user1);

        vm.prank(user1);
        vm.expectRevert(CVEBase.CVE__Unauthorized.selector);
        cve.mintLockBoost(amount);

        vm.prank(address(gaugeManager));
        cve.mintLockBoost(amount);

        assertEq(cve.balanceOf(user1), 0);
        assertEq(cve.balanceOf(address(gaugeManager)), amount);
    }
}

contract MockGaugeMarketManager {
    function isListed(address) external pure returns (bool) {
        return true;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return
            interfaceId == type(IMarketManager).interfaceId ||
            interfaceId == 0x01ffc9a7;
    }
}

contract MockGaugeToken {
    address public immutable marketManager;

    constructor(address marketManager_) {
        marketManager = marketManager_;
    }
}
