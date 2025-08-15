// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";

contract Market {
    function supportsInterface(bytes4 interfaceId) public pure returns (bool) {
        if (interfaceId == 0xffffffff) {
            return false;
        }
        return true;
    }
}

contract SetProtocolInterestFeeTest is TestBaseMarketIsolated {
    address public newMarket;

    function setUp() public virtual override {
        super.setUp();
        newMarket = address(new Market());
    }

    function test_setProtocolInterestFee_fail_whenCallerIsNotAuthorized()
        public
    {
        vm.prank(address(0));

        vm.expectRevert(
            CentralRegistry.CentralRegistry__Unauthorized.selector
        );
        centralRegistry.setProtocolInterestFee(newMarket, 100);
    }

    function test_setProtocolInterestFee_fail_whenValueTooHigh() public {
        vm.expectRevert(
            CentralRegistry.CentralRegistry__InvalidParameter.selector
        );
        centralRegistry.setProtocolInterestFee(newMarket, 7501);
    }

    function test_setProtocolInterestFee_fail_whenNotLendingMarket()
        public
    {
        vm.expectRevert(
            CentralRegistry.CentralRegistry__InvalidParameter.selector
        );
        centralRegistry.setProtocolInterestFee(newMarket, 5000);

        centralRegistry.addMarketManager(newMarket, 5000);
        centralRegistry.setProtocolInterestFee(newMarket, 5000);
    }

    function test_setProtocolInterestFee_success() public {
        centralRegistry.addMarketManager(newMarket, 5000);
        centralRegistry.setProtocolInterestFee(newMarket, 5000);
        assertEq(centralRegistry.protocolInterestFee(newMarket), 5000);
    }
}
