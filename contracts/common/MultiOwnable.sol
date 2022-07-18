// SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

interface IMultiOwnable {
    function addOwner(address owner) external;
    function removeOwner(address owner) external;
    function owners(uint256 i) external view returns (address);
    function numOwners() external view returns (uint256);
}

contract MultiOwnable {
    mapping(address => bool) public _isOwner;
    address[] public owners;
    uint256 public numOwners;

    constructor() {
        _isOwner[msg.sender] = true;
        owners.push(msg.sender);
        numOwners++;
    }

    function isOwner(address who) public view returns (bool) {
        return _isOwner[who];
    }

    function allOwners() public view returns (address[] memory) {
        return owners;
    }

    function addOwner(address owner) public onlyOwners {
        _isOwner[owner] = true;
        owners.push(owner);
        numOwners++;
    }

    function removeOwner(address owner) public onlyOwners {
        delete _isOwner[owner];

        for (uint8 i = 0; i < owners.length; i++) {
            if (owners[i] == owner) {
                if (i == owners.length - 1) {
                    owners.pop();
                } else {
                    owners[i] = owners[owners.length - 1];
                    owners.pop();
                }
                return;
            }
        }
        numOwners--;
    }

    error NotOwner(address msgSender);

    modifier onlyOwners {
        if (!_isOwner[msg.sender]) {
            revert NotOwner(msg.sender);
        }
        _;
    }
}