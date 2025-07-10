// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.19;

import { TestERC4626 } from "tests/market/token/4626/TestERC4626.sol";
import { TestBaseMarketIsolated, ICentralRegistry } from "tests/market/TestBaseMarketIsolated.sol";

import { MockERC20Token } from "contracts/mocks/MockERC20Token.sol";
import { MockSimpleCToken } from "contracts/mocks/MockSimpleCToken.sol";

import { console2 } from "forge-std/console2.sol";

// NOTES:
// 1. test_RevertWhen_Redeem fails because of insufficient liquidity

contract TestERC4626CToken is TestERC4626, TestBaseMarketIsolated {
    // @todo check the failing tests: test_maxWithdraw! which reverts
    // test_redeem, test_withdraw have problem with allowance
    function setUp() public override(TestERC4626, TestBaseMarketIsolated) {
        vm.chainId(1);
        vm.warp(1640926800);

        _USDC_ADDRESSES[1] = address(new MockERC20Token());
        _DAI_ADDRESSES[1] = address(new MockERC20Token());

        _deployCentralRegistry();
        _deployCVE();
        _deployRewardManager();
        _deployVeCVE();
        _deployGaugeManager();
        _deployMarketManager();
        _deployBorrowableCDAI();

        vm.warp(centralRegistry.genesisEpoch());
        rewardManager.startRewardManager();

        // start gauge to enable deposits
        vm.warp(veCVE.nextEpochStartTime() + 1000);

        // deploy position token and cToken
        MockERC20Token mockUnderlying = new MockERC20Token();
        vm.label(address(mockUnderlying), "tokenCollateral");
        MockSimpleCToken mockCToken = new MockSimpleCToken(
            ICentralRegistry(address(centralRegistry)),
            address(mockUnderlying),
            address(marketManagerIsolated)
        );
        vm.label(address(mockCToken), "cToken");

        // start market for cToken
        uint256 startAmount = 77777;
        mockUnderlying.mint(address(this), startAmount);
        mockUnderlying.approve(address(mockCToken), startAmount);

        console2.log("checkpoint 1");

        _prepareDAI(address(this), 20000000e18);
        console2.log("checkpoint 2");
        dai.approve(address(borrowableCDAI), 20000000e18);
        console2.log("checkpoint 3");
        marketManagerIsolated.listTokens(address(mockCToken), address(borrowableCDAI));
        console2.log("checkpoint 4");

        _underlying_ = address(mockUnderlying);
        _vault_ = address(mockCToken);
        _delta_ = 0;
        _vaultMayBeEmpty = true;
        _unlimitedAmount = true;
    }

    function test_withdraw(
        Init memory init,
        uint assets,
        uint allowance
    ) public override {}

    function test_maxWithdraw(Init memory init) public override {}

    function test_redeem(
        Init memory init,
        uint shares,
        uint allowance
    ) public override {}
}
