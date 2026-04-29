// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";

import { RewardsDistribution } from "contracts/misc/RewardsDistribution.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

import { MockERC20Token } from "contracts/mocks/MockERC20Token.sol";

/// @title TestRewardsDistribution
/// @notice Regression coverage for the claim-window polarity fix
///         (`_isClaimWindowActive`, negated call in `claim()`).
contract TestRewardsDistribution is Test {
    uint256 internal constant CLAIM_WINDOW = 30 days; // == MINIMUM_CLAIM_WINDOW
    uint256 internal constant REWARD_AMOUNT = 1_000e18;

    CentralRegistry internal centralRegistry;
    MockERC20Token internal rewardToken;
    RewardsDistribution internal distribution;

    bytes32 internal merkleRoot;
    bytes32[] internal emptyProof;
    uint40 internal claimEndTimestamp;

    function setUp() public {
        vm.warp(2_000_000_000);

        // Test contract is DAO so it can addMerkleRoots and setPauseState.
        centralRegistry = new CentralRegistry(
            address(this),
            address(this),
            block.timestamp + 365 days,
            address(0),
            address(0)
        );

        rewardToken = new MockERC20Token();
        rewardToken.mint(address(this), REWARD_AMOUNT);

        distribution = new RewardsDistribution(
            ICentralRegistry(address(centralRegistry))
        );

        // Single-leaf tree: root == leaf, proof empty.
        // Leaf = keccak256(abi.encodePacked(claimer, rewardToken, amount)).
        merkleRoot = keccak256(
            abi.encodePacked(address(this), address(rewardToken), REWARD_AMOUNT)
        );

        rewardToken.approve(address(distribution), REWARD_AMOUNT);

        bytes32[] memory roots = new bytes32[](1);
        roots[0] = merkleRoot;
        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardToken);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = REWARD_AMOUNT;
        uint256[] memory ends = new uint256[](1);
        ends[0] = block.timestamp + CLAIM_WINDOW;

        distribution.addMerkleRoots(roots, tokens, amounts, ends);
        claimEndTimestamp = uint40(ends[0]);

        distribution.setPauseState(false);
    }

    function test_claim_succeedsDuringActiveWindow() public {
        // Pre-fix reverted NotEligible inside the active window.
        (
            bytes32[] memory roots,
            uint256[] memory amounts,
            bytes32[][] memory proofs
        ) = _buildClaimArgs();

        uint256 balanceBefore = rewardToken.balanceOf(address(this));
        distribution.claim(roots, amounts, proofs);
        uint256 balanceAfter = rewardToken.balanceOf(address(this));

        assertEq(
            balanceAfter - balanceBefore,
            REWARD_AMOUNT,
            "claim should transfer the full reward during the active window"
        );
        assertTrue(
            distribution.rewardsClaimed(address(this), merkleRoot),
            "claim should mark rewards as claimed for caller+root"
        );
    }

    function test_claim_revertsAfterWindowExpires() public {
        // Pre-fix succeeded after expiry (post-fix correctly rejects).
        vm.warp(claimEndTimestamp + 1);

        (
            bytes32[] memory roots,
            uint256[] memory amounts,
            bytes32[][] memory proofs
        ) = _buildClaimArgs();

        vm.expectRevert(
            RewardsDistribution.RewardDistribution__NotEligible.selector
        );
        distribution.claim(roots, amounts, proofs);
    }

    function test_claim_revertsForUnconfiguredRoot() public {
        bytes32 bogusRoot = keccak256("not a real root");

        bytes32[] memory roots = new bytes32[](1);
        roots[0] = bogusRoot;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = REWARD_AMOUNT;
        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = emptyProof;

        // amounts[i] > config.rewardAmount (0 for unconfigured) trips
        // ParametersAreInvalid before reaching _isClaimWindowActive.
        vm.expectRevert(
            RewardsDistribution.RewardDistribution__ParametersAreInvalid.selector
        );
        distribution.claim(roots, amounts, proofs);
    }

    function test_canClaim_returnsTrueDuringActiveWindow() public view {
        assertTrue(
            distribution.canClaim(
                address(this),
                merkleRoot,
                REWARD_AMOUNT,
                emptyProof
            ),
            "canClaim should return true during the active window"
        );
    }

    function test_canClaim_returnsFalseAfterWindowExpires() public {
        vm.warp(claimEndTimestamp + 1);
        assertFalse(
            distribution.canClaim(
                address(this),
                merkleRoot,
                REWARD_AMOUNT,
                emptyProof
            ),
            "canClaim should return false after the window expires"
        );
    }

    function test_canClaim_returnsFalseForUnconfiguredRoot() public view {
        bytes32 bogusRoot = keccak256("not a real root");
        assertFalse(
            distribution.canClaim(
                address(this),
                bogusRoot,
                REWARD_AMOUNT,
                emptyProof
            ),
            "canClaim should return false for an unconfigured root"
        );
    }

    function test_canClaim_andClaim_consistentDuringActiveWindow() public {
        // Invariant: canClaim true ⇒ claim succeeds. Polarity bug broke this.
        assertTrue(
            distribution.canClaim(
                address(this),
                merkleRoot,
                REWARD_AMOUNT,
                emptyProof
            ),
            "precondition: canClaim should return true within active window"
        );

        (
            bytes32[] memory roots,
            uint256[] memory amounts,
            bytes32[][] memory proofs
        ) = _buildClaimArgs();

        distribution.claim(roots, amounts, proofs);
    }

    function test_canClaim_andClaim_consistentAfterWindowExpires() public {
        // Invariant: canClaim false ⇒ claim reverts. Both must agree post-expiry.
        vm.warp(claimEndTimestamp + 1);

        assertFalse(
            distribution.canClaim(
                address(this),
                merkleRoot,
                REWARD_AMOUNT,
                emptyProof
            ),
            "canClaim should return false after the window expires"
        );

        (
            bytes32[] memory roots,
            uint256[] memory amounts,
            bytes32[][] memory proofs
        ) = _buildClaimArgs();

        vm.expectRevert(
            RewardsDistribution.RewardDistribution__NotEligible.selector
        );
        distribution.claim(roots, amounts, proofs);
    }

    /// @notice `addMerkleRoots` overwrites prior config wholesale (no
    ///         additive accounting). Pins the foot-gun: re-adding with
    ///         a smaller amount strands the prior funded balance.
    function test_addMerkleRoots_overwriteWipesPriorRewardAmount() public {
        uint256 newAmount = REWARD_AMOUNT / 2;
        rewardToken.mint(address(this), newAmount);
        rewardToken.approve(address(distribution), newAmount);

        bytes32[] memory roots = new bytes32[](1);
        roots[0] = merkleRoot;
        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardToken);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = newAmount;
        uint256[] memory ends = new uint256[](1);
        ends[0] = block.timestamp + CLAIM_WINDOW;

        distribution.addMerkleRoots(roots, tokens, amounts, ends);

        (, , uint256 storedAmount) = distribution.rewardsConfig(merkleRoot);
        assertEq(
            storedAmount,
            newAmount,
            "rewardAmount should overwrite, not sum"
        );
        // Contract holds REWARD_AMOUNT (initial) + newAmount, but only
        // newAmount is claimable per the overwritten config.
        assertEq(
            rewardToken.balanceOf(address(distribution)),
            REWARD_AMOUNT + newAmount,
            "contract balance includes stranded prior funding"
        );
    }

    /// @notice Re-adding a root after a user has claimed does NOT reset
    ///         the user's `rewardsClaimed` flag. Prevents claim replay
    ///         after admin re-config.
    function test_addMerkleRoots_overwriteDoesNotResetClaimedFlag() public {
        // Claim first.
        (
            bytes32[] memory roots,
            uint256[] memory amounts,
            bytes32[][] memory proofs
        ) = _buildClaimArgs();
        distribution.claim(roots, amounts, proofs);
        assertTrue(distribution.rewardsClaimed(address(this), merkleRoot));

        // Admin re-adds the same root with fresh funding.
        rewardToken.mint(address(this), REWARD_AMOUNT);
        rewardToken.approve(address(distribution), REWARD_AMOUNT);
        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardToken);
        uint256[] memory addAmounts = new uint256[](1);
        addAmounts[0] = REWARD_AMOUNT;
        uint256[] memory ends = new uint256[](1);
        ends[0] = block.timestamp + CLAIM_WINDOW;
        bytes32[] memory addRoots = new bytes32[](1);
        addRoots[0] = merkleRoot;

        distribution.addMerkleRoots(addRoots, tokens, addAmounts, ends);

        // Re-claim must still revert — `rewardsClaimed` flag survives.
        vm.expectRevert(
            RewardsDistribution.RewardDistribution__NotEligible.selector
        );
        distribution.claim(roots, amounts, proofs);
    }

    /// @notice Re-adding can extend a closed claim window, effectively
    ///         re-opening claims for users who haven't yet claimed.
    ///         Pins the admin power as documented behavior.
    function test_addMerkleRoots_overwriteCanExtendClaimWindow() public {
        vm.warp(claimEndTimestamp + 1);

        (
            bytes32[] memory roots,
            uint256[] memory amounts,
            bytes32[][] memory proofs
        ) = _buildClaimArgs();

        // Window expired — claim rejected.
        vm.expectRevert(
            RewardsDistribution.RewardDistribution__NotEligible.selector
        );
        distribution.claim(roots, amounts, proofs);

        // Admin re-adds with later expiry.
        rewardToken.mint(address(this), REWARD_AMOUNT);
        rewardToken.approve(address(distribution), REWARD_AMOUNT);
        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardToken);
        uint256[] memory addAmounts = new uint256[](1);
        addAmounts[0] = REWARD_AMOUNT;
        uint256[] memory ends = new uint256[](1);
        ends[0] = block.timestamp + CLAIM_WINDOW;
        bytes32[] memory addRoots = new bytes32[](1);
        addRoots[0] = merkleRoot;

        distribution.addMerkleRoots(addRoots, tokens, addAmounts, ends);

        // Window re-opened — claim now succeeds.
        distribution.claim(roots, amounts, proofs);
    }

    /// INTERNAL FUNCTIONS ///

    function _buildClaimArgs()
        internal
        view
        returns (
            bytes32[] memory roots,
            uint256[] memory amounts,
            bytes32[][] memory proofs
        )
    {
        roots = new bytes32[](1);
        roots[0] = merkleRoot;
        amounts = new uint256[](1);
        amounts[0] = REWARD_AMOUNT;
        proofs = new bytes32[][](1);
        proofs[0] = emptyProof;
    }
}
