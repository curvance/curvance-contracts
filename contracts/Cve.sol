// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract CurvanceToken is ERC20 {
    address public operator;

    uint256 public maxSupply = 4_000_000 * 1e18; //100mil

    constructor() ERC20("Curvance Token", "CVE") {
        operator = msg.sender;
    }

    //get current operator off proxy incase there was a change
    function updateOperator(address _newOperator) public {
        require(msg.sender == operator, "!operator");
        operator = _newOperator;
    }

    function mint(address _to, uint256 _amount) external {
        require(totalSupply() + _amount <= maxSupply, "maxSupply reached");
        if (msg.sender != operator) {
            //dont error just return. if a shutdown happens, rewards on old system
            //can still be claimed, just wont mint cvx
            return;
        }
        _mint(_to, _amount);
    }
}
