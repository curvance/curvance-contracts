// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { CVEBase } from "contracts/token/CVEBase.sol";

/// @notice Curvance DAO's Remote CVE Contract.
/// @dev Remote CVE contract is identical to CVE contract except it does not/
///      have token vesting functions.
contract CVE is CVEBase {
    /// CONSTRUCTOR ///

    constructor(ICentralRegistry centralRegistry_) CVEBase(centralRegistry_) {}
}
