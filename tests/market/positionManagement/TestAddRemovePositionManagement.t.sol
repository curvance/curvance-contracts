// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { PositionManagementSimple } from "contracts/market/position-management/PositionManagementSimple.sol";
import { SimplePToken } from "contracts/market/token/SimplePToken.sol";
import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IEToken } from "contracts/interfaces/IEToken.sol";
import { IPToken } from "contracts/interfaces/IPToken.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract TestAddRemovePositionManagement is TestBaseMarketIsolated {
    address public owner;
    address public user;

    PositionManagementSimple public positionManagement;

    receive() external payable {}

    fallback() external payable {}

    // this is to use address(this) as mock cToken address
    function tokenType() external pure returns (uint256) {
        return 1;
    }

    function setUp() public override {
        super.setUp();

        owner = address(this);
        user = user1;

        centralRegistry.setExternalCalldataChecker(
            _UNISWAP_V2_ROUTER,
            address(new MockCalldataChecker(_UNISWAP_V2_ROUTER))
        );

        // setup eDAI
        {
            _deployEDAI();
            // add MToken support on price router
            oracleManager.addMTokenSupport(address(eDAI));
            _prepareDAI(owner, 200000e18);
            dai.approve(address(eDAI), 200000e18);
        }

        // deploy simple pToken
        {
            _deployPUSDC();
            oracleManager.addMTokenSupport(address(pUSDC));
            _prepareUSDC(owner, 100e6);
            usdc.approve(address(pUSDC), 100e6);

        }

        positionManagement = new PositionManagementSimple(
            ICentralRegistry(address(centralRegistry)),
            address(marketManagerIsolated),
            _WETH_ADDRESS
        );

        marketManagerIsolated.listTokens(address(pUSDC), address(eDAI));

        marketManagerIsolated.updatePositionToken(
            7000,    // collRatio 70%
            4000,    // collReqSoft 40%
            3000,    // collReqHard 25%
            1000,    // liqIncBase 10%
            1500,    // liqIncHard 15%
            500,     // liqIncMin 5%
            2000,    // liqIncMax 20%
            2000,    // minEffectiveCFactor 20%
            5000,    // maxEffectiveCFactor 50%
            1000     // baseCFactor 20%
        );

        address[] memory mTokens = new address[](1);
        mTokens[0] = address(pUSDC);
        uint256[] memory caps = new uint256[](1);
        caps[0] = 100 ether;
        marketManagerIsolated.setCollateralCaps(mTokens, caps);

    }


    function testAddPositionManager_Unauthorized() public {
        address unauthorizedAddress = makeAddr("unauthorizedAddress");
        vm.expectRevert(bytes4(keccak256("MarketManager__Unauthorized()")));
        marketManagerIsolated.addPositionManager(unauthorizedAddress);

    }

    function testAddPositionManager_AlreadyAdded() public {
        marketManagerIsolated.addPositionManager(address(positionManagement));
        vm.expectRevert(bytes4(keccak256("MarketManager__InvalidParameter()")));
        marketManagerIsolated.addPositionManager(address(positionManagement));
    }

    function testRemovePositionManager_Unauthorized() public {
        address unauthorizedAddress = makeAddr("unauthorizedAddress");
        vm.expectRevert(bytes4(keccak256("MarketManager__Unauthorized()")));
        marketManagerIsolated.removePositionManager(unauthorizedAddress);
    }
    
    function testRemovePositionManager_NotAdded() public {
        vm.expectRevert(bytes4(keccak256("MarketManager__InvalidParameter()")));
        marketManagerIsolated.removePositionManager(address(positionManagement));
    }

    function testAddPositionManager_InvalidInterface() public {
        address invalidAddress = makeAddr("invalidAddress");
        vm.expectRevert(bytes4(keccak256("MarketManager__InvalidParameter()")));
        marketManagerIsolated.addPositionManager(invalidAddress);
    }

    function testAddAndRemovePositionManager_Success() public {
        marketManagerIsolated.addPositionManager(address(positionManagement));
        assertEq(marketManagerIsolated.positionManagers(address(positionManagement)), true);
        marketManagerIsolated.removePositionManager(address(positionManagement));
        assertEq(marketManagerIsolated.positionManagers(address(positionManagement)), false);
    }




}
