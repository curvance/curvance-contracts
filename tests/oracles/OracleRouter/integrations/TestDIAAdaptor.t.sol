// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import { DIAAdaptor } from "contracts/oracles/adaptors/dia/DIAAdaptor.sol";
import { OracleRouter } from "contracts/oracles/OracleRouter.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { TestBaseOracleRouter } from "../TestBaseOracleRouter.sol";

contract TestDIAAdaptor is TestBaseOracleRouter {
    address private WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    address private DIA_ORACLE = 0xa93546947f3015c986695750b8bbEa8e26D65856;

    DIAAdaptor public adaptor;

    function setUp() public override {
        _fork(19422728);

        _deployCentralRegistry();

        oracleRouter = new OracleRouter(
            ICentralRegistry(address(centralRegistry))
        );
        centralRegistry.setOracleRouter(address(oracleRouter));

        adaptor = new DIAAdaptor(
            ICentralRegistry(address(centralRegistry)),
            DIA_ORACLE
        );

        DIAAdaptor.AdaptorData memory data;
        data.isConfigured = true;
        data.decimals = 6;
        data.max = 1000000e18;
        data.min = 0;
        data.heartbeat = 24 hours;
        data.key = "BTC/USD";
        adaptor.addAsset(WBTC, data, true);

        oracleRouter.addApprovedAdaptor(address(adaptor));
        oracleRouter.addAssetPriceFeed(WBTC, address(adaptor));
    }

    function testReturnsCorrectPrice() public {
        (uint256 price, uint256 errorCode) = oracleRouter.getPrice(
            WBTC,
            true,
            false
        );
        assertEq(errorCode, 0);
        assertGt(price, 0);
    }
}
