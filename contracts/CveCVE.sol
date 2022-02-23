//SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./BaseStaking.sol";

interface IBaseStaking {
    function stakeFor(address _account, uint256 _amount) external;

    function withdrawFor(
        address _account,
        uint256 _amount,
        bool _claim
    ) external;

    function preAndPostTransfer(address _account) external;

    function extraRewardsLength() external view returns (uint256);
}

contract CveCVE is ERC20 {
    using SafeERC20 for IERC20;

    BaseStaking public immutable staking;
    IERC20 public immutable cve;
    address public locker;

    uint256 private constant MAX_SUPPLY = 420000069 * 1e18;

    // emitted when a user unwraps cveCVE for CVE at 1:1 ratio
    event Unwrap(address indexed to, uint256 amount);
    event Deposited(address account, uint256 amount);

    constructor(
        IERC20 _cve,
        IERC20 _rewardToken,
        address _locker,
        address _operator,
        address _rewardManager
    ) ERC20("Curvance CVE", "cveCVE") {
        locker = _locker;
        cve = _cve;

        staking = new BaseStaking(_cve, _rewardToken, _operator, _rewardManager, _locker);
    }

    /**
     * @notice wrap cve for cveCVE
     * @param _amount amount of cve to wrap
     */
    function deposit(uint256 _amount) external {
        require(_amount > 0, "amount cannot be 0");
        require(totalSupply() + _amount <= MAX_SUPPLY, "max supply");

        // pull tokens
        cve.safeTransferFrom(msg.sender, address(this), _amount);

        // stake for user
        staking.stakeFor(msg.sender, _amount);

        // mint cveCVE
        _mint(msg.sender, _amount);

        emit Deposited(msg.sender, _amount);
    }

    /**
     * @notice wrap cve for cveCVE. providing a means for holders to unwrap and lock cve tokens automatically.
     * Otherwise tokens can be swapped in curve pool if locking is not wanted by user.
     * @param _amount amount of cve to wrap
     * @param _claim whether to claim rewards
     */
    function unwrap(uint256 _amount, bool _claim) external {
        require(_amount > 0, "amount cannot be 0");

        _burn(msg.sender, _amount);

        // withdraw to this contract
        staking.withdrawFor(msg.sender, _amount, _claim);

        // lock
        IVotingEscrow(locker).lockFor(msg.sender, _amount);

        emit Unwrap(msg.sender, _amount);
    }

    /**
     * @notice get (claim) rewards for an account
     * @param _account account for which rewards are claimed
     * @param _claimExtras whether to claim extra tokens if available
     */
    function getReward(address _account, bool _claimExtras) external {
        staking.getReward(_account, _claimExtras);
    }

    /**
     * @notice get balance of cveCVE holder
     * @param _account account in question
     */
    function getDepositedBalance(address _account) external view returns (uint256) {
        return balanceOf(_account);
    }

    /**
     * @notice get number of reward tokens
     */
    function rewardLength() external view returns (uint256) {
        return staking.extraRewardsLength();
    }

    /**
     * @notice get earned rewards of a user
     * @param _account user for whom to get earned rewards
     */
    function earned(address _account) external view returns (uint256) {
        return staking.earned(_account);
    }

    /**
     * @dev Hook that is called before any transfer of tokens. This includes
     * minting and burning.
     * @param _from address from which tokens are being transferred
     * @param _to address to which tokens are being transferred
     */
    function _beforeTokenTransfer(
        address _from,
        address _to,
        uint256
    ) internal override {
        if (_from != address(0)) {
            staking.preAndPostTransfer(_from);
        }
        if (_to != address(0)) {
            staking.preAndPostTransfer(_to);
        }
    }

    /////////////////////////////////////////////////////
    // MODIFIERS                                        /
    /////////////////////////////////////////////////////
}
