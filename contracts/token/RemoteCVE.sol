// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { CVEBase } from "contracts/token/CVEBase.sol";

/// @title RemoteCVE - Curvance Collective Token for Secondary Chains
/// @notice A simplified CVE token implementation for non-canonical chains in the Curvance ecosystem.
/// @dev This contract extends CVEBase to implement the CVE token on secondary chains with:
///      1. Cross-chain bridging capabilities inherited from CVEBase
///      2. Support for gauge emissions and lock boost functionality
///      3. Simplified implementation without token allocation or vesting mechanisms
///
///      Unlike the canonical CVE contract on the primary chain, RemoteCVE:
///      - Doesn't manage token allocations (DAO treasury, contributor vesting, etc.)
///      - Doesn't implement vesting schedules or allocation-based minting controls
///      - Primarily serves as a bridgeable representation of CVE on secondary chains
///      - Receives tokens only through cross-chain bridging from the canonical chain
///
///      RemoteCVE instances work in conjunction with the canonical CVE contract to 
///      enable a unified token economy across the entire Curvance multi-chain ecosystem.
///
contract CVE is CVEBase {
    /// CONSTRUCTOR ///

    constructor(ICentralRegistry cr) CVEBase(cr) {}
}
