// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { ProtocolManagerMassPause } from "contracts/architecture/ProtocolManagerMassPause.sol";
import { IERC165 } from "contracts/interfaces/IERC165.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";
import { TestProtocolManagerMassPause } from "tests/architecture/ProtocolManagerMassPause/TestProtocolManagerMassPause.t.sol";

contract PathologicalMarketManager {
    uint256 internal immutable tokenCount;

    constructor(uint256 count) {
        tokenCount = count;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        if (interfaceId == 0xffffffff) {
            return false;
        }

        return interfaceId == type(IMarketManager).interfaceId ||
            interfaceId == type(IERC165).interfaceId;
    }

    function liquidationPaused() external pure returns (uint256) {
        return 1;
    }

    function redeemPaused() external pure returns (uint256) {
        return 1;
    }

    function transferPaused() external pure returns (uint256) {
        return 1;
    }

    function actionsPaused(address) external pure returns (bool, bool, bool) {
        return (false, false, false);
    }

    function queryTokensListed() external view returns (address[] memory tokens) {
        tokens = new address[](tokenCount);
        for (uint256 i; i < tokenCount; ++i) {
            tokens[i] = address(uint160(i + 1));
        }
    }

    function setLiquidationPaused(bool) external {}
    function setRedeemPaused(bool) external {}
    function setTransferPaused(bool) external {}
    function setMintPaused(address, bool) external {}
    function setCollateralizationPaused(address, bool) external {}
    function setBorrowPaused(address, bool) external {}
}

contract TestProtocolManagerMassPausePathologicalMarket is
    TestProtocolManagerMassPause
{
    function test_massPause_pathologicalExplicitMarketCanExhaustGasBeforeLaterMarket()
        public
    {
        PathologicalMarketManager pathological =
            new PathologicalMarketManager(20_000);

        address[] memory markets = new address[](2);
        markets[0] = address(pathological);
        markets[1] = address(marketManager2);

        (bool success,) = address(massPause).call{ gas: 2_000_000 }(
            abi.encodeCall(
                ProtocolManagerMassPause.pauseTokenLevelEntryActions,
                (markets)
            )
        );

        assertFalse(
            success,
            "pathological market should exhaust bounded emergency gas"
        );
        _assertM2TokenLevelEntryUnpaused();
    }

    function test_massPause_registeredPathologicalMarketIsGovernanceGated() public {
        PathologicalMarketManager pathological =
            new PathologicalMarketManager(20_000);

        vm.prank(address(0xBEEF));
        vm.expectRevert();
        centralRegistry.addMarketManager(address(pathological));

        centralRegistry.addMarketManager(address(pathological));
        assertTrue(centralRegistry.isMarketManager(address(pathological)));
    }
}
