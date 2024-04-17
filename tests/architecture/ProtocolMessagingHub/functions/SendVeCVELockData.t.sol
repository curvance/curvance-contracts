// // SPDX-License-Identifier: UNLICENSED
// pragma solidity 0.8.17;

// import { TestBaseProtocolMessagingHub } from "../TestBaseProtocolMessagingHub.sol";
// import { ProtocolMessagingHub } from "contracts/architecture/ProtocolMessagingHub.sol";
// import { ICVELocker } from "contracts/interfaces/ICVELocker.sol";

// contract SendVeCVELockDataTest is TestBaseProtocolMessagingHub {
//     function setUp() public override {
//         super.setUp();

//         centralRegistry.addChainSupport(
//             address(this),
//             address(protocolMessagingHub),
//             address(cve),
//             42161,
//             1,
//             1,
//             23
//         );
//     }

//     function test_sendVeCVELockData_fail_whenCallerIsNotAuthorized() public {
//         vm.expectRevert(
//             ProtocolMessagingHub.ProtocolMessagingHub__Unauthorized.selector
//         );
//         protocolMessagingHub.sendVeCVELockData(
//             42161,
//             address(protocolMessagingHub),
//             0
//         );
//     }

//     function test_sendVeCVELockData_fail_whenChainIsNotSupported() public {
//         centralRegistry.removeChainSupport(address(this), 42161);

//         vm.expectRevert(
//             ProtocolMessagingHub
//                 .ProtocolMessagingHub__InvalidParameter
//                 .selector
//         );

//         vm.prank(harvester);
//         protocolMessagingHub.sendVeCVELockData(
//             42161,
//             address(protocolMessagingHub),
//             0
//         );
//     }

//     function test_sendVeCVELockData_fail_whenAddressIsNotMessagingHub()
//         public
//     {
//         centralRegistry.removeChainSupport(address(this), 42161);
//         centralRegistry.addChainSupport(
//             address(this),
//             address(1),
//             address(cve),
//             42161,
//             1,
//             1,
//             23
//         );

//         vm.expectRevert(
//             abi.encodeWithSelector(
//                 ProtocolMessagingHub
//                     .ProtocolMessagingHub__Unauthorized
//                     .selector,
//                 address(1),
//                 address(protocolMessagingHub)
//             )
//         );

//         vm.prank(harvester);
//         protocolMessagingHub.sendVeCVELockData(
//             42161,
//             address(protocolMessagingHub),
//             0
//         );
//     }

//     function test_sendVeCVELockData_fail_whenHasNoEnoughNativeAssetForGas()
//         public
//     {
//         vm.expectRevert();

//         vm.prank(harvester);
//         protocolMessagingHub.sendVeCVELockData(
//             42161,
//             address(protocolMessagingHub),
//             0
//         );
//     }

//     function test_sendVeCVELockData_success() public {
//         uint256 messageFee = protocolMessagingHub.quoteWormholeFee(
//             42161,
//             false,
//             0
//         );
//         deal(address(protocolMessagingHub), messageFee);

//         uint256 nextEpoch = ICVELocker(centralRegistry.cveLocker())
//             .nextEpochToDeliver();
//         assertEq(
//             protocolMessagingHub.lockedTokenDataSent(42161, nextEpoch),
//             0
//         );

//         vm.prank(harvester);
//         protocolMessagingHub.sendVeCVELockData(
//             42161,
//             address(protocolMessagingHub),
//             0
//         );

//         assertEq(
//             protocolMessagingHub.lockedTokenDataSent(42161, nextEpoch),
//             2
//         );

//         vm.prank(harvester);
//         protocolMessagingHub.sendVeCVELockData(
//             42161,
//             address(protocolMessagingHub),
//             0
//         );
//     }
// }
