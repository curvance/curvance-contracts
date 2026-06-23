// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { DeployScript } from "../../utils/DeployScript.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";

contract AddCTokenSupport is DeployScript {
    function run(address oracleManager, address[] calldata cTokens) external recordEvents {
        OracleManager manager = OracleManager(oracleManager);

        for (uint256 i; i < cTokens.length; ++i) {
            manager.addCTokenSupport(cTokens[i]);
        }
    }
}
