// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {
    LendingOptimizer
} from "contracts/market/optimizer/LendingOptimizer.sol";
import {OptimizerZapper} from "contracts/plugins/market/OptimizerZapper.sol";

import {SwapperLib} from "contracts/libraries/SwapperLib.sol";

import {IBorrowableCToken} from "contracts/interfaces/IBorrowableCToken.sol";
import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";
import {IERC20} from "contracts/interfaces/IERC20.sol";

/// @notice Fixed-block deployment differential for the product-reached Monad
///         OptimizerZapper. The live runtime predates the current nonzero
///         expected-shares entry guard.
/// @dev This proves a Low deployment/integration-safety gap, not extraction,
///      profitability, or an app bypass. The only current producer-side zero
///      boundary exercised here fails closed in the child optimizer.
contract OptimizerZapperLiveZeroMinimumPoC is Test {
    uint256 internal constant ENTRY_FORK_BLOCK = 88_452_434;
    uint256 internal constant SDK_BOUNDARY_FORK_BLOCK = 88_603_395;

    address internal constant LIVE_ZAPPER =
        0x190FD44CCFF0Da43Fd60EB496236C3066011a3cA;
    address internal constant OPTIMIZER =
        0xaD663aC84052b52BE4ed1b27BA416505e84a00Bf;
    address internal constant CENTRAL_REGISTRY =
        0x1310f352f1389969Ece6741671c4B919523912fF;
    address internal constant WMON =
        0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;
    address internal constant AUSD =
        0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a;
    address internal constant FUNDED_UNRELATED_CAUSD =
        0xfD493ce1A0ae986e09d17004B7E748817a47d73c;

    address internal user;
    IERC20 internal asset;
    LendingOptimizer internal optimizer;
    OptimizerZapper internal currentZapper;

    struct OptimizerState {
        uint256 userAssets;
        uint256 zapperAssets;
        uint256 currentZapperAssets;
        uint256 unrelatedDonorAssets;
        uint256 optimizerIdleAssets;
        uint256 userShares;
        uint256 totalAssets;
        uint256 totalSupply;
        uint256 userAllowance;
        address[] markets;
        uint256[] marketShares;
    }

    function setUp() public {
        _selectFork(ENTRY_FORK_BLOCK);
        _bindLiveDeployment();
    }

    function test_liveZeroMinimumCrossesEntryWhileHeadRejectsAtEntry() public {
        SwapperLib.Swap memory action = _noSwapAction(0);

        vm.expectRevert(
            LendingOptimizer.LendingOptimizer__InvalidParameter.selector
        );
        OptimizerZapper(LIVE_ZAPPER)
            .swapAndDeposit(OPTIMIZER, false, action, 0, user);

        vm.expectRevert(
            OptimizerZapper.OptimizerZapper__ExecutionError.selector
        );
        currentZapper.swapAndDeposit(OPTIMIZER, false, action, 0, user);
    }

    function test_sdkOneShareBoundaryFailsClosedInChildAndRollsBack() public {
        _selectFork(SDK_BOUNDARY_FORK_BLOCK);
        _bindLiveDeployment();

        uint256 inputAmount = 2;
        assertEq(
            optimizer.convertToShares(inputAmount),
            1,
            "two base units must preview exactly one optimizer share"
        );

        SwapperLib.Swap memory action = _noSwapAction(inputAmount);
        _fundFromUnrelatedBorrowable(inputAmount);

        vm.prank(user);
        asset.approve(LIVE_ZAPPER, inputAmount);

        OptimizerState memory beforeState = _snapshot();

        vm.prank(user);
        vm.expectRevert(
            OptimizerZapper.OptimizerZapper__ExecutionError.selector
        );
        currentZapper.swapAndDeposit(OPTIMIZER, false, action, 0, user);
        _assertUnchanged(beforeState);

        vm.prank(user);
        vm.expectRevert(LendingOptimizer.LendingOptimizer__ZeroAmount.selector);
        OptimizerZapper(LIVE_ZAPPER)
            .swapAndDeposit(OPTIMIZER, false, action, 0, user);

        _assertUnchanged(beforeState);
    }

    function _selectFork(uint256 forkBlock) internal {
        vm.createSelectFork(
            vm.envString("MON_NODE_URI_MONAD_ARCHIVE"), forkBlock
        );
        assertEq(block.chainid, 143, "wrong chain");
        assertEq(block.number, forkBlock, "wrong fork block");
    }

    function _bindLiveDeployment() internal {
        // Full runtime includes Solidity's 53-byte metadata trailer. The
        // executable-only size is 4,167 bytes.
        assertEq(address(LIVE_ZAPPER).code.length, 4_220, "live code drift");
        assertEq(
            address(OptimizerZapper(LIVE_ZAPPER).centralRegistry()),
            CENTRAL_REGISTRY,
            "live registry drift"
        );
        assertEq(
            OptimizerZapper(LIVE_ZAPPER).wrappedNative(),
            WMON,
            "live wrapped native drift"
        );

        optimizer = LendingOptimizer(OPTIMIZER);
        asset = IERC20(optimizer.asset());
        assertEq(address(asset), AUSD, "optimizer asset drift");

        currentZapper =
            new OptimizerZapper(ICentralRegistry(CENTRAL_REGISTRY), WMON);
        assertTrue(
            address(currentZapper).codehash != address(LIVE_ZAPPER).codehash,
            "HEAD must differ from live runtime"
        );

        user = makeAddr("optimizer-zapper-user");
    }

    function _fundFromUnrelatedBorrowable(uint256 amount) internal {
        address[] memory markets = optimizer.getApprovedMarkets();
        for (uint256 i; i < markets.length; ++i) {
            assertNotEq(
                FUNDED_UNRELATED_CAUSD,
                markets[i],
                "funding donor must be outside optimizer route"
            );
        }

        assertEq(
            IBorrowableCToken(FUNDED_UNRELATED_CAUSD).asset(),
            address(asset),
            "funding donor underlying drift"
        );
        uint256 donorBefore = asset.balanceOf(FUNDED_UNRELATED_CAUSD);
        assertGe(donorBefore, amount, "funding donor cash");

        vm.prank(FUNDED_UNRELATED_CAUSD);
        assertTrue(asset.transfer(user, amount), "funding transfer failed");

        assertEq(asset.balanceOf(user), amount, "funded user balance");
        assertEq(
            asset.balanceOf(FUNDED_UNRELATED_CAUSD),
            donorBefore - amount,
            "funding donor debit"
        );
    }

    function _noSwapAction(uint256 inputAmount)
        internal
        view
        returns (SwapperLib.Swap memory action)
    {
        action = SwapperLib.Swap({
            inputToken: address(asset),
            inputAmount: inputAmount,
            outputToken: address(asset),
            target: address(0),
            slippage: 0,
            call: bytes("")
        });
    }

    function _snapshot() internal view returns (OptimizerState memory state) {
        state.userAssets = asset.balanceOf(user);
        state.zapperAssets = asset.balanceOf(LIVE_ZAPPER);
        state.currentZapperAssets = asset.balanceOf(address(currentZapper));
        state.unrelatedDonorAssets = asset.balanceOf(FUNDED_UNRELATED_CAUSD);
        state.optimizerIdleAssets = asset.balanceOf(OPTIMIZER);
        state.userShares = optimizer.balanceOf(user);
        state.totalAssets = optimizer.totalAssets();
        state.totalSupply = IERC20(OPTIMIZER).totalSupply();
        state.userAllowance = asset.allowance(user, LIVE_ZAPPER);
        state.markets = optimizer.getApprovedMarkets();
        state.marketShares = new uint256[](state.markets.length);

        for (uint256 i; i < state.markets.length; ++i) {
            state.marketShares[i] =
                IBorrowableCToken(state.markets[i]).balanceOf(OPTIMIZER);
        }
    }

    function _assertUnchanged(OptimizerState memory beforeState)
        internal
        view
    {
        assertEq(asset.balanceOf(user), beforeState.userAssets, "user assets");
        assertEq(
            asset.balanceOf(LIVE_ZAPPER),
            beforeState.zapperAssets,
            "live zapper assets"
        );
        assertEq(
            asset.balanceOf(address(currentZapper)),
            beforeState.currentZapperAssets,
            "current zapper assets"
        );
        assertEq(
            asset.balanceOf(FUNDED_UNRELATED_CAUSD),
            beforeState.unrelatedDonorAssets,
            "unrelated donor assets"
        );
        assertEq(
            asset.balanceOf(OPTIMIZER),
            beforeState.optimizerIdleAssets,
            "optimizer idle assets"
        );
        assertEq(
            optimizer.balanceOf(user),
            beforeState.userShares,
            "user optimizer shares"
        );
        assertEq(
            optimizer.totalAssets(),
            beforeState.totalAssets,
            "optimizer total assets"
        );
        assertEq(
            IERC20(OPTIMIZER).totalSupply(),
            beforeState.totalSupply,
            "optimizer total supply"
        );
        assertEq(
            asset.allowance(user, LIVE_ZAPPER),
            beforeState.userAllowance,
            "user allowance"
        );
        assertEq(
            optimizer.getApprovedMarkets(),
            beforeState.markets,
            "approved markets"
        );

        for (uint256 i; i < beforeState.markets.length; ++i) {
            assertEq(
                IBorrowableCToken(beforeState.markets[i]).balanceOf(OPTIMIZER),
                beforeState.marketShares[i],
                "optimizer market shares"
            );
        }
    }
}
