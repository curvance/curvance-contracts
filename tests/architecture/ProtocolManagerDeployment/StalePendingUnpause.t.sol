// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { ProtocolManagerDeployment } from "contracts/architecture/ProtocolManagerDeployment.sol";
import { TestProtocolManagerDeployment } from "tests/architecture/ProtocolManagerDeployment/TestProtocolManagerDeployment.t.sol";

contract TestProtocolManagerDeploymentStalePendingUnpause is
    TestProtocolManagerDeployment
{
    function test_unpauseMarket_stalePendingUnpauseCanClearLaterMintPause() public {
        _deployMarketViaManager();

        address marketAdmin = address(0xCAFE);
        centralRegistry.addMarketPermissions(marketAdmin);

        // Simulate a later risk response after deployment, before the
        // deployment owner has consumed its one-time unpause allowance.
        vm.startPrank(marketAdmin);
        marketManagerIsolated.setMintPaused(address(borrowableCWMON), true);
        marketManagerIsolated.setMintPaused(
            address(borrowableCUSDC_MONAD),
            true
        );
        vm.stopPrank();

        assertTrue(
            deploymentManager.pendingUnpause(address(marketManagerIsolated)),
            "deployment owner still has a stale unpause allowance"
        );

        deploymentManager.unpauseMarket(address(marketManagerIsolated));

        (bool mintPaused0, , ) = marketManagerIsolated.actionsPaused(
            address(borrowableCWMON)
        );
        (bool mintPaused1, , ) = marketManagerIsolated.actionsPaused(
            address(borrowableCUSDC_MONAD)
        );

        assertFalse(
            mintPaused0,
            "stale deployment allowance cleared token0 mint pause"
        );
        assertFalse(
            mintPaused1,
            "stale deployment allowance cleared token1 mint pause"
        );
        assertFalse(
            deploymentManager.pendingUnpause(address(marketManagerIsolated)),
            "stale allowance was consumed"
        );
    }

    function test_revokeUnpause_preservesLaterRiskMintPause() public {
        _deployMarketViaManager();

        address marketAdmin = address(0xCAFE);
        centralRegistry.addMarketPermissions(marketAdmin);

        vm.startPrank(marketAdmin);
        marketManagerIsolated.setMintPaused(address(borrowableCWMON), false);
        marketManagerIsolated.setMintPaused(
            address(borrowableCUSDC_MONAD),
            false
        );

        marketManagerIsolated.setMintPaused(address(borrowableCWMON), true);
        marketManagerIsolated.setMintPaused(
            address(borrowableCUSDC_MONAD),
            true
        );
        deploymentManager.revokeUnpause(address(marketManagerIsolated));
        vm.stopPrank();

        assertFalse(
            deploymentManager.pendingUnpause(address(marketManagerIsolated)),
            "stale deployment allowance should be revoked"
        );

        vm.expectRevert(
            ProtocolManagerDeployment
                .ProtocolManagerDeployment__NoPendingUnpause
                .selector
        );
        deploymentManager.unpauseMarket(address(marketManagerIsolated));

        (bool mintPaused0, , ) = marketManagerIsolated.actionsPaused(
            address(borrowableCWMON)
        );
        (bool mintPaused1, , ) = marketManagerIsolated.actionsPaused(
            address(borrowableCUSDC_MONAD)
        );

        assertTrue(mintPaused0, "token0 risk pause should remain");
        assertTrue(mintPaused1, "token1 risk pause should remain");
    }
}
