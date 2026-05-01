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

            // This script is only intended to clear the initial mint-only
            // pause set during market deployment. Preflight before mutating
            // so it cannot partially unpause a market in another pause state.
            require(market.liquidationPaused() == 1, "liquidation paused");
            require(market.redeemPaused() == 1, "redeem paused");
            require(market.transferPaused() == 1, "transfer paused");

            _checkInitialMintOnlyPause(market, cToken0, "cToken0");
            _checkInitialMintOnlyPause(market, cToken1, "cToken1");

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

    function _checkInitialMintOnlyPause(
        MarketManagerIsolated market,
        address cToken,
        string memory label
    ) internal view {
        (
            bool mintPaused,
            bool collateralizationPaused,
            bool borrowPaused
        ) = market.actionsPaused(cToken);

        require(mintPaused == true, string.concat(label, " mint not paused"));
        require(
            collateralizationPaused == false,
            string.concat(label, " collateralization paused")
        );
        require(borrowPaused == false, string.concat(label, " borrow paused"));
    }
}
