// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {BaseTest} from "lib/atlas/test/base/BaseTest.t.sol";
import "@atlas/contracts/libraries/CallVerification.sol";
import "@atlas/contracts/types/UserOperation.sol";
import "@atlas/contracts/types/SolverOperation.sol";
import "@atlas/contracts/types/DAppOperation.sol";
import "@atlas/contracts/types/AtlasErrors.sol";
import {SolverBase} from "@atlas/contracts/solver/SolverBase.sol";
import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";
import { AuctionManager } from "contracts/architecture/AuctionManager.sol";
import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import {AtlasEvents} from "@atlas/contracts/types/AtlasEvents.sol";
import {SolverOutcome} from "@atlas/contracts/types/EscrowTypes.sol";
import {Vm} from "forge-std/Vm.sol";

contract AuctionManagerSolverScenariosTest is AtlasErrors, TestBaseMarketIsolated, BaseTest {
    AuctionManager public dappControl;

    address public collateralToken = address(0xccccccc);

    MockSolver public solver;
    MockSolver public solver2;
    MockSolver public solver3;

    address public constant OEV_ALLOCATION_DESTINATION_FASTLANE = address(0x1);
    address public constant OEV_ALLOCATION_DESTINATION_PROTOCOL = address(0x2);
    uint256 public constant OEV_SHARE_BUNDLER = 2000; // 20%
    uint256 public constant OEV_SHARE_FASTLANE = 1000; // 10%
    uint32 public constant SOLVER_GAS_LIMIT = 6_000_000;
    uint256 solverBidAmount = 1 ether;
    uint256 solverOpTestPenalty = 0.1e18;

    uint256 auctioneerPK = 0xabcdef;
    address auctioneer = vm.addr(auctioneerPK);

    uint256 userOpSignerPK = 0x123456;
    address userOpSigner = vm.addr(userOpSignerPK);

    uint256 bundlerPK = 0x234567;
    address bundler = vm.addr(bundlerPK);

    address mockCurvanceGov = address(0xf11);

    function setUp() public override(BaseTest, TestBaseMarketIsolated) {
        super.setUp();

        vm.startPrank(governanceEOA);
        dappControl = new AuctionManager(
            address(atlas),
            ICentralRegistry(address(centralRegistry)),
            OEV_SHARE_FASTLANE,
            OEV_ALLOCATION_DESTINATION_FASTLANE,
            OEV_ALLOCATION_DESTINATION_PROTOCOL,
            6000
        );

        dappControl.setAuthorizedUserOpSigner(userOpSigner);
        atlasVerification.initializeGovernance(address(dappControl));
        atlasVerification.addSignatory(address(dappControl), auctioneer);
        // Set up mock contracts
        address executionEnv = dappControl.authorizedExecutionEnv();
        centralRegistry.addAuctionPermissions(executionEnv);

        vm.stopPrank();

        // vm.startPrank(mockCurvanceGov);
        // centralRegistry.setDAppControl(address(dappControl));
        // marketManagerIsolated.addAuthorizedAtlasDAppControl(address(dappControl));
        // vm.stopPrank();

        vm.prank(solverOneEOA);
        solver = new MockSolver(address(WETH_ADDRESS), address(atlas));
        vm.deal(address(solver), 10 * solverBidAmount);
        vm.prank(solverOneEOA);
        atlas.depositAndBond{value: 5 ether}(5 ether);

        vm.prank(solverTwoEOA);
        solver2 = new MockSolver(address(WETH_ADDRESS), address(atlas));
        vm.deal(address(solver2), 10 * solverBidAmount);
        vm.prank(solverTwoEOA);
        atlas.depositAndBond{value: 5 ether}(5 ether);

        vm.prank(solverThreeEOA);
        solver3 = new MockSolver(address(WETH_ADDRESS), address(atlas));
        vm.deal(address(solver3), 10 * solverBidAmount);
        vm.prank(solverThreeEOA);
        atlas.depositAndBond{value: 5 ether}(5 ether);
    }

    // Initialization test
    function testInitialization() public view {
        assertEq(dappControl.fastlaneRevenueDestination(), OEV_ALLOCATION_DESTINATION_FASTLANE);
        assertEq(dappControl.curvanceRevenueDestination(), OEV_ALLOCATION_DESTINATION_PROTOCOL);
        assertEq(dappControl.fastlaneSplitBPS(), OEV_SHARE_BUNDLER);
        assertEq(dappControl.solverGasLimit(), SOLVER_GAS_LIMIT);
        assertEq(dappControl.authorizedUserOpSigner(), userOpSigner);
        assertEq(address(dappControl.CENTRAL_REGISTRY()), address(centralRegistry));
    }

    function buildUserOperation(uint256 signerPK) internal view returns (UserOperation memory) {
        address signer = vm.addr(signerPK);
        UserOperation memory userOp = UserOperation({
            from: signer,
            to: address(atlas),
            value: 0,
            gas: 1_000_000,
            maxFeePerGas: 1_000_000_000,
            nonce: 1,
            deadline: block.number + 100,
            dapp: address(dappControl),
            control: address(dappControl),
            callConfig: dappControl.CALL_CONFIG(),
            dappGasLimit: 2_000_000,
            solverGasLimit: SOLVER_GAS_LIMIT,
            bundlerSurchargeRate: 1000,
            sessionKey: auctioneer,
            data: abi.encodeWithSelector(dappControl.initiateAuction.selector),
            signature: new bytes(0)
        });

        Sig memory sig;
        (sig.v, sig.r, sig.s) = vm.sign(signerPK, atlasVerification.getUserOperationPayload(userOp));
        userOp.signature = abi.encodePacked(sig.r, sig.s, sig.v);
        return userOp;
    }

    function buildSolverOperation(
        uint256 solverPK,
        address solverContract,
        bytes32 userOpHash,
        uint256 bidAmount,
        uint256 penaltyBid,
        address collateral,
        address market,
        bool isReverting
    ) internal view returns (SolverOperation memory) {
        bytes memory data;
        if (isReverting) {
            data = abi.encodeWithSelector(solver.solveRevert.selector, penaltyBid, collateral, market);
        } else {
            data = abi.encodeWithSelector(solver.solve.selector, penaltyBid, collateral, market);
        }

        address solverEoa = vm.addr(solverPK);
        SolverOperation memory solverOp = SolverOperation({
            from: solverEoa,
            to: address(atlas),
            value: 0,
            gas: SOLVER_GAS_LIMIT,
            maxFeePerGas: 1_000_000_000,
            deadline: block.number + 100,
            solver: solverContract,
            control: address(dappControl),
            userOpHash: userOpHash,
            bidToken: address(0),
            bidAmount: bidAmount,
            data: data,
            signature: new bytes(0)
        });

        Sig memory sig;
        (sig.v, sig.r, sig.s) = vm.sign(solverPK, atlasVerification.getSolverPayload(solverOp));
        solverOp.signature = abi.encodePacked(sig.r, sig.s, sig.v);
        return solverOp;
    }

    function buildDAppOperation(bytes32 userOpHash, bytes32 callChainHash, address givenBundler)
        internal
        view
        returns (DAppOperation memory)
    {
        DAppOperation memory dappOp = DAppOperation({
            from: auctioneer,
            to: address(atlas),
            nonce: 0,
            deadline: block.number + 100,
            control: address(dappControl),
            bundler: givenBundler,
            userOpHash: userOpHash,
            callChainHash: callChainHash,
            signature: new bytes(0)
        });
        Sig memory sig;
        (sig.v, sig.r, sig.s) = vm.sign(auctioneerPK, atlasVerification.getDAppOperationPayload(dappOp));
        dappOp.signature = abi.encodePacked(sig.r, sig.s, sig.v);
        return dappOp;
    }

    struct SolverBidPattern {
        uint256 bidAmount;
        uint256 testPenalty;
        address collateral;
        address market;
        bool isPreSolverOpFailing;
        bool isReverting;
    }

    function threeSolverTestTemplate(
        SolverBidPattern memory solverOne,
        SolverBidPattern memory solverTwo,
        SolverBidPattern memory solverThree
    ) public {
        UserOperation memory userOp = buildUserOperation(userOpSignerPK);
        address executionEnv = dappControl.authorizedExecutionEnv();

        bytes32 userOpHash = atlasVerification.getUserOperationHash(userOp);
        SolverOperation memory solverOp1 = buildSolverOperation(
            solverOnePK,
            address(solver),
            userOpHash,
            solverOne.bidAmount,
            solverOne.testPenalty,
            solverOne.collateral,
            solverOne.market,
            solverOne.isReverting
        );
        SolverOperation memory solverOp2 = buildSolverOperation(
            solverTwoPK,
            address(solver2),
            userOpHash,
            solverTwo.bidAmount,
            solverTwo.testPenalty,
            solverTwo.collateral,
            solverTwo.market,
            solverTwo.isReverting
        );
        SolverOperation memory solverOp3 = buildSolverOperation(
            solverThreePK,
            address(solver3),
            userOpHash,
            solverThree.bidAmount,
            solverThree.testPenalty,
            solverThree.collateral,
            solverThree.market,
            solverThree.isReverting
        );
        SolverOperation[] memory solverOps = new SolverOperation[](3);
        solverOps[0] = solverOp1;
        solverOps[1] = solverOp2;
        solverOps[2] = solverOp3;
        bytes32 callChainHash = CallVerification.getCallChainHash(userOp, solverOps);
        DAppOperation memory dappOp = buildDAppOperation(userOpHash, callChainHash, bundler);

        uint256 fastlaneBalanceBefore = address(OEV_ALLOCATION_DESTINATION_FASTLANE).balance;
        uint256 protocolBalanceBefore = address(OEV_ALLOCATION_DESTINATION_PROTOCOL).balance;

        uint256 solverOneBidPaid = solverOne.isReverting || solverOne.isPreSolverOpFailing ? 0 : solverOne.bidAmount;
        uint256 solverTwoBidPaid = solverTwo.isReverting || solverTwo.isPreSolverOpFailing ? 0 : solverTwo.bidAmount;
        uint256 solverThreeBidPaid =
            solverThree.isReverting || solverThree.isPreSolverOpFailing ? 0 : solverThree.bidAmount;

        uint256 solverOneResult = solverOne.isPreSolverOpFailing
            ? (1 << uint256(SolverOutcome.PreSolverFailed))
            : (solverOne.isReverting ? (1 << uint256(SolverOutcome.SolverOpReverted)) : 0);
        uint256 solverTwoResult = solverTwo.isPreSolverOpFailing
            ? (1 << uint256(SolverOutcome.PreSolverFailed))
            : (solverTwo.isReverting ? (1 << uint256(SolverOutcome.SolverOpReverted)) : 0);
        uint256 solverThreeResult = solverThree.isPreSolverOpFailing
            ? (1 << uint256(SolverOutcome.PreSolverFailed))
            : (solverThree.isReverting ? (1 << uint256(SolverOutcome.SolverOpReverted)) : 0);

        uint256 solverOneBondedBefore = atlas.balanceOfBonded(address(solverOneEOA));
        uint256 solverTwoBondedBefore = atlas.balanceOfBonded(address(solverTwoEOA));
        uint256 solverThreeBondedBefore = atlas.balanceOfBonded(address(solverThreeEOA));

        vm.deal(bundler, 2 ether);
        vm.txGasPrice(1 gwei);

        uint256 bundlerBalanceBefore = address(bundler).balance;

        vm.expectEmit(address(atlas));
        emit AtlasEvents.SolverTxResult(
            address(solver),
            solverOneEOA,
            address(dappControl),
            address(0),
            solverOne.bidAmount,
            !solverOne.isPreSolverOpFailing,
            !solverOne.isReverting && !solverOne.isPreSolverOpFailing,
            solverOneResult
        );
        vm.expectEmit(address(atlas));
        emit AtlasEvents.SolverTxResult(
            address(solver2),
            solverTwoEOA,
            address(dappControl),
            address(0),
            solverTwo.bidAmount,
            !solverTwo.isPreSolverOpFailing,
            !solverTwo.isReverting && !solverTwo.isPreSolverOpFailing,
            solverTwoResult
        );
        vm.expectEmit(address(atlas));
        emit AtlasEvents.SolverTxResult(
            address(solver3),
            solverThreeEOA,
            address(dappControl),
            address(0),
            solverThree.bidAmount,
            !solverThree.isPreSolverOpFailing,
            !solverThree.isReverting && !solverThree.isPreSolverOpFailing,
            solverThreeResult
        );
        if (solverOneBidPaid + solverTwoBidPaid + solverThreeBidPaid > 0) {
            uint256 totalOev = solverOneBidPaid + solverTwoBidPaid + solverThreeBidPaid;
            // vm.expectEmit(executionEnv);
            // emit AuctionManager.CurvanceOevAllocated(
            //     bundler,
            //     totalOev,
            //     totalOev * OEV_SHARE_BUNDLER / 10_000,
            //     totalOev * OEV_SHARE_FASTLANE / 10_000,
            //     totalOev - (totalOev * OEV_SHARE_BUNDLER / 10_000) - (totalOev * OEV_SHARE_FASTLANE / 10_000)
            // );
        }
        vm.expectEmit(true, true, true, false, address(atlas));
        emit AtlasEvents.MetacallResult(bundler, userOpSigner, false, 0, 0);

        vm.recordLogs();

        vm.startBroadcast(bundlerPK);

        (bool success, bytes memory returnData) = address(atlas).call{gas: 21_100_000}(
            abi.encodeWithSelector(atlas.metacall.selector, userOp, solverOps, dappOp, address(0))
        );

        // Retrieve and decode logs.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool eventFound = false;
        uint256 ethPaidToBundler;
        uint256 netGasSurcharge;
        for (uint256 i = 0; i < logs.length; i++) {
            // Check for the correct event signature.
            if (
                logs[i].topics.length >= 3
                    && logs[i].topics[0] == keccak256("MetacallResult(address,address,bool,uint256,uint256)")
            ) {
                eventFound = true;
                (, uint256 _ethPaidToBundler, uint256 _netGasSurcharge) =
                    abi.decode(logs[i].data, (bool, uint256, uint256));

                ethPaidToBundler = _ethPaidToBundler;
                netGasSurcharge = _netGasSurcharge;
                require(ethPaidToBundler > 0, "ethPaidToBundler is not > 0");
                require(netGasSurcharge > 0, "netGasSurcharge is not > 0");
            }
        }

        assertEq(success, true, "metacall should succeed");
        assertEq(abi.decode(returnData, (bool)), false, "auctionWon should be false");

        assertLt(atlas.balanceOfBonded(address(solverOneEOA)), solverOneBondedBefore);
        assertLt(atlas.balanceOfBonded(address(solverTwoEOA)), solverTwoBondedBefore);
        assertLt(atlas.balanceOfBonded(address(solverThreeEOA)), solverThreeBondedBefore);
    }

    function testOevAuction_multipleSolvers_zeroBids_success() public {
        threeSolverTestTemplate(
            SolverBidPattern({
                bidAmount: 0,
                testPenalty: solverOpTestPenalty,
                collateral: collateralToken,
                market: address(marketManagerIsolated),
                isReverting: false,
                isPreSolverOpFailing: false
            }),
            SolverBidPattern({
                bidAmount: 0,
                testPenalty: solverOpTestPenalty,
                collateral: collateralToken,
                market: address(marketManagerIsolated),
                isReverting: false,
                isPreSolverOpFailing: false
            }),
            SolverBidPattern({
                bidAmount: 0,
                testPenalty: solverOpTestPenalty,
                collateral: collateralToken,
                market: address(marketManagerIsolated),
                isReverting: false,
                isPreSolverOpFailing: false
            })
        );
    }

    function testOevAuction_multipleSolvers_oevBids_success() public {
        threeSolverTestTemplate(
            SolverBidPattern({
                bidAmount: solverBidAmount,
                testPenalty: solverOpTestPenalty,
                collateral: collateralToken,
                market: address(marketManagerIsolated),
                isReverting: false,
                isPreSolverOpFailing: false
            }),
            SolverBidPattern({
                bidAmount: solverBidAmount * 2,
                testPenalty: solverOpTestPenalty,
                collateral: collateralToken,
                market: address(marketManagerIsolated),
                isReverting: false,
                isPreSolverOpFailing: false
            }),
            SolverBidPattern({
                bidAmount: solverBidAmount * 3,
                testPenalty: solverOpTestPenalty,
                collateral: collateralToken,
                market: address(marketManagerIsolated),
                isReverting: false,
                isPreSolverOpFailing: false
            })
        );
    }

    function testOevAuction_multipleSolvers_mixedBids_success() public {
        threeSolverTestTemplate(
            SolverBidPattern({
                bidAmount: solverBidAmount,
                testPenalty: solverOpTestPenalty,
                collateral: collateralToken,
                market: address(marketManagerIsolated),
                isReverting: false,
                isPreSolverOpFailing: false
            }),
            SolverBidPattern({
                bidAmount: 0,
                testPenalty: solverOpTestPenalty,
                collateral: collateralToken,
                market: address(marketManagerIsolated),
                isReverting: false,
                isPreSolverOpFailing: false
            }),
            SolverBidPattern({
                bidAmount: solverBidAmount * 2,
                testPenalty: solverOpTestPenalty,
                collateral: collateralToken,
                market: address(marketManagerIsolated),
                isReverting: false,
                isPreSolverOpFailing: false
            })
        );
    }

    function testOevAuction_multipleSolvers_mixedBids_two_success() public {
        threeSolverTestTemplate(
            SolverBidPattern({
                bidAmount: 0,
                testPenalty: solverOpTestPenalty * 1001 / 1000,
                collateral: collateralToken,
                market: address(marketManagerIsolated),
                isReverting: false,
                isPreSolverOpFailing: false
            }),
            SolverBidPattern({
                bidAmount: solverBidAmount,
                testPenalty: solverOpTestPenalty,
                collateral: collateralToken,
                market: address(marketManagerIsolated),
                isReverting: false,
                isPreSolverOpFailing: false
            }),
            SolverBidPattern({
                bidAmount: 0,
                testPenalty: solverOpTestPenalty * 999 / 1000,
                collateral: collateralToken,
                market: address(marketManagerIsolated),
                isReverting: true,
                isPreSolverOpFailing: false
            })
        );
    }

    function testOevAuction_multipleSolvers_mixedBids_one_success() public {
        threeSolverTestTemplate(
            SolverBidPattern({
                bidAmount: 0,
                testPenalty: solverOpTestPenalty * 999 / 1000,
                collateral: collateralToken,
                market: address(marketManagerIsolated),
                isReverting: true,
                isPreSolverOpFailing: false
            }),
            SolverBidPattern({
                bidAmount: 0,
                testPenalty: solverOpTestPenalty * 998 / 1000,
                collateral: collateralToken,
                market: address(marketManagerIsolated),
                isReverting: true,
                isPreSolverOpFailing: false
            }),
            SolverBidPattern({
                bidAmount: solverBidAmount,
                testPenalty: solverOpTestPenalty * 997 / 1000,
                collateral: collateralToken,
                market: address(marketManagerIsolated),
                isReverting: false,
                isPreSolverOpFailing: false
            })
        );
    }

    function testOevAuction_multipleSolvers_all_revert_zeroBids() public {
        threeSolverTestTemplate(
            SolverBidPattern({
                bidAmount: 0,
                testPenalty: solverOpTestPenalty,
                collateral: collateralToken,
                market: address(marketManagerIsolated),
                isReverting: true,
                isPreSolverOpFailing: false
            }),
            SolverBidPattern({
                bidAmount: 0,
                testPenalty: solverOpTestPenalty * 1001 / 1000,
                collateral: collateralToken,
                market: address(marketManagerIsolated),
                isReverting: true,
                isPreSolverOpFailing: false
            }),
            SolverBidPattern({
                bidAmount: 0,
                testPenalty: solverOpTestPenalty * 1002 / 1000,
                collateral: collateralToken,
                market: address(marketManagerIsolated),
                isReverting: true,
                isPreSolverOpFailing: false
            })
        );
    }

    function testOevAuction_multipleSolvers_two_revert() public {
        threeSolverTestTemplate(
            SolverBidPattern({
                bidAmount: solverBidAmount,
                testPenalty: solverOpTestPenalty,
                collateral: collateralToken,
                market: address(marketManagerIsolated),
                isReverting: true,
                isPreSolverOpFailing: false
            }),
            SolverBidPattern({
                bidAmount: 0,
                testPenalty: solverOpTestPenalty * 1001 / 1000,
                collateral: collateralToken,
                market: address(marketManagerIsolated),
                isReverting: true,
                isPreSolverOpFailing: false
            }),
            SolverBidPattern({
                bidAmount: solverBidAmount,
                testPenalty: solverOpTestPenalty * 1002 / 1000,
                collateral: collateralToken,
                market: address(marketManagerIsolated),
                isReverting: false,
                isPreSolverOpFailing: false
            })
        );
    }

    function testOevAuction_multipleSolvers_one_revert() public {
        threeSolverTestTemplate(
            SolverBidPattern({
                bidAmount: solverBidAmount,
                testPenalty: solverOpTestPenalty,
                collateral: collateralToken,
                market: address(marketManagerIsolated),
                isReverting: false,
                isPreSolverOpFailing: false
            }),
            SolverBidPattern({
                bidAmount: solverBidAmount,
                testPenalty: solverOpTestPenalty * 1001 / 1000,
                collateral: collateralToken,
                market: address(marketManagerIsolated),
                isReverting: true,
                isPreSolverOpFailing: false
            }),
            SolverBidPattern({
                bidAmount: solverBidAmount,
                testPenalty: solverOpTestPenalty * 1002 / 1000,
                collateral: collateralToken,
                market: address(marketManagerIsolated),
                isReverting: false,
                isPreSolverOpFailing: false
            })
        );
    }

    function testOevAuction_multipleSolvers_one_revert_two() public {
        threeSolverTestTemplate(
            SolverBidPattern({
                bidAmount: solverBidAmount,
                testPenalty: solverOpTestPenalty,
                collateral: collateralToken,
                market: address(marketManagerIsolated),
                isReverting: false,
                isPreSolverOpFailing: false
            }),
            SolverBidPattern({
                bidAmount: solverBidAmount,
                testPenalty: solverOpTestPenalty * 1001 / 1000,
                collateral: collateralToken,
                market: address(marketManagerIsolated),
                isReverting: true,
                isPreSolverOpFailing: false
            }),
            SolverBidPattern({
                bidAmount: solverBidAmount,
                testPenalty: solverOpTestPenalty * 1002 / 1000,
                collateral: collateralToken,
                market: address(marketManagerIsolated),
                isReverting: false,
                isPreSolverOpFailing: false
            })
        );
    }

    function testOevAuction_multipleSolvers_all_revert_nonZeroBids() public {
        threeSolverTestTemplate(
            SolverBidPattern({
                bidAmount: solverBidAmount,
                testPenalty: solverOpTestPenalty,
                collateral: collateralToken,
                market: address(marketManagerIsolated),
                isReverting: true,
                isPreSolverOpFailing: false
            }),
            SolverBidPattern({
                bidAmount: solverBidAmount,
                testPenalty: solverOpTestPenalty * 1001 / 1000,
                collateral: collateralToken,
                market: address(marketManagerIsolated),
                isReverting: true,
                isPreSolverOpFailing: false
            }),
            SolverBidPattern({
                bidAmount: solverBidAmount,
                testPenalty: solverOpTestPenalty * 1002 / 1000,
                collateral: collateralToken,
                market: address(marketManagerIsolated),
                isReverting: true,
                isPreSolverOpFailing: false
            })
        );
    }

    function testOevAuction_multipleSolvers_all_revert() public {
        threeSolverTestTemplate(
            SolverBidPattern({
                bidAmount: solverBidAmount,
                testPenalty: solverOpTestPenalty,
                collateral: collateralToken,
                market: address(marketManagerIsolated),
                isReverting: true,
                isPreSolverOpFailing: false
            }),
            SolverBidPattern({
                bidAmount: 0,
                testPenalty: solverOpTestPenalty * 1001 / 1000,
                collateral: collateralToken,
                market: address(marketManagerIsolated),
                isReverting: true,
                isPreSolverOpFailing: false
            }),
            SolverBidPattern({
                bidAmount: solverBidAmount,
                testPenalty: solverOpTestPenalty * 1002 / 1000,
                collateral: collateralToken,
                market: address(marketManagerIsolated),
                isReverting: true,
                isPreSolverOpFailing: false
            })
        );
    }

    function testOevAuction_multipleSolvers_onePreSolverOpFailing_invalidPenalty() public {
        threeSolverTestTemplate(
            SolverBidPattern({
                bidAmount: solverBidAmount,
                testPenalty: 1,
                collateral: collateralToken,
                market: address(marketManagerIsolated),
                isReverting: false,
                isPreSolverOpFailing: true
            }),
            SolverBidPattern({
                bidAmount: solverBidAmount,
                testPenalty: solverOpTestPenalty,
                collateral: collateralToken,
                market: address(marketManagerIsolated),
                isReverting: false,
                isPreSolverOpFailing: false
            }),
            SolverBidPattern({
                bidAmount: solverBidAmount,
                testPenalty: solverOpTestPenalty,
                collateral: collateralToken,
                market: address(marketManagerIsolated),
                isReverting: false,
                isPreSolverOpFailing: false
            })
        );
    }

    function testOevAuction_multipleSolvers_onePreSolverOpFailing_invalidMarket() public {
        threeSolverTestTemplate(
            SolverBidPattern({
                bidAmount: solverBidAmount,
                testPenalty: solverOpTestPenalty,
                collateral: address(0x0abcd),
                market: address(marketManagerIsolated),
                isReverting: false,
                isPreSolverOpFailing: true
            }),
            SolverBidPattern({
                bidAmount: solverBidAmount,
                testPenalty: solverOpTestPenalty,
                collateral: collateralToken,
                market: address(marketManagerIsolated),
                isReverting: false,
                isPreSolverOpFailing: false
            }),
            SolverBidPattern({
                bidAmount: solverBidAmount,
                testPenalty: solverOpTestPenalty,
                collateral: collateralToken,
                market: address(marketManagerIsolated),
                isReverting: false,
                isPreSolverOpFailing: false
            })
        );
    }
}

contract MockSolver is SolverBase {
    fallback() external payable {}
    receive() external payable {}

    constructor(address weth, address atlas) SolverBase(weth, atlas, msg.sender) {}

    function solve() external pure {}

    function solveRevert() external pure {
        revert("Atlas OEV is not allowed");
    }
}