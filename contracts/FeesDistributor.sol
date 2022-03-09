//SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface CErc20 {
    function totalAdminFees() external view returns (uint256);

    function _withdrawAdminFees(uint256 withdrawAmount) external returns (uint256);

    function underlying() external view returns (address);
}

interface IComptroller {
    function getAllMarkets() external view returns (CErc20[] memory);
}

interface IVotingEscrow {
    struct Reward {
        uint40 periodFinish;
        uint216 rewardRate;
        uint40 lastUpdateTime;
        uint216 rewardPerTokenStored;
    }

    function notifyRewardAmount(address rewardsToken, uint256 reward) external;

    function rewardData(address token) external returns (Reward memory);
}

contract FeesDistributor is Ownable {
    using SafeERC20 for IERC20;

    uint32 public lastHarvestedTime;
    address public operator; // keeper
    uint32 public harvestInterval = 86400 * 7;
    address public immutable ve; // voting escrow

    address[] public pools;
    address[] public underlyingTokens;

    mapping(address => bool) public poolExists;
    mapping(address => bool) public underlyingExists;
    mapping(address => uint256) public feesHarvested; // CErc20 => amount
    mapping(address => uint256) public feesRemaining; // underlying => amount

    event PoolAdded(address pool);
    event PoolRemoved(address pool);
    event NewOperator(address operator);
    event NewHarvestInterval(uint256 interval);
    event FeesHarvested(address pool, address market, uint256 amount);
    event FeesDistributed(address target, address token, uint256 amount);
    event RecoveredToken(address token, address from, address to, uint256 amount);

    constructor(address _operator, address _ve) {
        operator = _operator;
        ve = _ve;
    }

    /**
     * @dev set operator
     * @param _operator operator to set
     */
    function setOperator(address _operator) external onlyOwner {
        require(operator != _operator, "same operator");
        require(_operator != address(0), "address zero");
        operator = _operator;

        emit NewOperator(_operator);
    }

    /**
     * @dev add new pool
     * @param _pool pool to add
     */
    function addPool(address _pool) external onlyOwner {
        require(_pool != address(0), "invalid pool");
        require(!poolExists[_pool], "pool already exists");
        poolExists[_pool] = true;
        pools.push(_pool);

        emit PoolAdded(_pool);
    }

    /**
     * @dev remove pool
     * @param _pool pool to be removed
     */
    function removePool(address _pool) external onlyOwner {
        require(poolExists[_pool], "pool does not exist");
        for (uint256 i = 0; i < pools.length; i++) {
            if (_pool == pools[i]) {
                delete pools[i];
                poolExists[_pool] = false;

                emit PoolRemoved(_pool);
            }
        }
    }

    /**
     * @dev set harvest interval
     * @param _interval new interval
     */
    function setHarvestInterval(uint32 _interval) external onlyOwner {
        require(_interval > 0, "invalid interval");
        harvestInterval = _interval;

        emit NewHarvestInterval(_interval);
    }

    /**
     * @dev recover token
     * @param _token token to recover
     * @param _to recipient
     * @param _amount amount to recover. 0 means contract balance
     */
    function recoverToken(
        address _token,
        address _to,
        uint256 _amount
    ) external onlyOwner {
        require(_to != address(0), "invalid recipient");
        require(!underlyingExists[_token], "cannot withdraw harvested token");
        if (_amount > 0) IERC20(_token).safeTransfer(_to, _amount);
        else IERC20(_token).safeTransfer(_to, IERC20(_token).balanceOf(address(this)));

        emit RecoveredToken(_token, msg.sender, _to, _amount);
    }

    /**
     * @dev harvest admin fees
     * @param _distribute whether to distribute harvested tokens to vested escrow
     */
    function harvestAdminFees(bool _distribute) external onlyOperator {
        require(block.timestamp >= lastHarvestedTime + harvestInterval, "not time to harvest");
        CErc20[] memory markets;
        uint256 fees;
        uint256 errorCode;
        for (uint256 i = 0; i < pools.length; i++) {
            markets = IComptroller(pools[i]).getAllMarkets();
            for (uint256 j = 0; j < markets.length; j++) {
                address underlying = markets[j].underlying();
                if (!underlyingExists[underlying]) {
                    underlyingExists[underlying] = true;
                    underlyingTokens.push(underlying);
                }
                fees = markets[j].totalAdminFees();
                if (fees > 0) {
                    errorCode = markets[j]._withdrawAdminFees(fees);
                    require(errorCode == 0, "withdraw admin fees failed");

                    feesHarvested[address(markets[j])] += fees;
                    if (_distribute) {
                        _notifyRewardsAmount(underlying, fees);
                    } else {
                        feesRemaining[underlying] += fees;
                    }

                    emit FeesHarvested(pools[i], address(markets[j]), fees);
                }
            }
        }
        lastHarvestedTime = uint32(block.timestamp);
    }

    /**
     * @dev distribute all harvested tokens to voting escrow
     */
    function distributeAll() external onlyOperator {
        address underlying;
        for (uint256 i = 0; i < underlyingTokens.length; i++) {
            underlying = underlyingTokens[i];
            if (feesRemaining[underlying] > 0) {
                distribute(underlying);
            }
        }
    }

    /**
     * @dev distribute already harvested token to voting escrow
     * @param _token token to be distributed
     */
    function distribute(address _token) public onlyOperator {
        require(feesRemaining[_token] > 0, "nothing to distribute");
        uint256 amount = feesRemaining[_token];
        feesRemaining[_token] = 0;
        _notifyRewardsAmount(_token, amount);
    }

    /**
     * @dev notify voting escrow about new rewards
     * @param _token token
     * @param _amount amount of tokens
     */
    function _notifyRewardsAmount(address _token, uint256 _amount) internal {
        IERC20(_token).safeIncreaseAllowance(ve, _amount);
        require(IVotingEscrow(ve).rewardData(_token).lastUpdateTime > 0, "token not a reward on ve");
        IVotingEscrow(ve).notifyRewardAmount(_token, _amount);

        emit FeesDistributed(ve, _token, _amount);
    }

    ///////////////////////////////////
    ///// Modifiers ///////////////////
    ///////////////////////////////////

    modifier onlyOperator() {
        require(msg.sender == operator, "not authorized");
        _;
    }
}
