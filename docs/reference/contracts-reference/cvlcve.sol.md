# CvlCVE.sol

### Intro

We want to offer the user to earn yield from staking CVE in `CveLocker.sol` while at the same time using it as collateral. We will facilitate this by introducing a wrapper that tokenizes deposits into `CveLocker.sol`.&#x20;

### Implementation details

With this implementation approach we want to front run other protocols offering CVE specific wrappers to earn yield by staking CVE.

To offer the user staking his CVE and also using it as collateral in fuse, we will base `CvlCVE.sol` on the Curve gauge wrapper and Convex cvxCRV staking wrapper implementations.

See:

{% embed url="https://github.com/curvefi/curve-dao-contracts/tree/master/contracts/gauges/wrappers" %}
Written in Vyper, the original implementation
{% endembed %}

{% embed url="https://github.com/convex-eth/platform/blob/main/contracts/contracts/wrappers/CvxCrvStakingWrapper.sol" %}
An implementation in Solidity, based on the Curve wrappers
{% endembed %}

#### Steps

* User deposits CVE into `CvlCVE.col`
* `CvlCVE.sol` stakes the CVE into `CveLocker.sol` indefinitely (contract address has special rights in the locker contract)
* User receives cvlCVE into his wallet (1 CVE == 1 cvlCVE)
* `CvlCVE.sol` claims staking rewards from `CveLocker.sol`&#x20;
  * possibly via usage of a Keeper
* User manually claims staking rewards from `CvlCVE.sol`
  * will either be a basket of tokens or CVE, **to be discussed**
* User can stake his cvlCVE into vlCVE to open a staking position with individual voting rights, 12 months lockup
  * in the transaction `CveLocker.sol` redeems cvlCVE for CVE from `CvlCVE.sol`, to facilitate this it withdraws CVE from `CveLocker.sol`, the CVE then gets re-staked into `CveLocker.sol` in the name of the user's address
    * since the total amount of cvlCVE is always matched by CVE in `CvlCVE.sol`'s staking position, the user will always be able to stake cvlCVE
  * the redeemed cvlCVE gets burned&#x20;

![Flow chart representation of the interactions/steps and attributes](../../.gitbook/assets/image.png)

### Usage as collateral

Regarding the usage as collateral, this leads to the following:&#x20;

* there will be a Curve pool to maintain the peg 1 CVE === 1 cvlCVE and to allow swapping cvlCVE for CVE
* there will be a Curvance pool that accepts cvlCVE as collateral&#x20;
* If user gets liquidated, the liquidator seizes the collateral (cvlCVE) and can either&#x20;
  * swap it for CVE in our Curve pool (or any other asset on the secondary market)
  * keep the cvlCVE and continue to claim rewards
  * stake his cvlCVE into a vlCVE position with individual voting rights and 12 months lockup
* If the user does not get liquidated he can withdraw his collateral as usual
