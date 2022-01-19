// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./interfaces/IVestedEscrowFactory.sol";

/// @title Vesting Escrow
/// @author Convex Finance, Curvance
/// @notice Vest CVkkkE with a set schedule
/// @dev Intended to be deployed many times for each vesting schedule via `VestedEscrowFactory`
contract VestedEscrow is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public token;
    address public factory;
    address public stakeContract;
    uint256 public startTime;
    uint256 public endTime;
    uint256 public totalTime;
    uint256 public initialLockedSupply;
    uint256 public unallocatedSupply;

    mapping(address => uint256) public initialLocked;
    mapping(address => uint256) public totalClaimed;

    address[] public extraRewards;

    event Fund(address indexed recipient, uint256 reward);
    event Claim(address indexed user, uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == IVestedEscrowFactory(factory).owner(), "!auth");
        _;
    }

    /// @notice Initialize the contract.
    /// @param _token Address of the ERC20 token being distributed
    /// @param _startTime Timestamp at which the distribution starts
    /// @param _endTime Timestamp at which everything should be vested
    /// @param _stakeContract Contract to stake in when `claimAndStake` is called
    constructor(
        address _token,
        uint256 _startTime,
        uint256 _endTime,
        address _stakeContract
    ) {
        require(_startTime >= block.timestamp, "start must be future");
        require(_endTime > _startTime, "end must be greater");

        token = IERC20(_token);
        startTime = _startTime;
        endTime = _endTime;
        totalTime = endTime - startTime;
        factory = msg.sender; // Will be `VestedEscrowFactory`
        stakeContract = _stakeContract;
    }

    /// @notice Transfer vestable tokens into the contract
    /// @dev Handled separate from `fund` to reduce transaction count when using funding admins
    /// @param _amount Number of tokens to transfer
    function addTokens(uint256 _amount) external onlyOwner returns (bool) {
        token.safeTransferFrom(msg.sender, address(this), _amount);
        unallocatedSupply += _amount;
        return true;
    }

    /// @notice Vest tokens for multiple recipients
    /// @param _recipients List of addresses to fund
    /// @param _amounts Amount of vested tokens for each address
    function fund(address[] calldata _recipients, uint256[] calldata _amounts)
        external
        onlyOwner
        nonReentrant
        returns (bool)
    {
        uint256 totalAmount = 0;
        for (uint256 i = 0; i < _recipients.length; i++) {
            uint256 amount = _amounts[i];
            initialLocked[_recipients[i]] += amount;
            totalAmount += amount;
            emit Fund(_recipients[i], amount);
        }

        initialLockedSupply += totalAmount;
        require(unallocatedSupply >= totalAmount, "total funding more than unallocated");
        unallocatedSupply -= totalAmount;
        return true;
    }

    /// @notice Get the number of tokens which have vested for a given address at a given time
    /// @param _recipient Address to check
    /// @param _time Timestamp at which to check
    function vestedOf(address _recipient, uint256 _time) public view returns (uint256) {
        if (_time < startTime) {
            return 0;
        }
        uint256 locked = initialLocked[_recipient];
        uint256 elapsed = _time - startTime;

        /// @dev Prevents the total vested amount of the recipient being greater than total allocated to them
        uint256 total = ((locked * elapsed) / totalTime) < locked ? ((locked * elapsed) / totalTime) : locked;
        return total;
    }

    /// @notice Get the number of tokens which have vested for a given address
    /// @param _recipient Address to check
    function vestedOf(address _recipient) public view returns (uint256) {
        return vestedOf(_recipient, block.timestamp);
    }

    /// @notice Get the total number of tokens which have vested, that are held by this contract
    function vestedSupply() public view returns (uint256) {
        uint256 _time = block.timestamp;
        if (_time < startTime) {
            return 0;
        }
        uint256 locked = initialLockedSupply;
        uint256 elapsed = _time - startTime;

        /// @dev Prevents the total vested amount being greater than total allocated supply
        uint256 total = ((locked * elapsed) / totalTime) < locked ? ((locked * elapsed) / totalTime) : locked;

        return total;
    }

    /// @notice Get the total number of tokens which are still locked (have not yet vested)
    function lockedSupply() external view returns (uint256) {
        uint256 totalVested = vestedSupply();
        return initialLockedSupply - totalVested;
    }

    /// @notice Get the number of unclaimed vested tokens for a given address
    /// @param _recipient Address to check
    function balanceOf(address _recipient) external view returns (uint256) {
        uint256 vested = vestedOf(_recipient);
        return vested - totalClaimed[_recipient];
    }

    /// @notice Get the number of locked tokens for a given address
    /// @param _recipient Address to check
    function lockedOf(address _recipient) external view returns (uint256) {
        uint256 vested = vestedOf(_recipient);
        return initialLocked[_recipient] - vested;
    }

    /// @notice Claim tokens which have vested
    /// @param _recipient Address to claim tokens for
    function claim(address _recipient) public nonReentrant {
        uint256 vested = vestedOf(_recipient);
        uint256 claimable = vested - totalClaimed[_recipient];
        require(claimable > 0, "nothing to claim");

        totalClaimed[_recipient] = totalClaimed[_recipient] + claimable;
        token.safeTransfer(_recipient, claimable);

        emit Claim(msg.sender, claimable);
    }

    /// @notice Claim tokens which have vested for caller's address
    function claim() external {
        claim(msg.sender);
    }

    /// @dev Change this to `claimAndLock` using `CveLocker.sol` when ready
    // function claimAndStake(address _recipient) internal nonReentrant {
    //     require(stakeContract != address(0), "no staking contract");
    //     require(cveRewardPool(stakeContract).stakingToken() == address(token), "stake token mismatch");

    //     uint256 vested = vestedOf(_recipient);
    //     uint256 claimable = vested.sub(totalClaimed[_recipient]);

    //     totalClaimed[_recipient] = totalClaimed[_recipient].add(claimable);

    //     token.safeApprove(stakeContract, 0);
    //     token.safeApprove(stakeContract, claimable);
    //     cveRewardPool(stakeContract).stakeFor(_recipient, claimable);

    //     emit Claim(_recipient, claimable);
    // }

    // function claimAndStake() external {
    //     claimAndStake(msg.sender);
    // }
}
