// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { RewardsData } from "contracts/interfaces/IRewardManager.sol";

contract TestBaseVeCVE is TestBaseMarketIsolated {
    RewardsData public rewardsData;
    uint256 internal constant _MIN_FUZZ_AMOUNT = 1e18;
    uint256 internal constant _MAX_FUZZ_AMOUNT = 420e24;

    modifier setRewardsData(
        bool shouldLock,
        bool isFreshLock,
        bool isFreshLockContinuous
    ) {
        rewardsData = RewardsData(
            false,
            shouldLock,
            isFreshLock,
            isFreshLockContinuous
        );
        _;
    }

    function setUp() public virtual override {
        super.setUp();

        rewardsData = RewardsData(false, true, true, true);
    }
}
