// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

contract VestingEscrow {

    address private _owner;
    uint private reentrant = 1;

    constructor() {
        _owner == _msgSender();
    }

    struct VestingSchedule {
        uint TermLength;
        uint ReleasePerEpoch;
        uint Epochs;
        uint Balance;
    }

    mapping(address => VestingSchedule) private ScheduleMaps;
    ScheduleMaps[] ScheduleGroups;
    mapping(string => ScheduleGroups) private IdentifyVestingSchedule;

    function checkBalance(address wallet) public view returns (uint) {
        return (ScheduleMaps[wallet].Balance);
    }

    function epochRelease(string group) private onlyOwner returns (bool) {
        return true;
    }

    function addVestingSchedule(address wallet, string group, uint groupNumber, uint TermLength, uint ReleasePerEpoch, uint Epochs, uint Balance) public onlyOwner {
        IdentifyVestingSchedule ivs = new IdentifyVestingSchedule;
        ivs = group[groupNumber[wallet[]]]

        IdentifyVestingSchedule.push(ScheduleGroups.push(ScheduleMaps.push(wallet, group, TermLength, ReleasePerEpoch, Epochs, Balance)));
    }

    function removeVestingSchedule(address wallet, string group) public onlyOwner {
        
    }








    function owner() public view virtual returns (address) {
        return _owner;
    }

    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    modifier onlyOwner() {
        require(owner() == _msgSender(), "Ownable: caller is not the owner");
        _;
    }

    modifier nonReentrant() {
        require(reentrant == 1, "reentry");
        reentrant = 2;
        _;
        reentrant = 1;
    }
}