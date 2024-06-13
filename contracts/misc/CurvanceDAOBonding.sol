// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";

contract CurvanceDAOBonding {
    /// TYPES ///

    /// @notice Stores DAO terms for allocation to
    ///         Curvance DAO.
    struct DaoTerms {
        bool hasBonded;
        uint256 bondAllocation;
        uint256 cveAllocation;
    }

    /// CONSTANTS ///

    /// @notice The address receiving DAO bonding proceeds on
    ///         Ethereum Mainnet.
    address public constant devShopAddress =
        address(0xc1EA2eADCD0c8a22ca3ed6d4004D21bF3037aCBA);
    /// @notice The token DAOs bond from into CVE position.
    address public constant bondToken =
        address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    /// @notice Exchange Ratio between bond token and CVE, assumes
    ///         USDC bond token with 6 decimals versus CVE 18 decimals.
    uint256 public constant bondToCVE = 135e9;

    /// STORAGE ///

    /// @notice DAO Address => DAOTerms
    mapping(address => DaoTerms) public daoParticipant;

    /// ERRORS ///

    error CurvanceDAOBonding__Unauthorized();
    error CurvanceDAOBonding__InvalidParameters();

    /// EVENTS ///

    event DAOBonded(
        address DAOParticipant,
        uint256 bondTokenAmount,
        uint256 cveAllocation
    );

    /// CONSTRUCTOR ///

    constructor() {
        /// Add Participants here
        _addDaoParticipant(
            address(0x9e2b6378ee8ad2A4A95Fe481d63CAba8FB0EBBF9),
            50000e6,
            37_037_037e16
        ); // Alchemix

        _addDaoParticipant(
            address(0xC47eC74A753acb09e4679979AfC428cdE0209639),
            50000e6,
            37_037_037e16
        ); // Spiral DAO
    }

    /// EXTERNAL FUNCTIONS ///

    function bond() external {
        DaoTerms memory terms = daoParticipant[msg.sender];
        if (terms.bondAllocation == 0 || terms.hasBonded) {
            revert CurvanceDAOBonding__InvalidParameters();
        }

        daoParticipant[msg.sender].hasBonded = true;

        // Transfer bonding token.
        SafeTransferLib.safeTransferFrom(
            bondToken,
            msg.sender,
            devShopAddress,
            terms.bondAllocation
        );

        emit DAOBonded(msg.sender, terms.bondAllocation, terms.cveAllocation);
    }

    function addDaoParticipant(
        address daoAddress,
        uint256 bondAllocation,
        uint256 cveAllocation
    ) external {
        if (msg.sender != devShopAddress) {
            revert CurvanceDAOBonding__Unauthorized();
        }

        _addDaoParticipant(daoAddress, bondAllocation, cveAllocation);
    }

    /// INTERNAL FUNCTIONS ///

    function _addDaoParticipant(
        address daoAddress,
        uint256 bondAllocation,
        uint256 cveAllocation
    ) internal {
        if (daoParticipant[daoAddress].bondAllocation > 0) {
            revert CurvanceDAOBonding__InvalidParameters();
        }

        if (bondAllocation == 0 || cveAllocation == 0) {
            revert CurvanceDAOBonding__InvalidParameters();
        }

        daoParticipant[daoAddress] = DaoTerms({
            hasBonded: false,
            bondAllocation: bondAllocation,
            cveAllocation: cveAllocation
        });
    }
}
