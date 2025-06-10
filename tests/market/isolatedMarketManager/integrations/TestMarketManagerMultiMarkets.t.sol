// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarketManagerEntropy } from "../TestBaseMarketManagerEntropy.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { MockSimplePToken } from "contracts/mocks/MockSimplePToken.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";
import { EToken } from "contracts/market/token/EToken.sol";
import { IMToken } from "contracts/interfaces/IMToken.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

import "forge-std/console2.sol";

contract TestMarketManagerMultiMarkets is TestBaseMarketManagerEntropy {
    function setUp() public override {
        _fork();

        _deployCentralRegistry();
        _deployCVE();
        _deployRewardManager();
        _deployVeCVE();
        _deployGaugeManager();
        _deployMarketManager();
        _deployAuxiliaryData();
        // eth/usd is needed in oracle manager constructor
        chainlinkEthUsd = chainlinkEthUsds[
            block.chainid
        ] = new MockV3Aggregator(8, 1500e8, 1e50, 1e6);
        _deployOracleManager();
        chainlinkAdaptor = chainlinkAdaptors[
            block.chainid
        ] = new ChainlinkAdaptor(ICentralRegistry(address(centralRegistry)));
        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));
        // start gauge to enable deposits
        vm.warp(veCVE.nextEpochStartTime() + 1000);
        chainlinkEthUsd.updateAnswer(1500e8);
    }

    function setUpFuzzTest(
        uint16 /* _noOfPositionTokens */,
        uint16 _noOfEarnTokens,
        uint16 _noOfUsers,
        uint16 _entropy
    )
        internal
        returns (
            MockSimplePToken[] memory,
            EToken[] memory,
            address[] memory,
            MockV3Aggregator[] memory,
            MockV3Aggregator[] memory,
            MockV3Aggregator[] memory
        )
    {
        noOfPositionTokens = 1; // uint256((_noOfPositionTokens % 5)) + 2;
        noOfEarnTokens = uint256((_noOfEarnTokens % 5)) + 1;
        noOfUsersCollateral = uint256((_noOfUsers % 3)) + 2;
        noOfUsersDebt = uint256((_noOfUsers % 3)) + 1;
        noOfUsersMixed = uint256((_noOfUsers % 2)) + 1;
        noOfUsers = noOfUsersCollateral + noOfUsersDebt + noOfUsersMixed;
        entropy = uint256(_entropy) + 1;

        MockSimplePToken[] memory pTokens = new MockSimplePToken[](
            noOfPositionTokens
        );
        EToken[] memory eTokens = new EToken[](noOfEarnTokens);
        address[] memory users = new address[](noOfUsers);

        MockV3Aggregator[] memory pTokensAgg = new MockV3Aggregator[](
            noOfPositionTokens
        );
        MockV3Aggregator[]
            memory pTokensUnderlyingAgg = new MockV3Aggregator[](
                noOfPositionTokens
            );
        MockV3Aggregator[] memory eTokensAgg = new MockV3Aggregator[](
            noOfEarnTokens
        );

        for (uint256 i = 0; i < noOfUsers; i++) {
            users[i] = address(uint160((i + 100)));
        }
        (
            pTokens,
            pTokensAgg,
            pTokensUnderlyingAgg
        ) = _genCollateralateraltoken(noOfPositionTokens, entropy);

        (eTokens, eTokensAgg) = _genEarnToken(noOfEarnTokens);
        return (
            pTokens,
            eTokens,
            users,
            pTokensAgg,
            pTokensUnderlyingAgg,
            eTokensAgg
        );
    }

    function _setupLiquidity(
        uint256 collateralLimit,
        uint256 debtLimit,
        address[] memory users,
        MockSimplePToken[] memory pTokens,
        EToken[] memory eTokens
    ) internal {
        uint256 runs;
        uint256 _amountCollateral;
        uint256 _amountDebt;
        for (uint256 i = 0; i < noOfUsers; i++) {
            runs = _genRandom(i, entropy, 1, noOfPositionTokens);
            for (uint256 j = 0; j < runs; j++) {
                console2.log("collateralLimt %s", collateralLimit);
                console2.log("debtLimit %s", debtLimit);
                _amountCollateral = _genRandom(
                    i,
                    entropy,
                    100e18,
                    collateralLimit
                );
                _amountDebt = _genRandom(i, entropy, 100e18, debtLimit);
                if (i < noOfUsersCollateral) {
                    _genColWithEntropy(
                        users[i],
                        pTokens[j],
                        _amountCollateral
                    );
                } else if (i < noOfUsersCollateral + noOfUsersDebt) {
                    _supplyETokenWithEntropy(
                        users[i],
                        eTokens[j % noOfEarnTokens],
                        _amountDebt
                    );
                } else {
                    _genColWithEntropy(
                        users[i],
                        pTokens[j],
                        _amountCollateral
                    );
                    _supplyETokenWithEntropy(
                        users[i],
                        eTokens[j % noOfEarnTokens],
                        _amountDebt
                    );
                }
            }
        }
        _executeBorrows(users, eTokens, pTokens);
    }

    function testLiquidationMultipleMarkets() public {
        address[] memory users = new address[](3);
        users[0] = address(0x1111);
        users[1] = address(0x2222);
        users[2] = address(0x3333);

        noOfPositionTokens = 2;
        noOfEarnTokens = 2;

        MockSimplePToken[] memory pTokens = new MockSimplePToken[](
            noOfPositionTokens
        );
        EToken[] memory eTokens = new EToken[](noOfEarnTokens);
        MockV3Aggregator[] memory pTokensAgg = new MockV3Aggregator[](
            noOfPositionTokens
        );
        MockV3Aggregator[]
            memory pTokensUnderlyingAgg = new MockV3Aggregator[](
                noOfPositionTokens
            );
        MockV3Aggregator[] memory eTokensAgg = new MockV3Aggregator[](
            noOfEarnTokens
        );

        (
            pTokens,
            pTokensAgg,
            pTokensUnderlyingAgg
        ) = _genCollateralateraltoken(noOfPositionTokens, 0);
        (eTokens, eTokensAgg) = _genEarnToken(noOfEarnTokens);

        _genCollateral(users[0], pTokens[0], 100e18);
        _postCollateral(users[0], pTokens[0], 100e18);

        _genCollateral(users[1], pTokens[1], 100e18);
        _postCollateral(users[1], pTokens[1], 100e18);

        _genCollateral(users[2], pTokens[1], 100e18);
        _postCollateral(users[2], pTokens[1], 100e18);

        _supplyEToken(users[2], eTokens[0], 300e18);

        _borrow(users[0], eTokens[0], 70e18);
        _borrow(users[1], eTokens[0], 70e18);
        _borrow(users[2], eTokens[0], 70e18);

        for (uint256 i = 0; i < noOfPositionTokens; i++) {
            skip(20 minutes);
            _updateRoundData(pTokensAgg[i], 0, 1e7);
        }

        _liquidate(eTokens[0], pTokens[0], users[0], false);
        _liquidate(eTokens[0], pTokens[1], users[1], true);

        _prepareLiquidationMultiple(liquidator, eTokens);
        // _liquidateAccount(users[2], liquidator);
    }

    function testLiquidationMultipleMarketsWithEntropyEtoken(
        uint16 _noOfPositionTokens,
        uint16 _noOfEarnTokens,
        uint16 _noOfUsers,
        uint16 _entropy
    ) public {
        (
            MockSimplePToken[] memory pTokens,
            EToken[] memory eTokens,
            address[] memory users,
            MockV3Aggregator[] memory pTokensAgg,
            ,

        ) = setUpFuzzTest(
                _noOfPositionTokens,
                _noOfEarnTokens,
                _noOfUsers,
                _entropy
            );
        _setupLiquidity(100e18, 200e18, users, pTokens, eTokens);

        for (uint256 i; i < noOfPositionTokens; i++) {
            skip(20 minutes);
            _updateRoundData(pTokensAgg[0], 0, 1e7);
        }

        _liquidateAllByEToken(eTokens, pTokens, users);
    }

    function testLiquidationMultipleMarketsWithEntropyExact(
        uint16 _noOfPositionTokens,
        uint16 _noOfEarnTokens,
        uint16 _noOfUsers,
        uint16 _entropy
    ) public {
        (
            MockSimplePToken[] memory pTokens,
            EToken[] memory eTokens,
            address[] memory users,
            MockV3Aggregator[] memory pTokensAgg,
            ,

        ) = setUpFuzzTest(
                _noOfPositionTokens,
                _noOfEarnTokens,
                _noOfUsers,
                _entropy
            );
        _setupLiquidity(100e18, 200e18, users, pTokens, eTokens);

        for (uint256 i; i < noOfPositionTokens; i++) {
            skip(20 minutes);
            _updateRoundData(pTokensAgg[0], 0, 1e7);
        }

        _liquidateAllExact(eTokens, pTokens, users);
    }

    function testLiquidationMultipleMarketsWithEntropyAccount(
        uint16 _noOfPositionTokens,
        uint16 _noOfEarnTokens,
        uint16 _noOfUsers,
        uint16 _entropy
    ) public {
        (
            MockSimplePToken[] memory pTokens,
            EToken[] memory eTokens,
            address[] memory users,
            MockV3Aggregator[] memory pTokensAgg,
            ,

        ) = setUpFuzzTest(
                _noOfPositionTokens,
                _noOfEarnTokens,
                _noOfUsers,
                _entropy
            );
        _setupLiquidity(100e18, 200e18, users, pTokens, eTokens);

        for (uint256 i; i < noOfPositionTokens; i++) {
            skip(20 minutes);
            _updateRoundData(pTokensAgg[0], 0, 1e7);
        }

        _prepareLiquidationMultiple(liquidator, eTokens);
        for (uint256 i = 0; i < noOfUsersCollateral; i++) {
            if (!auxiliaryData.flaggedForLiquidation(address(marketManagerIsolated), users[i], address(eTokens[0]), address(pTokens[0]))) {
                continue;
            }
            // _liquidateAccount(users[i], liquidator);
        }
    }

    function _compareUserAssets(
        IMToken[] memory userAssets,
        uint256[] memory pTokenBalancesPre,
        uint256[] memory eTokenBalancesPre,
        uint256[] memory underlyingBalancesPre,
        address user
    ) internal view {
        uint256[] memory pTokenBalances = new uint256[](noOfPositionTokens);
        uint256[] memory eTokenBalances = new uint256[](noOfEarnTokens);
        uint256[] memory underlyingBalances = new uint256[](noOfEarnTokens);

        for (uint256 i = 0; i < userAssets.length; i++) {
            if (userAssets[i].isPToken()) {
                pTokenBalances[i] = userAssets[i].balanceOf(user);
            } else {
                eTokenBalances[i] = userAssets[i].balanceOf(user);
                underlyingBalances[i] = IERC20(userAssets[i].underlying())
                    .balanceOf(user);
            }
        }
        console2.log("\nuser %s", user);
        console2.log("\npTokenBalances");
        for (uint256 i = 0; i < noOfPositionTokens; i++) {
            console2.log(
                "pre %s post %s",
                pTokenBalancesPre[i],
                pTokenBalances[i]
            );
        }
        console2.log("\neTokenBalances");
        for (uint256 i = 0; i < noOfEarnTokens; i++) {
            console2.log(
                "pre %s post %s",
                eTokenBalancesPre[i],
                eTokenBalances[i]
            );
        }
        console2.log("\nunderlyingBalances");
        for (uint256 i = 0; i < noOfEarnTokens; i++) {
            console2.log(
                "pre %s post %s",
                underlyingBalancesPre[i],
                underlyingBalances[i]
            );
        }
    }
}
