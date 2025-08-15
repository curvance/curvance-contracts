// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { IPositionManager } from "contracts/interfaces/IPositionManager.sol";
import { ERC165 } from "contracts/libraries/external/ERC165.sol";

// Mock Position Manager for testing.
contract MockPositionManager is IPositionManager, ERC165 {

    /// @inheritdoc IPositionManager
    function onBorrow(
        address borrowToken,
        uint256 borrowAmount,
        address owner,
        LeverageAction memory leverageAction
    ) external override {}

    /// @inheritdoc IPositionManager
    function onRedeem(
        address collateralToken,
        uint256 collateralAmount,
        address owner,
        DeleverageAction memory deleverageAction
    ) external override {
        // Implementation not required for the test
        // we would usually ensure:
        // 1. if the positionManager contract has >= deleverageAction.collateralAmount
        // 2. if the collateralToken is the same as deleverageAction.collateralToken
        // 3. if the collateralAmount argument is the same as deleverageAction.collateralAmount argument
        // 4. then take a protocol fee if necessary

        // We would then swap the collateral for the borrowToken,
        // repay the borrowToken.
        // and transfer any remaining borrowed tokens to the user
        // and transfer any remaining tokenOut tokens to the user
    }

    /// @inheritdoc ERC165
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return
            interfaceId == type(IPositionManager).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
