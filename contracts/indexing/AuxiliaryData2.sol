// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { LiquidityManagerIsolated } from "contracts/market/isolated/LiquidityManagerIsolated.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IVeCVE } from "contracts/interfaces/IVeCVE.sol";

contract AuxiliaryData2 {
    ICentralRegistry public immutable centralRegistry;

    struct StaticMarketAsset {
        address _address;
        string name;
        string symbol;
        uint8 decimals;
        uint256 totalSupply;
    }

    struct StaticMarketToken {
        address _address;
        StaticMarketAsset asset;
        uint256 collateralCap;
        LiquidityManagerIsolated.CurvanceToken config;
        uint256[2] adapters;
        uint256 totalSupply; // totalSupply - reserved
    }

    struct DynamicMarketToken {
        address _address;
        uint256 posted;
        uint256 sharePrice;
        uint256 tokenPrice;
        uint256 tvl;
        uint256 borrowRate;
        uint256 utilizationRate;
        uint256 supplyRate;
        uint256 predicted_supplyRate;
        uint256 liquidity;
    }

    struct DynamicMarketData {
        address _address;
        DynamicMarketToken[] tokens;
    }

    struct StaticMarketData {
        address _address;
        StaticMarketToken[] tokens;
    }

    struct UserMarketToken {
        address _address;
        bool hasPosition;
        uint256 tokenAmount;
        uint256 shareAmount;
        uint256 debt;
    }

    struct UserData {
        uint256[] locks;
        uint256[] cooldowns;
        mapping(address => UserMarketToken[]) marketTokens;
    }

    constructor(ICentralRegistry centralRegistry_) {
        centralRegistry = centralRegistry_;
    }

    function getAllDynamicState() public view {}

    function getStaticMarketData() public view {
        // address[] memory markets = centralRegistry.marketManagers();
    }

    function getDynamicMarketData() public view {
        // address[] memory markets = centralRegistry.marketManagers();
    }

    function getUserData(
        address account
    ) public view returns (UserData memory data) {
        // Load locks
        (data.locks, ) = IVeCVE(centralRegistry.veCVE()).queryUserLocks(
            account
        );

        return data;
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
}
