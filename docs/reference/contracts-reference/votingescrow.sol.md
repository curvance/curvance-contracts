# VotingEscrow.sol

### Abstract

To ensure that those who participate in governance for Curvance are aligned with the best interest of the protocol, we will give the option to users to lock up their CVE into a voting escrow in return for voting power and a share of platform fees and CVE emissions.

### Implementations

`lock(address _account, uint256 _amount)`

Locks `_amount` CVE into the locker and adds `_amount` of veCVE to `_account` 's locked balance and starts the 1 year unlock process.

`deposit(address _account, uint256 _amount)`

Locks `_amount` of CVE into the locker and adds `_amount` of veCVE to the team multisig's locked balance and mints `_amount` of veCVE to `_account` .

Does not start the 1 year unlock process until the user calls `unwrap` on `cveCVE.sol` to convert their cveCVE to veCVE.

`withdraw(address _to, uint256 _amount)`

Withdraws `_amount` of CVE to `_to`. Only callable by `owner` .

`claim(address _account)`

Claims pending reward for `_account`.

`claimAll(address _account)`

Claims all pending rewards for `_account`.

`updateReward(address _account)`

Updates pending reward info for `_account` .

Gets called whenever the following functions are called:

* `claim` and `claimAll`
* `lock`
* `deposit`
* `transfer` from `cveCVE.sol`

`addReward(address _rewardToken, address _distributor)`

Adds an ERC-20 reward to be distributed to stakers. Sets a `_distributor` address with permission to fund the locker with reward tokens to distribute.
