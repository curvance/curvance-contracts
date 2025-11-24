// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { DeployScript } from "../utils/DeployScript.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract BulkUnpauseMarkets is DeployScript {
    function run(
        address[] memory markets
    ) external recordEvents {

        for(uint256 i; i < markets.length; i++) {
            MarketManagerIsolated market = MarketManagerIsolated(markets[i]);
            address cToken0 = market.tokensListed(0);
            address cToken1 = market.tokensListed(1);

            market.setMintPaused(cToken0, false);
            market.setMintPaused(cToken1, false);

            (bool mintPaused, bool collateralizationPaused, bool borrowPaused) = market.actionsPaused(cToken0);
            require(mintPaused == false, "cToken0 mint paused");
            require(collateralizationPaused == false, "cToken0 collateralization paused");
            require(borrowPaused == false, "cToken0 borrow paused");

            (mintPaused, collateralizationPaused, borrowPaused) = market.actionsPaused(cToken1);
            require(mintPaused == false, "cToken1 mint paused");
            require(collateralizationPaused == false, "cToken1 collateralization paused");
            require(borrowPaused == false, "cToken1 borrow paused");
        }
    }
}