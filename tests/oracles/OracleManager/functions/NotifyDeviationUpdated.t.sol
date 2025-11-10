// // SPDX-License-Identifier: GPL-3.0
// pragma solidity 0.8.28;

// import { TestBaseOracleManager } from "../TestBaseOracleManager.sol";
// import { OracleManager } from "contracts/oracles/OracleManager.sol";
// import { IOracleAdaptor } from "contracts/interfaces/IOracleAdaptor.sol";

// contract NotifyDeviationUpdatedTest is TestBaseOracleManager {
//     function setUp() public override {
//         super.setUp();

//         _addDualPriceFeed();
//     }

//     // Displays how the bounds are bumped when an adaptor loosens its threshold
//     function test_notifyDeviationUpdated_bumpsBounds_whenAdaptorLoosens() public {
//         // 180 bps bad, 130 bps caution
//         (uint16 badSourceBefore, uint16 cautionBefore) = oracleManager.assetPricingConfig(_USDC_ADDRESS);

//         // Looser threshold, 120 bps
//         uint256 newDeviationThreshold = 120;

//         // uint256 public constant DEFAULT_DEVIATION_DIFFERENCE = 50;
//         // uint256 public constant MIN_DEVIATION_BUFFER = 20;
//         vm.expectEmit(true, true, true, true, address(oracleManager));
//         emit OracleManager.AssetDeviationBoundsSet(
//             _USDC_ADDRESS,
//             uint16(10000 + (newDeviationThreshold + 20 + 50)),
//             uint16(10000 + (newDeviationThreshold + 20))
//         );

//         // Prank as approved adaptor and trigger notification.
//         vm.prank(address(dualChainlinkAdaptor));
//         oracleManager.notifyDeviationUpdated(_USDC_ADDRESS, newDeviationThreshold);

//         (uint16 badSourceAfter, uint16 cautionAfter) = oracleManager.assetPricingConfig(_USDC_ADDRESS);
//         assertEq(uint256(cautionAfter), 10000 + (newDeviationThreshold + 20));
//         assertEq(uint256(badSourceAfter), 10000 + (newDeviationThreshold + 20 + 50));
//     }

//     // If an adaptor tightens its threshold, but is not the loosest feed,
//     // notifyDeviationUpdated should not change the bounds.
//     function test_notifyDeviationUpdated_keepsBounds_whenAdaptorTightens() public {
//         // caution 130 bps, badSource 180 bps
//         (uint16 badSourceBefore, uint16 cautionBefore) = oracleManager.assetPricingConfig(_USDC_ADDRESS);

//         // Stricter threshold
//         uint256 newDeviationThreshold = 80;

//         // Prank as approved adaptor and trigger notification.
//         vm.prank(address(dualChainlinkAdaptor));
//         oracleManager.notifyDeviationUpdated(_USDC_ADDRESS, newDeviationThreshold);

//         // Bounds should be unchanged
//         (uint16 badSourceAfter, uint16 cautionAfter) = oracleManager.assetPricingConfig(_USDC_ADDRESS);
//         assertEq(badSourceAfter, badSourceBefore);
//         assertEq(cautionAfter, cautionBefore);
//     }


//     function test_notifyDeviationUpdated_fuzzed(uint256 newDeviationThreshold) public {

//         newDeviationThreshold = bound(newDeviationThreshold, 0, 400);
        
//         // caution 130 bps, badSource 180 bps
//         (uint16 badBefore, uint16 cautionBefore) = oracleManager.assetPricingConfig(_USDC_ADDRESS);

//         bool shouldBump;
//         bool shouldRevert;

//         // if newCautionBound + MIN_DEVIATION_BUFFER >= current cautionBound (130)
//         // newCautionBound + 20 >= 110
//         if (newDeviationThreshold >= 110) {
//             shouldBump = true;
//         }

//         // Will hit max bound of 300
//         // newDeviationThreshold + 20 + 50
//         if (newDeviationThreshold > 230) {
//             shouldRevert = true;
//         }

//         if (shouldRevert) {

//             vm.prank(address(dualChainlinkAdaptor));

//             vm.expectRevert(OracleManager.OracleManager__InvalidParameter.selector);
            
//             oracleManager.notifyDeviationUpdated(_USDC_ADDRESS, newDeviationThreshold);

//             return;

//         }

//         uint256 newMinCautionBound = newDeviationThreshold + 20;
//         uint256 newBadBound = newMinCautionBound + 50;
        
//         if (shouldBump) {
            
//             vm.prank(address(dualChainlinkAdaptor));
//             vm.expectEmit(true, true, true, true, address(oracleManager));
//             emit OracleManager.AssetDeviationBoundsSet(
//                 _USDC_ADDRESS,
//                 uint16(10000 + newBadBound),
//                 uint16(10000 + newMinCautionBound)
//             );

//             oracleManager.notifyDeviationUpdated(_USDC_ADDRESS, newDeviationThreshold);
//         }
//         else {

//             // No op path
//             vm.prank(address(dualChainlinkAdaptor));
//             oracleManager.notifyDeviationUpdated(_USDC_ADDRESS, newDeviationThreshold);
//         }

//         // If we expected a revert, we never reach here.
//         (uint16 badAfter, uint16 cautionAfter) = oracleManager.assetPricingConfig(_USDC_ADDRESS);

//         if (shouldBump) {
//             // Assert new bound state changes.
//             assertEq(uint256(cautionAfter), 10000 + newMinCautionBound);
//             assertEq(uint256(badAfter), 10000 + newBadBound);

//         } else {
//             // No bump, unchanged.
//             assertEq(badAfter, badBefore);
//             assertEq(cautionAfter, cautionBefore);
//         }
//     }

//     function test_notifyDeviationUpdated_fail_whenCallerNotApproved() public {

//         vm.expectRevert(OracleManager.OracleManager__AdaptorIsNotApproved.selector);

//         vm.prank(user1);

//         oracleManager.notifyDeviationUpdated(_USDC_ADDRESS, 120);
//     }

    
// }


