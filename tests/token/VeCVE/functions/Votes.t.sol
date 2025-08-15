// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

import { TestBaseVeCVE } from "../TestBaseVeCVE.sol";
import { VeCVE } from "contracts/token/VeCVE.sol";
import { BPS } from "contracts/libraries/ConstantsLib.sol";

contract VotesTest is TestBaseVeCVE {
    function setUp() public override {
        super.setUp();

        _skipRestrictionDuration();
    }

    function test_getVotes_zero() public {
        assertEq(veCVE.getVotes(address(this)), 0);
    }

    function test_getVotes_zero_whenLockIsExpired(uint256 amount) public {
        amount = bound(amount, _MIN_FUZZ_AMOUNT, _MAX_FUZZ_AMOUNT);
        _prepareCVE(address(this), amount);
        cve.approve(address(veCVE), amount);

        veCVE.createLock(amount, false, action, "", 0);

        (, uint40 unlockTime) = veCVE.userLocks(address(this), 0);
        vm.warp(unlockTime * 2);
        assertEq(veCVE.getVotes(address(this)), 0);
    }

    function test_getVotes_continous_lock_withBoost(
        uint256 amount,
        uint16 boost
    ) public {
        amount = bound(amount, _MIN_FUZZ_AMOUNT, _MAX_FUZZ_AMOUNT);
        boost = uint16(bound(boost, BPS + 1, type(uint16).max));
        centralRegistry.setVoteBoostMultiplier(boost);
        _prepareCVE(address(this), amount);
        cve.approve(address(veCVE), amount);

        veCVE.createLock(amount, true, action, "", 0);
        vm.warp(1000);

        // current boost is x2
        assertEq(
            veCVE.getVotes(address(this)),
            (amount * boost) / BPS
        );
    }

    function test_getVotes_after_lock(uint256 amount, uint16 timeWarp) public {
        amount = bound(amount, _MIN_FUZZ_AMOUNT, _MAX_FUZZ_AMOUNT);
        _prepareCVE(address(this), amount);
        cve.approve(address(veCVE), amount);

        veCVE.createLock(amount, false, action, "", 0);
        vm.warp(timeWarp);

        (, uint40 unlockTime) = veCVE.userLocks(address(this), 0);
        if (block.timestamp > unlockTime) {
            assertEq(veCVE.getVotes(address(this)), 0);
            return;
        }
        uint256 epoch = (unlockTime - block.timestamp) / veCVE.EPOCH_DURATION();
        uint256 votes = (amount * epoch) / veCVE.LOCK_DURATION_EPOCHS();

        assertEq(veCVE.getVotes(address(this)), votes);
    }
}
