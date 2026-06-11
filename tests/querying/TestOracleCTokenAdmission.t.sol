// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {ICToken} from "contracts/interfaces/ICToken.sol";
import {IOracleManager} from "contracts/interfaces/IOracleManager.sol";
import {MarketManagerIsolated} from "contracts/market/isolated/MarketManagerIsolated.sol";

contract TestOracleCTokenAdmission is Test {
    address internal constant ORACLE_MANAGER_TO_TEST = 0x32faD39e79FAc67f80d1C86CbD1598043e52CDb6;
    address internal constant MARKET_MANAGER_TO_TEST = 0xBc4cd7bbd8d38027A88838B88BA04561FA778C35;
    address internal constant CTOKEN_TO_TEST = 0xdB3e888c3b50771821226d30Ab6eC14eB5ba85bA;

    function test_validate_live_cTokenOracleAdmission() public {
        string memory rpcUrl = vm.envOr("MON_NODE_URI_MONAD_MAINNET", string(""));
        if (bytes(rpcUrl).length == 0) {
            vm.skip(true);
        }

        try vm.createSelectFork(rpcUrl) {
            // Fork selected.
        } catch {
            vm.skip(true);
        }

        IOracleManager liveOracleManager = IOracleManager(ORACLE_MANAGER_TO_TEST);
        ICToken cToken = ICToken(CTOKEN_TO_TEST);
        MarketManagerIsolated liveMarketManager = MarketManagerIsolated(MARKET_MANAGER_TO_TEST);

        address underlying = cToken.asset();

        assertTrue(underlying != address(0), "ctoken underlying is zero");
        assertEq(address(cToken.marketManager()), MARKET_MANAGER_TO_TEST, "market manager mismatch");
        assertTrue(liveMarketManager.isListed(CTOKEN_TO_TEST), "ctoken not listed in market manager");
        assertTrue(cToken.isBorrowable(), "ctoken should be borrowable");
        assertEq(liveOracleManager.cTokens(CTOKEN_TO_TEST), underlying, "oracle ctoken underlying mismatch");
        assertTrue(liveOracleManager.isSupportedAsset(underlying), "underlying oracle support missing");
        assertTrue(liveOracleManager.isSupportedAsset(CTOKEN_TO_TEST), "ctoken oracle support missing");

        (uint256 underlyingPrice, uint256 underlyingError) = liveOracleManager.getPrice(underlying, true, true);
        assertTrue(underlyingPrice > 0, "underlying price is zero");
        assertTrue(underlyingError < 2, "underlying price bad source");

        (uint256 cTokenPrice, uint256 cTokenError) = liveOracleManager.getPrice(CTOKEN_TO_TEST, true, true);
        assertTrue(cTokenPrice > 0, "ctoken price is zero");
        assertTrue(cTokenError < 2, "ctoken price bad source");
    }
}
