// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

contract SetGenesisEpochTest is TestBaseMarket {
    event GenesisEpochSet(uint256 newGenesisEpoch);

    function setUp() public override {
        super.setUp();

        vm.warp(centralRegistry.genesisEpoch() - 1);
    }

    function test_setGenesisEpoch_fail_whenCallerIsNotAuthorized() public {
        uint256 newGenesisEpoch = centralRegistry.genesisEpoch() + 1;

        vm.prank(address(0));

        vm.expectRevert(
            CentralRegistry.CentralRegistry__Unauthorized.selector
        );
        centralRegistry.setGenesisEpoch(newGenesisEpoch);
    }

    function test_setGenesisEpoch_fail_whenEpochAlreadyStarted() public {
        uint256 newGenesisEpoch = centralRegistry.genesisEpoch() + 1;

        vm.warp(centralRegistry.genesisEpoch());

        vm.expectRevert(
            CentralRegistry.CentralRegistry__EpochHasStarted.selector
        );
        centralRegistry.setGenesisEpoch(newGenesisEpoch);
    }

    function test_setGenesisEpoch_fail_whenNewEpochIsPriorToCurrent() public {
        uint256 newGenesisEpoch = centralRegistry.genesisEpoch() - 1;

        vm.prank(address(0));

        vm.expectRevert(
            CentralRegistry.CentralRegistry__ParametersMisconfigured.selector
        );
        centralRegistry.setGenesisEpoch(newGenesisEpoch);
    }

    function test_setGenesisEpoch_success() public {
        uint256 newGenesisEpoch = centralRegistry.genesisEpoch() + 1;

        vm.expectEmit(true, true, true, true);
        emit GenesisEpochSet(newGenesisEpoch);

        centralRegistry.setGenesisEpoch(newGenesisEpoch);

        assertEq(centralRegistry.genesisEpoch(), newGenesisEpoch);
    }
}
