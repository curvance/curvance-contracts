// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "contracts/libraries/external/redstone/RedstoneConsumerNumericBase.sol";

/// @notice Modified from Redstone Team implementation
contract PrimaryProdDataServiceConsumerBase is RedstoneConsumerNumericBase {
  /// TYPES ///

  /// STORAGE ///

  mapping(address => uint256) internal _isAuthorisedSigner;

  /// CONSTRUCTOR ///

  constructor(address[] memory signers) {
    _storeAuthorisedSigners(signers);
  }

  /// PUBLIC FUNCTIONS ///

  function getDataServiceId() public view virtual override returns (string memory) {
    return "redstone-primary-prod";
  }

  function getUniqueSignersThreshold() public view virtual override returns (uint8) {
    return 3;
  }

  function getAuthorisedSignerIndex(
    address signerAddress
  ) public view virtual override returns (uint8) {
    uint256 index = _isAuthorisedSigner[signerAddress];

    /// Validate that `signerAddress` is authorised.
    if (index == 0) {
      revert SignerNotAuthorised(signerAddress);
    }

    // Return authorised signer index.
    return uint8(index);
  }

  /// INTERNAL FUNCTIONs TO OVERRIDE ///

  function _storeAuthorisedSigners(address[] memory signers) internal virtual {}

}