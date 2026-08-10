// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";

import {MonitorReader} from "contracts/views/MonitorReader.sol";

contract MonitorReaderMonadForkTest is Test {
    address internal constant CENTRAL_REGISTRY =
        0x1310f352f1389969Ece6741671c4B919523912fF;
    address internal constant HIGH_YIELD_AUSD_OPTIMIZER =
        0xaD663aC84052b52BE4ed1b27BA416505e84a00Bf;

    MonitorReader internal reader;

    function setUp() public {
        vm.createSelectFork(vm.envString("MON_NODE_URI_MONAD_ARCHIVE"));
        reader = new MonitorReader();
    }

    function test_currentProtocolHasNoCriticalSignals() public view {
        uint256 gasBefore = gasleft();
        (
            uint256 wiring,
            uint256 tokenAccounting,
            uint256 backing,
            uint256 borrowAccounting
        ) = reader.protocolCriticalSignals(CENTRAL_REGISTRY);
        console2.log("protocolCriticalSignals gas", gasBefore - gasleft());
        (uint256 optimizerCritical, uint256 optimizerReadFailure) =
            reader.optimizerCriticalSignals(HIGH_YIELD_AUSD_OPTIMIZER);

        assertEq(wiring, 0, "critical wiring");
        assertEq(tokenAccounting, 0, "critical token accounting");
        assertEq(backing, 0, "critical backing");
        assertEq(borrowAccounting, 0, "critical borrow accounting");
        assertEq(optimizerCritical, 0, "critical optimizer");
        assertEq(optimizerReadFailure, 0, "optimizer could not verify");
    }

    function test_currentProtocolReaderCanVerifyAdvisories() public view {
        uint256 gasBefore = gasleft();
        (
            uint256 oracleZero,
            uint256 oracleDegraded,
            uint256 collateralOrCap,
            uint256 protocolReadFailure
        ) = reader.protocolAdvisorySignals(CENTRAL_REGISTRY);
        console2.log("protocolAdvisorySignals gas", gasBefore - gasleft());
        uint256 optimizerWarning =
            reader.optimizerWarningSignal(HIGH_YIELD_AUSD_OPTIMIZER);
        (, uint256 optimizerReadFailure) =
            reader.optimizerCriticalSignals(HIGH_YIELD_AUSD_OPTIMIZER);
        console2.log("oracle zero", oracleZero);
        console2.log("oracle degraded", oracleDegraded);
        console2.log("collateral or cap", collateralOrCap);
        console2.log("optimizer warning", optimizerWarning);

        assertEq(protocolReadFailure, 0, "protocol reader could not verify");
        assertEq(optimizerReadFailure, 0, "optimizer reader could not verify");
    }
}
