// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/console.sol";

import { RedstoneCoreAdaptor } from "contracts/oracles/adaptors/redstone/RedstoneCoreAdaptor.sol";
import { RedstoneAdaptorMulticallChecker } from "contracts/market/multicall-checker/RedstoneAdaptorMulticallChecker.sol";

import { CentralRegistry } from "contracts/architecture/CentralRegistry.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { DeployConfiguration } from "../utils/DeployConfiguration.sol";

contract RedstoneAdaptorDeployer is DeployConfiguration {
    address public redstoneAdaptor;

    function _deployRedstoneAdaptor(address centralRegistry) internal {
        require(centralRegistry != address(0), "Set the centralRegistry!");
        ICentralRegistry icr = ICentralRegistry(centralRegistry);
        CentralRegistry cr = CentralRegistry(centralRegistry);

        address[] memory redstoneSigners = new address[](4);
        redstoneSigners[0] = 0x8BB8F32Df04c8b654987DAaeD53D6B6091e3B774;
        redstoneSigners[1] = 0xdEB22f54738d54976C4c0fe5ce6d408E40d88499;
        redstoneSigners[2] = 0x51Ce04Be4b3E32572C4Ec9135221d0691Ba7d202;
        redstoneSigners[3] = 0xDD682daEC5A90dD295d14DA4b0bec9281017b5bE;
        RedstoneCoreAdaptor adaptor = new RedstoneCoreAdaptor(
            icr,
            redstoneSigners,
            3
        );

        redstoneAdaptor = address(adaptor);
        _saveDeployedContracts("redstoneAdaptor", address(adaptor));

        RedstoneAdaptorMulticallChecker multicallChecker = new RedstoneAdaptorMulticallChecker(
                address(icr)
            );
        _saveDeployedContracts(
            "multicallChecker",
            address(multicallChecker)
        );
        cr.setMulticallChecker(
            address(adaptor),
            address(multicallChecker)
        );
    }
}
