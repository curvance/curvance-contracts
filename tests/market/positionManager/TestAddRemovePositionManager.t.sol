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

//         // Setup borrowable cUSDC.
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
//
//          _setCTokenConfigBasic(address(borrowableCUSDC), 100_000e18, 100_000e18);
//          _setCTokenConfigBasic(address(borrowableCDAI), 100_000e18, 100_000e18);

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
