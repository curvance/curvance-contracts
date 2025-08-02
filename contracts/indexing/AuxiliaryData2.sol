// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IVeCVE } from "contracts/interfaces/IVeCVE.sol";

contract AuxiliaryData2 {
    ICentralRegistry public immutable centralRegistry;

    struct UserData {
        uint256[] userLocks;
    }

    constructor(ICentralRegistry centralRegistry_) {
        centralRegistry = centralRegistry_;
    }

    function marketMultiCooldown(
        address[] calldata markets,
        address user
    ) public view returns (uint256[] memory) {
        uint256[] memory cooldowns = new uint256[](markets.length);
        for (uint256 i; i < markets.length; ++i) {
            IMarketManager mm = IMarketManager(markets[i]);
            uint256 cooldownTimestamp = mm.accountAssets(user);

            cooldowns[i] = cooldownTimestamp + mm.MIN_HOLD_PERIOD();
        }
        return cooldowns;
    }

    function getAllDynamicSate() public view {}

    function getStaticMarketData() public view {}

    function getDynamicMarketData() public view {}

    function getUserData(
        address account
    ) public view returns (UserData memory data) {
        // Load locks
        (data.userLocks, ) = IVeCVE(centralRegistry.veCVE()).queryUserLocks(
            account
        );

        return data;
    }
}
