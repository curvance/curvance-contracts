// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseStrategyCTokenWithExitFee } from "../TestBaseStrategyCTokenWithExitFee.sol";
import { BaseCToken } from "contracts/market/token/BaseCToken.sol";
import { FixedPointMathLib } from "contracts/libraries/external/FixedPointMathLib.sol";

contract WithdrawTest is TestBaseStrategyCTokenWithExitFee {
    event Transfer(address indexed from, address indexed to, uint256 amount);

    /// @notice ERC4626 contract: `withdraw(assets)` delivers exactly `assets`
    ///         to receiver. Fee is paid via additional shares burned.
    function test_strategyCTokenWithExitFeeWithdraw_deliversExactAssets() public {
        strategyCBALRETHWithExitFee.mint(100, address(this));

        uint256 underlyingBefore = balRETH.balanceOf(address(this));
        uint256 sharesBefore = strategyCBALRETHWithExitFee.balanceOf(address(this));

        // Withdraw 98 underlying. Gross-up to 100, burn 100 shares, deliver 98.
        strategyCBALRETHWithExitFee.withdraw(98, address(this), address(this));

        assertEq(
            balRETH.balanceOf(address(this)),
            underlyingBefore + 98,
            "receiver should get exactly the requested assets"
        );
        assertEq(
            strategyCBALRETHWithExitFee.balanceOf(address(this)),
            sharesBefore - 100,
            "shares burned should cover assets + fee"
        );
    }

    /// @notice maxWithdraw is net-of-fee so withdraw(maxWithdraw(owner)) is
    ///         callable without exceeding owner's share balance.
    function test_strategyCTokenWithExitFeeWithdraw_atMaxWithdrawDoesNotRevert()
        public
    {
        strategyCBALRETHWithExitFee.mint(100, address(this));

        uint256 max = strategyCBALRETHWithExitFee.maxWithdraw(address(this));
        uint256 sharesBefore = strategyCBALRETHWithExitFee.balanceOf(address(this));

        // Pre-fix maxWithdraw returned the gross value, causing this to
        // revert in `_burn` because `_previewWithdraw` would round up past
        // owner's balance.
        strategyCBALRETHWithExitFee.withdraw(max, address(this), address(this));

        // Owner should be left with at most the rounding-error remainder.
        uint256 sharesAfter = strategyCBALRETHWithExitFee.balanceOf(address(this));
        assertLe(
            sharesAfter,
            sharesBefore,
            "share balance should not increase"
        );
        assertEq(
            sharesBefore - sharesAfter,
            100,
            "all shares should be burned at maxWithdraw"
        );
    }

    /// @notice Fuzz: across mint amounts, withdraw(maxWithdraw) must not
    ///         overshoot share balance. Empirical pin for the rounding
    ///         bound. Exit fee stays at construction default (200 bps);
    ///         changing it via fuzz introduces orthogonal setup variance
    ///         we don't need to cover the H1 concern.
    function testFuzz_strategyCTokenWithExitFeeWithdraw_atMaxWithdrawNeverOvershoots(
        uint256 mintAmount
    ) public {
        // Leave room for dead-shares init (77777 wei consumed by listTokens)
        // plus a safety margin. Still sweeps 13+ orders of magnitude.
        mintAmount = bound(mintAmount, 100, _ONE - 1e6);

        strategyCBALRETHWithExitFee.mint(mintAmount, address(this));

        uint256 max = strategyCBALRETHWithExitFee.maxWithdraw(address(this));
        if (max == 0) return;

        // Must not revert on insufficient share balance.
        strategyCBALRETHWithExitFee.withdraw(max, address(this), address(this));
    }

    /// @notice withdraw(assets, receiver, owner) routes assets to receiver
    ///         and burns shares from owner. Pin that the new `_withdraw`
    ///         override propagates `receiver` correctly under cross-account
    ///         use.
    function test_strategyCTokenWithExitFeeWithdraw_routesToDistinctReceiver()
        public
    {
        strategyCBALRETHWithExitFee.mint(100, address(this));
        strategyCBALRETHWithExitFee.approve(address(this), type(uint256).max);

        address receiver = makeAddr("receiver");
        uint256 receiverBefore = balRETH.balanceOf(receiver);
        uint256 ownerSharesBefore = strategyCBALRETHWithExitFee.balanceOf(address(this));

        strategyCBALRETHWithExitFee.withdraw(98, receiver, address(this));

        assertEq(
            balRETH.balanceOf(receiver),
            receiverBefore + 98,
            "receiver should get exactly the requested assets"
        );
        assertEq(
            strategyCBALRETHWithExitFee.balanceOf(address(this)),
            ownerSharesBefore - 100,
            "shares should burn from owner, not receiver"
        );
    }

    /// @notice Pin behavior of `setExitFee` mid-position: a user who
    ///         deposited at a lower fee pays the CURRENT fee on exit.
    ///         No grandfathering. Documented protocol behavior.
    function test_strategyCTokenWithExitFeeWithdraw_appliesCurrentFeeAtExit()
        public
    {
        // Lower fee at deposit time.
        strategyCBALRETHWithExitFee.setExitFee(50); // 0.5%
        strategyCBALRETHWithExitFee.mint(100, address(this));

        // Admin raises fee mid-position.
        strategyCBALRETHWithExitFee.setExitFee(200); // 2%

        uint256 underlyingBefore = balRETH.balanceOf(address(this));
        // maxWithdraw is computed at the CURRENT fee, not the deposit-time fee.
        uint256 max = strategyCBALRETHWithExitFee.maxWithdraw(address(this));

        strategyCBALRETHWithExitFee.withdraw(max, address(this), address(this));

        // User receives exactly `max` (which is post-2%-fee), not what
        // they would have received at the original 0.5% fee.
        assertEq(
            balRETH.balanceOf(address(this)) - underlyingBefore,
            max,
            "user gets current-fee net amount, not deposit-time amount"
        );
        assertEq(
            max,
            98,
            "max should reflect 2% current fee on 100 underlying"
        );
    }

    /// @notice Boundary: withdraw(maxWithdraw + 1) MUST revert. Pins
    ///         the upper edge of the allowed range so a future regression
    ///         that loosens the gross-up surfaces immediately.
    function test_strategyCTokenWithExitFeeWithdraw_revertsAboveMaxWithdraw()
        public
    {
        strategyCBALRETHWithExitFee.mint(100, address(this));
        uint256 max = strategyCBALRETHWithExitFee.maxWithdraw(address(this));

        vm.expectRevert();
        strategyCBALRETHWithExitFee.withdraw(max + 1, address(this), address(this));
    }

    /// @notice Behavior shift documentation: pre-fix `withdraw(convertToAssets(balanceOf))`
    ///         succeeded (delivered net-of-fee assets, ERC4626 violation).
    ///         Post-fix it reverts because gross-up of the gross value
    ///         exceeds owner's share value. Callers must use `maxWithdraw`
    ///         which is now correctly net-of-fee. Pins the API shift.
    function test_strategyCTokenWithExitFeeWithdraw_revertsOnGrossAssetValue()
        public
    {
        strategyCBALRETHWithExitFee.mint(100, address(this));

        uint256 grossValue =
            strategyCBALRETHWithExitFee.convertToAssets(100);
        uint256 maxValue =
            strategyCBALRETHWithExitFee.maxWithdraw(address(this));

        // convertToAssets returns gross; maxWithdraw returns net-of-fee.
        assertGt(
            grossValue,
            maxValue,
            "gross conversion should exceed maxWithdraw"
        );

        // Pre-fix this would deliver maxValue (98) for grossValue (100).
        // Post-fix the gross-up reverts because grossValue > owner's share value.
        vm.expectRevert();
        strategyCBALRETHWithExitFee.withdraw(grossValue, address(this), address(this));
    }

    /// @notice Sanity: previewWithdraw(assets) reports the share count
    ///         that withdraw(assets) actually burns. ERC4626 contract
    ///         requires preview to be >= actual.
    function test_strategyCTokenWithExitFeeWithdraw_previewMatchesActualBurn()
        public
    {
        strategyCBALRETHWithExitFee.mint(100, address(this));

        uint256 preview = strategyCBALRETHWithExitFee.previewWithdraw(98);
        uint256 sharesBefore = strategyCBALRETHWithExitFee.balanceOf(address(this));

        strategyCBALRETHWithExitFee.withdraw(98, address(this), address(this));

        uint256 actualBurn = sharesBefore - strategyCBALRETHWithExitFee.balanceOf(address(this));
        assertGe(preview, actualBurn, "preview must be >= actual burn (ERC4626)");
        assertEq(preview, actualBurn, "preview should equal actual burn at this scale");
    }
}
