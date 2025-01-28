// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IPendlePTOracle } from "contracts/interfaces/external/pendle/IPendlePtOracle.sol";

import { EToken } from "contracts/market/token/EToken.sol";
import { UniversalBalanceNative } from "contracts/architecture/UniversalBalanceNative.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";
import { SimplePToken } from "contracts/market/token/SimplePToken.sol";

import "tests/market/TestBaseMarket.sol";

contract User {}

contract TestUniversalBalanceNative is TestBaseMarket {
    address public owner;

    MockDataFeed public mockUsdcFeed;
    MockDataFeed public mockWethFeed;
    MockDataFeed public mockStethFeed;
    MockV3Aggregator public mockWbtcFeed;

    SimplePToken public cWBTC;
    UniversalBalanceNative public universalBalanceNative;
    EToken public eWETH;

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
            address(mockUsdcFeed),
            0,
            true
        );
        dualChainlinkAdaptor.addAsset(
            _WETH_ADDRESS,
            address(mockUsdcFeed),
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

        eWETH = _deployEToken(_WETH_ADDRESS);

        universalBalanceNative = new UniversalBalanceNative(
            ICentralRegistry(address(centralRegistry)),
            address(eWETH),
            _WETH_ADDRESS
        );

        // start epoch
        vm.warp(gaugeManager.startTime());
        vm.roll(block.number + 1000);

        mockUsdcFeed.setMockUpdatedAt(block.timestamp);
        mockWbtcFeed.updateAnswer(60000e8);

        // deploy eWETH
        {
            // support market
            _prepareWETH(owner, 200000 ether);
            weth.approve(address(eWETH), 200000e18);
            marketManager.listToken(address(eWETH));
            // add MToken support on oracle manager
            oracleManager.addMTokenSupport(address(eWETH));
            address[] memory markets = new address[](1);
            markets[0] = address(eWETH);
        }

        // deploy cWBTC
        {
            // deploy aura position vault
            cWBTC = new SimplePToken(
                ICentralRegistry(address(centralRegistry)),
                wbtc,
                address(marketManager)
            );

            // support market
            _prepareWBTC(owner, 1e8);
            wbtc.approve(address(cWBTC), 1e8);
            marketManager.listToken(address(cWBTC));
            // add MToken support on oracle manager
            oracleManager.addMTokenSupport(address(cWBTC));
            // set position token configuration
            marketManager.updatePositionToken(
                address(cWBTC),
                7000,
                4000, // liquidate at 71%
                3000,
                200, // 2% liq incentive
                400,
                1000
            );

            address[] memory mTokens = new address[](1);
            mTokens[0] = address(cWBTC);
            uint256[] memory caps = new uint256[](1);
            caps[0] = 100e8;
            marketManager.setPTokenCollateralCaps(mTokens, caps);
        }

        owners.push(user2);
        owners.push(user3);
        owners.push(user4);

        for (uint256 i; i < 3; i++) {
            vm.prank(owners[i]);
            universalBalanceNative.setDelegateApproval(user1, true);
        }

        recipients.push(user2);
        recipients.push(user3);
        recipients.push(user4);

        for (uint256 i; i < 3; i++) {
            vm.prank(recipients[i]);
            universalBalanceNative.setDelegateApproval(user1, true);
        }
    }

    function testInitialize() public {
        assertEq(
            address(universalBalanceNative.linkedToken()),
            address(eWETH)
        );
        assertEq(universalBalanceNative.underlying(), _WETH_ADDRESS);
    }

    function testDeposit() public {
        _prepareWETH(user1, 200e18);

        uint256 receiveAmount = eWETH.convertToShares(100e18);
        uint256 wethBalance = weth.balanceOf(address(universalBalanceNative));
        uint256 eWETHBalance = eWETH.balanceOf(
            address(universalBalanceNative)
        );

        vm.startPrank(user1);
        weth.approve(address(universalBalanceNative), 100e18);
        universalBalanceNative.deposit(100e18, false);
        vm.stopPrank();

        (uint256 sittingBalance, uint256 lentBalance) = universalBalanceNative
            .userBalances(user1);
        assertEq(sittingBalance, 100e18);
        assertEq(lentBalance, 0);
        assertEq(
            weth.balanceOf(address(universalBalanceNative)),
            wethBalance + 100e18
        );
        assertEq(
            eWETH.balanceOf(address(universalBalanceNative)),
            eWETHBalance
        );
        assertEq(weth.balanceOf(user1), 100e18);

        vm.startPrank(user1);
        weth.approve(address(universalBalanceNative), 100e18);
        universalBalanceNative.deposit(100e18, true);
        vm.stopPrank();

        (sittingBalance, lentBalance) = universalBalanceNative.userBalances(
            user1
        );
        assertEq(sittingBalance, 100e18);
        assertEq(lentBalance, 100e18);
        assertEq(
            weth.balanceOf(address(universalBalanceNative)),
            wethBalance + 100e18
        );
        assertEq(
            eWETH.balanceOf(address(universalBalanceNative)),
            eWETHBalance + receiveAmount
        );
        assertEq(weth.balanceOf(user1), 0);
    }

    function testDepositNative() public {
        vm.deal(user1, 200e18);

        uint256 receiveAmount = eWETH.convertToShares(100e18);
        uint256 ethBalance = address(universalBalanceNative).balance;
        uint256 wethBalance = weth.balanceOf(address(universalBalanceNative));
        uint256 eWETHBalance = eWETH.balanceOf(
            address(universalBalanceNative)
        );

        vm.prank(user1);
        universalBalanceNative.depositNative{ value: 100e18 }(false);

        (uint256 sittingBalance, uint256 lentBalance) = universalBalanceNative
            .userBalances(user1);
        assertEq(sittingBalance, 100e18);
        assertEq(lentBalance, 0);
        assertEq(address(universalBalanceNative).balance, ethBalance);
        assertEq(
            weth.balanceOf(address(universalBalanceNative)),
            wethBalance + 100e18
        );
        assertEq(
            eWETH.balanceOf(address(universalBalanceNative)),
            eWETHBalance
        );
        assertEq(user1.balance, 100e18);

        vm.prank(user1);
        universalBalanceNative.depositNative{ value: 100e18 }(true);

        (sittingBalance, lentBalance) = universalBalanceNative.userBalances(
            user1
        );
        assertEq(sittingBalance, 100e18);
        assertEq(lentBalance, 100e18);
        assertEq(address(universalBalanceNative).balance, ethBalance);
        assertEq(
            weth.balanceOf(address(universalBalanceNative)),
            wethBalance + 100e18
        );
        assertEq(
            eWETH.balanceOf(address(universalBalanceNative)),
            eWETHBalance + receiveAmount
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
            receiveAmounts[i] = eWETH.convertToShares(amounts[i]);
        }

        uint256 wethBalance = weth.balanceOf(address(universalBalanceNative));
        uint256 eWETHBalance = eWETH.balanceOf(
            address(universalBalanceNative)
        );
        uint256 userWETHBalance = weth.balanceOf(user1);

        vm.startPrank(user1);

        weth.approve(address(universalBalanceNative), 1_000e18);

        universalBalanceNative.multiDepositFor(
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
            ) = universalBalanceNative.userBalances(recipients[i]);

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
            weth.balanceOf(address(universalBalanceNative)),
            wethBalance + sittingAmount
        );
        assertEq(
            eWETH.balanceOf(address(universalBalanceNative)),
            eWETHBalance + lentAmount
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
            receiveAmounts[i] = eWETH.convertToShares(amounts[i]);
        }

        uint256 wethBalance = weth.balanceOf(address(universalBalanceNative));
        uint256 eWETHBalance = eWETH.balanceOf(
            address(universalBalanceNative)
        );
        uint256 userETHBalance = user1.balance;

        vm.prank(user1);
        universalBalanceNative.multiDepositNativeFor{ value: 1_000e18 }(
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
            ) = universalBalanceNative.userBalances(recipients[i]);

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
            weth.balanceOf(address(universalBalanceNative)),
            wethBalance + sittingAmount
        );
        assertEq(
            eWETH.balanceOf(address(universalBalanceNative)),
            eWETHBalance + lentAmount
        );
        assertEq(user1.balance, userETHBalance - 600e18);
    }

    function testWithdraw() public {
        testDeposit();

        uint256 redeemAmount = eWETH.convertToShares(100e18);
        uint256 ethBalance = address(universalBalanceNative).balance;
        uint256 wethBalance = weth.balanceOf(address(universalBalanceNative));
        uint256 eWETHBalance = eWETH.balanceOf(
            address(universalBalanceNative)
        );

        vm.prank(user1);
        universalBalanceNative.withdraw(100e18, false, user2);

        (uint256 sittingBalance, uint256 lentBalance) = universalBalanceNative
            .userBalances(user1);

        assertEq(sittingBalance, 0);
        assertEq(lentBalance, 100e18);
        assertEq(address(universalBalanceNative).balance, ethBalance);
        assertEq(
            weth.balanceOf(address(universalBalanceNative)),
            wethBalance - 100e18
        );
        assertEq(
            eWETH.balanceOf(address(universalBalanceNative)),
            eWETHBalance
        );
        assertEq(weth.balanceOf(user2), 100e18);

        vm.prank(user1);
        universalBalanceNative.withdraw(100e18, true, user2);

        (sittingBalance, lentBalance) = universalBalanceNative.userBalances(
            user1
        );
        assertEq(sittingBalance, 0);
        assertEq(lentBalance, 0);
        assertEq(address(universalBalanceNative).balance, ethBalance);
        assertEq(
            weth.balanceOf(address(universalBalanceNative)),
            wethBalance - 100e18
        );
        assertEq(
            eWETH.balanceOf(address(universalBalanceNative)),
            eWETHBalance - redeemAmount
        );
        assertEq(weth.balanceOf(user2), 200e18);
    }

    function testWithdrawNative() public {
        testDepositNative();

        uint256 redeemAmount = eWETH.convertToShares(100e18);
        uint256 ethBalance = address(universalBalanceNative).balance;
        uint256 wethBalance = weth.balanceOf(address(universalBalanceNative));
        uint256 eWETHBalance = eWETH.balanceOf(
            address(universalBalanceNative)
        );
        uint256 userETHBalance = user1.balance;

        vm.prank(user1);
        universalBalanceNative.withdrawNative(100e18, false, user2);

        (uint256 sittingBalance, uint256 lentBalance) = universalBalanceNative
            .userBalances(user1);
        assertEq(sittingBalance, 0);
        assertEq(lentBalance, 100e18);
        assertEq(address(universalBalanceNative).balance, ethBalance);
        assertEq(
            weth.balanceOf(address(universalBalanceNative)),
            wethBalance - 100e18
        );
        assertEq(
            eWETH.balanceOf(address(universalBalanceNative)),
            eWETHBalance
        );
        assertEq(user2.balance, userETHBalance + 100e18);

        vm.prank(user1);
        universalBalanceNative.withdrawNative(100e18, true, user2);

        (sittingBalance, lentBalance) = universalBalanceNative.userBalances(
            user1
        );
        assertEq(sittingBalance, 0);
        assertEq(lentBalance, 0);
        assertEq(address(universalBalanceNative).balance, ethBalance);
        assertEq(
            weth.balanceOf(address(universalBalanceNative)),
            wethBalance - 100e18
        );
        assertEq(
            eWETH.balanceOf(address(universalBalanceNative)),
            eWETHBalance - redeemAmount
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
                address(universalBalanceNative),
                depositAmounts[i] * 2
            );
            universalBalanceNative.deposit(depositAmounts[i], true);
            universalBalanceNative.deposit(depositAmounts[i], false);

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

        uint256 ethBalance = address(universalBalanceNative).balance;
        uint256 wethBalance = weth.balanceOf(address(universalBalanceNative));
        uint256 eWETHBalance = eWETH.balanceOf(
            address(universalBalanceNative)
        );
        uint256 userWETHBalance = weth.balanceOf(user1);

        vm.prank(user1);
        universalBalanceNative.multiWithdrawFor(
            withdrawAmounts,
            forceLentRedemption,
            user1,
            owners
        );

        for (uint256 i; i < 3; i++) {
            (
                uint256 sittingBalance,
                uint256 lentBalance
            ) = universalBalanceNative.userBalances(owners[i]);

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

        assertEq(address(universalBalanceNative).balance, ethBalance);
        assertEq(
            weth.balanceOf(address(universalBalanceNative)),
            wethBalance - sittingAmountUsed
        );
        assertEq(
            eWETH.balanceOf(address(universalBalanceNative)),
            eWETHBalance - lentAmountUsed
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

            universalBalanceNative.depositNative{ value: depositAmounts[i] }(
                true
            );
            universalBalanceNative.depositNative{ value: depositAmounts[i] }(
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

        uint256 ethBalance = address(universalBalanceNative).balance;
        uint256 wethBalance = weth.balanceOf(address(universalBalanceNative));
        uint256 eWETHBalance = eWETH.balanceOf(
            address(universalBalanceNative)
        );
        uint256 userETHBalance = user1.balance;

        vm.prank(user1);
        universalBalanceNative.multiWithdrawNativeFor(
            withdrawAmounts,
            forceLentRedemption,
            user1,
            owners
        );

        for (uint256 i; i < 3; i++) {
            (
                uint256 sittingBalance,
                uint256 lentBalance
            ) = universalBalanceNative.userBalances(owners[i]);

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

        assertEq(address(universalBalanceNative).balance, ethBalance);
        assertEq(
            weth.balanceOf(address(universalBalanceNative)),
            wethBalance - sittingAmountUsed
        );
        assertEq(
            eWETH.balanceOf(address(universalBalanceNative)),
            eWETHBalance - lentAmountUsed
        );
        assertEq(user1.balance, userETHBalance + 600e18);
    }

    function testTransfer() public {
        testDeposit();

        uint256 redeemAmount = eWETH.convertToShares(100e18);
        uint256 ethBalance = address(universalBalanceNative).balance;
        uint256 wethBalance = weth.balanceOf(address(universalBalanceNative));
        uint256 eWETHBalance = eWETH.balanceOf(
            address(universalBalanceNative)
        );
        uint256 userUSDCBalance = weth.balanceOf(user2);

        vm.prank(user1);
        universalBalanceNative.transfer(100e18, true, false, user2);

        (
            uint256 user1SittingBalance,
            uint256 user1LentBalance
        ) = universalBalanceNative.userBalances(user1);
        (
            uint256 user2SittingBalance,
            uint256 user2LentBalance
        ) = universalBalanceNative.userBalances(user2);

        assertEq(user1SittingBalance, 100e18);
        assertEq(user1LentBalance, 0);
        assertEq(user2SittingBalance, 100e18);
        assertEq(user2LentBalance, 0);
        assertEq(address(universalBalanceNative).balance, ethBalance);
        assertEq(weth.balanceOf(user2), userUSDCBalance);

        wethBalance += 100e18;
        eWETHBalance -= redeemAmount;

        assertEq(weth.balanceOf(address(universalBalanceNative)), wethBalance);
        assertEq(
            eWETH.balanceOf(address(universalBalanceNative)),
            eWETHBalance
        );

        vm.prank(user1);
        universalBalanceNative.transfer(100e18, false, true, user2);

        (user1SittingBalance, user1LentBalance) = universalBalanceNative
            .userBalances(user1);
        (user2SittingBalance, user2LentBalance) = universalBalanceNative
            .userBalances(user2);

        assertEq(user1SittingBalance, 0);
        assertEq(user1LentBalance, 0);
        assertEq(user2SittingBalance, 100e18);
        assertEq(user2LentBalance, 100e18);
        assertEq(address(universalBalanceNative).balance, ethBalance);
        assertEq(weth.balanceOf(user2), userUSDCBalance);

        wethBalance -= 100e18;
        eWETHBalance += redeemAmount;

        assertEq(weth.balanceOf(address(universalBalanceNative)), wethBalance);
        assertEq(
            eWETH.balanceOf(address(universalBalanceNative)),
            eWETHBalance
        );
    }

    function testShiftBalance() public {
        testDeposit();

        uint256 redeemAmount = eWETH.convertToShares(100e18);
        uint256 ethBalance = address(universalBalanceNative).balance;
        uint256 wethBalance = weth.balanceOf(address(universalBalanceNative));
        uint256 eWETHBalance = eWETH.balanceOf(
            address(universalBalanceNative)
        );
        uint256 userUSDCBalance = weth.balanceOf(user1);

        vm.prank(user1);
        universalBalanceNative.shiftBalance(100e18, true);

        (
            uint256 userSittingBalance,
            uint256 userLentBalance
        ) = universalBalanceNative.userBalances(user1);

        assertEq(userSittingBalance, 200e18);
        assertEq(userLentBalance, 0);
        assertEq(address(universalBalanceNative).balance, ethBalance);
        assertEq(weth.balanceOf(user1), userUSDCBalance);

        wethBalance += 100e18;
        eWETHBalance -= redeemAmount;

        assertEq(weth.balanceOf(address(universalBalanceNative)), wethBalance);
        assertEq(
            eWETH.balanceOf(address(universalBalanceNative)),
            eWETHBalance
        );

        vm.prank(user1);
        universalBalanceNative.shiftBalance(200e18, false);

        redeemAmount = eWETH.convertToShares(200e18);
        (userSittingBalance, userLentBalance) = universalBalanceNative
            .userBalances(user1);

        assertEq(userSittingBalance, 0);
        assertEq(userLentBalance, 200e18);
        assertEq(address(universalBalanceNative).balance, ethBalance);
        assertEq(weth.balanceOf(user1), userUSDCBalance);

        wethBalance -= 200e18;
        eWETHBalance += redeemAmount;

        assertEq(weth.balanceOf(address(universalBalanceNative)), wethBalance);
        assertEq(
            eWETH.balanceOf(address(universalBalanceNative)),
            eWETHBalance
        );
    }

    function testLentBalanceIncreased() public {
        testDeposit();

        // mint cWBTC & borrow WETH
        _prepareWBTC(user2, 100e8);
        vm.startPrank(user2);
        wbtc.approve(address(cWBTC), 100e8);
        cWBTC.mint(100e8, user2);
        marketManager.postCollateral(user2, address(cWBTC), 100e8);
        eWETH.borrow(50e18);

        vm.stopPrank();

        skip(10 weeks);

        _prepareWETH(owner, 100e18);
        weth.approve(address(eWETH), 100e18);
        eWETH.mint(100e18);

        vm.prank(user1);
        universalBalanceNative.withdrawNative(50e18, true, address(this));

        (uint256 sittingBalance, uint256 lentBalance) = universalBalanceNative
            .userBalances(user1);
        assertEq(sittingBalance, 100e18);
        assertGt(lentBalance, 50e18);
    }
}
