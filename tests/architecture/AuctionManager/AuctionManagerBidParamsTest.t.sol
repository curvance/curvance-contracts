// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {BaseTest} from "lib/atlas/test/base/BaseTest.t.sol";
import "../src/CurvanceDAppControl.sol";

contract AuctionManagerBidParamsTest is BaseTest {
    CurvanceDAppControlTestWrapper public dappControlWrapper;

    address public constant MOCK_CENTRAL_REGISTRY = address(0x1234);
    uint256 public constant OEV_SHARE_BUNDLER = 2000; // 20%
    uint256 public constant OEV_SHARE_FASTLANE = 1000; // 10%
    address public constant OEV_ALLOCATION_DESTINATION_FASTLANE = address(0x1);
    address public constant OEV_ALLOCATION_DESTINATION_PROTOCOL = address(0x2);

    function setUp() public override {
        super.setUp();

        dappControlWrapper = new CurvanceDAppControlTestWrapper(
            address(atlas),
            MOCK_CENTRAL_REGISTRY,
            OEV_SHARE_BUNDLER,
            OEV_SHARE_FASTLANE,
            OEV_ALLOCATION_DESTINATION_FASTLANE,
            OEV_ALLOCATION_DESTINATION_PROTOCOL
        );
    }

    function testGetBidParamsFromSolverOpData_malformed_reverts() public {
        // Test with data length less than 96 bytes
        bytes memory malformedData = new bytes(95);

        vm.expectRevert(CurvanceDAppControl.MalformedSolverOperation.selector);
        dappControlWrapper.getBidParamsFromSolverOpData(malformedData);
    }

    function testGetBidParamsFromSolverOpData_exactMinimumLength() public {
        // Test with exactly 96 bytes (minimum required)
        bytes memory minData = new bytes(96);

        uint256 expectedPenalty = 123456789;
        address expectedCollateral = address(0x1234567890123456789012345678901234567890);
        address expectedMarket = address(0x9876543210987654321098765432109876543210);

        assembly {
            let dataPtr := add(minData, 32)
            mstore(add(dataPtr, 0), expectedPenalty)
            mstore(add(dataPtr, 32), expectedCollateral)
            mstore(add(dataPtr, 64), expectedMarket)
        }

        (uint256 penalty, address collateral, address market) = dappControlWrapper.getBidParamsFromSolverOpData(minData);

        assertEq(penalty, expectedPenalty);
        assertEq(collateral, expectedCollateral);
        assertEq(market, expectedMarket);
    }

    function testGetBidParamsFromSolverOpData_withPrefixData() public {
        // Test with additional data before the bid parameters
        uint256 prefixLength = 128;
        bytes memory dataWithPrefix = new bytes(prefixLength + 96);

        // Fill prefix with random data
        for (uint256 i = 0; i < prefixLength; i++) {
            dataWithPrefix[i] = bytes1(uint8(i % 256));
        }

        uint256 expectedPenalty = 987654321;
        address expectedCollateral = address(0xABcdEFABcdEFabcdEfAbCdefabcdeFABcDEFabCD);
        address expectedMarket = address(0x1111222233334444555566667777888899990000);

        assembly {
            let dataPtr := add(dataWithPrefix, 32)
            let offset := add(dataPtr, prefixLength)
            mstore(offset, expectedPenalty)
            mstore(add(offset, 32), expectedCollateral)
            mstore(add(offset, 64), expectedMarket)
        }

        (uint256 penalty, address collateral, address market) =
            dappControlWrapper.getBidParamsFromSolverOpData(dataWithPrefix);

        assertEq(penalty, expectedPenalty);
        assertEq(collateral, expectedCollateral);
        assertEq(market, expectedMarket);
    }

    function testGetBidParamsFromSolverOpData_maxValues() public {
        // Test with maximum values
        bytes memory data = new bytes(96);

        uint256 expectedPenalty = type(uint256).max;
        address expectedCollateral = address(type(uint160).max);
        address expectedMarket = address(type(uint160).max);

        assembly {
            let dataPtr := add(data, 32)
            mstore(dataPtr, expectedPenalty)
            mstore(add(dataPtr, 32), expectedCollateral)
            mstore(add(dataPtr, 64), expectedMarket)
        }

        (uint256 penalty, address collateral, address market) = dappControlWrapper.getBidParamsFromSolverOpData(data);

        assertEq(penalty, expectedPenalty);
        assertEq(collateral, expectedCollateral);
        assertEq(market, expectedMarket);
    }

    function testGetBidParamsFromSolverOpData_zeroValues() public {
        // Test with zero values
        bytes memory data = new bytes(96);

        (uint256 penalty, address collateral, address market) = dappControlWrapper.getBidParamsFromSolverOpData(data);

        assertEq(penalty, 0);
        assertEq(collateral, address(0));
        assertEq(market, address(0));
    }

    function testGetBidParamsFromSolverOpData_largeDataArray() public {
        // Test with a very large data array
        uint256 largeSize = 1000; // Reduced size to avoid gas issues
        bytes memory largeData = new bytes(largeSize);

        uint256 expectedPenalty = 555666777;
        address expectedCollateral = address(0x1122334455667788990011223344556677889900);
        address expectedMarket = address(0x9988776655443322110099887766554433221100);

        assembly {
            let dataPtr := add(largeData, 32)
            let offset := add(dataPtr, sub(largeSize, 96))
            mstore(offset, expectedPenalty)
            mstore(add(offset, 32), expectedCollateral)
            mstore(add(offset, 64), expectedMarket)
        }

        (uint256 penalty, address collateral, address market) =
            dappControlWrapper.getBidParamsFromSolverOpData(largeData);

        assertEq(penalty, expectedPenalty);
        assertEq(collateral, expectedCollateral);
        assertEq(market, expectedMarket);
    }

    function testGetBidParamsFromSolverOpData_addressPacking() public {
        // Test that addresses are properly extracted
        bytes memory data = new bytes(96);

        uint256 expectedPenalty = 111111111;
        address expectedCollateral = address(0x123456789aBCdef0123456789AbCDEF012345678);
        address expectedMarket = address(0xfEdcBA9876543210FedCBa9876543210fEdCBa98);

        assembly {
            let dataPtr := add(data, 32)
            mstore(dataPtr, expectedPenalty)
            mstore(add(dataPtr, 32), expectedCollateral)
            mstore(add(dataPtr, 64), expectedMarket)
        }

        (uint256 penalty, address collateral, address market) = dappControlWrapper.getBidParamsFromSolverOpData(data);

        assertEq(penalty, expectedPenalty);
        assertEq(collateral, expectedCollateral);
        assertEq(market, expectedMarket);
    }

    function testGetBidParamsFromSolverOpData_boundaryLength96() public {
        _testBoundaryLength(96, 999888777);
    }

    function testGetBidParamsFromSolverOpData_boundaryLength97() public {
        _testBoundaryLength(97, 999888778);
    }

    function testGetBidParamsFromSolverOpData_boundaryLength128() public {
        _testBoundaryLength(128, 999888779);
    }

    function testGetBidParamsFromSolverOpData_boundaryLength256() public {
        _testBoundaryLength(256, 999888780);
    }

    function _testBoundaryLength(uint256 length, uint256 penalty) internal {
        bytes memory data = new bytes(length);
        address expectedCollateral = address(0xAAbbCCDdeEFf00112233445566778899aABBcCDd);
        address expectedMarket = address(0x1122334455667788990011223344556677889900);

        assembly {
            let dataPtr := add(data, 32)
            let offset := add(dataPtr, sub(mload(data), 96))
            mstore(offset, penalty)
            mstore(add(offset, 32), expectedCollateral)
            mstore(add(offset, 64), expectedMarket)
        }

        (uint256 actualPenalty, address actualCollateral, address actualMarket) =
            dappControlWrapper.getBidParamsFromSolverOpData(data);

        assertEq(actualPenalty, penalty);
        assertEq(actualCollateral, expectedCollateral);
        assertEq(actualMarket, expectedMarket);
    }

    function testGetBidParamsFromSolverOpData_realSolverOpFormat() public {
        // Create a mock solver for testing
        MockSolverForBidParams mockSolver = new MockSolverForBidParams();

        uint256 expectedPenalty = 0.1e18;
        address expectedCollateral = address(0xCCCCCCC);
        address expectedMarket = address(0xDDDDDDD);

        bytes memory realFormatData =
            abi.encodeWithSelector(mockSolver.solve.selector, expectedPenalty, expectedCollateral, expectedMarket);

        (uint256 penalty, address collateral, address market) =
            dappControlWrapper.getBidParamsFromSolverOpData(realFormatData);

        assertEq(penalty, expectedPenalty);
        assertEq(collateral, expectedCollateral);
        assertEq(market, expectedMarket);
    }

    function testGetBidParamsFromSolverOpData_fuzzTest(
        uint256 dataLength,
        uint256 penalty,
        address collateral,
        address market
    ) public {
        vm.assume(dataLength >= 96 && dataLength <= 1000);

        bytes memory data = new bytes(dataLength);

        assembly {
            let dataPtr := add(data, 32)
            let offset := add(dataPtr, sub(dataLength, 96))
            mstore(offset, penalty)
            mstore(add(offset, 32), collateral)
            mstore(add(offset, 64), market)
        }

        (uint256 actualPenalty, address actualCollateral, address actualMarket) =
            dappControlWrapper.getBidParamsFromSolverOpData(data);

        assertEq(actualPenalty, penalty);
        assertEq(actualCollateral, collateral);
        assertEq(actualMarket, market);
    }
}

// Mock solver contract for testing
contract MockSolverForBidParams {
    function solve(uint256 penalty, address collateral, address market) external pure {
        // Mock function - intentionally empty
    }
}

// Wrapper contract to expose internal function for testing
contract CurvanceDAppControlTestWrapper is CurvanceDAppControl {
    constructor(
        address atlas,
        address centralRegistry_,
        uint256 oevShareBundler_,
        uint256 oevShareFastlane_,
        address oevAllocationDestinationFastlane_,
        address oevAllocationDestinationProtocol_
    )
        CurvanceDAppControl(
            atlas,
            centralRegistry_,
            oevShareBundler_,
            oevShareFastlane_,
            oevAllocationDestinationFastlane_,
            oevAllocationDestinationProtocol_
        )
    {}

    function getBidParamsFromSolverOpData(bytes calldata solverOpData)
        external
        pure
        returns (uint256 penaltyBid, address collateralBid, address marketBid)
    {
        return _getBidParamsFromSolverOpData(solverOpData);
    }
}