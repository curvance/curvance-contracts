// // SPDX-License-Identifier: UNLICENSED
// pragma solidity ^0.8.19;

// import { SimplePositionManager } from "contracts/market/position-management/SimplePositionManager.sol";
// import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";
// import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
// import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

// contract TestAddRemovePositionManager is TestBaseMarketIsolated {
//     address public owner;
//     address public user;

//     SimplePositionManager public positionManager;

//     receive() external payable {}

//     fallback() external payable {}

//     function setUp() public override {
//         super.setUp();

//         owner = address(this);
//         user = user1;

//         centralRegistry.setExternalCalldataChecker(
//             _UNISWAP_V2_ROUTER,
//             address(new MockCalldataChecker(_UNISWAP_V2_ROUTER))
//         );

//         // Setup borrowable cDAI.
//         {
//             _deployBorrowableCDAI();
//             // Add cToken support on Oracle Manager.
//             oracleManager.addCTokenSupport(address(borrowableCDAI));
//             _prepareDAI(owner, 200000e18);
//             dai.approve(address(borrowableCDAI), 200000e18);
//         }

//         // deploy simple cToken
//         {
//             _deployBorrowableCUSDC();
//             oracleManager.addCTokenSupport(address(borrowableCUSDC));
//             _prepareUSDC(owner, 100e6);
//             usdc.approve(address(borrowableCUSDC), 100e6);

//         }

//         positionManager = new SimplePositionManager(
//             ICentralRegistry(address(centralRegistry)),
//             address(marketManagerIsolated),
//             _WETH_ADDRESS
//         );

//         marketManagerIsolated.listTokens(address(borrowableCUSDC), address(borrowableCDAI));

//         marketManagerIsolated.updatePositionToken(
//             7000,    // collRatio 70%
//             4000,    // collReqSoft 40%
//             3000,    // collReqHard 25%
//             1000,    // liqIncBase 10%
//             1500,    // liqIncHard 15%
//             500,     // liqIncMin 5%
//             2000,    // liqIncMax 20%
//             2000,    // minEffectiveCFactor 20%
//             5000,    // maxEffectiveCFactor 50%
//             1000     // baseCFactor 20%
//         );

//         address[] memory cTokens = new address[](1);
//         cTokens[0] = address(borrowableCUSDC);
//         uint256[] memory caps = new uint256[](1);
//         caps[0] = 100 ether;
//         marketManagerIsolated.setCollateralCaps(cTokens, caps);

//     }


//     function testAddPositionManager_Unauthorized() public {
//         address unauthorizedAddress = makeAddr("unauthorizedAddress");
//         vm.expectRevert(bytes4(keccak256("MarketManager__Unauthorized()")));
//         marketManagerIsolated.addPositionManager(unauthorizedAddress);

//     }

//     function testAddPositionManager_AlreadyAdded() public {
//         marketManagerIsolated.addPositionManager(address(positionManager));
//         vm.expectRevert(bytes4(keccak256("MarketManager__InvalidParameter()")));
//         marketManagerIsolated.addPositionManager(address(positionManager));
//     }

//     function testRemovePositionManager_Unauthorized() public {
//         address unauthorizedAddress = makeAddr("unauthorizedAddress");
//         vm.expectRevert(bytes4(keccak256("MarketManager__Unauthorized()")));
//         marketManagerIsolated.removePositionManager(unauthorizedAddress);
//     }
    
//     function testRemovePositionManager_NotAdded() public {
//         vm.expectRevert(bytes4(keccak256("MarketManager__InvalidParameter()")));
//         marketManagerIsolated.removePositionManager(address(positionManager));
//     }

//     function testAddPositionManager_InvalidInterface() public {
//         address invalidAddress = makeAddr("invalidAddress");
//         vm.expectRevert(bytes4(keccak256("MarketManager__InvalidParameter()")));
//         marketManagerIsolated.addPositionManager(invalidAddress);
//     }

//     function testAddAndRemovePositionManager_Success() public {
//         marketManagerIsolated.addPositionManager(address(positionManager));
//         assertEq(marketManagerIsolated.isPositionManager(address(positionManager)), true);
//         marketManagerIsolated.removePositionManager(address(positionManager));
//         assertEq(marketManagerIsolated.isPositionManager(address(positionManager)), false);
//     }




// }
