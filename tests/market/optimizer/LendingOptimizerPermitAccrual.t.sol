// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "contracts/interfaces/IERC20.sol";
import {LendingOptimizerHarness} from "./LendingOptimizerHarness.sol";
import {TestBaseLendingOptimizer} from "./TestBaseLendingOptimizer.sol";

contract TestLendingOptimizerPermitAccrual is TestBaseLendingOptimizer {
    function setUp() public override {
        super.setUp();
        _setUpOneMarket();
    }

    function test_lendingOptimizer_permitOnlyApprovesAndTransferFromAccruesOptimizer() public {
        uint256 ownerPrivateKey = 0xA11CE;
        address owner = vm.addr(ownerPrivateKey);
        uint256 assetsBefore = _depositAndSkipForOptimizerYield(owner);
        address spender = makeAddr("optimizerPermitSpender");
        address receiver = makeAddr("optimizerPermitReceiver");
        uint256 shares = optimizer.balanceOf(owner) / 3;
        uint256 deadline = block.timestamp + 1 days;
        uint256 nonce = optimizer.nonces(owner);

        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                optimizer.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                        owner,
                        spender,
                        shares,
                        nonce,
                        deadline
                    )
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);

        optimizer.permit(owner, spender, shares, deadline, v, r, s);

        assertEq(optimizer.nonces(owner), nonce + 1);
        assertEq(optimizer.allowance(owner, spender), shares);
        assertEq(optimizer.totalAssets(), assetsBefore, "permit should not sync NAV or move value");

        uint256 ownerBalanceBefore = optimizer.balanceOf(owner);
        uint256 receiverBalanceBefore = optimizer.balanceOf(receiver);

        vm.prank(spender);
        assertTrue(optimizer.transferFrom(owner, receiver, shares));

        assertGt(optimizer.totalAssets(), assetsBefore, "permit transferFrom must sync NAV");
        assertEq(optimizer.balanceOf(owner), ownerBalanceBefore - shares);
        assertEq(optimizer.balanceOf(receiver), receiverBalanceBefore + shares);
        assertEq(optimizer.allowance(owner, spender), 0);
    }

    function _depositAndSkipForOptimizerYield(address receiver) internal returns (uint256 assetsBefore) {
        uint256 depositAmount = 100_000e6;
        deal(USDC_MONAD, address(this), depositAmount);
        IERC20(USDC_MONAD).approve(address(optimizer), depositAmount);
        LendingOptimizerHarness(address(optimizer)).depositToMarket(depositAmount, receiver, cUSDC_WMON_MARKET);

        assetsBefore = optimizer.totalAssets();
        skip(30 days);
    }
}
