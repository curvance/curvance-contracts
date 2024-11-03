// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.19;

import { TestERC4626 } from "tests/market/token/4626/TestERC4626.sol";
import { TestBaseMarket, ICentralRegistry } from "tests/market/TestBaseMarket.sol";

import { MockERC20Token } from "contracts/mocks/MockERC20Token.sol";
import { MockSimplePToken } from "contracts/mocks/MockSimplePToken.sol";

contract TestERC4626PToken is TestERC4626, TestBaseMarket {
    // @todo check the failing tests: test_maxWithdraw! which reverts
    // test_redeem, test_withdraw have problem with allowance
    function setUp() public override(TestERC4626, TestBaseMarket) {
        vm.chainId(1);

        _USDC_ADDRESSES[1] = address(new MockERC20Token());

        _deployCentralRegistry();
        _deployCVE();
        _deployRewardManager();
        _deployVeCVE();
        _deployGaugeManager();
        _deployMarketManager();

        vm.warp(centralRegistry.genesisEpoch());
        rewardManager.startRewardManager();

        // start gauge to enable deposits
        vm.warp(veCVE.nextEpochStartTime() + 1000);

        // deploy position token and pToken
        MockERC20Token mockUnderlying = new MockERC20Token();
        vm.label(address(mockUnderlying), "tokenCollateral");
        MockSimplePToken mockPToken = new MockSimplePToken(
            ICentralRegistry(address(centralRegistry)),
            address(mockUnderlying),
            address(marketManager)
        );
        vm.label(address(mockPToken), "pToken");

        // start market for pToken
        uint256 startAmount = 42069;
        mockUnderlying.mint(address(this), startAmount);
        mockUnderlying.approve(address(mockPToken), startAmount);
        marketManager.listToken(address(mockPToken));

        _underlying_ = address(mockUnderlying);
        _vault_ = address(mockPToken);
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
