// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { ClaimAction } from "contracts/interfaces/IRewardManager.sol";

contract TestBaseVeCVE is TestBaseMarketIsolated {
    ClaimAction public action;
    uint256 internal constant _MIN_FUZZ_AMOUNT = 1e18;
    uint256 internal constant _MAX_FUZZ_AMOUNT = 420e24;

    modifier setClaimAction(
        bool shouldLock,
        bool isFreshLock,
        bool isFreshLockContinuous
    ) {
        action = ClaimAction(
            false,
            shouldLock,
            isFreshLock,
            isFreshLockContinuous
        );
        _;
    }

    function setUp() public virtual override {
        super.setUp();

        action = ClaimAction(false, true, true, true);
    }
}
