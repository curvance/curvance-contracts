// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseOracleManager } from "../TestBaseOracleManager.sol";
import { ICToken } from "contracts/interfaces/ICToken.sol";
import { IERC165 } from "contracts/interfaces/IERC165.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";

contract AddCTokenSupportTest is TestBaseOracleManager {
    function setUp() public override {
        super.setUp();

        _deployBorrowableCUSDC();
    }

    function test_addCTokenSupport_fail_whenCallerIsNotAuthorized() public {
        vm.prank(address(1));

        vm.expectRevert(OracleManager.OracleManager__Unauthorized.selector);
        oracleManager.addCTokenSupport(address(borrowableCUSDC));
    }

    function test_addCTokenSupport_fail_whenCTokenIsAlreadyConfigured()
        public
    {
        oracleManager.addCTokenSupport(address(borrowableCUSDC));

        vm.expectRevert(
            OracleManager.OracleManager__InvalidParameter.selector
        );
        oracleManager.addCTokenSupport(address(borrowableCUSDC));
    }

    function test_addCTokenSupport_fail_whenCTokenIsInvalid() public {
        vm.expectRevert(OracleManager.OracleManager__InvalidParameter.selector);
        oracleManager.addCTokenSupport(address(1));
    }

    function test_addCTokenSupport_fail_whenShapeDoesNotSupportICToken() public {
        MockNonERC165CTokenShape fake = new MockNonERC165CTokenShape(
            _USDC_ADDRESS,
            address(marketManagerIsolated)
        );

        vm.expectRevert(OracleManager.OracleManager__InvalidParameter.selector);
        oracleManager.addCTokenSupport(address(fake));
    }

    function test_addCTokenSupport_fail_whenICTokenShapeUsesUnregisteredMarketManager() public {
        MockERC165CTokenLiar fake = new MockERC165CTokenLiar(
            _USDC_ADDRESS,
            makeAddr("unregisteredMarketManager")
        );

        vm.expectRevert(OracleManager.OracleManager__InvalidParameter.selector);
        oracleManager.addCTokenSupport(address(fake));
    }

    function test_addCTokenSupport_success_whenRegisteredMarketManagerTokenIsUnlisted() public {
        assertFalse(marketManagerIsolated.isListed(address(borrowableCUSDC)));

        address underlying = oracleManager.cTokens(address(borrowableCUSDC));
        assertEq(underlying, address(0));

        oracleManager.addCTokenSupport(address(borrowableCUSDC));

        underlying = oracleManager.cTokens(address(borrowableCUSDC));
        assertEq(underlying, _USDC_ADDRESS);

        _addSinglePriceFeed();

        assertTrue(oracleManager.isSupportedAsset(_USDC_ADDRESS));
    }

    function test_addCTokenSupport_success_whenCTokenIsCollateralOnly() public {
        _deploySimpleCUSDC();

        assertFalse(simpleCUSDC.isBorrowable());
        assertFalse(marketManagerIsolated.isListed(address(simpleCUSDC)));

        oracleManager.addCTokenSupport(address(simpleCUSDC));

        assertEq(oracleManager.cTokens(address(simpleCUSDC)), _USDC_ADDRESS);
    }
}

contract MockNonERC165CTokenShape {
    address public immutable asset;
    address public immutable marketManager;

    constructor(address asset_, address marketManager_) {
        asset = asset_;
        marketManager = marketManager_;
    }
}

contract MockERC165CTokenLiar is MockNonERC165CTokenShape {
    constructor(address asset_, address marketManager_)
        MockNonERC165CTokenShape(asset_, marketManager_)
    {}

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId ||
            interfaceId == type(ICToken).interfaceId;
    }
}
