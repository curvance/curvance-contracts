pragma solidity 0.8.26;
import { StatefulBaseMarket } from "tests/fuzzing/StatefulBaseMarket.sol";
import { EToken } from "contracts/market/token/EToken.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

contract FuzzETokenSystem is StatefulBaseMarket {
    /// @custom:property s-dtok-1 marketUnderlyingHeld() must always be equal to the underlying token balance of the eToken contract
    /// @custom:precondition eToken is one of the supported assets
    function marketUnderlyingHeld_equivalent_to_balanceOf_underlying(
        address eToken
    ) public {
        _isSupportedEToken(eToken);

        uint256 marketUnderlyingHeld = EToken(eToken).marketUnderlyingHeld();

        address underlying = EToken(eToken).underlying();
        uint256 underlyingBalance = IERC20(underlying).balanceOf(
            address(eToken)
        );

        assertEq(
            marketUnderlyingHeld,
            underlyingBalance,
            "S-DTOK-1 - marketUnderlyingHeld should return eToken.balanceOf(eToken)"
        );
    }

    /// @custom:property s-dtok-2 decimals for eToken must always be equal to the underlying's number of decimals
    /// @custom:precondition eToken is one of the supported assets
    function decimals_for_eToken_equivalent_to_underlying(
        address eToken
    ) public {
        _isSupportedEToken(eToken);
        address underlying = EToken(eToken).underlying();

        assertEq(
            EToken(eToken).decimals(),
            IERC20(underlying).decimals(),
            "S-DTOK-2 - decimals for eToken must be equivalent to underlying decimals"
        );
    }

    // @custom:property s-dtok-3 isPToken() should return false for eToken
    // @custom:precondition eToken is either eUSDC or eDAI
    function isPToken_returns_false(address eToken) public {
        _isSupportedEToken(eToken);
        assertWithMsg(
            !EToken(eToken).isPToken(),
            "S-DTOK-3 - isPToken() should return false"
        );
    }
}
