// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { DIAAdaptor } from "contracts/oracles/adaptors/dia/DIAAdaptor.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { TestBaseOracleManager } from "../TestBaseOracleManager.sol";

contract TestDIAAdaptor is TestBaseOracleManager {
    address internal _DIA_ORACLE = 0xa93546947f3015c986695750b8bbEa8e26D65856;

    DIAAdaptor public adaptor;

    function setUp() public override {
        _fork(19422728);

        _deployDAOTimelock();
        _deployCentralRegistry();
        _deployOracleManager();

        adaptor = new DIAAdaptor(
            ICentralRegistry(address(centralRegistry)),
            _DIA_ORACLE
        );

        DIAAdaptor.AdaptorData memory data;
        data.isConfigured = true;
        data.decimals = 6;
        data.max = 1000000e18;
        data.min = 0;
        data.heartbeat = 24 hours;
        data.key = "BTC/USD";
        adaptor.addAsset(_WBTC_ADDRESS, data, true);

        oracleManager.addApprovedAdaptor(address(adaptor));
        oracleManager.addAssetPriceFeed(_WBTC_ADDRESS, address(adaptor));
    }

    function testReturnsCorrectPrice() public {
        (uint256 price, uint256 errorCode) = oracleManager.getPrice(
            _WBTC_ADDRESS,
            true,
            false
        );
        assertEq(errorCode, 0);
        assertGt(price, 0);
    }
}
