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

import "../src/CurvanceDAppControl.sol";
import {MockCentralRegistrySimple} from "./MockCentralRegistrySimple.sol";
import {MockMarketManagerIsolated} from "./MockMarketManagerIsolated.sol";
import {AtlasEvents} from "@atlas/contracts/types/AtlasEvents.sol";
import {SolverOutcome} from "@atlas/contracts/types/EscrowTypes.sol";
import {Vm} from "forge-std/Vm.sol";

contract AuctionManagerPreSolverTest is BaseTest, AtlasErrors {
    CurvanceDAppControl public dappControl;
    MockCentralRegistrySimple public centralRegistry;
    MockMarketManagerIsolated public marketManager;
    MockMarketManagerIsolated public unauthorizedMarketManager;

    address public collateralToken = address(0xccccccc);
    address public invalidCollateral = address(0xbbbbbbb);

    MockSolver public solver;

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

    function setUp() public override {
        super.setUp();

        vm.startPrank(mockCurvanceGov);
        centralRegistry = new MockCentralRegistrySimple();

        // Create authorized market manager
        marketManager = new MockMarketManagerIsolated(address(centralRegistry));
        marketManager.addMockToken(collateralToken, 0.8e18, 0.05e18, 0.15e18, 4e6, 5e6);

        // Create unauthorized market manager (not registered in central registry)
        unauthorizedMarketManager = new MockMarketManagerIsolated(address(centralRegistry));
        unauthorizedMarketManager.addMockToken(collateralToken, 0.8e18, 0.05e18, 0.15e18, 4e6, 5e6);
        vm.stopPrank();

        vm.startPrank(governanceEOA);
        dappControl = new CurvanceDAppControl(
            address(atlas),
            address(centralRegistry),
            OEV_SHARE_BUNDLER,
            OEV_SHARE_FASTLANE,
            OEV_ALLOCATION_DESTINATION_FASTLANE,
            OEV_ALLOCATION_DESTINATION_PROTOCOL
        );
        dappControl.setAuthorizedUserOpSigner(userOpSigner);
        atlasVerification.initializeGovernance(address(dappControl));
        atlasVerification.addSignatory(address(dappControl), auctioneer);

        // Set up mock contracts
        centralRegistry.setDAppControl(address(dappControl));
        centralRegistry.addMarketManager(address(marketManager));

        // Grant control the user op signer wallet
        vm.stopPrank();

        vm.startPrank(mockCurvanceGov);
        centralRegistry.setDAppControl(address(dappControl));
        marketManager.addAuthorizedAtlasDAppControl(address(dappControl));
        // Don't authorize the second market manager
        vm.stopPrank();

        vm.prank(solverOneEOA);
        solver = new MockSolver(address(WETH_ADDRESS), address(atlas));
        vm.deal(address(solver), 10 * solverBidAmount);
        vm.prank(solverOneEOA);
        atlas.depositAndBond{value: 5 ether}(5 ether);
    }

    // ========================================
    // Test Unauthorized Market Manager
    // ========================================

    function testPreSolverCall_unauthorizedMarket_preSolverFails() public {
        UserOperation memory userOp = buildUserOperation(userOpSignerPK);

        SolverOperation memory solverOp = buildSolverOperation(
            solverOnePK,
            address(solver),
            atlasVerification.getUserOperationHash(userOp),
            solverBidAmount,
            solverOpTestPenalty,
            collateralToken,
            address(unauthorizedMarketManager), // Use unauthorized market
            false // not reverting
        );

        SolverOperation[] memory solverOps = new SolverOperation[](1);
        solverOps[0] = solverOp;

        bytes32 callChainHash = CallVerification.getCallChainHash(userOp, solverOps);
        DAppOperation memory dappOp =
            buildDAppOperation(atlasVerification.getUserOperationHash(userOp), callChainHash, bundler);

        vm.deal(bundler, 2 ether);
        vm.txGasPrice(1 gwei);

        // Expect the solver to fail with PreSolverFailed due to unauthorized market
        // because the market manager is not registered in the central registry
        uint256 expectedResult = 1 << uint256(SolverOutcome.PreSolverFailed);
        
        vm.expectEmit(address(atlas));
        emit AtlasEvents.SolverTxResult(
            address(solver),
            solverOneEOA,
            address(dappControl),
            address(0),
            solverBidAmount,
            false, // executed = false (PreSolver failed)
            false, // success = false
            expectedResult // PreSolverFailed
        );
        
        vm.startBroadcast(bundlerPK);
        
        // Atlas catches ALL PreSolver reverts gracefully, including unauthorized markets!
        // verifyMarketManager() revert is caught just like penalty validation failures
        (bool success, bytes memory returnData) = address(atlas).call{gas: 21_100_000}(
            abi.encodeWithSelector(atlas.metacall.selector, userOp, solverOps, dappOp, address(0))
        );

        vm.stopBroadcast();

        // Atlas handles the failure gracefully:
        assertEq(success, true, "metacall should succeed even with unauthorized market");
        bool auctionWon = abi.decode(returnData, (bool));
        assertEq(auctionWon, false, "auction should not be won due to PreSolver failure");
    }

    // ========================================
    // Test Invalid Collateral
    // ========================================

    function testPreSolverCall_invalidCollateral_preSolverFails() public {
        // Test with a collateral that's not configured in the market manager
        // The market manager only has collateralToken configured, so invalidCollateral should fail
        // with _UNAUTHORIZED_LIQUIDATION_SELECTOR because ctData.collRatio == 0 for unlisted tokens
        UserOperation memory userOp = buildUserOperation(userOpSignerPK);

        SolverOperation memory solverOp = buildSolverOperation(
            solverOnePK,
            address(solver),
            atlasVerification.getUserOperationHash(userOp),
            solverBidAmount,
            solverOpTestPenalty,
            invalidCollateral, // This collateral is NOT configured in market manager
            address(marketManager),
            false
        );

        SolverOperation[] memory solverOps = new SolverOperation[](1);
        solverOps[0] = solverOp;

        bytes32 callChainHash = CallVerification.getCallChainHash(userOp, solverOps);
        DAppOperation memory dappOp =
            buildDAppOperation(atlasVerification.getUserOperationHash(userOp), callChainHash, bundler);

        vm.deal(bundler, 2 ether);
        vm.txGasPrice(1 gwei);

        // Expect the solver to fail with PreSolverFailed due to unauthorized liquidation
        // The specific error MarketManager__UnauthorizedLiquidation() (0xfac97a2b) will be caught by Atlas
        uint256 expectedResult = 1 << uint256(SolverOutcome.PreSolverFailed);

        vm.expectEmit(address(atlas));
        emit AtlasEvents.SolverTxResult(
            address(solver),
            solverOneEOA,
            address(dappControl),
            address(0),
            solverBidAmount,
            false, // executed = false (PreSolver failed due to unauthorized collateral)
            false, // success = false
            expectedResult // PreSolverFailed
        );

        vm.startBroadcast(bundlerPK);

        // Atlas catches the MarketManager__UnauthorizedLiquidation() error gracefully
        // and marks the solver as PreSolverFailed
        (bool success, bytes memory returnData) = address(atlas).call{gas: 21_100_000}(
            abi.encodeWithSelector(atlas.metacall.selector, userOp, solverOps, dappOp, address(0))
        );

        vm.stopBroadcast();

        // Atlas handles the failure gracefully:
        assertEq(success, true, "metacall should succeed even with unauthorized collateral");
        bool auctionWon = abi.decode(returnData, (bool));
        assertEq(auctionWon, false, "auction should not be won due to PreSolver failure");
    }

    function testPreSolverCall_mismatchedCollateral_preSolverFails() public {
        // Test where both collaterals are valid/listed, but there's a mismatch:
        // - Solver data specifies invalidCollateral (gets unlocked in preSolverCall)
        // - But solver attempts liquidation with collateralToken (different from unlocked)
        // This should fail the transient storage check in _checkLiquidationConfig

        // First, configure invalidCollateral in the market manager so it's "valid"
        vm.prank(mockCurvanceGov);
        marketManager.addMockToken(
            invalidCollateral,
            0.8e18, // collRatio - same as collateralToken
            0.05e18, // liqIncMin
            0.15e18, // liqIncMax
            4e6, // closeFactorMin
            5e6 // closeFactorMax
        );

        UserOperation memory userOp = buildUserOperation(userOpSignerPK);

        // Create a solver that will attempt liquidation with the WRONG collateral
        MockSolverWithCollateralMismatch mismatchSolver = new MockSolverWithCollateralMismatch(
            address(WETH_ADDRESS),
            address(atlas),
            marketManager, // Pass the contract directly, not address
            collateralToken // This is what it will try to liquidate (different from solver data)
        );

        vm.deal(address(mismatchSolver), 10 * solverBidAmount);

        SolverOperation memory solverOp = buildSolverOperation(
            solverOnePK,
            address(mismatchSolver),
            atlasVerification.getUserOperationHash(userOp),
            solverBidAmount,
            solverOpTestPenalty,
            invalidCollateral, // This gets unlocked in preSolverCall
            address(marketManager),
            false
        );

        SolverOperation[] memory solverOps = new SolverOperation[](1);
        solverOps[0] = solverOp;

        bytes32 callChainHash = CallVerification.getCallChainHash(userOp, solverOps);
        DAppOperation memory dappOp =
            buildDAppOperation(atlasVerification.getUserOperationHash(userOp), callChainHash, bundler);

        vm.deal(bundler, 2 ether);
        vm.txGasPrice(1 gwei);

        // Expect the solver to revert during execution due to collateral mismatch
        uint256 expectedResult = 1 << uint256(SolverOutcome.SolverOpReverted);

        vm.expectEmit(address(atlas));
        emit AtlasEvents.SolverTxResult(
            address(mismatchSolver),
            solverOneEOA,
            address(dappControl),
            address(0),
            solverBidAmount,
            true, // executed = true (preSolver passed, but solver reverted)
            false, // success = false (solver reverted during execution)
            expectedResult // SolverOpReverted
        );

        vm.startBroadcast(bundlerPK);

        (bool success, bytes memory returnData) = address(atlas).call{gas: 21_100_000}(
            abi.encodeWithSelector(atlas.metacall.selector, userOp, solverOps, dappOp, address(0))
        );

        vm.stopBroadcast();

        // Atlas handles the solver revert gracefully:
        assertEq(success, true, "metacall should succeed even with solver collateral mismatch");
        bool auctionWon = abi.decode(returnData, (bool));
        assertEq(auctionWon, false, "auction should not be won due to solver failure");
    }

    // ========================================
    // Test Extreme Penalty Values - These Should All Fail PreSolver
    // ========================================

    function testPreSolverCall_zeroPenalty_preSolverFailsLegacy() public {
        // NOTE: This test validates that zero penalty (0%) fails PreSolver validation
        // because it's below the minimum allowed penalty of 5% (0.05e18)
        _testPenaltyValueExpectingPreSolverFailure(0);
    }

    function testPreSolverCall_maxPenalty_preSolverFailsLegacy() public {
        // NOTE: This test validates that max penalty fails PreSolver validation
        // because it's above the maximum allowed penalty of 15% (0.15e18)
        _testPenaltyValueExpectingPreSolverFailure(type(uint256).max);
    }

    function testPreSolverCall_highPenalty_preSolverFailsLegacy() public {
        // NOTE: This test validates that 1000% penalty fails PreSolver validation
        // because it's above the maximum allowed penalty of 15% (0.15e18)
        _testPenaltyValueExpectingPreSolverFailure(10e18); // 1000% penalty
    }

    function _testPenaltyValueExpectingPreSolverFailure(uint256 penalty) internal {
        UserOperation memory userOp = buildUserOperation(userOpSignerPK);

        SolverOperation memory solverOp = buildSolverOperation(
            solverOnePK,
            address(solver),
            atlasVerification.getUserOperationHash(userOp),
            solverBidAmount,
            penalty, // Use invalid penalty value
            collateralToken,
            address(marketManager),
            false
        );

        SolverOperation[] memory solverOps = new SolverOperation[](1);
        solverOps[0] = solverOp;

        bytes32 callChainHash = CallVerification.getCallChainHash(userOp, solverOps);
        DAppOperation memory dappOp =
            buildDAppOperation(atlasVerification.getUserOperationHash(userOp), callChainHash, bundler);

        vm.deal(bundler, 2 ether);
        vm.txGasPrice(1 gwei);

        // Expect the solver to fail with PreSolverFailed due to invalid penalty
        uint256 expectedResult = 1 << uint256(SolverOutcome.PreSolverFailed);

        vm.expectEmit(address(atlas));
        emit AtlasEvents.SolverTxResult(
            address(solver),
            solverOneEOA,
            address(dappControl),
            address(0),
            solverBidAmount,
            false, // executed = false (PreSolver failed)
            false, // success = false
            expectedResult // PreSolverFailed
        );

        vm.startBroadcast(bundlerPK);

        (bool success, bytes memory returnData) = address(atlas).call{gas: 21_100_000}(
            abi.encodeWithSelector(atlas.metacall.selector, userOp, solverOps, dappOp, address(0))
        );

        vm.stopBroadcast();

        // Atlas handles the failure gracefully:
        assertEq(success, true, "metacall should succeed even with invalid penalty");
        bool auctionWon = abi.decode(returnData, (bool));
        assertEq(auctionWon, false, "auction should not be won due to PreSolver failure");
    }

    // ========================================
    // Test Malformed Solver Data
    // ========================================

    function testPreSolverCall_malformedData_reverts() public {
        UserOperation memory userOp = buildUserOperation(userOpSignerPK);
        bytes32 userOpHash = atlasVerification.getUserOperationHash(userOp);

        // Create solver operation with malformed data (less than 96 bytes)
        SolverOperation memory solverOp = SolverOperation({
            from: solverOneEOA,
            to: address(atlas),
            value: 0,
            gas: SOLVER_GAS_LIMIT,
            maxFeePerGas: 1_000_000_000,
            deadline: block.number + 100,
            solver: address(solver),
            control: address(dappControl),
            userOpHash: userOpHash,
            bidToken: address(0),
            bidAmount: solverBidAmount,
            data: abi.encodeWithSelector(solver.solve.selector), // Only 4 bytes - malformed!
            signature: new bytes(0)
        });

        Sig memory sig;
        (sig.v, sig.r, sig.s) = vm.sign(solverOnePK, atlasVerification.getSolverPayload(solverOp));
        solverOp.signature = abi.encodePacked(sig.r, sig.s, sig.v);

        SolverOperation[] memory solverOps = new SolverOperation[](1);
        solverOps[0] = solverOp;

        bytes32 callChainHash = CallVerification.getCallChainHash(userOp, solverOps);
        DAppOperation memory dappOp = buildDAppOperation(userOpHash, callChainHash, bundler);

        vm.deal(bundler, 2 ether);
        vm.txGasPrice(1 gwei);

        vm.startBroadcast(bundlerPK);

        // NOTE: getBidParamsFromSolverOpData() reverts with MalformedSolverOperation
        // This happens early in _preSolverCall, so let's test if Atlas catches this too
        vm.expectRevert(); // Testing if this is caught or causes hard revert
        (bool success,) = address(atlas).call{gas: 21_100_000}(
            abi.encodeWithSelector(atlas.metacall.selector, userOp, solverOps, dappOp, address(0))
        );

        vm.stopBroadcast();
    }

    // ========================================
    // Test Valid Operations
    // ========================================

    function testPreSolverCall_validOperation_success() public {
        UserOperation memory userOp = buildUserOperation(userOpSignerPK);

        SolverOperation memory solverOp = buildSolverOperation(
            solverOnePK,
            address(solver),
            atlasVerification.getUserOperationHash(userOp),
            solverBidAmount,
            solverOpTestPenalty,
            collateralToken,
            address(marketManager),
            false
        );

        SolverOperation[] memory solverOps = new SolverOperation[](1);
        solverOps[0] = solverOp;

        bytes32 callChainHash = CallVerification.getCallChainHash(userOp, solverOps);
        DAppOperation memory dappOp =
            buildDAppOperation(atlasVerification.getUserOperationHash(userOp), callChainHash, bundler);

        vm.deal(bundler, 2 ether);
        vm.txGasPrice(1 gwei);

        vm.startBroadcast(bundlerPK);

        (bool success,) = address(atlas).call{gas: 21_100_000}(
            abi.encodeWithSelector(atlas.metacall.selector, userOp, solverOps, dappOp, address(0))
        );

        vm.stopBroadcast();

        assertEq(success, true, "Valid operation should succeed");
    }

    // ========================================
    // Test Using Event-Based Validation (Copied from existing pattern)
    // ========================================

    function testPreSolverCall_zeroPenalty_preSolverFails() public {
        UserOperation memory userOp = buildUserOperation(userOpSignerPK);
        address executionEnv = dappControl.authorizedExecutionEnv();

        bytes32 userOpHash = atlasVerification.getUserOperationHash(userOp);
        SolverOperation memory solverOp = buildSolverOperation(
            solverOnePK,
            address(solver),
            userOpHash,
            solverBidAmount,
            0, // Zero penalty - should fail validation
            collateralToken,
            address(marketManager),
            false
        );

        SolverOperation[] memory solverOps = new SolverOperation[](1);
        solverOps[0] = solverOp;

        bytes32 callChainHash = CallVerification.getCallChainHash(userOp, solverOps);
        DAppOperation memory dappOp = buildDAppOperation(userOpHash, callChainHash, bundler);

        vm.deal(bundler, 2 ether);
        vm.txGasPrice(1 gwei);

        // Expect the solver to fail with PreSolverFailed (bit 16 = 65536)
        uint256 expectedResult = 1 << uint256(SolverOutcome.PreSolverFailed); // 65536

        vm.expectEmit(address(atlas));
        emit AtlasEvents.SolverTxResult(
            address(solver),
            solverOneEOA,
            address(dappControl),
            address(0),
            solverBidAmount,
            false, // executed = false (didn't execute due to PreSolver failure)
            false, // success = false
            expectedResult // result = PreSolverFailed flag
        );

        // Expect MetacallResult with solverSuccessful = false
        vm.expectEmit(true, true, true, false, address(atlas));
        emit AtlasEvents.MetacallResult(
            bundler,
            userOpSigner,
            false, // solverSuccessful = false (no successful solvers)
            0, // ethPaidToBundler (will be some gas refund amount)
            0 // netGasSurcharge (will be some gas amount)
        );

        vm.startBroadcast(bundlerPK);

        (bool success, bytes memory returnData) = address(atlas).call{gas: 21_100_000}(
            abi.encodeWithSelector(atlas.metacall.selector, userOp, solverOps, dappOp, address(0))
        );

        vm.stopBroadcast();

        // Metacall should succeed (Atlas executed properly)
        assertEq(success, true, "metacall should execute successfully");

        // But no solvers should have succeeded
        bool auctionWon = abi.decode(returnData, (bool));
        assertEq(auctionWon, false, "auction should not be won (no successful solvers)");
    }

    function testPreSolverCall_maxPenalty_preSolverFails() public {
        UserOperation memory userOp = buildUserOperation(userOpSignerPK);

        bytes32 userOpHash = atlasVerification.getUserOperationHash(userOp);
        SolverOperation memory solverOp = buildSolverOperation(
            solverOnePK,
            address(solver),
            userOpHash,
            solverBidAmount,
            type(uint256).max, // Max penalty - should fail validation
            collateralToken,
            address(marketManager),
            false
        );

        SolverOperation[] memory solverOps = new SolverOperation[](1);
        solverOps[0] = solverOp;

        bytes32 callChainHash = CallVerification.getCallChainHash(userOp, solverOps);
        DAppOperation memory dappOp = buildDAppOperation(userOpHash, callChainHash, bundler);

        vm.deal(bundler, 2 ether);
        vm.txGasPrice(1 gwei);

        // Expect the solver to fail with PreSolverFailed
        uint256 expectedResult = 1 << uint256(SolverOutcome.PreSolverFailed);

        vm.expectEmit(address(atlas));
        emit AtlasEvents.SolverTxResult(
            address(solver),
            solverOneEOA,
            address(dappControl),
            address(0),
            solverBidAmount,
            false, // executed = false
            false, // success = false
            expectedResult // PreSolverFailed
        );

        vm.startBroadcast(bundlerPK);

        (bool success, bytes memory returnData) = address(atlas).call{gas: 21_100_000}(
            abi.encodeWithSelector(atlas.metacall.selector, userOp, solverOps, dappOp, address(0))
        );

        vm.stopBroadcast();

        assertEq(success, true, "metacall should execute successfully");

        bool auctionWon = abi.decode(returnData, (bool));
        assertEq(auctionWon, false, "auction should not be won due to invalid penalty");
    }

    function testPreSolverCall_validPenalty_preSolverSucceeds() public {
        UserOperation memory userOp = buildUserOperation(userOpSignerPK);

        bytes32 userOpHash = atlasVerification.getUserOperationHash(userOp);
        SolverOperation memory solverOp = buildSolverOperation(
            solverOnePK,
            address(solver),
            userOpHash,
            solverBidAmount,
            0.1e18, // Valid penalty (10% - within 5%-15% range)
            collateralToken,
            address(marketManager),
            false
        );

        SolverOperation[] memory solverOps = new SolverOperation[](1);
        solverOps[0] = solverOp;

        bytes32 callChainHash = CallVerification.getCallChainHash(userOp, solverOps);
        DAppOperation memory dappOp = buildDAppOperation(userOpHash, callChainHash, bundler);

        vm.deal(bundler, 2 ether);
        vm.txGasPrice(1 gwei);

        // Expect the solver to succeed (no failure flags)
        vm.expectEmit(address(atlas));
        emit AtlasEvents.SolverTxResult(
            address(solver),
            solverOneEOA,
            address(dappControl),
            address(0),
            solverBidAmount,
            true, // executed = true
            true, // success = true
            0 // result = 0 (no failure flags)
        );

        vm.startBroadcast(bundlerPK);

        (bool success, bytes memory returnData) = address(atlas).call{gas: 21_100_000}(
            abi.encodeWithSelector(atlas.metacall.selector, userOp, solverOps, dappOp, address(0))
        );

        vm.stopBroadcast();

        assertEq(success, true, "metacall should execute successfully");

        bool auctionWon = abi.decode(returnData, (bool));
        assertEq(auctionWon, false, "auction won should be false (as per existing test pattern)");
    }

    // ========================================
    // Helper Functions (copied from existing test)
    // ========================================

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
            data: abi.encodeWithSelector(dappControl.initiateOevAuction.selector),
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
}

// Reuse the MockSolver from the main test file
contract MockSolver is SolverBase {
    fallback() external payable {}
    receive() external payable {}

    constructor(address weth, address atlas) SolverBase(weth, atlas, msg.sender) {}

    function solve(uint256 penalty, address collateral, address market) external pure {
        // Mock function - intentionally empty
    }

    function solveRevert(uint256 penalty, address collateral, address market) external pure {
        revert("Atlas OEV is not allowed");
    }
}

// Mock solver that attempts liquidation with different collateral than solver data
contract MockSolverWithCollateralMismatch is SolverBase {
    fallback() external payable {}
    receive() external payable {}

    MockMarketManagerIsolated public marketManager;
    address public wrongCollateralToLiquidate; // Different from what's in solver data

    constructor(
        address weth,
        address atlas,
        MockMarketManagerIsolated _marketManager,
        address _wrongCollateralToLiquidate
    ) SolverBase(weth, atlas, msg.sender) {
        marketManager = _marketManager;
        wrongCollateralToLiquidate = _wrongCollateralToLiquidate;
    }

    function solve(uint256 penalty, address collateral, address market) external {
        // The solver data has 'collateral' (which got unlocked in preSolverCall)
        // But we'll try to liquidate 'wrongCollateralToLiquidate' instead
        // This should trigger the _UNAUTHORIZED_LIQUIDATION_SELECTOR in _checkLiquidationConfig

        // First set up a position for liquidation
        marketManager.createPosition{value: 1000}();

        // Now attempt liquidation with the WRONG collateral (not what was unlocked)
        marketManager.liquidatePosition(
            address(this), // Liquidate our own position
            wrongCollateralToLiquidate, // This doesn't match 'collateral' that was unlocked!
            address(0x456) // dummy debt token
        );
    }

    function solveRevert(uint256 penalty, address collateral, address market) external pure {
        revert("Atlas OEV is not allowed");
    }
}