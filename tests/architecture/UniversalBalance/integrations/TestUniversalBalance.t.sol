// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import { IMToken } from "contracts/interfaces/IMToken.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IPendlePTOracle } from "contracts/interfaces/external/pendle/IPendlePtOracle.sol";

import { UniversalBalance } from "contracts/architecture/UniversalBalance.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";
import { SimplePToken } from "contracts/market/token/SimplePToken.sol";

import "tests/market/TestBaseMarket.sol";

contract User {}

contract TestUniversalBalance is TestBaseMarket {
    address public owner;

    MockDataFeed public mockUsdcFeed;
    MockDataFeed public mockStethFeed;
    MockV3Aggregator public mockWbtcFeed;

    SimplePToken public cWBTC;
    UniversalBalance public universalBalance;

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

        universalBalance = new UniversalBalance(
            ICentralRegistry(address(centralRegistry)),
            address(eUSDC)
        );

        // start epoch
        vm.warp(gaugeManager.startTime());
        vm.roll(block.number + 1000);

        mockUsdcFeed.setMockUpdatedAt(block.timestamp);
        mockWbtcFeed.updateAnswer(60000e8);

        // deploy eUSDC
        {
            // support market
            _prepareUSDC(owner, 200_000e6);
            usdc.approve(address(eUSDC), 200_000e6);
            marketManager.listToken(address(eUSDC));

            address[] memory markets = new address[](1);
            markets[0] = address(eUSDC);
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
                IMToken(address(cWBTC)),
                7000,
                4000, // liquidate at 71%
                3000,
                200, // 2% liq incentive
                400,
                0,
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
            universalBalance.setDelegateApproval(user1, true);
        }

        recipients.push(user2);
        recipients.push(user3);
        recipients.push(user4);

        for (uint256 i; i < 3; i++) {
            vm.prank(recipients[i]);
            universalBalance.setDelegateApproval(user1, true);
        }
    }

    function testInitialize() public {
        assertEq(address(universalBalance.linkedEToken()), address(eUSDC));
        assertEq(universalBalance.underlying(), _USDC_ADDRESS);
    }

    function testDeposit() public {
        _prepareUSDC(user1, 200e6);

        uint256 receiveAmount = eUSDC.convertToShares(100e6);
        uint256 usdcBalance = usdc.balanceOf(address(universalBalance));
        uint256 eUSDCBalance = eUSDC.balanceOf(address(universalBalance));

        vm.startPrank(user1);
        usdc.approve(address(universalBalance), 100e6);
        universalBalance.deposit(100e6, false);
        vm.stopPrank();

        (uint256 sittingBalance, uint256 lentBalance) = universalBalance
            .userBalances(user1);
        assertEq(sittingBalance, 100e6);
        assertEq(lentBalance, 0);
        assertEq(
            usdc.balanceOf(address(universalBalance)),
            usdcBalance + 100e6
        );
        assertEq(eUSDC.balanceOf(address(universalBalance)), eUSDCBalance);
        assertEq(usdc.balanceOf(user1), 100e6);

        vm.startPrank(user1);
        usdc.approve(address(universalBalance), 100e6);
        universalBalance.deposit(100e6, true);
        vm.stopPrank();

        (sittingBalance, lentBalance) = universalBalance.userBalances(user1);
        assertEq(sittingBalance, 100e6);
        assertEq(lentBalance, receiveAmount);
        assertEq(
            usdc.balanceOf(address(universalBalance)),
            usdcBalance + 100e6
        );
        assertEq(
            eUSDC.balanceOf(address(universalBalance)),
            eUSDCBalance + receiveAmount
        );
        assertEq(usdc.balanceOf(user1), 0);
    }

    function testMultiDepositFor() public {
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 100e6;
        amounts[1] = 200e6;
        amounts[2] = 300e6;

        bool[] memory willLend = new bool[](3);
        willLend[0] = true;
        willLend[1] = false;
        willLend[2] = true;

        _prepareUSDC(user1, 1_000e6);

        uint256[] memory receiveAmounts = new uint256[](3);

        for (uint256 i; i < 3; i++) {
            receiveAmounts[i] = eUSDC.convertToShares(amounts[i]);
        }

        uint256 usdcBalance = usdc.balanceOf(address(universalBalance));
        uint256 eUSDCBalance = eUSDC.balanceOf(address(universalBalance));
        uint256 userUSDCBalance = usdc.balanceOf(user1);

        vm.startPrank(user1);

        usdc.approve(address(universalBalance), 1_000e6);

        universalBalance.multiDepositFor(
            1_000e6,
            amounts,
            willLend,
            recipients
        );

        vm.stopPrank();

        uint256 lentAmount = 0;
        uint256 sittingAmount = 0;

        for (uint256 i; i < 3; i++) {
            (uint256 sittingBalance, uint256 lentBalance) = universalBalance
                .userBalances(recipients[i]);

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
            usdc.balanceOf(address(universalBalance)),
            usdcBalance + sittingAmount
        );
        assertEq(
            eUSDC.balanceOf(address(universalBalance)),
            eUSDCBalance + lentAmount
        );
        assertEq(usdc.balanceOf(user1), userUSDCBalance - 600e6);
    }

    function testWithdraw() public {
        testDeposit();

        uint256 redeemAmount = eUSDC.convertToShares(100e6);
        uint256 ethBalance = address(universalBalance).balance;
        uint256 usdcBalance = usdc.balanceOf(address(universalBalance));
        uint256 eUSDCBalance = eUSDC.balanceOf(address(universalBalance));

        vm.prank(user1);
        universalBalance.withdraw(100e6, false, user2);

        (uint256 sittingBalance, uint256 lentBalance) = universalBalance
            .userBalances(user1);
        assertEq(sittingBalance, 0);
        assertEq(lentBalance, 100e6);
        assertEq(address(universalBalance).balance, ethBalance);
        assertEq(
            usdc.balanceOf(address(universalBalance)),
            usdcBalance - 100e6
        );
        assertEq(eUSDC.balanceOf(address(universalBalance)), eUSDCBalance);
        assertEq(usdc.balanceOf(user2), 100e6);

        vm.prank(user1);
        universalBalance.withdraw(100e6, true, user2);

        (sittingBalance, lentBalance) = universalBalance.userBalances(user1);
        assertEq(sittingBalance, 0);
        assertEq(lentBalance, 0);
        assertEq(address(universalBalance).balance, ethBalance);
        assertEq(
            usdc.balanceOf(address(universalBalance)),
            usdcBalance - 100e6
        );
        assertEq(
            eUSDC.balanceOf(address(universalBalance)),
            eUSDCBalance - redeemAmount
        );
        assertEq(usdc.balanceOf(user2), 200e6);
    }

    function testMultiWithdrawFor() public {
        uint256[] memory depositAmounts = new uint256[](3);
        depositAmounts[0] = 200e6;
        depositAmounts[1] = 300e6;
        depositAmounts[2] = 400e6;

        for (uint256 i; i < 3; i++) {
            _prepareUSDC(owners[i], depositAmounts[i] * 2);

            vm.startPrank(owners[i]);

            usdc.approve(address(universalBalance), depositAmounts[i] * 2);
            universalBalance.deposit(depositAmounts[i], true);
            universalBalance.deposit(depositAmounts[i], false);

            vm.stopPrank();
        }

        uint256[] memory withdrawAmounts = new uint256[](3);
        withdrawAmounts[0] = 100e6;
        withdrawAmounts[1] = 200e6;
        withdrawAmounts[2] = 300e6;

        bool[] memory forceLentRedemption = new bool[](3);
        forceLentRedemption[0] = true;
        forceLentRedemption[1] = false;
        forceLentRedemption[2] = true;

        uint256 ethBalance = address(universalBalance).balance;
        uint256 usdcBalance = usdc.balanceOf(address(universalBalance));
        uint256 eUSDCBalance = eUSDC.balanceOf(address(universalBalance));
        uint256 userUSDCBalance = usdc.balanceOf(user1);

        vm.prank(user1);
        universalBalance.multiWithdrawFor(
            withdrawAmounts,
            forceLentRedemption,
            user1,
            owners
        );

        for (uint256 i; i < 3; i++) {
            (uint256 sittingBalance, uint256 lentBalance) = universalBalance
                .userBalances(owners[i]);

            if (forceLentRedemption[i]) {
                assertEq(sittingBalance, depositAmounts[i]);
                assertEq(lentBalance, 100e6);
            } else {
                assertEq(sittingBalance, 100e6);
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

        assertEq(address(universalBalance).balance, ethBalance);
        assertEq(
            usdc.balanceOf(address(universalBalance)),
            usdcBalance - sittingAmountUsed
        );
        assertEq(
            eUSDC.balanceOf(address(universalBalance)),
            eUSDCBalance - lentAmountUsed
        );
        assertEq(usdc.balanceOf(user1), userUSDCBalance + 600e6);
    }

    function testTransfer() public {
        testDeposit();

        uint256 redeemAmount = eUSDC.convertToShares(100e6);
        uint256 ethBalance = address(universalBalance).balance;
        uint256 usdcBalance = usdc.balanceOf(address(universalBalance));
        uint256 eUSDCBalance = eUSDC.balanceOf(address(universalBalance));
        uint256 userUSDCBalance = usdc.balanceOf(user2);

        vm.prank(user1);
        universalBalance.transfer(100e6, true, false, user2);

        (
            uint256 user1SittingBalance,
            uint256 user1LentBalance
        ) = universalBalance.userBalances(user1);
        (
            uint256 user2SittingBalance,
            uint256 user2LentBalance
        ) = universalBalance.userBalances(user2);

        assertEq(user1SittingBalance, 100e6);
        assertEq(user1LentBalance, 0);
        assertEq(user2SittingBalance, 100e6);
        assertEq(user2LentBalance, 0);
        assertEq(address(universalBalance).balance, ethBalance);
        assertEq(usdc.balanceOf(user2), userUSDCBalance);

        usdcBalance += 100e6;
        eUSDCBalance -= redeemAmount;

        assertEq(usdc.balanceOf(address(universalBalance)), usdcBalance);
        assertEq(eUSDC.balanceOf(address(universalBalance)), eUSDCBalance);

        vm.prank(user1);
        universalBalance.transfer(100e6, false, true, user2);

        (user1SittingBalance, user1LentBalance) = universalBalance
            .userBalances(user1);
        (user2SittingBalance, user2LentBalance) = universalBalance
            .userBalances(user2);

        assertEq(user1SittingBalance, 0);
        assertEq(user1LentBalance, 0);
        assertEq(user2SittingBalance, 100e6);
        assertEq(user2LentBalance, 100e6);
        assertEq(address(universalBalance).balance, ethBalance);
        assertEq(usdc.balanceOf(user2), userUSDCBalance);

        usdcBalance -= 100e6;
        eUSDCBalance += redeemAmount;

        assertEq(usdc.balanceOf(address(universalBalance)), usdcBalance);
        assertEq(eUSDC.balanceOf(address(universalBalance)), eUSDCBalance);
    }

    function testShiftBalance() public {
        testDeposit();

        uint256 redeemAmount = eUSDC.convertToShares(100e6);
        uint256 ethBalance = address(universalBalance).balance;
        uint256 usdcBalance = usdc.balanceOf(address(universalBalance));
        uint256 eUSDCBalance = eUSDC.balanceOf(address(universalBalance));
        uint256 userUSDCBalance = usdc.balanceOf(user1);

        vm.prank(user1);
        universalBalance.shiftBalance(100e6, true);

        (
            uint256 userSittingBalance,
            uint256 userLentBalance
        ) = universalBalance.userBalances(user1);

        assertEq(userSittingBalance, 200e6);
        assertEq(userLentBalance, 0);
        assertEq(address(universalBalance).balance, ethBalance);
        assertEq(usdc.balanceOf(user1), userUSDCBalance);

        usdcBalance += 100e6;
        eUSDCBalance -= redeemAmount;

        assertEq(usdc.balanceOf(address(universalBalance)), usdcBalance);
        assertEq(eUSDC.balanceOf(address(universalBalance)), eUSDCBalance);

        vm.prank(user1);
        universalBalance.shiftBalance(200e6, false);

        redeemAmount = eUSDC.convertToShares(200e6);
        (userSittingBalance, userLentBalance) = universalBalance.userBalances(
            user1
        );

        assertEq(userSittingBalance, 0);
        assertEq(userLentBalance, 200e6);
        assertEq(address(universalBalance).balance, ethBalance);
        assertEq(usdc.balanceOf(user1), userUSDCBalance);

        usdcBalance -= 200e6;
        eUSDCBalance += redeemAmount;

        assertEq(usdc.balanceOf(address(universalBalance)), usdcBalance);
        assertEq(eUSDC.balanceOf(address(universalBalance)), eUSDCBalance);
    }

    function testLentBalanceIncreased() public {
        testDeposit();

        // mint cWBTC & borrow USDC
        _prepareWBTC(user2, 100e8);
        vm.startPrank(user2);
        wbtc.approve(address(cWBTC), 100e8);
        cWBTC.mint(100e8, user2);
        marketManager.postCollateral(user2, address(cWBTC), 100e8);
        eUSDC.borrow(50e6);

        vm.stopPrank();

        skip(10 weeks);

        _prepareUSDC(owner, 100e6);
        usdc.approve(address(eUSDC), 100e6);
        eUSDC.mint(100e6);

        vm.prank(user1);
        universalBalance.withdraw(50e6, true, address(this));

        (uint256 sittingBalance, uint256 lentBalance) = universalBalance
            .userBalances(user1);
        assertEq(sittingBalance, 100e6);
        assertGt(lentBalance, 50e6);
    }
}
