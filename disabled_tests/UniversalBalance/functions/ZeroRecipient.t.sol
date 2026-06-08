// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {TestBaseUniversalBalance} from "../TestBaseUniversalBalance.sol";
import {UniversalBalance} from "contracts/architecture/UniversalBalance.sol";
import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";
import {MockToken} from "contracts/mocks/MockToken.sol";
import {SafeTransferLib} from "contracts/libraries/external/SafeTransferLib.sol";

contract UniversalBalanceZeroRecipientTest is TestBaseUniversalBalance {
    function test_universalBalance_withdraw_revertsZeroRecipient() public {
        _prepareUSDC(user1, 1e6);

        vm.startPrank(user1);
        universalBalance.deposit(1e6, false);

        vm.expectRevert(UniversalBalance.UniversalBalance__InvalidParameter.selector);
        universalBalance.withdraw(1e6, false, address(0));
        vm.stopPrank();
    }

    function test_universalBalance_transfer_revertsZeroRecipient() public {
        _prepareUSDC(user1, 1e6);

        vm.startPrank(user1);
        universalBalance.deposit(1e6, false);

        vm.expectRevert(UniversalBalance.UniversalBalance__InvalidParameter.selector);
        universalBalance.transfer(1e6, false, false, address(0));
        vm.stopPrank();
    }

    function test_universalBalance_multiWithdrawFor_revertsZeroRecipient() public {
        _prepareUSDC(user1, 1e6);

        vm.startPrank(user1);
        universalBalance.deposit(1e6, false);
        universalBalance.setDelegateApproval(user2, true);
        vm.stopPrank();

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e6;
        bool[] memory forceLentRedemption = new bool[](1);
        address[] memory owners = new address[](1);
        owners[0] = user1;

        vm.prank(user2);
        vm.expectRevert(UniversalBalance.UniversalBalance__InvalidParameter.selector);
        universalBalance.multiWithdrawFor(amounts, forceLentRedemption, address(0), owners);
    }

    function test_universalBalance_withdrawFromLentTransfersRedeemedRoundingExcess() public {
        MockToken asset = new MockToken("Mock USD", "mUSD", 6);
        MockBorrowableForUniversalBalance linkedToken = new MockBorrowableForUniversalBalance(address(asset));
        UniversalBalance balance =
            new UniversalBalance(ICentralRegistry(address(centralRegistry)), address(linkedToken));

        asset.transfer(user1, 100);
        asset.transfer(address(linkedToken), 50);

        vm.startPrank(user1);
        asset.approve(address(balance), 100);
        balance.deposit(100, true);
        vm.stopPrank();

        linkedToken.setExchangeRate(1.5e18);

        uint256 recipientBalance = asset.balanceOf(user2);

        vm.prank(user1);
        (uint256 amountWithdrawn, bool lendingBalanceUsed) = balance.withdraw(2, true, user2);

        assertTrue(lendingBalanceUsed);
        assertEq(amountWithdrawn, 3);
        assertEq(asset.balanceOf(user2), recipientBalance + 3);
        assertEq(asset.balanceOf(address(balance)), 0);
    }
}

contract MockBorrowableForUniversalBalance {
    address public immutable asset;
    uint256 public exchangeRate = 1e18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(address asset_) {
        asset = asset_;
    }

    function isBorrowable() external pure returns (bool) {
        return true;
    }

    function setExchangeRate(uint256 exchangeRate_) external {
        exchangeRate = exchangeRate_;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = (assets * 1e18) / exchangeRate;
        SafeTransferLib.safeTransferFrom(asset, msg.sender, address(this), assets);
        balanceOf[receiver] += shares;
        totalSupply += shares;
    }

    function exchangeRateUpdated() external view returns (uint256) {
        return exchangeRate;
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        balanceOf[owner] -= shares;
        totalSupply -= shares;
        assets = (shares * exchangeRate) / 1e18;
        SafeTransferLib.safeTransfer(asset, receiver, assets);
    }
}
