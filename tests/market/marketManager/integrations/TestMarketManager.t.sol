// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "../TestBaseMarketManagerEntropy.sol";
import { MockCTokenPrimitive } from "contracts/mocks/MockCTokenPrimitive.sol";

contract TestMarketManager is TestBaseMarketManagerEntropy {
    function setUp() public override {
        _fork();

        _deployCentralRegistry();
        _deployCVE();
        _deployRewardManager();
        _deployVeCVE();
        _deployGaugePool();
        _deployMarketManager();
        _deployDynamicInterestRateModel();
        // eth/usd is needed in price router constructor
        chainlinkEthUsd = chainlinkEthUsds[
            block.chainid
        ] = new MockV3Aggregator(8, 1500e8, 1e50, 1e6);
        _deployOracleRouter();
        chainlinkAdaptor = chainlinkAdaptors[
            block.chainid
        ] = new ChainlinkAdaptor(ICentralRegistry(address(centralRegistry)));
        oracleRouter.addApprovedAdaptor(address(chainlinkAdaptor));
        // start gauge to enable deposits
        gaugePool.start(address(marketManager));
        vm.warp(veCVE.nextEpochStartTime() + 1000);
        chainlinkEthUsd.updateAnswer(1500e8);
    }

    function testHypotheticalLiquidityOf() public {
        address[] memory users = new address[](3);
        users[0] = address(0x1111);
        users[1] = address(0x2222);
        users[2] = address(0x3333);

        noOfCollateralTokens = 2;
        noOfDebtTokens = 2;

        MockCTokenPrimitive[] memory cTokens = new MockCTokenPrimitive[](
            noOfCollateralTokens
        );
        DToken[] memory dTokens = new DToken[](noOfDebtTokens);
        MockV3Aggregator[] memory cTokensAgg = new MockV3Aggregator[](
            noOfCollateralTokens
        );
        MockV3Aggregator[]
            memory cTokensUnderlyingAgg = new MockV3Aggregator[](
                noOfCollateralTokens
            );
        MockV3Aggregator[] memory dTokensAgg = new MockV3Aggregator[](
            noOfDebtTokens
        );

        (
            cTokens,
            cTokensAgg,
            cTokensUnderlyingAgg
        ) = _genCollateralateraltoken(noOfCollateralTokens, 0);
        (dTokens, dTokensAgg) = _genDebtToken(noOfDebtTokens);

        _genCollateral(users[0], cTokens[0], 1 ether);
        _postCollateral(users[0], cTokens[0], 1 ether);

        _genCollateral(users[1], cTokens[1], 1 ether);
        _postCollateral(users[1], cTokens[1], 1 ether);

        _genCollateral(users[2], cTokens[1], 1 ether);
        _postCollateral(users[2], cTokens[1], 1 ether);

        _supplyDToken(users[2], dTokens[0], 3 ether);

        _borrow(users[0], dTokens[0], 0.7 ether);
        _borrow(users[1], dTokens[0], 0.7 ether);
        _borrow(users[2], dTokens[0], 0.7 ether);

        for (uint256 i = 0; i < noOfCollateralTokens; i++) {
            skip(20 minutes);
            _updateRoundData(cTokensAgg[i], 0, 1e7);
        }

        vm.expectRevert(
            MarketManager.MarketManager__InvalidParameter.selector
        );
        marketManager.hypotheticalLiquidityOf(
            users[0],
            address(cTokens[0]),
            0,
            1
        );

        (uint256 liquidity, uint256 debt, ) = marketManager
            .hypotheticalLiquidityOf(users[0], address(cTokens[0]), 0, 0);

        assertEq(liquidity, 0);
        assertGt(debt, 0);
    }

    function testPostCollateral() public {
        address[] memory users = new address[](3);
        users[0] = address(0x1111);
        users[1] = address(0x2222);
        users[2] = address(0x3333);

        noOfCollateralTokens = 2;
        noOfDebtTokens = 2;

        MockCTokenPrimitive[] memory cTokens = new MockCTokenPrimitive[](
            noOfCollateralTokens
        );
        DToken[] memory dTokens = new DToken[](noOfDebtTokens);
        MockV3Aggregator[] memory cTokensAgg = new MockV3Aggregator[](
            noOfCollateralTokens
        );
        MockV3Aggregator[]
            memory cTokensUnderlyingAgg = new MockV3Aggregator[](
                noOfCollateralTokens
            );
        MockV3Aggregator[] memory dTokensAgg = new MockV3Aggregator[](
            noOfDebtTokens
        );

        (
            cTokens,
            cTokensAgg,
            cTokensUnderlyingAgg
        ) = _genCollateralateraltoken(noOfCollateralTokens, 0);
        (dTokens, dTokensAgg) = _genDebtToken(noOfDebtTokens);

        _genCollateral(users[0], cTokens[0], 1 ether);

        vm.expectRevert(
            MarketManager.MarketManager__InvalidParameter.selector
        );
        vm.prank(users[0]);
        marketManager.postCollateral(
            address(users[0]),
            address(cTokens[0]),
            0
        );

        vm.expectRevert(MarketManager.MarketManager__TokenNotListed.selector);
        vm.prank(users[0]);
        marketManager.postCollateral(
            address(users[0]),
            address(address(0)),
            1 ether
        );

        vm.expectRevert(
            MarketManager.MarketManager__InsufficientCollateral.selector
        );
        vm.prank(users[0]);
        marketManager.postCollateral(
            address(users[0]),
            address(cTokens[0]),
            2 ether
        );

        vm.prank(users[0]);
        marketManager.postCollateral(
            address(users[0]),
            address(cTokens[0]),
            1 ether
        );
    }

    function testRemoveCollateral() public {
        address[] memory users = new address[](3);
        users[0] = address(0x1111);
        users[1] = address(0x2222);
        users[2] = address(0x3333);

        noOfCollateralTokens = 2;
        noOfDebtTokens = 2;

        MockCTokenPrimitive[] memory cTokens = new MockCTokenPrimitive[](
            noOfCollateralTokens
        );
        DToken[] memory dTokens = new DToken[](noOfDebtTokens);
        MockV3Aggregator[] memory cTokensAgg = new MockV3Aggregator[](
            noOfCollateralTokens
        );
        MockV3Aggregator[]
            memory cTokensUnderlyingAgg = new MockV3Aggregator[](
                noOfCollateralTokens
            );
        MockV3Aggregator[] memory dTokensAgg = new MockV3Aggregator[](
            noOfDebtTokens
        );

        (
            cTokens,
            cTokensAgg,
            cTokensUnderlyingAgg
        ) = _genCollateralateraltoken(noOfCollateralTokens, 0);
        (dTokens, dTokensAgg) = _genDebtToken(noOfDebtTokens);

        _genCollateral(users[0], cTokens[0], 1 ether);
        _postCollateral(users[0], cTokens[0], 1 ether);

        skip(30 minutes);

        vm.expectRevert(
            MarketManager.MarketManager__InvalidParameter.selector
        );
        marketManager.removeCollateral(address(cTokens[0]), 0);

        vm.expectRevert(MarketManager.MarketManager__InvariantError.selector);
        marketManager.removeCollateral(address(cTokens[0]), 1 ether);

        vm.expectRevert(
            MarketManager.MarketManager__InsufficientCollateral.selector
        );
        vm.prank(users[0]);
        marketManager.removeCollateral(address(cTokens[0]), 2 ether);

        vm.prank(users[0]);
        marketManager.removeCollateral(address(cTokens[0]), 1 ether);
    }

    function testPositionCloseAfterRemoveCollateral() public {
        address[] memory users = new address[](3);
        users[0] = address(0x1111);
        users[1] = address(0x2222);
        users[2] = address(0x3333);

        noOfCollateralTokens = 2;
        noOfDebtTokens = 2;

        MockCTokenPrimitive[] memory cTokens = new MockCTokenPrimitive[](
            noOfCollateralTokens
        );
        DToken[] memory dTokens = new DToken[](noOfDebtTokens);
        MockV3Aggregator[] memory cTokensAgg = new MockV3Aggregator[](
            noOfCollateralTokens
        );
        MockV3Aggregator[]
            memory cTokensUnderlyingAgg = new MockV3Aggregator[](
                noOfCollateralTokens
            );
        MockV3Aggregator[] memory dTokensAgg = new MockV3Aggregator[](
            noOfDebtTokens
        );

        (
            cTokens,
            cTokensAgg,
            cTokensUnderlyingAgg
        ) = _genCollateralateraltoken(noOfCollateralTokens, 0);
        (dTokens, dTokensAgg) = _genDebtToken(noOfDebtTokens);

        _genCollateral(users[0], cTokens[0], 1 ether);
        _postCollateral(users[0], cTokens[0], 1 ether);

        skip(30 minutes);

        uint256 collateralSurplus;
        uint256 liquidityDeficit;
        bool[] memory positionsToClose;
        (collateralSurplus, liquidityDeficit, positionsToClose) = marketManager
            .hypotheticalLiquidityOf(users[0], address(cTokens[0]), 0, 0);

        assertEq(positionsToClose.length, 1);
        assertEq(positionsToClose[0], false);
        (bool hasPosition, , ) = marketManager.tokenDataOf(
            users[0],
            address(cTokens[0])
        );
        assertEq(hasPosition, true);

        vm.prank(users[0]);
        marketManager.removeCollateral(address(cTokens[0]), 1 ether);

        (hasPosition, , ) = marketManager.tokenDataOf(
            users[0],
            address(cTokens[0])
        );
        assertEq(hasPosition, false);

        (collateralSurplus, liquidityDeficit, positionsToClose) = marketManager
            .hypotheticalLiquidityOf(users[0], address(cTokens[0]), 0, 0);
        assertEq(collateralSurplus, 0);
        assertEq(liquidityDeficit, 0);
    }

    function testPositionCloseAfterRedeem() public {
        address[] memory users = new address[](3);
        users[0] = address(0x1111);
        users[1] = address(0x2222);
        users[2] = address(0x3333);

        noOfCollateralTokens = 2;
        noOfDebtTokens = 2;

        MockCTokenPrimitive[] memory cTokens = new MockCTokenPrimitive[](
            noOfCollateralTokens
        );
        DToken[] memory dTokens = new DToken[](noOfDebtTokens);
        MockV3Aggregator[] memory cTokensAgg = new MockV3Aggregator[](
            noOfCollateralTokens
        );
        MockV3Aggregator[]
            memory cTokensUnderlyingAgg = new MockV3Aggregator[](
                noOfCollateralTokens
            );
        MockV3Aggregator[] memory dTokensAgg = new MockV3Aggregator[](
            noOfDebtTokens
        );

        (
            cTokens,
            cTokensAgg,
            cTokensUnderlyingAgg
        ) = _genCollateralateraltoken(noOfCollateralTokens, 0);
        (dTokens, dTokensAgg) = _genDebtToken(noOfDebtTokens);

        _genCollateral(users[0], cTokens[0], 1 ether);
        _postCollateral(users[0], cTokens[0], 1 ether);

        skip(30 minutes);

        uint256 collateralSurplus;
        uint256 liquidityDeficit;
        bool[] memory positionsToClose;
        (collateralSurplus, liquidityDeficit, positionsToClose) = marketManager
            .hypotheticalLiquidityOf(users[0], address(cTokens[0]), 0, 0);

        assertEq(positionsToClose.length, 1);
        assertEq(positionsToClose[0], false);
        (bool hasPosition, , ) = marketManager.tokenDataOf(
            users[0],
            address(cTokens[0])
        );
        assertEq(hasPosition, true);

        vm.prank(users[0]);
        cTokens[0].withdrawCollateral(1 ether, users[0], users[0]);

        (hasPosition, , ) = marketManager.tokenDataOf(
            users[0],
            address(cTokens[0])
        );
        assertEq(hasPosition, false);

        (collateralSurplus, liquidityDeficit, positionsToClose) = marketManager
            .hypotheticalLiquidityOf(users[0], address(cTokens[0]), 0, 0);
        assertEq(collateralSurplus, 0);
        assertEq(liquidityDeficit, 0);
    }

    function testPositionCloseAfterLiquidate() public {
        address[] memory users = new address[](3);
        users[0] = address(0x1111);
        users[1] = address(0x2222);
        users[2] = address(0x3333);

        noOfCollateralTokens = 2;
        noOfDebtTokens = 2;

        MockCTokenPrimitive[] memory cTokens = new MockCTokenPrimitive[](
            noOfCollateralTokens
        );
        DToken[] memory dTokens = new DToken[](noOfDebtTokens);
        MockV3Aggregator[] memory cTokensAgg = new MockV3Aggregator[](
            noOfCollateralTokens
        );
        MockV3Aggregator[]
            memory cTokensUnderlyingAgg = new MockV3Aggregator[](
                noOfCollateralTokens
            );
        MockV3Aggregator[] memory dTokensAgg = new MockV3Aggregator[](
            noOfDebtTokens
        );

        (
            cTokens,
            cTokensAgg,
            cTokensUnderlyingAgg
        ) = _genCollateralateraltoken(noOfCollateralTokens, 0);
        (dTokens, dTokensAgg) = _genDebtToken(noOfDebtTokens);

        _genCollateral(users[0], cTokens[0], 1 ether);
        _postCollateral(users[0], cTokens[0], 1 ether);

        _supplyDToken(users[2], dTokens[0], 3 ether);
        _borrow(users[0], dTokens[0], 0.6 ether);

        _supplyDToken(users[2], dTokens[1], 3 ether);
        _borrow(users[0], dTokens[1], 0.1 ether);

        skip(20 minutes);
        _updateRoundData(cTokensAgg[0], 0, 0.9e8);

        uint256 collateralSurplus;
        uint256 liquidityDeficit;
        bool[] memory positionsToClose;
        (collateralSurplus, liquidityDeficit, positionsToClose) = marketManager
            .hypotheticalLiquidityOf(users[0], address(cTokens[0]), 0, 0);

        bool hasPosition;
        assertEq(positionsToClose.length, 3);
        assertEq(positionsToClose[0], false);
        assertEq(positionsToClose[1], false);
        assertEq(positionsToClose[2], false);
        (hasPosition, , ) = marketManager.tokenDataOf(
            users[0],
            address(cTokens[0])
        );
        assertEq(hasPosition, true);
        (hasPosition, , ) = marketManager.tokenDataOf(
            users[0],
            address(dTokens[0])
        );
        assertEq(hasPosition, true);
        (hasPosition, , ) = marketManager.tokenDataOf(
            users[0],
            address(dTokens[1])
        );
        assertEq(hasPosition, true);

        _liquidate(dTokens[0], cTokens[0], users[0], true);

        (collateralSurplus, liquidityDeficit, positionsToClose) = marketManager
            .hypotheticalLiquidityOf(users[0], address(cTokens[0]), 0, 0);

        assertEq(positionsToClose.length, 3);
        assertEq(positionsToClose[0], false);
        assertEq(positionsToClose[1], true);
        assertEq(positionsToClose[2], false);
        (hasPosition, , ) = marketManager.tokenDataOf(
            users[0],
            address(cTokens[0])
        );
        assertEq(hasPosition, true);
        (hasPosition, , ) = marketManager.tokenDataOf(
            users[0],
            address(dTokens[0])
        );
        assertEq(hasPosition, true);
        (hasPosition, , ) = marketManager.tokenDataOf(
            users[0],
            address(dTokens[1])
        );
        assertEq(hasPosition, true);
        vm.prank(address(dTokens[1]));
        marketManager.canBorrowWithPrune(address(dTokens[1]), users[0], 0);
        vm.prank(users[0]);

        (collateralSurplus, liquidityDeficit, positionsToClose) = marketManager
            .hypotheticalLiquidityOf(users[0], address(cTokens[0]), 0, 0);

        assertEq(positionsToClose.length, 2);
        assertEq(positionsToClose[0], false);
        assertEq(positionsToClose[1], false);
        (hasPosition, , ) = marketManager.tokenDataOf(
            users[0],
            address(cTokens[0])
        );
        assertEq(hasPosition, true);
        (hasPosition, , ) = marketManager.tokenDataOf(
            users[0],
            address(dTokens[0])
        );
        assertEq(hasPosition, false);
        (hasPosition, , ) = marketManager.tokenDataOf(
            users[0],
            address(dTokens[1])
        );
        assertEq(hasPosition, true);
    }
}
