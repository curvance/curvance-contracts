// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IPendlePTOracle } from "contracts/interfaces/external/pendle/IPendlePtOracle.sol";

import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { NativeUniversalBalance } from "contracts/architecture/NativeUniversalBalance.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";
import { SimpleCToken } from "contracts/market/token/SimpleCToken.sol";

import "tests/market/TestBaseMarketIsolated.sol";

contract TestNativeUniversalBalance is TestBaseMarketIsolated {
    address public owner;

    MockDataFeed public mockUsdcFeed;
    MockDataFeed public mockWethFeed;
    MockDataFeed public mockStethFeed;
    MockV3Aggregator public mockWbtcFeed;

    SimpleCToken public cWBTC;
    NativeUniversalBalance public nativeUniversalBalance;
    BorrowableCToken public borrowableCWETH;

    address[] public owners;
    address[] public recipients;

    receive() external payable {}

    fallback() external payable {}

    function setUp() public override {
        super.setUp();

        owner = address(this);

        // use mock pricing for testing
        mockUsdcFeed = new MockDataFeed(_CHAINLINK_USDC_USD);
        chainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            address(mockUsdcFeed),
            0,
            true
        );
        dualChainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            address(mockUsdcFeed),
            0,
            true
        );

        mockWethFeed = new MockDataFeed(_CHAINLINK_ETH_USD);
        chainlinkAdaptor.addAsset(
            _WETH_ADDRESS,
            address(mockWethFeed),
            0,
            true
        );
        dualChainlinkAdaptor.addAsset(
            _WETH_ADDRESS,
            address(mockWethFeed),
            0,
            true
        );

        mockWbtcFeed = new MockV3Aggregator(8, 60000e8, 1e50, 1e6);
        chainlinkAdaptor.addAsset(
            _WBTC_ADDRESS,
            address(mockWbtcFeed),
            0,
            true
        );
        dualChainlinkAdaptor.addAsset(
            _WBTC_ADDRESS,
            address(mockWbtcFeed),
            0,
            true
        );
        oracleManager.addAssetPriceFeed(
            _WBTC_ADDRESS,
            address(chainlinkAdaptor)
        );
        oracleManager.addAssetPriceFeed(
            _WBTC_ADDRESS,
            address(dualChainlinkAdaptor)
        );

        borrowableCWETH = _deployBorrowableCToken(_WETH_ADDRESS);

        nativeUniversalBalance = new NativeUniversalBalance(
            ICentralRegistry(address(centralRegistry)),
            address(borrowableCWETH),
            _WETH_ADDRESS
        );

        // start epoch
        vm.warp(gaugeManager.gaugeStartTime());
        vm.roll(block.number + 1000);

        mockUsdcFeed.setMockUpdatedAt(block.timestamp);
        mockWethFeed.setMockUpdatedAt(block.timestamp);
        mockWbtcFeed.updateAnswer(60000e8);

        _prepareWETH(owner, 200000 ether);
        weth.approve(address(borrowableCWETH), 200000e18);

        oracleManager.addCTokenSupport(address(borrowableCWETH));
        address[] memory markets = new address[](1);
        markets[0] = address(borrowableCWETH);

        cWBTC = new SimpleCToken(
            ICentralRegistry(address(centralRegistry)),
            wbtc,
            address(marketManagerIsolated)
        );

        _prepareWBTC(owner, 1e8);
        wbtc.approve(address(cWBTC), 1e8);

        marketManagerIsolated.listTokens(address(cWBTC), address(borrowableCWETH));

        oracleManager.addCTokenSupport(address(cWBTC));

        _setCTokenConfigBasic(address(cWBTC), 100e8, 0);

        _setCTokenConfigBasic(address(borrowableCWETH), 1000e18, 1000e18);

        owners.push(user2);
        owners.push(user3);
        owners.push(user4);

        for (uint256 i; i < 3; i++) {
            vm.prank(owners[i]);
            nativeUniversalBalance.setDelegateApproval(user1, true);
        }

        recipients.push(user2);
        recipients.push(user3);
        recipients.push(user4);

        for (uint256 i; i < 3; i++) {
            vm.prank(recipients[i]);
            nativeUniversalBalance.setDelegateApproval(user1, true);
        }

    }

    function testInitialize() public {
        assertEq(
            address(nativeUniversalBalance.linkedToken()),
            address(borrowableCWETH)
        );
        assertEq(nativeUniversalBalance.underlying(), _WETH_ADDRESS);
    }

    function testDeposit() public {
        _prepareWETH(user1, 200e18);

        uint256 receiveAmount = borrowableCWETH.convertToShares(100e18);
        uint256 wethBalance = weth.balanceOf(address(nativeUniversalBalance));
        uint256 borrowableCWETHBalance = borrowableCWETH.balanceOf(
            address(nativeUniversalBalance)
        );

        vm.startPrank(user1);
        weth.approve(address(nativeUniversalBalance), 100e18);
        nativeUniversalBalance.deposit(100e18, false);
        vm.stopPrank();

        (uint256 sittingBalance, uint256 lentBalance) = nativeUniversalBalance
            .userBalances(user1);
        assertEq(sittingBalance, 100e18);
        assertEq(lentBalance, 0);
        assertEq(
            weth.balanceOf(address(nativeUniversalBalance)),
            wethBalance + 100e18
        );
        assertEq(
            borrowableCWETH.balanceOf(address(nativeUniversalBalance)),
            borrowableCWETHBalance
        );
        assertEq(weth.balanceOf(user1), 100e18);

        vm.startPrank(user1);
        weth.approve(address(nativeUniversalBalance), 100e18);
        nativeUniversalBalance.deposit(100e18, true);
        vm.stopPrank();

        (sittingBalance, lentBalance) = nativeUniversalBalance.userBalances(
            user1
        );
        assertEq(sittingBalance, 100e18);
        assertEq(lentBalance, 100e18);
        assertEq(
            weth.balanceOf(address(nativeUniversalBalance)),
            wethBalance + 100e18
        );
        assertEq(
            borrowableCWETH.balanceOf(address(nativeUniversalBalance)),
            borrowableCWETHBalance + receiveAmount
        );
        assertEq(weth.balanceOf(user1), 0);
    }

    function testDepositNative() public {
        vm.deal(user1, 200e18);

        uint256 receiveAmount = borrowableCWETH.convertToShares(100e18);
        uint256 ethBalance = address(nativeUniversalBalance).balance;
        uint256 wethBalance = weth.balanceOf(address(nativeUniversalBalance));
        uint256 borrowableCWETHBalance = borrowableCWETH.balanceOf(
            address(nativeUniversalBalance)
        );

        vm.prank(user1);
        nativeUniversalBalance.depositNative{ value: 100e18 }(false);

        (uint256 sittingBalance, uint256 lentBalance) = nativeUniversalBalance
            .userBalances(user1);
        assertEq(sittingBalance, 100e18);
        assertEq(lentBalance, 0);
        assertEq(address(nativeUniversalBalance).balance, ethBalance);
        assertEq(
            weth.balanceOf(address(nativeUniversalBalance)),
            wethBalance + 100e18
        );
        assertEq(
            borrowableCWETH.balanceOf(address(nativeUniversalBalance)),
            borrowableCWETHBalance
        );
        assertEq(user1.balance, 100e18);

        vm.prank(user1);
        nativeUniversalBalance.depositNative{ value: 100e18 }(true);

        (sittingBalance, lentBalance) = nativeUniversalBalance.userBalances(
            user1
        );
        assertEq(sittingBalance, 100e18);
        assertEq(lentBalance, 100e18);
        assertEq(address(nativeUniversalBalance).balance, ethBalance);
        assertEq(
            weth.balanceOf(address(nativeUniversalBalance)),
            wethBalance + 100e18
        );
        assertEq(
            borrowableCWETH.balanceOf(address(nativeUniversalBalance)),
            borrowableCWETHBalance + receiveAmount
        );
        assertEq(user1.balance, 0);
    }

    function testMultiDepositFor() public {
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 100e18;
        amounts[1] = 200e18;
        amounts[2] = 300e18;

        bool[] memory willLend = new bool[](3);
        willLend[0] = true;
        willLend[1] = false;
        willLend[2] = true;

        _prepareWETH(user1, 1_000e18);

        uint256[] memory receiveAmounts = new uint256[](3);

        for (uint256 i; i < 3; i++) {
            receiveAmounts[i] = borrowableCWETH.convertToShares(amounts[i]);
        }

        uint256 wethBalance = weth.balanceOf(address(nativeUniversalBalance));
        uint256 borrowableCWETHBalance = borrowableCWETH.balanceOf(
            address(nativeUniversalBalance)
        );
        uint256 userWETHBalance = weth.balanceOf(user1);

        vm.startPrank(user1);

        weth.approve(address(nativeUniversalBalance), 1_000e18);

        nativeUniversalBalance.multiDepositFor(
            1_000e18,
            amounts,
            willLend,
            recipients
        );

        vm.stopPrank();

        uint256 lentAmount = 0;
        uint256 sittingAmount = 0;

        for (uint256 i; i < 3; i++) {
            (
                uint256 sittingBalance,
                uint256 lentBalance
            ) = nativeUniversalBalance.userBalances(recipients[i]);

            if (willLend[i]) {
                assertEq(sittingBalance, 0);
                assertEq(lentBalance, receiveAmounts[i]);
                lentAmount += receiveAmounts[i];
            } else {
                assertEq(sittingBalance, amounts[i]);
                assertEq(lentBalance, 0);
                sittingAmount += amounts[i];
            }
        }

        assertEq(
            weth.balanceOf(address(nativeUniversalBalance)),
            wethBalance + sittingAmount
        );
        assertEq(
            borrowableCWETH.balanceOf(address(nativeUniversalBalance)),
            borrowableCWETHBalance + lentAmount
        );
        assertEq(weth.balanceOf(user1), userWETHBalance - 600e18);
    }

    function testMultiDepositNativeFor() public {
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 100e18;
        amounts[1] = 200e18;
        amounts[2] = 300e18;

        bool[] memory willLend = new bool[](3);
        willLend[0] = true;
        willLend[1] = false;
        willLend[2] = true;

        deal(user1, 1_000e18);

        uint256[] memory receiveAmounts = new uint256[](3);

        for (uint256 i; i < 3; i++) {
            receiveAmounts[i] = borrowableCWETH.convertToShares(amounts[i]);
        }

        uint256 wethBalance = weth.balanceOf(address(nativeUniversalBalance));
        uint256 borrowableCWETHBalance = borrowableCWETH.balanceOf(
            address(nativeUniversalBalance)
        );
        uint256 userETHBalance = user1.balance;

        vm.prank(user1);
        nativeUniversalBalance.multiDepositNativeFor{ value: 1_000e18 }(
            amounts,
            willLend,
            recipients
        );

        uint256 lentAmount = 0;
        uint256 sittingAmount = 0;

        for (uint256 i; i < 3; i++) {
            (
                uint256 sittingBalance,
                uint256 lentBalance
            ) = nativeUniversalBalance.userBalances(recipients[i]);

            if (willLend[i]) {
                assertEq(sittingBalance, 0);
                assertEq(lentBalance, receiveAmounts[i]);
                lentAmount += receiveAmounts[i];
            } else {
                assertEq(sittingBalance, amounts[i]);
                assertEq(lentBalance, 0);
                sittingAmount += amounts[i];
            }
        }

        assertEq(
            weth.balanceOf(address(nativeUniversalBalance)),
            wethBalance + sittingAmount
        );
        assertEq(
            borrowableCWETH.balanceOf(address(nativeUniversalBalance)),
            borrowableCWETHBalance + lentAmount
        );
        assertEq(user1.balance, userETHBalance - 600e18);
    }

    function testWithdraw() public {
        testDeposit();

        uint256 redeemAmount = borrowableCWETH.convertToShares(100e18);
        uint256 ethBalance = address(nativeUniversalBalance).balance;
        uint256 wethBalance = weth.balanceOf(address(nativeUniversalBalance));
        uint256 borrowableCWETHBalance = borrowableCWETH.balanceOf(
            address(nativeUniversalBalance)
        );

        vm.prank(user1);
        nativeUniversalBalance.withdraw(100e18, false, user2);

        (uint256 sittingBalance, uint256 lentBalance) = nativeUniversalBalance
            .userBalances(user1);

        assertEq(sittingBalance, 0);
        assertEq(lentBalance, 100e18);
        assertEq(address(nativeUniversalBalance).balance, ethBalance);
        assertEq(
            weth.balanceOf(address(nativeUniversalBalance)),
            wethBalance - 100e18
        );
        assertEq(
            borrowableCWETH.balanceOf(address(nativeUniversalBalance)),
            borrowableCWETHBalance
        );
        assertEq(weth.balanceOf(user2), 100e18);

        vm.prank(user1);
        nativeUniversalBalance.withdraw(100e18, true, user2);

        (sittingBalance, lentBalance) = nativeUniversalBalance.userBalances(
            user1
        );
        assertEq(sittingBalance, 0);
        assertEq(lentBalance, 0);
        assertEq(address(nativeUniversalBalance).balance, ethBalance);
        assertEq(
            weth.balanceOf(address(nativeUniversalBalance)),
            wethBalance - 100e18
        );
        assertEq(
            borrowableCWETH.balanceOf(address(nativeUniversalBalance)),
            borrowableCWETHBalance - redeemAmount
        );
        assertEq(weth.balanceOf(user2), 200e18);
    }

    function testWithdrawNative() public {
        testDepositNative();

        uint256 redeemAmount = borrowableCWETH.convertToShares(100e18);
        uint256 ethBalance = address(nativeUniversalBalance).balance;
        uint256 wethBalance = weth.balanceOf(address(nativeUniversalBalance));
        uint256 borrowableCWETHBalance = borrowableCWETH.balanceOf(
            address(nativeUniversalBalance)
        );
        uint256 userETHBalance = user1.balance;

        vm.prank(user1);
        nativeUniversalBalance.withdrawNative(100e18, false, user2);

        (uint256 sittingBalance, uint256 lentBalance) = nativeUniversalBalance
            .userBalances(user1);
        assertEq(sittingBalance, 0);
        assertEq(lentBalance, 100e18);
        assertEq(address(nativeUniversalBalance).balance, ethBalance);
        assertEq(
            weth.balanceOf(address(nativeUniversalBalance)),
            wethBalance - 100e18
        );
        assertEq(
            borrowableCWETH.balanceOf(address(nativeUniversalBalance)),
            borrowableCWETHBalance
        );
        assertEq(user2.balance, userETHBalance + 100e18);

        vm.prank(user1);
        nativeUniversalBalance.withdrawNative(100e18, true, user2);

        (sittingBalance, lentBalance) = nativeUniversalBalance.userBalances(
            user1
        );
        assertEq(sittingBalance, 0);
        assertEq(lentBalance, 0);
        assertEq(address(nativeUniversalBalance).balance, ethBalance);
        assertEq(
            weth.balanceOf(address(nativeUniversalBalance)),
            wethBalance - 100e18
        );
        assertEq(
            borrowableCWETH.balanceOf(address(nativeUniversalBalance)),
            borrowableCWETHBalance - redeemAmount
        );
        assertEq(user2.balance, userETHBalance + 200e18);

        vm.stopPrank();
    }

    function testMultiWithdrawFor() public {
        uint256[] memory depositAmounts = new uint256[](3);
        depositAmounts[0] = 200e18;
        depositAmounts[1] = 300e18;
        depositAmounts[2] = 400e18;

        for (uint256 i; i < 3; i++) {
            _prepareWETH(owners[i], depositAmounts[i] * 2);

            vm.startPrank(owners[i]);

            weth.approve(
                address(nativeUniversalBalance),
                depositAmounts[i] * 2
            );
            nativeUniversalBalance.deposit(depositAmounts[i], true);
            nativeUniversalBalance.deposit(depositAmounts[i], false);

            vm.stopPrank();
        }

        uint256[] memory withdrawAmounts = new uint256[](3);
        withdrawAmounts[0] = 100e18;
        withdrawAmounts[1] = 200e18;
        withdrawAmounts[2] = 300e18;

        bool[] memory forceLentRedemption = new bool[](3);
        forceLentRedemption[0] = true;
        forceLentRedemption[1] = false;
        forceLentRedemption[2] = true;

        uint256 ethBalance = address(nativeUniversalBalance).balance;
        uint256 wethBalance = weth.balanceOf(address(nativeUniversalBalance));
        uint256 borrowableCWETHBalance = borrowableCWETH.balanceOf(
            address(nativeUniversalBalance)
        );
        uint256 userWETHBalance = weth.balanceOf(user1);

        vm.prank(user1);
        nativeUniversalBalance.multiWithdrawFor(
            withdrawAmounts,
            forceLentRedemption,
            user1,
            owners
        );

        for (uint256 i; i < 3; i++) {
            (
                uint256 sittingBalance,
                uint256 lentBalance
            ) = nativeUniversalBalance.userBalances(owners[i]);

            if (forceLentRedemption[i]) {
                assertEq(sittingBalance, depositAmounts[i]);
                assertEq(lentBalance, 100e18);
            } else {
                assertEq(sittingBalance, 100e18);
                assertEq(lentBalance, depositAmounts[i]);
            }
        }

        uint256 lentAmountUsed = 0;
        uint256 sittingAmountUsed = 0;

        for (uint256 i; i < 3; i++) {
            if (forceLentRedemption[i]) {
                lentAmountUsed += withdrawAmounts[i];
            } else {
                sittingAmountUsed += withdrawAmounts[i];
            }
        }

        assertEq(address(nativeUniversalBalance).balance, ethBalance);
        assertEq(
            weth.balanceOf(address(nativeUniversalBalance)),
            wethBalance - sittingAmountUsed
        );
        assertEq(
            borrowableCWETH.balanceOf(address(nativeUniversalBalance)),
            borrowableCWETHBalance - lentAmountUsed
        );
        assertEq(weth.balanceOf(user1), userWETHBalance + 600e18);
    }

    function testMultiWithdrawNativeFor() public {
        uint256[] memory depositAmounts = new uint256[](3);
        depositAmounts[0] = 200e18;
        depositAmounts[1] = 300e18;
        depositAmounts[2] = 400e18;

        for (uint256 i; i < 3; i++) {
            deal(owners[i], depositAmounts[i] * 2);

            vm.startPrank(owners[i]);

            nativeUniversalBalance.depositNative{ value: depositAmounts[i] }(
                true
            );
            nativeUniversalBalance.depositNative{ value: depositAmounts[i] }(
                false
            );

            vm.stopPrank();
        }

        uint256[] memory withdrawAmounts = new uint256[](3);
        withdrawAmounts[0] = 100e18;
        withdrawAmounts[1] = 200e18;
        withdrawAmounts[2] = 300e18;

        bool[] memory forceLentRedemption = new bool[](3);
        forceLentRedemption[0] = true;
        forceLentRedemption[1] = false;
        forceLentRedemption[2] = true;

        uint256 ethBalance = address(nativeUniversalBalance).balance;
        uint256 wethBalance = weth.balanceOf(address(nativeUniversalBalance));
        uint256 borrowableCWETHBalance = borrowableCWETH.balanceOf(
            address(nativeUniversalBalance)
        );
        uint256 userETHBalance = user1.balance;

        vm.prank(user1);
        nativeUniversalBalance.multiWithdrawNativeFor(
            withdrawAmounts,
            forceLentRedemption,
            user1,
            owners
        );

        for (uint256 i; i < 3; i++) {
            (
                uint256 sittingBalance,
                uint256 lentBalance
            ) = nativeUniversalBalance.userBalances(owners[i]);

            if (forceLentRedemption[i]) {
                assertEq(sittingBalance, depositAmounts[i]);
                assertEq(lentBalance, 100e18);
            } else {
                assertEq(sittingBalance, 100e18);
                assertEq(lentBalance, depositAmounts[i]);
            }
        }

        uint256 lentAmountUsed = 0;
        uint256 sittingAmountUsed = 0;

        for (uint256 i; i < 3; i++) {
            if (forceLentRedemption[i]) {
                lentAmountUsed += withdrawAmounts[i];
            } else {
                sittingAmountUsed += withdrawAmounts[i];
            }
        }

        assertEq(address(nativeUniversalBalance).balance, ethBalance);
        assertEq(
            weth.balanceOf(address(nativeUniversalBalance)),
            wethBalance - sittingAmountUsed
        );
        assertEq(
            borrowableCWETH.balanceOf(address(nativeUniversalBalance)),
            borrowableCWETHBalance - lentAmountUsed
        );
        assertEq(user1.balance, userETHBalance + 600e18);
    }

    function testTransfer() public {
        testDeposit();

        uint256 redeemAmount = borrowableCWETH.convertToShares(100e18);
        uint256 ethBalance = address(nativeUniversalBalance).balance;
        uint256 wethBalance = weth.balanceOf(address(nativeUniversalBalance));
        uint256 borrowableCWETHBalance = borrowableCWETH.balanceOf(
            address(nativeUniversalBalance)
        );
        uint256 userUSDCBalance = weth.balanceOf(user2);

        vm.prank(user1);
        nativeUniversalBalance.transfer(100e18, true, false, user2);

        (
            uint256 user1SittingBalance,
            uint256 user1LentBalance
        ) = nativeUniversalBalance.userBalances(user1);
        (
            uint256 user2SittingBalance,
            uint256 user2LentBalance
        ) = nativeUniversalBalance.userBalances(user2);

        assertEq(user1SittingBalance, 100e18);
        assertEq(user1LentBalance, 0);
        assertEq(user2SittingBalance, 100e18);
        assertEq(user2LentBalance, 0);
        assertEq(address(nativeUniversalBalance).balance, ethBalance);
        assertEq(weth.balanceOf(user2), userUSDCBalance);

        wethBalance += 100e18;
        borrowableCWETHBalance -= redeemAmount;

        assertEq(weth.balanceOf(address(nativeUniversalBalance)), wethBalance);
        assertEq(
            borrowableCWETH.balanceOf(address(nativeUniversalBalance)),
            borrowableCWETHBalance
        );

        vm.prank(user1);
        nativeUniversalBalance.transfer(100e18, false, true, user2);

        (user1SittingBalance, user1LentBalance) = nativeUniversalBalance
            .userBalances(user1);
        (user2SittingBalance, user2LentBalance) = nativeUniversalBalance
            .userBalances(user2);

        assertEq(user1SittingBalance, 0);
        assertEq(user1LentBalance, 0);
        assertEq(user2SittingBalance, 100e18);
        assertEq(user2LentBalance, 100e18);
        assertEq(address(nativeUniversalBalance).balance, ethBalance);
        assertEq(weth.balanceOf(user2), userUSDCBalance);

        wethBalance -= 100e18;
        borrowableCWETHBalance += redeemAmount;

        assertEq(weth.balanceOf(address(nativeUniversalBalance)), wethBalance);
        assertEq(
            borrowableCWETH.balanceOf(address(nativeUniversalBalance)),
            borrowableCWETHBalance
        );
    }

    function testShiftBalance() public {
        testDeposit();

        uint256 redeemAmount = borrowableCWETH.convertToShares(100e18);
        uint256 ethBalance = address(nativeUniversalBalance).balance;
        uint256 wethBalance = weth.balanceOf(address(nativeUniversalBalance));
        uint256 borrowableCWETHBalance = borrowableCWETH.balanceOf(
            address(nativeUniversalBalance)
        );
        uint256 userUSDCBalance = weth.balanceOf(user1);

        vm.prank(user1);
        nativeUniversalBalance.shiftBalance(100e18, true);

        (
            uint256 userSittingBalance,
            uint256 userLentBalance
        ) = nativeUniversalBalance.userBalances(user1);

        assertEq(userSittingBalance, 200e18);
        assertEq(userLentBalance, 0);
        assertEq(address(nativeUniversalBalance).balance, ethBalance);
        assertEq(weth.balanceOf(user1), userUSDCBalance);

        wethBalance += 100e18;
        borrowableCWETHBalance -= redeemAmount;

        assertEq(weth.balanceOf(address(nativeUniversalBalance)), wethBalance);
        assertEq(
            borrowableCWETH.balanceOf(address(nativeUniversalBalance)),
            borrowableCWETHBalance
        );

        vm.prank(user1);
        nativeUniversalBalance.shiftBalance(200e18, false);

        redeemAmount = borrowableCWETH.convertToShares(200e18);
        (userSittingBalance, userLentBalance) = nativeUniversalBalance
            .userBalances(user1);

        assertEq(userSittingBalance, 0);
        assertEq(userLentBalance, 200e18);
        assertEq(address(nativeUniversalBalance).balance, ethBalance);
        assertEq(weth.balanceOf(user1), userUSDCBalance);

        wethBalance -= 200e18;
        borrowableCWETHBalance += redeemAmount;

        assertEq(weth.balanceOf(address(nativeUniversalBalance)), wethBalance);
        assertEq(
            borrowableCWETH.balanceOf(address(nativeUniversalBalance)),
            borrowableCWETHBalance
        );
    }

    function testLentBalanceIncreased() public {
        testDeposit();

        // mint cWBTC & borrow WETH
        _prepareWBTC(user2, 100e8);
        vm.startPrank(user2);
        wbtc.approve(address(cWBTC), 100e8);
        cWBTC.deposit(100e8, user2);
        cWBTC.postCollateral(100e8);
        borrowableCWETH.borrow(50e18);

        vm.stopPrank();

        skip(10 weeks);

        _prepareWETH(owner, 100e18);
        weth.approve(address(borrowableCWETH), 100e18);
        borrowableCWETH.deposit(100e18, address(this));

        vm.prank(user1);
        nativeUniversalBalance.withdrawNative(50e18, true, address(this));

        (uint256 sittingBalance, uint256 lentBalance) = nativeUniversalBalance
            .userBalances(user1);
        assertEq(sittingBalance, 100e18);
        assertGt(lentBalance, 50e18);
    }
}
