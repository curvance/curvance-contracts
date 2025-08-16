// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { BaseCalldataChecker } from "contracts/calldata-checker/BaseCalldataChecker.sol";

import { BaseCalldataCheckerWrapper } from "./BaseCalldataCheckerWrapper.sol";
import { Test } from "forge-std/Test.sol";

contract TestBaseCalldataChecker is Test {
    BaseCalldataCheckerWrapper public checker;

    function setUp() public {
        checker = new BaseCalldataCheckerWrapper();
    }

    function test_slice_fail_SliceLengthTooLarge() public {
        bytes memory data = hex"69420a";

        // Exceeds _SLICE_OVERFLOW_LIMIT
        uint256 sliceLength = type(uint256).max - 30; 
        
        vm.expectRevert(BaseCalldataChecker.BaseCalldataChecker__OverflowError.selector);
        checker.slice(data, 0, sliceLength);
    }

    // This will fail due to the third conditional (data too short), but it passes the first check
    function test_slice_fail_SliceLengthExactlyAtLimit() public {
        bytes memory data = hex"69420a696969696969696969696969696969696969696969696969696969696969";

        uint256 sliceLength = type(uint256).max - 31;
        
        vm.expectRevert(BaseCalldataChecker.BaseCalldataChecker__OutOfBounds.selector);  
        checker.slice(data, 0, sliceLength);
    }

    // Trips second conditional because:
    // type(uint256).max - 10 > type(uint256).max - 20
    function test_slice_fail_StartPointPlusLengthOverflow() public {
        bytes memory data = hex"69420a";
        
        uint256 sliceStartPoint = type(uint256).max - 10;
        uint256 sliceLength = 20;
        
        vm.expectRevert(BaseCalldataChecker.BaseCalldataChecker__OverflowError.selector);
        checker.slice(data, sliceStartPoint, sliceLength);
    }

    // Trips second conditional when we are giving sliceStartPoint type(uint256).max
    // subtracting any non zero would cause an error
    function test_slice_fail_StartPointAtMaxValue() public {
        bytes memory data = hex"69420a";
        
        uint256 sliceStartPoint = type(uint256).max;

        // Any non-zero length will cause overflow
        uint256 sliceLength = 1; 
        
        vm.expectRevert(BaseCalldataChecker.BaseCalldataChecker__OverflowError.selector);
        checker.slice(data, sliceStartPoint, sliceLength);
    }

    function test_slice_fail_OutOfBounds_StartPointBeyondData() public {
        bytes memory data = hex"69420a"; // 3 bytes
        
        uint256 sliceStartPoint = 5;
        uint256 sliceLength = 1;
        
        vm.expectRevert(BaseCalldataChecker.BaseCalldataChecker__OutOfBounds.selector);
        checker.slice(data, sliceStartPoint, sliceLength);
    }

    function test_slice_success_ValidSlice() public view {
        bytes memory data = hex"69420a1234567890";
        
        uint256 sliceStartPoint = 2;
        uint256 sliceLength = 3;
        
        bytes memory result = checker.slice(data, sliceStartPoint, sliceLength);
        bytes memory expected = hex"0a1234";
        
        assertEq(result, expected);
    }


    
}