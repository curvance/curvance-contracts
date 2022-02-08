# CvlCVEBOOST.sol



### Intro

This specification is work in progress and subject to change. We will not implement an auto-compounding vault at the current stage.

We want to offer the user to earn yield from staking cvlCVE in `CvlCVEBOOST.sol` to earn auto-compounding rewards.

### Steps

* User stakes cvlCVE in `CvlCVEBOOST.sol`
* User receives shares, share value grows over time

### Implementation details

With this implementation approach we want to front run other protocols offering an auto-compounding vault for cvlCVE.

We will fork the yearn vault for the auto-compounding and shares features they have.

See:

{% embed url="https://github.com/yearn/yearn-vaults/tree/main/contracts" %}

{% embed url="https://docs.yearn.finance/vaults/smart-contracts/vault" %}

The only strategy this vault will run is:&#x20;

* stake cvlCVE into `CvlCVEBOOST.sol`
* claim rewards from `cvlCVE.sol`
* convert them into CVE
* stake the CVE into `cvlCVE.sol` for cvlCVE and compound

**More details: to be defined.**
