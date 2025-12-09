// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { DeployScript } from "../utils/DeployScript.sol";
import { CombinedAggregator } from "contracts/oracles/adaptors/wrappedAggregators/CombinedAggregator.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { RedstoneClassicAdaptor } from "contracts/oracles/adaptors/redstone/RedstoneClassicAdaptor.sol";

// 1. deploy combined aggregator
// 2. remove ezETH from chainlink adaptor (also removes asset pricing adaptor from OracleManager)
// 3. add ezETH to redstone adaptor
// 4. add asset pricing adaptor to OracleManager (redstone adaptor)
// 5. sanity checks

// cTokens already supported by OracleManager

contract AddCombinedAggregator_EzETH is DeployScript {
    struct PriceGuard {
        bool enabled;
        bool inUSD;
        uint256 timestampSubtract;
        uint256 ips;
        uint256 basePrice;
        uint256 minPrice;
    }

    // ezETH token address
    address public constant EZETH = 0x2416092f143378750bb29b79eD961ab195CcEea5;
    // central registry address
    address public constant CENTRAL_REGISTRY = 0x1310f352f1389969Ece6741671c4B919523912fF;
    // ETH/USD REDSTONE feed
    address public constant PRIMARY_AGGREGATOR = 0x8D89d6c114193154f111D7C83299D285C9cC5BBC;
    // ezETH/ETH Chainlink feed
    address public constant SECONDARY_AGGREGATOR = 0xdA0Da3272575e3fed2Bd61Bc63DB776516e808F2;
    // heartbeat at combined aggregator level
    uint256 public constant SECONDARY_HEARTBEAT = 24 hours;
    // heartbeat at redstone adaptor level
    uint256 public constant ADAPTOR_HEARTBEAT = 24 hours;
    // ezETH/USD asset id
    string public constant ASSET_ID = "ezETH/USD";
    // price guard config
    PriceGuard public constant PRICE_GUARD_CONFIG = PriceGuard({
        enabled: true,
        inUSD: false, // not used
        timestampSubtract: 608400,
        ips: 951293759,
        basePrice: 1065671892017052691,
        minPrice: 1012388297416200056
    });
    // chainlink adaptor address
    address public constant CHAINLINK_ADAPTOR = 0xACfE3fCcae79445836E03c5359BB96bd352b9C00;
    // redstone adaptor address
    address public constant REDSTONE_CLASSIC_ADAPTOR = 0x0fA602b3e748438A3F1599206Ed6DC497ab3331E;
    // oracle manager address
    address public constant ORACLE_MANAGER = 0x32faD39e79FAc67f80d1C86CbD1598043e52CDb6;

    function run(
    ) external recordEvents {
        IERC20 token = IERC20(EZETH);

        // ====== Deploy and configure CombinedAggregator ======
        address agg = address(
            new CombinedAggregator(
                ICentralRegistry(address(CENTRAL_REGISTRY)),
                PRIMARY_AGGREGATOR,
                SECONDARY_AGGREGATOR,
                SECONDARY_HEARTBEAT,
                ASSET_ID
            )
        );
        emit ContractDeployed(agg, string.concat("CombinedAggregator-", token.symbol()));

        // Configure PriceGuard on CombinedAggregator
        if (PRICE_GUARD_CONFIG.enabled) {
            CombinedAggregator(agg).setGuardedPriceConfig(
                PRICE_GUARD_CONFIG.ips > 0 ? block.timestamp - PRICE_GUARD_CONFIG.timestampSubtract : 0,
                PRICE_GUARD_CONFIG.ips,
                PRICE_GUARD_CONFIG.basePrice,
                PRICE_GUARD_CONFIG.minPrice
            );
        }

        // ====== remove chainlink adaptor and add redstone adaptor ======

        // Start adaptor instance
        ChainlinkAdaptor chainlinkAdaptor = ChainlinkAdaptor(CHAINLINK_ADAPTOR);

        // remove asset from adaptor
        // also removes asset pricing adaptor from OracleManager (chainlink adaptor)
        chainlinkAdaptor.removeAsset(EZETH);

        OracleManager oracleManager = OracleManager(ORACLE_MANAGER);

        RedstoneClassicAdaptor redstoneAdaptor = RedstoneClassicAdaptor(REDSTONE_CLASSIC_ADAPTOR);
        
        // assetId should be fine because we convert to bytes32 both ways
        redstoneAdaptor.addAsset(EZETH, true, agg, ADAPTOR_HEARTBEAT, ASSET_ID);

        // add asset pricing adaptor to OracleManager (redstone adaptor)
        oracleManager.addAssetPricingAdaptor(EZETH, REDSTONE_CLASSIC_ADAPTOR, 250, 220, 250, 220);

        // ======= Sanity checks ======

        require(!chainlinkAdaptor.isSupportedAsset(EZETH), "Asset should not be supported by chainlink adaptor");
        require(redstoneAdaptor.isSupportedAsset(EZETH), "Asset should be supported by redstone adaptor");

        address[] memory adaptors = oracleManager.getPricingAdaptors(EZETH);
        require(adaptors.length == 1, "Adaptor should be only one");
        require(adaptors[0] == REDSTONE_CLASSIC_ADAPTOR, "Adaptor should be redstone");

    }
}
