// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { IVault } from "contracts/interfaces/IVault.sol";

interface IUpshiftVault is IVault {
    /// @notice Requests redemption of shares for underlying assets.
    /// @dev For vaults with lagDuration == 0, this transfers funds immediately.
    /// @param shares The number of shares to redeem.
    /// @param receiverAddr The address that will receive the assets.
    /// @param holderAddr The address of the shares holder.
    /// @return assets The amount of underlying assets received.
    /// @return claimableEpoch The epoch when assets become claimable.
    function requestRedeem(
        uint256 shares,
        address receiverAddr,
        address holderAddr
    ) external returns (uint256 assets, uint256 claimableEpoch);
}
