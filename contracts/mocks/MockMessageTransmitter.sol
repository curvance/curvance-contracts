// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import { BurnMessage } from "contracts/libraries/external/BurnMessage.sol";
import { Message } from "contracts/libraries/external/Message.sol";
import { TypedMemView } from "contracts/libraries/external/TypedMemView.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";

contract MockMessageTransmitter {
    using TypedMemView for bytes;
    using TypedMemView for bytes29;
    using BurnMessage for bytes29;
    using Message for bytes29;

    bool internal _forceTransfer;
    address internal _burnToken;
    address internal _recipient;
    uint256 internal _amount;

    function enableForceTransfer(
        address burnToken,
        address recipient,
        uint256 amount
    ) external {
        _forceTransfer = true;
        _burnToken = burnToken;
        _recipient = recipient;
        _amount = amount;
    }

    function disableForceTransfer() external {
        _forceTransfer = false;
    }

    function receiveMessage(
        bytes calldata message,
        bytes calldata /* attestation */
    ) external returns (bool) {
        if (_forceTransfer) {
            IERC20(_burnToken).transfer(_recipient, _amount);
            return true;
        }

        bytes29 _msg = message.ref(0);
        bytes memory _messageBody = _msg._messageBody().clone();

        _msg = _messageBody.ref(0);

        bytes32 mintRecipient = _msg._getMintRecipient();
        bytes32 burnToken = _msg._getBurnToken();
        uint256 amount = _msg._getAmount();

        IERC20(Message.bytes32ToAddress(burnToken)).transfer(
            Message.bytes32ToAddress(mintRecipient),
            amount
        );

        return true;
    }
}
