// // SPDX-License-Identifier: UNLICENSED
// pragma solidity ^0.8.19;

// import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
// import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";
// import { MarketManager } from "contracts/market/MarketManager.sol";
// import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

// contract CentralRegistrySetDurationsTest is TestBaseMarket {
//     MarketManager[] internal _marketManagers;

//     function setUp() public override {
//         super.setUp();

//         centralRegistry.removeMarketManager(address(marketManager));
//         centralRegistry.removeMarketManager(address(marketManagerIsolated));  // remove isolated market manager for this test

//         for (uint256 i = 0; i < 10; i++) {
//             _marketManagers.push(
//                 new MarketManager(ICentralRegistry(address(centralRegistry)))
//             );
//             centralRegistry.addMarketManager(
//                 address(_marketManagers[i]),
//                 marketInterestFactor
//             );
//         }
//     }

//     function test_centralRegistrySetRegularDuration_fail_whenCallerIsNotAuthorized()
//         public
//     {
//         vm.prank(address(1));

//         vm.expectRevert(
//             CentralRegistry.CentralRegistry__Unauthorized.selector
//         );
//         uint256 newDuration = 10;
//         centralRegistry.setRegularDuration(newDuration);
//     }

//     function test_centralRegistrySetRegularDuration_success() public {
//         for (uint256 i = 0; i < 10; i++) {
//             assertEq(_marketManagers[i].regularDuration(), 3);
//         }

//         uint256 newDuration = 10;
//         centralRegistry.setRegularDuration(newDuration);

//         for (uint256 i = 0; i < 10; i++) {
//             assertEq(_marketManagers[i].regularDuration(), newDuration);
//         }
//     }

//     function test_centralRegistrySetPriorityDuration_fail_whenCallerIsNotAuthorized()
//         public
//     {
//         vm.prank(address(1));

//         vm.expectRevert(
//             CentralRegistry.CentralRegistry__Unauthorized.selector
//         );
//         uint256 newDuration = 2;
//         centralRegistry.setPriorityDuration(newDuration);
//     }

//     function test_centralRegistrySetPriorityDuration_success() public {
//         for (uint256 i = 0; i < 10; i++) {
//             assertEq(_marketManagers[i].priorityDuration(), 1);
//         }

//         uint256 newDuration = 2;
//         centralRegistry.setPriorityDuration(newDuration);

//         for (uint256 i = 0; i < 10; i++) {
//             assertEq(_marketManagers[i].priorityDuration(), newDuration);
//         }
//     }

//     function test_centralRegistrySetEndDuration_fail_whenCallerIsNotAuthorized()
//         public
//     {
//         vm.prank(address(1));

//         vm.expectRevert(
//             CentralRegistry.CentralRegistry__Unauthorized.selector
//         );
//         uint256 newDuration = 60;
//         centralRegistry.setEndDuration(newDuration);
//     }

//     function test_centralRegistrySetEndDuration_success() public {
//         for (uint256 i = 0; i < 10; i++) {
//             assertEq(_marketManagers[i].endDuration(), 30);
//         }

//         uint256 newDuration = 60;
//         centralRegistry.setEndDuration(newDuration);

//         for (uint256 i = 0; i < 10; i++) {
//             assertEq(_marketManagers[i].endDuration(), newDuration);
//         }
//     }

//     /// @dev Test that setting a priority duration that is not less than the current regular duration reverts.
//     function test_setPriorityDuration_fail_whenNewValueNotLessThanRegular() public {
//         // Given the default regularDuration is 3,
//         // trying to set priorityDuration to 3 (or higher) should revert.
//         uint256 invalidPriority = 3;
//         vm.expectRevert("Priority duration must be less than regular duration");
//         centralRegistry.setPriorityDuration(invalidPriority);
//     }

//     /// @dev Test that setting regular duration fails if the new value is not greater than the current priority duration.
//     function test_setRegularDuration_fail_whenNewValueNotGreaterThanPriority() public {
//         // Given the default priorityDuration is 1,
//         // trying to set regularDuration to 1 (or less) should revert.
//         uint256 invalidRegular = 1;
//         vm.expectRevert("Regular duration must be greater than priority duration");
//         centralRegistry.setRegularDuration(invalidRegular);
//     }

//     /// @dev Test that setting regular duration fails if the new value is not less than the current end duration.
//     function test_setRegularDuration_fail_whenNewValueNotLessThanEnd() public {
//         // Given the default endDuration is 30,
//         // trying to set regularDuration to 30 (or greater) should revert.
//         uint256 invalidRegular = 30;
//         vm.expectRevert("Regular duration must be less than end duration");
//         centralRegistry.setRegularDuration(invalidRegular);
//     }

//     /// @dev Test that setting end duration fails if the new value is not greater than the current regular duration.
//     function test_setEndDuration_fail_whenNewValueNotGreaterThanRegular() public {
//         // Given the default regularDuration is 3,
//         // trying to set endDuration to 3 (or less) should revert.
//         uint256 invalidEnd = 3;
//         vm.expectRevert("End duration must be greater than regular duration");
//         centralRegistry.setEndDuration(invalidEnd);
//     }
// }