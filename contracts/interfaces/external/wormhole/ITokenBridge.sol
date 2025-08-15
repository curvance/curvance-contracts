// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface ITokenBridge {
    /// @param payloadID PayloadID
    /// @param amount Amount being transferred (big-endian uint256).
    /// @param tokenAddress Address of the token.
    ///                     Left-zero-padded if shorter than 32 bytes.
    /// @param tokenChain Chain ID of the token.
    /// @param to Address of the recipient.
    ///           Left-zero-padded if shorter than 32 bytes.
    /// @param toChain Chain ID of the recipient.
    /// @param fromAddress Address of the message sender.
    ///                    Left-zero-padded if shorter than 32 bytes.
    /// @param payload An arbitrary payload.
    struct TransferWithPayload {
        uint8 payloadID;
        uint256 amount;
        bytes32 tokenAddress;
        uint16 tokenChain;
        bytes32 to;
        uint16 toChain;
        bytes32 fromAddress;
        bytes payload;
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Send ERC20 token through portal.
    ///
    /// @dev This type of transfer is called a "contract-controlled transfer".
    ///      There are three differences from a regular token transfer:
    ///      1) Additional arbitrary payload can be attached to the message.
    ///      2) Only the recipient (typically a contract) can redeem
    ///         the transaction.
    ///      3) The sender's address (msg.sender) is also included in
    ///         the transaction payload.
    function transferTokensWithPayload(
        address token,
        uint256 amount,
        uint16 recipientChain,
        bytes32 recipient,
        uint32 nonce,
        bytes memory payload
    ) external payable returns (uint64 sequence);

    /// @notice Complete a contract-controlled transfer of an ERC20 token.
    /// @dev The transaction can only be redeemed by the recipient,
    ///      typically a contract.
    /// @param encodedVm A byte array containing a VAA signed by the guardians.
    /// @return The byte array representing a TransferWithPayload.
    function completeTransferWithPayload(
        bytes memory encodedVm
    ) external returns (bytes memory);

    /// @notice Parse a token transfer with payload.
    /// @param encoded The byte array corresponding to the token transfer (not
    ///                 the whole VAA, only the payload)
    function parseTransferWithPayload(
        bytes memory encoded
    ) external pure returns (TransferWithPayload memory);

    function bridgeContracts(uint16 chainId) external view returns (bytes32);
}
