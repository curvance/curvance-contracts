// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.28;

// contracts/libraries/ConstantsLib.sol

/// @dev Scalar for math. `WAD` * `WAD`.
uint256 constant WAD_SQUARED = 1e36;

/// @dev Scalar for math. `WAD` * `WAD` / `BPS`.
///      1e18 * 1e18 / 1e4
uint256 constant WAD_SQUARED_BPS_OFFSET = 1e32;

/// @dev Scalar for math. Increased precision when WAD is insufficient
///      but WAD_SQUARED runs the risk of overflow.
uint256 constant RAY = 1e27;

/// @dev Scalar for math. `WAD` * `BPS`.
uint256 constant WAD_BPS = 1e22;

/// @dev Scalar for math. Base precision matching ether.
uint256 constant WAD = 1e18;

/// @dev Scalar for math. Represents basis points typically used in TradFi.
uint256 constant BPS = 1e4;

/// @dev Return value indicating no price returned at all.
uint256 constant BAD_SOURCE = 2;

/// @dev Return value indicating price divergence or a missing price feed.
uint256 constant CAUTION = 1;

/// @dev Return value indicating no price error.
uint256 constant NO_ERROR = 0;

/// @dev Extra time added to top end Oracle feed heartbeat incase of
///      transaction congestion delaying an update.
uint256 constant HEARTBEAT_GRACE_PERIOD = 120;

/// @dev Unix time has 31,536,000 seconds per year.
///      All my homies hate leap seconds and leap years.
uint256 constant SECONDS_PER_YEAR = 31_536_000;

// contracts/libraries/external/ERC20.sol

/// @notice Simple ERC20 + EIP-2612 implementation.
/// @author Solady (https://github.com/vectorized/solady/blob/main/src/tokens/ERC20.sol)
/// @author Modified from Solmate (https://github.com/transmissions11/solmate/blob/main/src/tokens/ERC20.sol)
/// @author Modified from OpenZeppelin (https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/ERC20.sol)
///
/// @dev Note:
/// - The ERC20 standard allows minting and transferring to and from the zero address,
///   minting and transferring zero tokens, as well as self-approvals.
///   For performance, this implementation WILL NOT revert for such actions.
///   Please add any checks with overrides if desired.
/// - The `permit` function uses the ecrecover precompile (0x1).
///
/// If you are overriding:
/// - NEVER violate the ERC20 invariant:
///   the total sum of all balances must be equal to `totalSupply()`.
/// - Check that the overridden function is actually used in the function you want to
///   change the behavior of. Much of the code has been manually inlined for performance.
abstract contract ERC20 {
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       CUSTOM ERRORS                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev The total supply has overflowed.
    error TotalSupplyOverflow();

    /// @dev The allowance has overflowed.
    error AllowanceOverflow();

    /// @dev The allowance has underflowed.
    error AllowanceUnderflow();

    /// @dev Insufficient balance.
    error InsufficientBalance();

    /// @dev Insufficient allowance.
    error InsufficientAllowance();

    /// @dev The permit is invalid.
    error InvalidPermit();

    /// @dev The permit has expired.
    error PermitExpired();

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                           EVENTS                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev Emitted when `amount` tokens is transferred from `from` to `to`.
    event Transfer(address indexed from, address indexed to, uint256 amount);

    /// @dev Emitted when `amount` tokens is approved by `owner` to be used by `spender`.
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    /// @dev `keccak256(bytes("Transfer(address,address,uint256)"))`.
    uint256 private constant _TRANSFER_EVENT_SIGNATURE =
        0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef;

    /// @dev `keccak256(bytes("Approval(address,address,uint256)"))`.
    uint256 private constant _APPROVAL_EVENT_SIGNATURE =
        0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          STORAGE                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev The storage slot for the total supply.
    uint256 private constant _TOTAL_SUPPLY_SLOT = 0x05345cdf77eb68f44c;

    /// @dev The balance slot of `owner` is given by:
    /// ```
    ///     mstore(0x0c, _BALANCE_SLOT_SEED)
    ///     mstore(0x00, owner)
    ///     let balanceSlot := keccak256(0x0c, 0x20)
    /// ```
    uint256 private constant _BALANCE_SLOT_SEED = 0x87a211a2;

    /// @dev The allowance slot of (`owner`, `spender`) is given by:
    /// ```
    ///     mstore(0x20, spender)
    ///     mstore(0x0c, _ALLOWANCE_SLOT_SEED)
    ///     mstore(0x00, owner)
    ///     let allowanceSlot := keccak256(0x0c, 0x34)
    /// ```
    uint256 private constant _ALLOWANCE_SLOT_SEED = 0x7f5e9f20;

    /// @dev The nonce slot of `owner` is given by:
    /// ```
    ///     mstore(0x0c, _NONCES_SLOT_SEED)
    ///     mstore(0x00, owner)
    ///     let nonceSlot := keccak256(0x0c, 0x20)
    /// ```
    uint256 private constant _NONCES_SLOT_SEED = 0x38377508;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         CONSTANTS                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev `(_NONCES_SLOT_SEED << 16) | 0x1901`.
    uint256 private constant _NONCES_SLOT_SEED_WITH_SIGNATURE_PREFIX = 0x383775081901;

    /// @dev `keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")`.
    bytes32 private constant _DOMAIN_TYPEHASH =
        0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f;

    /// @dev `keccak256("1")`.
    bytes32 private constant _VERSION_HASH =
        0xc89efdaa54c0f20c7adf612882df0950f5a951637e0307cdcb4c672f298b8bc6;

    /// @dev `keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)")`.
    bytes32 private constant _PERMIT_TYPEHASH =
        0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       ERC20 METADATA                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev Returns the name of the token.
    function name() public view virtual returns (string memory);

    /// @dev Returns the symbol of the token.
    function symbol() public view virtual returns (string memory);

    /// @dev Returns the decimals places of the token.
    function decimals() public view virtual returns (uint8) {
        return 18;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                           ERC20                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev Returns the amount of tokens in existence.
    function totalSupply() public view virtual returns (uint256 result) {
        /// @solidity memory-safe-assembly
        assembly {
            result := sload(_TOTAL_SUPPLY_SLOT)
        }
    }

    /// @dev Returns the amount of tokens owned by `owner`.
    function balanceOf(address owner) public view virtual returns (uint256 result) {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x0c, _BALANCE_SLOT_SEED)
            mstore(0x00, owner)
            result := sload(keccak256(0x0c, 0x20))
        }
    }

    /// @dev Returns the amount of tokens that `spender` can spend on behalf of `owner`.
    function allowance(address owner, address spender)
        public
        view
        virtual
        returns (uint256 result)
    {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x20, spender)
            mstore(0x0c, _ALLOWANCE_SLOT_SEED)
            mstore(0x00, owner)
            result := sload(keccak256(0x0c, 0x34))
        }
    }

    /// @dev Sets `amount` as the allowance of `spender` over the caller's tokens.
    ///
    /// Emits a {Approval} event.
    function approve(address spender, uint256 amount) public virtual returns (bool) {
        /// @solidity memory-safe-assembly
        assembly {
            // Compute the allowance slot and store the amount.
            mstore(0x20, spender)
            mstore(0x0c, _ALLOWANCE_SLOT_SEED)
            mstore(0x00, caller())
            sstore(keccak256(0x0c, 0x34), amount)
            // Emit the {Approval} event.
            mstore(0x00, amount)
            log3(0x00, 0x20, _APPROVAL_EVENT_SIGNATURE, caller(), shr(96, mload(0x2c)))
        }
        return true;
    }

    /// @dev Transfer `amount` tokens from the caller to `to`.
    ///
    /// Requirements:
    /// - `from` must at least have `amount`.
    ///
    /// Emits a {Transfer} event.
    function transfer(address to, uint256 amount) public virtual returns (bool) {
        _beforeTokenTransfer(msg.sender, to, amount);
        /// @solidity memory-safe-assembly
        assembly {
            // Compute the balance slot and load its value.
            mstore(0x0c, _BALANCE_SLOT_SEED)
            mstore(0x00, caller())
            let fromBalanceSlot := keccak256(0x0c, 0x20)
            let fromBalance := sload(fromBalanceSlot)
            // Revert if insufficient balance.
            if gt(amount, fromBalance) {
                mstore(0x00, 0xf4d678b8) // `InsufficientBalance()`.
                revert(0x1c, 0x04)
            }
            // Subtract and store the updated balance.
            sstore(fromBalanceSlot, sub(fromBalance, amount))
            // Compute the balance slot of `to`.
            mstore(0x00, to)
            let toBalanceSlot := keccak256(0x0c, 0x20)
            // Add and store the updated balance of `to`.
            // Will not overflow because the sum of all user balances
            // cannot exceed the maximum uint256 value.
            sstore(toBalanceSlot, add(sload(toBalanceSlot), amount))
            // Emit the {Transfer} event.
            mstore(0x20, amount)
            log3(0x20, 0x20, _TRANSFER_EVENT_SIGNATURE, caller(), shr(96, mload(0x0c)))
        }
        _afterTokenTransfer(msg.sender, to, amount);
        return true;
    }

    /// @dev Transfers `amount` tokens from `from` to `to`.
    ///
    /// Note: Does not update the allowance if it is the maximum uint256 value.
    ///
    /// Requirements:
    /// - `from` must at least have `amount`.
    /// - The caller must have at least `amount` of allowance to transfer the tokens of `from`.
    ///
    /// Emits a {Transfer} event.
    function transferFrom(address from, address to, uint256 amount) public virtual returns (bool) {
        _beforeTokenTransfer(from, to, amount);
        /// @solidity memory-safe-assembly
        assembly {
            let from_ := shl(96, from)
            // Compute the allowance slot and load its value.
            mstore(0x20, caller())
            mstore(0x0c, or(from_, _ALLOWANCE_SLOT_SEED))
            let allowanceSlot := keccak256(0x0c, 0x34)
            let allowance_ := sload(allowanceSlot)
            // If the allowance is not the maximum uint256 value.
            if add(allowance_, 1) {
                // Revert if the amount to be transferred exceeds the allowance.
                if gt(amount, allowance_) {
                    mstore(0x00, 0x13be252b) // `InsufficientAllowance()`.
                    revert(0x1c, 0x04)
                }
                // Subtract and store the updated allowance.
                sstore(allowanceSlot, sub(allowance_, amount))
            }
            // Compute the balance slot and load its value.
            mstore(0x0c, or(from_, _BALANCE_SLOT_SEED))
            let fromBalanceSlot := keccak256(0x0c, 0x20)
            let fromBalance := sload(fromBalanceSlot)
            // Revert if insufficient balance.
            if gt(amount, fromBalance) {
                mstore(0x00, 0xf4d678b8) // `InsufficientBalance()`.
                revert(0x1c, 0x04)
            }
            // Subtract and store the updated balance.
            sstore(fromBalanceSlot, sub(fromBalance, amount))
            // Compute the balance slot of `to`.
            mstore(0x00, to)
            let toBalanceSlot := keccak256(0x0c, 0x20)
            // Add and store the updated balance of `to`.
            // Will not overflow because the sum of all user balances
            // cannot exceed the maximum uint256 value.
            sstore(toBalanceSlot, add(sload(toBalanceSlot), amount))
            // Emit the {Transfer} event.
            mstore(0x20, amount)
            log3(0x20, 0x20, _TRANSFER_EVENT_SIGNATURE, shr(96, from_), shr(96, mload(0x0c)))
        }
        _afterTokenTransfer(from, to, amount);
        return true;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          EIP-2612                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev For more performance, override to return the constant value
    /// of `keccak256(bytes(name()))` if `name()` will never change.
    function _constantNameHash() internal view virtual returns (bytes32 result) {}

    /// @dev Returns the current nonce for `owner`.
    /// This value is used to compute the signature for EIP-2612 permit.
    function nonces(address owner) public view virtual returns (uint256 result) {
        /// @solidity memory-safe-assembly
        assembly {
            // Compute the nonce slot and load its value.
            mstore(0x0c, _NONCES_SLOT_SEED)
            mstore(0x00, owner)
            result := sload(keccak256(0x0c, 0x20))
        }
    }

    /// @dev Sets `value` as the allowance of `spender` over the tokens of `owner`,
    /// authorized by a signed approval by `owner`.
    ///
    /// Emits a {Approval} event.
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public virtual {
        bytes32 nameHash = _constantNameHash();
        //  We simply calculate it on-the-fly to allow for cases where the `name` may change.
        if (nameHash == bytes32(0)) nameHash = keccak256(bytes(name()));
        /// @solidity memory-safe-assembly
        assembly {
            // Revert if the block timestamp is greater than `deadline`.
            if gt(timestamp(), deadline) {
                mstore(0x00, 0x1a15a3cc) // `PermitExpired()`.
                revert(0x1c, 0x04)
            }
            let m := mload(0x40) // Grab the free memory pointer.
            // Clean the upper 96 bits.
            owner := shr(96, shl(96, owner))
            spender := shr(96, shl(96, spender))
            // Compute the nonce slot and load its value.
            mstore(0x0e, _NONCES_SLOT_SEED_WITH_SIGNATURE_PREFIX)
            mstore(0x00, owner)
            let nonceSlot := keccak256(0x0c, 0x20)
            let nonceValue := sload(nonceSlot)
            // Prepare the domain separator.
            mstore(m, _DOMAIN_TYPEHASH)
            mstore(add(m, 0x20), nameHash)
            mstore(add(m, 0x40), _VERSION_HASH)
            mstore(add(m, 0x60), chainid())
            mstore(add(m, 0x80), address())
            mstore(0x2e, keccak256(m, 0xa0))
            // Prepare the struct hash.
            mstore(m, _PERMIT_TYPEHASH)
            mstore(add(m, 0x20), owner)
            mstore(add(m, 0x40), spender)
            mstore(add(m, 0x60), value)
            mstore(add(m, 0x80), nonceValue)
            mstore(add(m, 0xa0), deadline)
            mstore(0x4e, keccak256(m, 0xc0))
            // Prepare the ecrecover calldata.
            mstore(0x00, keccak256(0x2c, 0x42))
            mstore(0x20, and(0xff, v))
            mstore(0x40, r)
            mstore(0x60, s)
            let t := staticcall(gas(), 1, 0, 0x80, 0x20, 0x20)
            // If the ecrecover fails, the returndatasize will be 0x00,
            // `owner` will be checked if it equals the hash at 0x00,
            // which evaluates to false (i.e. 0), and we will revert.
            // If the ecrecover succeeds, the returndatasize will be 0x20,
            // `owner` will be compared against the returned address at 0x20.
            if iszero(eq(mload(returndatasize()), owner)) {
                mstore(0x00, 0xddafbaef) // `InvalidPermit()`.
                revert(0x1c, 0x04)
            }
            // Increment and store the updated nonce.
            sstore(nonceSlot, add(nonceValue, t)) // `t` is 1 if ecrecover succeeds.
            // Compute the allowance slot and store the value.
            // The `owner` is already at slot 0x20.
            mstore(0x40, or(shl(160, _ALLOWANCE_SLOT_SEED), spender))
            sstore(keccak256(0x2c, 0x34), value)
            // Emit the {Approval} event.
            log3(add(m, 0x60), 0x20, _APPROVAL_EVENT_SIGNATURE, owner, spender)
            mstore(0x40, m) // Restore the free memory pointer.
            mstore(0x60, 0) // Restore the zero pointer.
        }
    }

    /// @dev Returns the EIP-712 domain separator for the EIP-2612 permit.
    function DOMAIN_SEPARATOR() public view virtual returns (bytes32 result) {
        bytes32 nameHash = _constantNameHash();
        //  We simply calculate it on-the-fly to allow for cases where the `name` may change.
        if (nameHash == bytes32(0)) nameHash = keccak256(bytes(name()));
        /// @solidity memory-safe-assembly
        assembly {
            let m := mload(0x40) // Grab the free memory pointer.
            mstore(m, _DOMAIN_TYPEHASH)
            mstore(add(m, 0x20), nameHash)
            mstore(add(m, 0x40), _VERSION_HASH)
            mstore(add(m, 0x60), chainid())
            mstore(add(m, 0x80), address())
            result := keccak256(m, 0xa0)
        }
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                  INTERNAL MINT FUNCTIONS                   */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev Mints `amount` tokens to `to`, increasing the total supply.
    ///
    /// Emits a {Transfer} event.
    function _mint(address to, uint256 amount) internal virtual {
        _beforeTokenTransfer(address(0), to, amount);
        /// @solidity memory-safe-assembly
        assembly {
            let totalSupplyBefore := sload(_TOTAL_SUPPLY_SLOT)
            let totalSupplyAfter := add(totalSupplyBefore, amount)
            // Revert if the total supply overflows.
            if lt(totalSupplyAfter, totalSupplyBefore) {
                mstore(0x00, 0xe5cfe957) // `TotalSupplyOverflow()`.
                revert(0x1c, 0x04)
            }
            // Store the updated total supply.
            sstore(_TOTAL_SUPPLY_SLOT, totalSupplyAfter)
            // Compute the balance slot and load its value.
            mstore(0x0c, _BALANCE_SLOT_SEED)
            mstore(0x00, to)
            let toBalanceSlot := keccak256(0x0c, 0x20)
            // Add and store the updated balance.
            sstore(toBalanceSlot, add(sload(toBalanceSlot), amount))
            // Emit the {Transfer} event.
            mstore(0x20, amount)
            log3(0x20, 0x20, _TRANSFER_EVENT_SIGNATURE, 0, shr(96, mload(0x0c)))
        }
        _afterTokenTransfer(address(0), to, amount);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                  INTERNAL BURN FUNCTIONS                   */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev Burns `amount` tokens from `from`, reducing the total supply.
    ///
    /// Emits a {Transfer} event.
    function _burn(address from, uint256 amount) internal virtual {
        _beforeTokenTransfer(from, address(0), amount);
        /// @solidity memory-safe-assembly
        assembly {
            // Compute the balance slot and load its value.
            mstore(0x0c, _BALANCE_SLOT_SEED)
            mstore(0x00, from)
            let fromBalanceSlot := keccak256(0x0c, 0x20)
            let fromBalance := sload(fromBalanceSlot)
            // Revert if insufficient balance.
            if gt(amount, fromBalance) {
                mstore(0x00, 0xf4d678b8) // `InsufficientBalance()`.
                revert(0x1c, 0x04)
            }
            // Subtract and store the updated balance.
            sstore(fromBalanceSlot, sub(fromBalance, amount))
            // Subtract and store the updated total supply.
            sstore(_TOTAL_SUPPLY_SLOT, sub(sload(_TOTAL_SUPPLY_SLOT), amount))
            // Emit the {Transfer} event.
            mstore(0x00, amount)
            log3(0x00, 0x20, _TRANSFER_EVENT_SIGNATURE, shr(96, shl(96, from)), 0)
        }
        _afterTokenTransfer(from, address(0), amount);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                INTERNAL TRANSFER FUNCTIONS                 */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev Moves `amount` of tokens from `from` to `to`.
    function _transfer(address from, address to, uint256 amount) internal virtual {
        _beforeTokenTransfer(from, to, amount);
        /// @solidity memory-safe-assembly
        assembly {
            let from_ := shl(96, from)
            // Compute the balance slot and load its value.
            mstore(0x0c, or(from_, _BALANCE_SLOT_SEED))
            let fromBalanceSlot := keccak256(0x0c, 0x20)
            let fromBalance := sload(fromBalanceSlot)
            // Revert if insufficient balance.
            if gt(amount, fromBalance) {
                mstore(0x00, 0xf4d678b8) // `InsufficientBalance()`.
                revert(0x1c, 0x04)
            }
            // Subtract and store the updated balance.
            sstore(fromBalanceSlot, sub(fromBalance, amount))
            // Compute the balance slot of `to`.
            mstore(0x00, to)
            let toBalanceSlot := keccak256(0x0c, 0x20)
            // Add and store the updated balance of `to`.
            // Will not overflow because the sum of all user balances
            // cannot exceed the maximum uint256 value.
            sstore(toBalanceSlot, add(sload(toBalanceSlot), amount))
            // Emit the {Transfer} event.
            mstore(0x20, amount)
            log3(0x20, 0x20, _TRANSFER_EVENT_SIGNATURE, shr(96, from_), shr(96, mload(0x0c)))
        }
        _afterTokenTransfer(from, to, amount);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                INTERNAL ALLOWANCE FUNCTIONS                */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev Updates the allowance of `owner` for `spender` based on spent `amount`.
    function _spendAllowance(address owner, address spender, uint256 amount) internal virtual {
        /// @solidity memory-safe-assembly
        assembly {
            // Compute the allowance slot and load its value.
            mstore(0x20, spender)
            mstore(0x0c, _ALLOWANCE_SLOT_SEED)
            mstore(0x00, owner)
            let allowanceSlot := keccak256(0x0c, 0x34)
            let allowance_ := sload(allowanceSlot)
            // If the allowance is not the maximum uint256 value.
            if add(allowance_, 1) {
                // Revert if the amount to be transferred exceeds the allowance.
                if gt(amount, allowance_) {
                    mstore(0x00, 0x13be252b) // `InsufficientAllowance()`.
                    revert(0x1c, 0x04)
                }
                // Subtract and store the updated allowance.
                sstore(allowanceSlot, sub(allowance_, amount))
            }
        }
    }

    /// @dev Sets `amount` as the allowance of `spender` over the tokens of `owner`.
    ///
    /// Emits a {Approval} event.
    function _approve(address owner, address spender, uint256 amount) internal virtual {
        /// @solidity memory-safe-assembly
        assembly {
            let owner_ := shl(96, owner)
            // Compute the allowance slot and store the amount.
            mstore(0x20, spender)
            mstore(0x0c, or(owner_, _ALLOWANCE_SLOT_SEED))
            sstore(keccak256(0x0c, 0x34), amount)
            // Emit the {Approval} event.
            mstore(0x00, amount)
            log3(0x00, 0x20, _APPROVAL_EVENT_SIGNATURE, shr(96, owner_), shr(96, mload(0x2c)))
        }
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                     HOOKS TO OVERRIDE                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev Hook that is called before any transfer of tokens.
    /// This includes minting and burning.
    function _beforeTokenTransfer(address from, address to, uint256 amount) internal virtual {}

    /// @dev Hook that is called after any transfer of tokens.
    /// This includes minting and burning.
    function _afterTokenTransfer(address from, address to, uint256 amount) internal virtual {}
}

// contracts/libraries/external/FixedPointMathLib.sol

/// @notice Arithmetic library with operations for fixed-point numbers.
/// @dev Reduced function scope from full FixedPointMathLib library to only what is needed for Curvance.
/// @author Solady (https://github.com/vectorized/solady/blob/main/src/utils/FixedPointMathLib.sol)
/// @author Modified from Solmate (https://github.com/transmissions11/solmate/blob/main/src/utils/FixedPointMathLib.sol)
library FixedPointMathLib {
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       CUSTOM ERRORS                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev The operation failed, either due to a multiplication overflow, or a division by a zero.
    error MulDivFailed();

    /// @dev The full precision multiply-divide operation failed, either due
    /// to the result being larger than 256 bits, or a division by a zero.
    error FullMulDivFailed();

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                  GENERAL NUMBER UTILITIES                  */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev Calculates `floor(x * y / d)` with full precision.
    /// Throws if result overflows a uint256 or when `d` is zero.
    /// Credit to Remco Bloemen under MIT license: https://2π.com/21/muldiv
    function fullMulDiv(uint256 x, uint256 y, uint256 d) internal pure returns (uint256 result) {
        /// @solidity memory-safe-assembly
        assembly {
            for {} 1 {} {
                // 512-bit multiply `[p1 p0] = x * y`.
                // Compute the product mod `2**256` and mod `2**256 - 1`
                // then use the Chinese Remainder Theorem to reconstruct
                // the 512 bit result. The result is stored in two 256
                // variables such that `product = p1 * 2**256 + p0`.

                // Least significant 256 bits of the product.
                result := mul(x, y) // Temporarily use `result` as `p0` to save gas.
                let mm := mulmod(x, y, not(0))
                // Most significant 256 bits of the product.
                let p1 := sub(mm, add(result, lt(mm, result)))

                // Handle non-overflow cases, 256 by 256 division.
                if iszero(p1) {
                    if iszero(d) {
                        mstore(0x00, 0xae47f702) // `FullMulDivFailed()`.
                        revert(0x1c, 0x04)
                    }
                    result := div(result, d)
                    break
                }

                // Make sure the result is less than `2**256`. Also prevents `d == 0`.
                if iszero(gt(d, p1)) {
                    mstore(0x00, 0xae47f702) // `FullMulDivFailed()`.
                    revert(0x1c, 0x04)
                }

                /*------------------- 512 by 256 division --------------------*/

                // Make division exact by subtracting the remainder from `[p1 p0]`.
                // Compute remainder using mulmod.
                let r := mulmod(x, y, d)
                // `t` is the least significant bit of `d`.
                // Always greater or equal to 1.
                let t := and(d, sub(0, d))
                // Divide `d` by `t`, which is a power of two.
                d := div(d, t)
                // Invert `d mod 2**256`
                // Now that `d` is an odd number, it has an inverse
                // modulo `2**256` such that `d * inv = 1 mod 2**256`.
                // Compute the inverse by starting with a seed that is correct
                // correct for four bits. That is, `d * inv = 1 mod 2**4`.
                let inv := xor(2, mul(3, d))
                // Now use Newton-Raphson iteration to improve the precision.
                // Thanks to Hensel's lifting lemma, this also works in modular
                // arithmetic, doubling the correct bits in each step.
                inv := mul(inv, sub(2, mul(d, inv))) // inverse mod 2**8
                inv := mul(inv, sub(2, mul(d, inv))) // inverse mod 2**16
                inv := mul(inv, sub(2, mul(d, inv))) // inverse mod 2**32
                inv := mul(inv, sub(2, mul(d, inv))) // inverse mod 2**64
                inv := mul(inv, sub(2, mul(d, inv))) // inverse mod 2**128
                result :=
                    mul(
                        // Divide [p1 p0] by the factors of two.
                        // Shift in bits from `p1` into `p0`. For this we need
                        // to flip `t` such that it is `2**256 / t`.
                        or(
                            mul(sub(p1, gt(r, result)), add(div(sub(0, t), t), 1)),
                            div(sub(result, r), t)
                        ),
                        // inverse mod 2**256
                        mul(inv, sub(2, mul(d, inv)))
                    )
                break
            }
        }
    }

    /// @dev Calculates `floor(x * y / d)` with full precision, rounded up.
    /// Throws if result overflows a uint256 or when `d` is zero.
    /// Credit to Uniswap-v3-core under MIT license:
    /// https://github.com/Uniswap/v3-core/blob/contracts/libraries/FullMath.sol
    function fullMulDivUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256 result) {
        result = fullMulDiv(x, y, d);
        /// @solidity memory-safe-assembly
        assembly {
            if mulmod(x, y, d) {
                result := add(result, 1)
                if iszero(result) {
                    mstore(0x00, 0xae47f702) // `FullMulDivFailed()`.
                    revert(0x1c, 0x04)
                }
            }
        }
    }

    /// @dev Returns `floor(x * y / d)`.
    /// Reverts if `x * y` overflows, or `d` is zero.
    function mulDiv(uint256 x, uint256 y, uint256 d) internal pure returns (uint256 z) {
        /// @solidity memory-safe-assembly
        assembly {
            // Equivalent to require(d != 0 && (y == 0 || x <= type(uint256).max / y))
            if iszero(mul(d, iszero(mul(y, gt(x, div(not(0), y)))))) {
                mstore(0x00, 0xad251c27) // `MulDivFailed()`.
                revert(0x1c, 0x04)
            }
            z := div(mul(x, y), d)
        }
    }

    /// @dev Returns `ceil(x * y / d)`.
    /// Reverts if `x * y` overflows, or `d` is zero.
    function mulDivUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256 z) {
        /// @solidity memory-safe-assembly
        assembly {
            // Equivalent to require(d != 0 && (y == 0 || x <= type(uint256).max / y))
            if iszero(mul(d, iszero(mul(y, gt(x, div(not(0), y)))))) {
                mstore(0x00, 0xad251c27) // `MulDivFailed()`.
                revert(0x1c, 0x04)
            }
            z := add(iszero(iszero(mod(mul(x, y), d))), div(mul(x, y), d))
        }
    }

    /// @dev Returns the square root of `x`.
    function sqrt(uint256 x) internal pure returns (uint256 z) {
        /// @solidity memory-safe-assembly
        assembly {
            // `floor(sqrt(2**15)) = 181`. `sqrt(2**15) - 181 = 2.84`.
            z := 181 // The "correct" value is 1, but this saves a multiplication later.

            // This segment is to get a reasonable initial estimate for the Babylonian method. With a bad
            // start, the correct # of bits increases ~linearly each iteration instead of ~quadratically.

            // Let `y = x / 2**r`. We check `y >= 2**(k + 8)`
            // but shift right by `k` bits to ensure that if `x >= 256`, then `y >= 256`.
            let r := shl(7, lt(0xffffffffffffffffffffffffffffffffff, x))
            r := or(r, shl(6, lt(0xffffffffffffffffff, shr(r, x))))
            r := or(r, shl(5, lt(0xffffffffff, shr(r, x))))
            r := or(r, shl(4, lt(0xffffff, shr(r, x))))
            z := shl(shr(1, r), z)

            // Goal was to get `z*z*y` within a small factor of `x`. More iterations could
            // get y in a tighter range. Currently, we will have y in `[256, 256*(2**16))`.
            // We ensured `y >= 256` so that the relative difference between `y` and `y+1` is small.
            // That's not possible if `x < 256` but we can just verify those cases exhaustively.

            // Now, `z*z*y <= x < z*z*(y+1)`, and `y <= 2**(16+8)`, and either `y >= 256`, or `x < 256`.
            // Correctness can be checked exhaustively for `x < 256`, so we assume `y >= 256`.
            // Then `z*sqrt(y)` is within `sqrt(257)/sqrt(256)` of `sqrt(x)`, or about 20bps.

            // For `s` in the range `[1/256, 256]`, the estimate `f(s) = (181/1024) * (s+1)`
            // is in the range `(1/2.84 * sqrt(s), 2.84 * sqrt(s))`,
            // with largest error when `s = 1` and when `s = 256` or `1/256`.

            // Since `y` is in `[256, 256*(2**16))`, let `a = y/65536`, so that `a` is in `[1/256, 256)`.
            // Then we can estimate `sqrt(y)` using
            // `sqrt(65536) * 181/1024 * (a + 1) = 181/4 * (y + 65536)/65536 = 181 * (y + 65536)/2**18`.

            // There is no overflow risk here since `y < 2**136` after the first branch above.
            z := shr(18, mul(z, add(shr(r, x), 65536))) // A `mul()` is saved from starting `z` at 181.

            // Given the worst case multiplicative error of 2.84 above, 7 iterations should be enough.
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))
            z := shr(1, add(z, div(x, z)))

            // If `x+1` is a perfect square, the Babylonian method cycles between
            // `floor(sqrt(x))` and `ceil(sqrt(x))`. This statement ensures we return floor.
            // See: https://en.wikipedia.org/wiki/Integer_square_root#Using_only_integer_division
            z := sub(z, lt(div(x, z), z))
        }
    }
}

// contracts/interfaces/IActionRegistry.sol

interface IActionRegistry {
    /// @notice Checks whether `user` has transferability enabled or disabled
    ///         for their tokens.
    /// @param user The address to check whether transferability is enabled or
    ///             disabled for.
    /// @return result Indicates whether `user` has transferability disabled
    ///                or not, true = disabled, false = not disabled.
    function checkTransfersDisabled(
        address user
    ) external view returns (bool result);

    /// @notice Checks whether `user` has disabled creating new delegations
    ///         for actions inside Curvance.
    /// @param user The address to check whether delegation is enabled or
    ///             disabled for.
    /// @return result Indicates whether `user` has delegation disabled
    ///                or not, true = disabled, false = not disabled.
    function checkNewDelegationDisabled(
        address user
    ) external view returns (bool result);

    /// @notice Returns `user`'s approval index.
    /// @dev The approval index is a way to revoke approval on all tokens,
    ///      and features at once if a malicious delegation was allowed by
    ///      `user`.
    /// @param user The user to check delegated approval index for.
    /// @return result The `user`'s current approval index value.
    function userApprovalIndex(
        address user
    ) external view returns (uint256 result);
}

// contracts/interfaces/ICentralRegistry.sol

/// TYPES ///

/// @notice Configuration data for a separately supported blockchain.
/// @param isSupported Whether the chain is supported or not.
/// @param messagingChainId Messaging Chain ID where this address authorized.
/// @param domain Domain for the chain.
/// @param messagingHub Messaging Hub address on the chain.
/// @param votingHub Voting Hub address on the chain.
/// @param cveAddress CVE address on the chain.
/// @param feeTokenAddress Fee token address on the chain.
/// @param crosschainRelayer Crosschain relayer address on the chain.
struct ChainConfig {
    bool isSupported;
    uint16 messagingChainId;
    uint32 domain;
    address messagingHub;
    address votingHub;
    address cveAddress;
    address feeTokenAddress;
    address crosschainRelayer;
}

interface ICentralRegistry {
    /// @notice The length of one protocol epoch, in seconds.
    function EPOCH_DURATION() external view returns (uint256);

    /// @notice Sequencer uptime oracle on this chain (for L2s).
    function SEQUENCER_ORACLE() external view returns (address);

    /// @notice Returns Genesis Epoch Timestamp of Curvance.
    function genesisEpoch() external view returns (uint256);

    /// @notice Returns Protocol DAO address.
    function daoAddress() external view returns (address);

    /// @notice Returns Protocol Emergency Council address.
    function emergencyCouncil() external view returns (address);

    /// @notice Indicates if address has DAO permissions or not.
    function hasDaoPermissions(
        address addressToCheck
    ) external view returns (bool);

    /// @notice Indicates if address has elevated DAO permissions or not.
    function hasElevatedPermissions(
        address addressToCheck
    ) external view returns (bool);

    /// @notice Indicates if address has lock creation permissions or not.
    function hasLockingPermissions(
        address addressToCheck
    ) external view returns (bool);

    /// @notice Indicates if address has auction permissions or not.
    function hasAuctionPermissions(
        address addressToCheck
    ) external view returns (bool);

    /// @notice Indicates if address has market permissions or not.
    function hasMarketPermissions(
        address addressToCheck
    ) external view returns (bool);

    /// @notice Indicates if address has harvest permissions or not.
    function hasHarvestPermissions(
        address addressToCheck
    ) external view returns (bool);

    /// @notice Returns Reward Manager address.
    function rewardManager() external view returns (address);

    /// @notice Returns Gauge Manager address.
    function gaugeManager() external view returns (address);

    /// @notice Returns CVE address.
    function cve() external view returns (address);

    /// @notice Returns veCVE address.
    function veCVE() external view returns (address);

    /// @notice Returns Voting Hub address.
    function votingHub() external view returns (address);

    /// @notice Returns Messaging Hub address.
    function messagingHub() external view returns (address);

    /// @notice Returns Oracle Manager address.
    function oracleManager() external view returns (address);

    /// @notice Returns Fee Manager address.
    function feeManager() external view returns (address);

    /// @notice Returns Fee Token address.
    function feeToken() external view returns (address);

    /// @notice Returns Crosschain Core contract address.
    function crosschainCore() external view returns (address);

    /// @notice Returns Crosschain Relayer contract address.
    function crosschainRelayer() external view returns (address);

    /// @notice Returns Token Messenger contract address.
    function tokenMessager() external view returns (address);

    /// @notice Returns Messenger Transmitter contract address.
    function messageTransmitter() external view returns (address);

    /// @notice Returns domain value.
    function domain() external view returns (uint32);

    /// @notice Returns protocol gas fee on harvest, in `BPS`.
    function protocolCompoundFee() external view returns (uint256);

    /// @notice Returns protocol yield fee on strategy harvest, in `BPS`.
    function protocolYieldFee() external view returns (uint256);

    /// @notice Returns protocol yield + gas fee on strategy harvest,
    ///         in `BPS`.
    function protocolHarvestFee() external view returns (uint256);

    /// @notice Returns protocol fee on leverage actions, in `BPS`.
    function protocolLeverageFee() external view returns (uint256);

    /// @notice Returns default fee on interest generated from active loans,
    ///         in `BPS`.
    function defaultProtocolInterestFee() external view returns (uint256);

    /// @notice Returns earlyUnlockPenaltyMultiplier value, in `BPS`.
    function earlyUnlockPenaltyMultiplier() external view returns (uint256);

    /// @notice Returns voteBoostMultiplier value, in `BPS`.
    function voteBoostMultiplier() external view returns (uint256);

    /// @notice Returns lockBoostMultiplier value, in `BPS`.
    function lockBoostMultiplier() external view returns (uint256);

    /// @notice Returns swap slippage limit, WAD-scaled.
    function slippageLimit() external view returns (uint256);

    /// @notice Returns an array of Chain IDs recorded in GETH format.
    function foreignChainIds() external view returns (uint256[] memory);

    /// @notice Returns an array of Curvance markets on this chain.
    function marketManagers() external view returns (address[] memory);

    /// @notice Increments a caller's approval index.
    /// @dev By incrementing their approval index, a user's delegates will all
    ///      have their delegation authority revoked across all Curvance
    ///      contracts.
    ///      Emits an {ApprovalIndexIncremented} event.
    function incrementApprovalIndex() external;

    /// @notice Returns `user`'s approval index.
    /// @param user The user to check approval index for.
    function userApprovalIndex(address user) external view returns (uint256);

    /// @notice Returns whether a user has delegation disabled.
    /// @param user The user to check delegation status for.
    function checkNewDelegationDisabled(
        address user
    ) external view returns (bool);

    /// @notice Returns whether a particular GETH chainId is supported.
    /// ChainId => messagingHub address, 2 = supported; 1 = unsupported.
    function chainConfig(
        uint256 chainId
    ) external view returns (ChainConfig memory);

    /// @notice Returns the GETH chainId corresponding chainId corresponding
    ///         to Crosschain Messaging Protocol's `chainId`.
    /// @param chainId The Crosschain Messaging Protocol's chainId.
    /// @return The GETH chainId corresponding chainId corresponding to
    ///         Crosschain Messaging Protocol's `chainId`.
    function messagingToGETHChainId(
        uint16 chainId
    ) external view returns (uint256);

    /// @notice Returns the Crosschain Messaging Protocol's ChainId
    ///         corresponding to the GETH `chainId`.
    /// @param chainId The GETH chainId.
    /// @return The Crosschain Messaging Protocol's ChainId
    ///         corresponding to the GETH `chainId`.
    function GETHToMessagingChainId(
        uint256 chainId
    ) external view returns (uint256);

    /// @notice Indicates if an address is a market manager or not.
    function isMarketManager(
        address addressToCheck
    ) external view returns (bool);

    /// @notice Maps an intent target address to the contract that will
    ///         inspect provided external calldata.
    function externalCalldataChecker(
        address addressToCheck
    ) external view returns (address);

    /// @notice Maps a Multicall target address to the contract that will
    ///         inspect provided multicall calldata.
    function multicallChecker(
        address addressToCheck
    ) external view returns (address);

    /// @notice Indicates the amount of token rewards allocated on this chain,
    ///         for an epoch.
    function emissionsAllocatedByEpoch(
        uint256 epoch
    ) external view returns (uint256);

    /// @notice Indicates the amount of token rewards allocated across all
    ///         chains, for an era. An era is a particular period in time in
    ///         which rewards are constant, before a halvening event moves the
    ///         protocol to a new era.
    function targetEmissionAllocationByEra(
        uint256 era
    ) external view returns (uint256);

    /// @notice Unlocks a market to process auction-based liquidations.
    /// @param marketToUnlock The address of the market manager to unlock
    ///                       auction-based liquidations with a specific
    ///                       liquidation bonus.
    function unlockAuctionForMarket(address marketToUnlock) external;

    /// @notice Checks if a market is unlocked for auction operations.
    /// @return Whether the caller is an unlocked market, approved for
    ///         auction-based liquidations.
    function isMarketUnlocked() external view returns (bool);

    /// @notice Sets the amount of token rewards allocated on this chain,
    ///         for an epoch.
    /// @dev Only callable by the Voting Hub.
    /// @param epoch The epoch having its token emission values set.
    /// @param emissionsAllocated The amount of token rewards allocated on
    ///                           this chain, for an epoch.
    function setEmissionsAllocatedByEpoch(
        uint256 epoch,
        uint256 emissionsAllocated
    ) external;

    /// @notice Checks whether `user` has transferability enabled or disabled
    ///         for their tokens.
    /// @dev This is inherited from ActionRegistry portion of centralRegistry.
    /// @param user The address to check whether transferability is enabled or
    ///             disabled for.
    /// @return result Indicates whether `user` has transferability disabled
    ///                or not, true = disabled, false = not disabled.
    function checkTransfersDisabled(
        address user
    ) external view returns (bool result);
}

// contracts/interfaces/external/chainlink/IChainlink.sol

interface IChainlink {
    /// @notice Returns the number of decimals the aggregator responds with.
    function decimals() external view returns (uint8);

    /// @notice Returns the latest oracle data from the aggregator.
    /// @return roundId The round ID from the aggregator for which the data
    ///                 was retrieved.
    ///         answer The price returned by the aggregator.
    ///         startedAt The timestamp the current round was started.
    ///         updatedAt The timestamp the current round last was updated.
    ///         answeredInRound The round ID of the round in which `answer`
    ///                         was computed.
    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );
    
    /// @notice Returns the latest roundID the aggregator responds with.
    function latestRound() external view returns (uint256);

    function getRoundData(uint80 _roundId) external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );
}

// contracts/interfaces/IDynamicIRM.sol

interface IDynamicIRM {
    /// @notice Returns the interval at which interest rates are adjusted.
    /// @notice The interval at which interest rates are adjusted,
    ///         in seconds.
    function ADJUSTMENT_RATE() external view returns (uint256);

    /// @notice The borrowable token linked to this interest rate model
    ///         contract.
    function linkedToken() external view returns (address);

    /// @notice Calculates the current borrow rate, per second.
    /// @dev This function's intention is for frontend data querying and
    ///     should not be used for onchain execution.
    /// @param assetsHeld The amount of underlying assets held in the pool.
    /// @param debt The amount of outstanding debt in the pool.
    /// @return result The borrow interest rate percentage, per second,
    ///                in `WAD`.
    function borrowRate(
        uint256 assetsHeld,
        uint256 debt
    ) external view returns (uint256 result);

    /// @notice Calculates the current borrow rate per second,
    ///         with updated vertex multiplier applied.
    /// @param assetsHeld The amount of underlying assets held in the pool.
    /// @param debt The amount of outstanding debt in the pool.
    /// @return result The borrow rate percentage per second, in `WAD`.
    function predictedBorrowRate(
        uint256 assetsHeld,
        uint256 debt
    ) external view returns (uint256 result);

    /// @notice Calculates the current supply rate, per second.
    /// @dev This function's intention is for frontend data querying and
    ///     should not be used for onchain execution.
    /// @param assetsHeld The amount of underlying assets held in the pool.
    /// @param debt The amount of outstanding debt in the pool.
    /// @param interestFee The current interest rate protocol fee
    ///                    for the market token.
    /// @return result The supply interest rate percentage, per second,
    ///                in `WAD`.
    function supplyRate(
        uint256 assetsHeld,
        uint256 debt,
        uint256 interestFee
    ) external view returns (uint256 result);

    /// @notice Calculates the interest rate paid per second by borrowers,
    ///         in percentage paid, per second, in `WAD`, and updates
    ///         `vertexMultiplier` if necessary.
    /// @param assetsHeld The amount of underlying assets held in the pool.
    /// @param debt The amount of outstanding debt in the pool.
    /// @return ratePerSecond The interest rate paid per second by borrowers,
    ///                       in percentage paid, per second, in `WAD`.
    /// @return adjustmentRate The period of time at which interest rates are
    ///                        adjusted, in seconds.
    function adjustedBorrowRate(
        uint256 assetsHeld,
        uint256 debt
    ) external returns (uint256 ratePerSecond, uint256 adjustmentRate);

    /// @notice Calculates the borrow utilization rate of the market.
    /// @param assetsHeld The amount of underlying assets held in the pool.
    /// @param outstandingDebt The amount of outstanding debt in the pool.
    /// @return The utilization rate between [0, WAD].
    function utilizationRate(
        uint256 assetsHeld,
        uint256 outstandingDebt
    ) external view returns (uint256);
}

// contracts/interfaces/IERC165.sol

/**
 * @dev Interface of the ERC165 standard, as defined in the
 * https://eips.ethereum.org/EIPS/eip-165[EIP].
 *
 * Implementers can declare support of contract interfaces, which can then be
 * queried by others ({ERC165Checker}).
 *
 * For an implementation, see {ERC165}.
 */
interface IERC165 {
    /**
     * @dev Returns true if this contract implements the interface defined by
     * `interfaceId`. See the corresponding
     * https://eips.ethereum.org/EIPS/eip-165#how-interfaces-are-identified[EIP section]
     * to learn more about how these ids are created.
     *
     * This function call must use less than 30 000 gas.
     */
    function supportsInterface(
        bytes4 interfaceId
    ) external view returns (bool);
}

// contracts/interfaces/IERC20.sol

// @dev Interface of the ERC20 standard
interface IERC20 {
    // @dev Returns the name of the token.
    function name() external view returns (string memory);

    // @dev Returns the symbol of the token.
    function symbol() external view returns (string memory);

    // @dev Returns the decimals of the token.
    function decimals() external view returns (uint8);

    // @dev Emitted when `value` tokens are moved from one account (`from`) to
    //      another (`to`).
    // Note that `value` may be zero.
    event Transfer(address indexed from, address indexed to, uint256 value);

    // @dev Emitted when the allowance of a `spender` for an `owner` is set by
    //      a call to {approve}. `value` is the new allowance.
    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 value
    );

    // @dev Returns the amount of tokens in existence.
    function totalSupply() external view returns (uint256);

    // @dev Returns the amount of tokens owned by `account`.
    function balanceOf(address account) external view returns (uint256);

    // @dev Moves `amount` tokens from the caller's account to `to`.
    // Returns a boolean value indicating whether the operation succeeded.
    // Emits a {Transfer} event.
    function transfer(address to, uint256 amount) external returns (bool);

    // @dev Moves `amount` tokens from `from` to `to` using the
    //      allowance mechanism. `amount` is then deducted from the caller's
    //      allowance.
    // Returns a boolean value indicating whether the operation succeeded.
    // Emits a {Transfer} event.
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool);

    // @dev Returns the remaining number of tokens that `spender` will be
    //      allowed to spend on behalf of `owner` through {transferFrom}. This
    //      is zero by default.
    function allowance(
        address owner,
        address spender
    ) external view returns (uint256);

    //  @dev Sets `amount` as the allowance of `spender` over the caller's tokens.
    //       Returns a boolean value indicating whether the operation succeeded.
    //       IMPORTANT: Beware that changing an allowance with this method brings the risk
    //       that someone may use both the old and the new allowance by unfortunate
    //       transaction ordering. One possible solution to mitigate this race
    //       condition is to first reduce the spender's allowance to 0 and set the
    //       desired value afterwards:
    //       https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
    // Emits an {Approval} event.
    function approve(address spender, uint256 amount) external returns (bool);
}

// contracts/interfaces/IMarketManager.sol

interface IMarketManager {
    /// TYPES ///

    /// @notice Data structure passed communicating the intended liquidation
    ///         scenario to review based on current liquidity levels.
    /// @param collateralToken The token which was used as collateral
    ///                        by `account` and may be seized.
    /// @param debtToken The token to potentially repay which has
    ///                  outstanding debt by `account`.
    /// @param numAccounts The number of accounts to be, potentially,
    ///                    liquidated.
    /// @param liquidateExact Whether the liquidator desires a specific
    ///                       liquidation amount.
    /// @param liquidatedShares Empty variable slot to store how much
    ///                         `collateralToken` will be seized as
    ///                         part of a particular liquidation.
    /// @param debtRepaid Empty variable slot to store how much
    ///                   `debtToken` will be repaid as part of a
    ///                   particular liquidation.
    /// @param badDebt Empty variable slot to store how much bad debt will
    ///                be realized by lenders as part of a particular
    ///                liquidation.
    struct LiqAction {
        address collateralToken;
        address debtToken;
        uint256 numAccounts;
        bool liquidateExact;
        uint256 liquidatedShares;
        uint256 debtRepaid;
        uint256 badDebt;
    }

    /// @notice Data structure returned communicating outcome of a liquidity
    ///         scenario review based on current liquidity levels.
    /// @param liquidatedShares An array containing the collateral amounts to
    ///                         liquidate from accounts, in shares.
    /// @param debtRepaid The total amount of debt to repay from accounts,
    ///                   in assets.
    /// @param badDebtRealized The total amount of debt to realize as losses
    ///                        for lenders, in assets.
    struct LiqResult {
        uint256[] liquidatedShares;
        uint256 debtRepaid;
        uint256 badDebtRealized;
    }

    /// @notice Returns whether minting, collateralization, borrowing of
    ///         `cToken` is paused.
    /// @param cToken The address of the Curvance token to return
    ///               action statuses of.
    /// @return bool Whether minting `cToken` is paused or not.
    /// @return bool Whether collateralization `cToken` is paused or not.
    /// @return bool Whether borrowing `cToken` is paused or not.
    function actionsPaused(
        address cToken
    ) external view returns (bool, bool, bool);

    /// @notice Returns the current collateralization configuration
    ///         of `cToken`.
    /// @param cToken The address of the Curvance token to return
    ///               collateralization configuration of.
    /// @return The ratio at which this token can be borrowed against
    ///         when collateralized.
    /// @return The collateral requirement where dipping below this
    ///         will cause a soft liquidation.
    /// @return The collateral requirement where dipping below
    ///         this will cause a hard liquidation.
    function collConfig(address cToken) external view returns (
         uint256, uint256, uint256
    );

    /// @notice Returns the current liquidation configuration
    ///         of `cToken`.
    /// @param cToken The address of the Curvance token to return
    ///               liquidation configuration of.
    /// @dev Base/min/max liquidation incentives are stored BPS multipliers
    ///      (`BPS + premium`). Curves and close factors are raw BPS.
    /// @return The base ratio at which this token will be
    ///         compensated on soft liquidation.
    /// @return The liquidation incentive curve length between soft
    ///         liquidation to hard liquidation, in `BPS`. e.g. 5% base
    ///         incentive with 8% curve length results in 13% liquidation
    ///         incentive on hard liquidation.
    /// @return The minimum possible liquidation incentive for during an
    ///         auction, in `BPS`.
    /// @return The maximum possible liquidation incentive for during an
    ///         auction, in `BPS`.
    /// @return Maximum % that a liquidator can repay when soft
    ///         liquidating an account, in `BPS`.
    /// @return Curve length between soft liquidation and hard liquidation,
    ///         should be equal to 100% - `closeFactorBase`, in `BPS`.
    /// @return The minimum possible close factor for during an auction,
    ///         in `BPS`.
    /// @return The maximum possible close factor for during an auction,
    ///         in `BPS`.
    function liquidationConfig(address cToken) external view returns (
        uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256
    );

    /// @notice Enables an auction-based liquidation, potentially with a dynamic
    ///         close factor and liquidation penalty values in transient storage.
    /// @dev Transient storage enforces any liquidator outside auction-based
    ///      liquidations uses the default risk parameters.
    /// @param cToken The Curvance token to configure liquidations for during
    ///               an auction-based liquidation.
    /// @param incentive The auction liquidation incentive stored BPS
    ///                  multiplier (`BPS + premium`), or 0 to use
    ///                  protocol-derived values.
    /// @param closeFactor The auction close factor value, in raw `BPS`, or
    ///                    0 to use protocol-derived values.
    function setTransientLiquidationConfig(
        address cToken,
        uint256 incentive,
        uint256 closeFactor
    ) external;

    /// @notice Called from the AuctionManager as a post hook after liquidations
    ///         are tried to enable all collateral to be liquidated outside
    ///         an Auction tx.
    /// @notice Resets the liquidation risk parameters in transient storage to
    ///         zero.
    /// @dev This is redundant since the transient values will be reset after
    ///      the liquidation transaction, but can be useful during meta calls
    ///      with multiple liquidations during a single transaction. 
    function resetTransientLiquidationConfig() external;

    /// @notice Checks if the account should be allowed to mint tokens
    ///         in the given market.
    /// @param cToken The token to verify mints against.
    function canMint(address cToken) external;

    /// @notice Checks if the account should be allowed to collateralize
    ///         their shares of the given market.
    ///         Prunes unused positions in `account` data.
    /// @dev May emit a {PositionUpdated} event.
    /// @param cToken The token to verify collateralization of.
    /// @param account The account which would collateralize the asset.
    /// @param newNetCollateral The amount of shares that would be
    ///                         collateralized in total if allowed.
    function canCollateralize(
        address cToken,
        address account,
        uint256 newNetCollateral
    ) external;

    /// @notice Checks if the account should be allowed to redeem tokens
    ///         in the given market, and then redeems.
    /// @dev This can only be called by the cToken itself.
    /// @param cToken The token to verify the redemption against.
    /// @param shares The number of cToken shares to redeem for the
    ///               underlying asset in the market.
    /// @param account The account which would redeem `shares`.
    /// @param balanceOf The current cToken share balance of `account`.
    /// @param collateralPosted The current cToken shares posted as
    ///                         collateral by `account`.
    /// @param forceRedeemCollateral Whether the collateral should be always
    ///                              reduced.
    function canRedeemWithCollateralRemoval(
        address cToken,
        uint256 shares,
        address account,
        uint256 balanceOf,
        uint256 collateralPosted,
        bool forceRedeemCollateral
    ) external returns (uint256);

    /// @notice Checks if the account should be allowed to borrow
    ///         the underlying asset of the given market.
    ///         Prunes unused positions in `account` data.
    /// @dev May emit a {PositionUpdated} event.
    /// @param cToken The token to verify borrowability of.
    /// @param assets The amount of underlying assets `account` would borrow.
    /// @param account The account which would borrow the asset.
    /// @param newNetDebt The amount of assets that would be
    ///                   outstanding debt in total if allowed.
    function canBorrow(
        address cToken,
        uint256 assets,
        address account,
        uint256 newNetDebt
    ) external;

    /// @notice Checks if the account should be allowed to borrow
    ///         the underlying asset of the given market,
    ///         and notifies the market of the borrow.
    /// @dev This can only be called by the market itself.
    /// @param cToken The market to verify the borrow against.
    /// @param assets The amount of underlying assets `account` would borrow.
    /// @param account The account which would borrow the asset.
    /// @param newNetDebt The amount of assets that would be
    ///                   outstanding debt in total if allowed.
    function canBorrowWithNotify(
        address cToken,
        uint256 assets,
        address account,
        uint256 newNetDebt
    ) external;

    /// @notice Checks if the account should be allowed to repay a borrow
    ///         in the given market, may clean up positions.
    /// @param cToken The Curvance token to verify the repayment of.
    /// @param newNetDebt The new debt amount owed by `account` after
    ///                   repayment.
    /// @param debtAsset The debt asset being repaid to `cToken`.
    /// @param decimals The decimals that `debtToken` is measured in.
    /// @param account The account who will have their loan repaid.
    function canRepayWithReview(
        address cToken,
        uint256 newNetDebt,
        address debtAsset,
        uint256 decimals,
        address account
    ) external view;

    /// @notice Checks if the liquidation should be allowed to occur,
    ///         and returns how many collateralized shares should be seized
    ///         on liquidation.
    /// @param debtAmounts The amounts of outstanding debt the liquidator
    ///                    wishes to repay, in underlying assets, empty if
    ///                    intention is to liquidate maximum amount possible
    ///                    for each account.
    /// @param liquidator The address of the account trying to liquidate
    ///                   `accounts`.
    /// @param accounts The addresses of the accounts to be liquidated.
    /// @param action A LiqAction struct containing:
    ///               collateralToken The token which is used as collateral
    ///                               by `account` and may be seized.
    ///               debtToken The token to potentially repay which has
    ///                         outstanding debt by `account`.
    ///               numAccounts The number of accounts to be, potentially,
    ///                           liquidated.
    ///               liquidateExact Whether the liquidator desires a
    ///                              specific liquidation amount.
    ///               collateralLiquidated Empty variable slot to store how
    ///                                    much `collateralToken` will be
    ///                                    seized as part of a particular
    ///                                    liquidation.
    ///               debtRepaid Empty variable slot to store how much
    ///                          `debtToken` will be repaid as part of a
    ///                          particular liquidation.
    ///               badDebt Empty variable slot to store how much bad debt
    ///                       will be realized as part of a particular
    ///                       liquidation.
    /// @return result A LiqResult struct containing:
    ///                liquidatedShares An array containing the collateral
    ///                                 amounts to liquidate from
    ///                                 `accounts`.
    ///                debtRepaid The total amount of debt to repay from
    ///                           `accounts`.
    ///                badDebtRealized The total amount of debt to realize as
    ///                                losses for lenders inside this market.
    /// @return An array containing the debt amounts to repay from
    ///        `accounts`, in assets.
    function canLiquidate(
        uint256[] memory debtAmounts,
        address liquidator,
        address[] calldata accounts,
        IMarketManager.LiqAction memory action
    ) external returns (LiqResult memory, uint256[] memory);

    /// @notice Checks if the seizing of `collateralToken` by repayment of
    ///         `debtToken` should be allowed.
    /// @param collateralToken The Curvance token which was used as collateral
    ///                        and will be seized.
    /// @param debtToken The Curvance token which has outstanding debt to and
    ///                  would be repaid during `collateralToken` seizure.
    function canSeize(address collateralToken, address debtToken) external;

    /// @notice Checks if the account should be allowed to transfer collateral
    ///         tokens in the given market.
    /// @param cToken The Curvance token to verify the transfer of.
    /// @param shares The amount of `cToken` to transfer.
    /// @param account The account which will transfer `shares`.
    /// @param balanceOf The current balance that `account` has of `cToken`
    ///                  shares.
    /// @param collateralPosted The amount of `cToken` shares posted as
    ///                         collateral by `account`.
    /// @param isCollateral Boolean indicating whether the token is currently
    ///                     being used as collateral.
    function canTransfer(
        address cToken,
        uint256 shares,
        address account,
        uint256 balanceOf,
        uint256 collateralPosted,
        bool isCollateral
    ) external returns (uint256);

    /// @notice Updates `account` cooldownTimestamp to the current block
    ///         timestamp.
    /// @dev The caller must be a listed cToken in the `markets` mapping.
    /// @param cToken The address of the token that the account is borrowing.
    /// @param account The address of the account that has just borrowed.
    function notifyBorrow(address cToken, address account) external;

    /// @notice A list of all tokens inside this market for
    ///         offchain querying.
    function queryTokensListed() external view returns (address[] memory);

    /// @notice Returns whether `cToken` is listed in the lending market.
    /// @param cToken market token address.
    function isListed(address cToken) external view returns (bool);

    /// @notice The total amount of `cToken` that can be posted as collateral,
    ///         in shares.
    function collateralCaps(address cToken) external view returns (uint256);

    /// @notice The total amount of `cToken` underlying that can be borrowed,
    ///         in assets.
    function debtCaps(address cToken) external view returns (uint256);

    /// @notice Returns whether `addressToCheck` is an approved position
    ///         manager or not.
    /// @param addressToCheck Address to check for position management
    ///                       authority.
    function isPositionManager(
        address addressToCheck
    ) external view returns (bool);

    /// @notice Returns the assets an account has entered.
    /// @param account The address of the account to pull assets for.
    /// @return A dynamic list with the assets `account` has entered.
    function assetsOf(
        address account
    ) external view returns (address[] memory);

    /// @notice Determine `account`'s current status between collateral,
    ///         debt, and additional liquidity.
    /// @param account The account to determine liquidity for.
    /// @return The current total collateral amount of `account`.
    /// @return The maximum debt amount of `account` can take out with
    ///         their current collateral.
    /// @return The current total borrow amount of `account`.
    function statusOf(
        address account
    ) external returns (uint256, uint256, uint256);
}

// contracts/interfaces/IMulticallChecker.sol

interface IMulticallChecker {
    function checkCalldata(
        address caller,
        address target,
        bytes memory data
    ) external;
}

// contracts/interfaces/IOracleAdaptor.sol

interface IOracleAdaptor {
    /// TYPES ///

    /// @notice Return data from pricing an asset.
    /// @param price The price of the asset.
    /// @param inUsd Boolean indicating whether `price` is denominated
    ///              in USD (true) or native token (false).
    /// @param hadError Boolean indicating whether the asset was priced
    ///                 without running into any issues or not.
    struct PricingResult {
        uint256 price;
        bool inUSD;
        bool hadError;
    }

    /// @notice Guard logic when pricing `asset` configured to prevent oracle
    ///         mispricing either by mistake or malicious PriceGuard when
    ///         pricing `asset` denominated either USD or native tokens.
    /// @param timestampStart When `increasePerYear` should start increasing
    ///                       `basePrice` raising the maximum price returned
    ///                       when pricing `asset`.
    /// @param ips The magnitude that `basePrice` should increase overtime
    ///            from `timestampStart`, in `WAD`, per second.
    /// @param basePrice The base price that should be the maximum price
    ///                  returned when pricing `asset`.
    /// @param minPrice The minimum price that should be allowed to be
    ///                 returned when pricing `asset`.
    struct PriceGuard {
        uint40 timestampStart;
        uint40 ips;
        uint88 basePrice;
        uint88 minPrice;
    }

    /// @notice Called by OracleManager to price an asset.
    /// @param asset The address of the asset for which the price is needed.
    /// @param inUSD A boolean to determine if the price should be returned in
    ///              USD or not.
    /// @param getLower A boolean to determine if lower of two oracle prices
    ///                 should be retrieved.
    /// @return result Return data for a priced asset containing:
    ///                price The price of the asset.
    ///                inUSD Boolean indicating whether `price` is denominated
    ///                      in USD (true) or native token (false).
    ///                hadError Boolean indicating whether the asset was priced
    ///                         without running into any issues or not.
    function getPrice(
        address asset,
        bool inUSD,
        bool getLower
    ) external view returns (PricingResult memory);

    /// @notice Whether an asset is supported by the Oracle Adaptor or not.
    /// @dev Asset => Supported by adaptor.
    function isSupportedAsset(address asset) external view returns (bool);

    /// @notice Token price guard configuration for pricing an asset.
    /// @dev Token address => inUSD => Price Guard configuration.
    function getPriceGuard(
        address asset,
        bool inUSD
    ) external view returns (PriceGuard memory);

    /// @notice Returns the adaptor's type.
    /// @dev Used by frontends to determine how to properly interact
    ///      with a supported asset.
    function adaptorType() external view returns (uint256);
}

// contracts/libraries/LowLevelCallsHelper.sol

library LowLevelCallsHelper {
    /// ERRORS ///

    error LowLevelCallsHelper__InsufficientBalance();
    error LowLevelCallsHelper__CallFailed();

    /// INTERNAL FUNCTIONS ///

    /// @notice Executes a low level .call() and validates that execution
    ///         was safely performed.
    /// @dev Bubbles up errors and reverts if anything along the execution
    ///      path failed or was a red flag.
    /// @param target The target contract address to execute .call() at.
    /// @param data The bytecode data to attach to the .call() execution
    ///             including the function signature hash and function call
    ///             parameters.
    function _call(
        address target,
        bytes memory data
    ) internal returns (bytes memory) {
        (bool success, bytes memory returnData) = target.call{value: 0}(data);
        
        return _verifyResult(target, success, returnData);
    }

    /// @notice Executes a low level .call(), with attached native token
    ///         and validates that execution was safely performed.
    /// @dev Bubbles up errors and reverts if anything along the execution
    ///      path failed or was a red flag.
    /// @param target The target contract address to execute .call() at.
    /// @param data The bytecode data to attach to the .call() execution
    ///             including the function signature hash and function call
    ///             parameters.
    /// @param value The amount of native token to attach to the low level
    ///              call.
    function _callWithNative(
        address target,
        bytes memory data,
        uint256 value
    ) internal returns (bytes memory) {
        if (address(this).balance < value) {
            revert LowLevelCallsHelper__InsufficientBalance();
        }

        (bool success, bytes memory returnData) = target.call{
            value: value
        }(data);

        return _verifyResult(target, success, returnData);
    }

    /// @notice Executes a low level .delegatecall() and validates that
    ///         execution was safely performed.
    /// @dev Bubbles up errors and reverts if anything along the execution
    ///      path failed or was a red flag.
    /// @param target The target contract address to execute .delegatecall()
    ///               at.
    /// @param data The bytecode data to attach to the .call() execution
    ///             including the function signature hash and function call
    ///             parameters.
    function _delegateCall(
        address target,
        bytes memory data
    ) internal returns (bytes memory) {
        (bool success, bytes memory returnData) = target.delegatecall(data);

        return _verifyResult(target, success, returnData);
    }

    /// @dev Validates whether the low level call or delegate call was
    ///      successful and reverts in cases of bubbled up revert messages
    ///      or if `target` was not actually a contract.
    function _verifyResult(
        address target,
        bool success,
        bytes memory returnData
    ) internal view returns (bytes memory) {
        _propagateError(success, returnData);

        // If the call was successful but there was no return data we need
        // to make sure a contract was actually called as expected.
        if (returnData.length == 0 && target.code.length == 0) {
            revert LowLevelCallsHelper__CallFailed();
        }

        return returnData;
    }

    /// @dev Propagates an error message, if necessary.
    /// @param success If transaction was successful.
    /// @param resultData The transaction result data.
    function _propagateError(
        bool success,
        bytes memory resultData
    ) internal pure {
        if (!success) {
            if (resultData.length == 0) {
                revert LowLevelCallsHelper__CallFailed();
            }

            // Bubble up error if there was one given.
            assembly {
                revert(add(32, resultData), mload(resultData))
            }
        }
    }
}

// contracts/libraries/ReentrancyGuardTransient.sol

/// @notice Reentrancy guard mixin.
/// @author Solady (https://github.com/vectorized/solady/blob/main/src/utils/ReentrancyGuardTransient.sol)
/// @dev Mai: Edited to always use transient storage.
abstract contract ReentrancyGuard {
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       CUSTOM ERRORS                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev Unauthorized reentrant call.
    error Reentrancy();

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          STORAGE                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev Equivalent to: `uint32(bytes4(keccak256("Reentrancy()"))) | 1 << 71`.
    /// 9 bytes is large enough to avoid collisions in practice,
    /// but not too large to result in excessive bytecode bloat.
    uint256 private constant _REENTRANCY_GUARD_SLOT = 0x8000000000ab143c06;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      REENTRANCY GUARD                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev Guards a function from reentrancy.
    modifier nonReentrant() virtual {
        /// @solidity memory-safe-assembly
        assembly {
            if tload(_REENTRANCY_GUARD_SLOT) {
                mstore(0x00, 0xab143c06) // `Reentrancy()`.
                revert(0x1c, 0x04)
            }
            tstore(_REENTRANCY_GUARD_SLOT, address())
        }
        _;
        /// @solidity memory-safe-assembly
        assembly {
            tstore(_REENTRANCY_GUARD_SLOT, 0)
        }
    }

    /// @dev Guards a view function from read-only reentrancy.
    modifier nonReadReentrant() virtual {
        /// @solidity memory-safe-assembly
        assembly {
            if tload(_REENTRANCY_GUARD_SLOT) {
                mstore(0x00, 0xab143c06) // `Reentrancy()`.
                revert(0x1c, 0x04)
            }
        }
        _;
    }
}

// contracts/libraries/external/SafeTransferLib.sol

/// @notice Safe ETH and ERC20 transfer library that gracefully handles missing return values.
/// @author Solady (https://github.com/vectorized/solady/blob/main/src/utils/SafeTransferLib.sol)
/// @author Modified from Solmate (https://github.com/transmissions11/solmate/blob/main/src/utils/SafeTransferLib.sol)
///
/// @dev Note:
/// - For ETH transfers, please use `forceSafeTransferETH` for DoS protection.
/// - For ERC20s, this implementation won't check that a token has code,
///   responsibility is delegated to the caller.
library SafeTransferLib {
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       CUSTOM ERRORS                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev The ETH transfer has failed.
    error ETHTransferFailed();

    /// @dev The ERC20 `transferFrom` has failed.
    error TransferFromFailed();

    /// @dev The ERC20 `transfer` has failed.
    error TransferFailed();

    /// @dev The ERC20 `approve` has failed.
    error ApproveFailed();

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         CONSTANTS                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev Suggested gas stipend for contract receiving ETH that disallows any storage writes.
    uint256 internal constant GAS_STIPEND_NO_STORAGE_WRITES = 2300;

    /// @dev Suggested gas stipend for contract receiving ETH to perform a few
    /// storage reads and writes, but low enough to prevent griefing.
    uint256 internal constant GAS_STIPEND_NO_GRIEF = 100000;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       ETH OPERATIONS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    // If the ETH transfer MUST succeed with a reasonable gas budget, use the force variants.
    //
    // The regular variants:
    // - Forwards all remaining gas to the target.
    // - Reverts if the target reverts.
    // - Reverts if the current contract has insufficient balance.
    //
    // The force variants:
    // - Forwards with an optional gas stipend
    //   (defaults to `GAS_STIPEND_NO_GRIEF`, which is sufficient for most cases).
    // - If the target reverts, or if the gas stipend is exhausted,
    //   creates a temporary contract to force send the ETH via `SELFDESTRUCT`.
    //   Future compatible with `SENDALL`: https://eips.ethereum.org/EIPS/eip-4758.
    // - Reverts if the current contract has insufficient balance.
    //
    // The try variants:
    // - Forwards with a mandatory gas stipend.
    // - Instead of reverting, returns whether the transfer succeeded.

    /// @dev Sends `amount` (in wei) ETH to `to`.
    function safeTransferETH(address to, uint256 amount) internal {
        /// @solidity memory-safe-assembly
        assembly {
            if iszero(call(gas(), to, amount, codesize(), 0x00, codesize(), 0x00)) {
                mstore(0x00, 0xb12d13eb) // `ETHTransferFailed()`.
                revert(0x1c, 0x04)
            }
        }
    }

    /// @dev Sends all the ETH in the current contract to `to`.
    function safeTransferAllETH(address to) internal {
        /// @solidity memory-safe-assembly
        assembly {
            // Transfer all the ETH and check if it succeeded or not.
            if iszero(call(gas(), to, selfbalance(), codesize(), 0x00, codesize(), 0x00)) {
                mstore(0x00, 0xb12d13eb) // `ETHTransferFailed()`.
                revert(0x1c, 0x04)
            }
        }
    }

    /// @dev Force sends `amount` (in wei) ETH to `to`, with a `gasStipend`.
    function forceSafeTransferETH(address to, uint256 amount, uint256 gasStipend) internal {
        /// @solidity memory-safe-assembly
        assembly {
            if lt(selfbalance(), amount) {
                mstore(0x00, 0xb12d13eb) // `ETHTransferFailed()`.
                revert(0x1c, 0x04)
            }
            if iszero(call(gasStipend, to, amount, codesize(), 0x00, codesize(), 0x00)) {
                mstore(0x00, to) // Store the address in scratch space.
                mstore8(0x0b, 0x73) // Opcode `PUSH20`.
                mstore8(0x20, 0xff) // Opcode `SELFDESTRUCT`.
                if iszero(create(amount, 0x0b, 0x16)) { revert(codesize(), codesize()) } // For gas estimation.
            }
        }
    }

    /// @dev Force sends all the ETH in the current contract to `to`, with a `gasStipend`.
    function forceSafeTransferAllETH(address to, uint256 gasStipend) internal {
        /// @solidity memory-safe-assembly
        assembly {
            if iszero(call(gasStipend, to, selfbalance(), codesize(), 0x00, codesize(), 0x00)) {
                mstore(0x00, to) // Store the address in scratch space.
                mstore8(0x0b, 0x73) // Opcode `PUSH20`.
                mstore8(0x20, 0xff) // Opcode `SELFDESTRUCT`.
                if iszero(create(selfbalance(), 0x0b, 0x16)) { revert(codesize(), codesize()) } // For gas estimation.
            }
        }
    }

    /// @dev Force sends `amount` (in wei) ETH to `to`, with `GAS_STIPEND_NO_GRIEF`.
    function forceSafeTransferETH(address to, uint256 amount) internal {
        /// @solidity memory-safe-assembly
        assembly {
            if lt(selfbalance(), amount) {
                mstore(0x00, 0xb12d13eb) // `ETHTransferFailed()`.
                revert(0x1c, 0x04)
            }
            if iszero(call(GAS_STIPEND_NO_GRIEF, to, amount, codesize(), 0x00, codesize(), 0x00)) {
                mstore(0x00, to) // Store the address in scratch space.
                mstore8(0x0b, 0x73) // Opcode `PUSH20`.
                mstore8(0x20, 0xff) // Opcode `SELFDESTRUCT`.
                if iszero(create(amount, 0x0b, 0x16)) { revert(codesize(), codesize()) } // For gas estimation.
            }
        }
    }

    /// @dev Force sends all the ETH in the current contract to `to`, with `GAS_STIPEND_NO_GRIEF`.
    function forceSafeTransferAllETH(address to) internal {
        /// @solidity memory-safe-assembly
        assembly {
            // forgefmt: disable-next-item
            if iszero(call(GAS_STIPEND_NO_GRIEF, to, selfbalance(), codesize(), 0x00, codesize(), 0x00)) {
                mstore(0x00, to) // Store the address in scratch space.
                mstore8(0x0b, 0x73) // Opcode `PUSH20`.
                mstore8(0x20, 0xff) // Opcode `SELFDESTRUCT`.
                if iszero(create(selfbalance(), 0x0b, 0x16)) { revert(codesize(), codesize()) } // For gas estimation.
            }
        }
    }

    /// @dev Sends `amount` (in wei) ETH to `to`, with a `gasStipend`.
    function trySafeTransferETH(address to, uint256 amount, uint256 gasStipend)
        internal
        returns (bool success)
    {
        /// @solidity memory-safe-assembly
        assembly {
            success := call(gasStipend, to, amount, codesize(), 0x00, codesize(), 0x00)
        }
    }

    /// @dev Sends all the ETH in the current contract to `to`, with a `gasStipend`.
    function trySafeTransferAllETH(address to, uint256 gasStipend)
        internal
        returns (bool success)
    {
        /// @solidity memory-safe-assembly
        assembly {
            success := call(gasStipend, to, selfbalance(), codesize(), 0x00, codesize(), 0x00)
        }
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      ERC20 OPERATIONS                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev Sends `amount` of ERC20 `token` from `from` to `to`.
    /// Reverts upon failure.
    ///
    /// The `from` account must have at least `amount` approved for
    /// the current contract to manage.
    function safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        /// @solidity memory-safe-assembly
        assembly {
            let m := mload(0x40) // Cache the free memory pointer.
            mstore(0x60, amount) // Store the `amount` argument.
            mstore(0x40, to) // Store the `to` argument.
            mstore(0x2c, shl(96, from)) // Store the `from` argument.
            mstore(0x0c, 0x23b872dd000000000000000000000000) // `transferFrom(address,address,uint256)`.
            // Perform the transfer, reverting upon failure.
            if iszero(
                and( // The arguments of `and` are evaluated from right to left.
                    or(eq(mload(0x00), 1), iszero(returndatasize())), // Returned 1 or nothing.
                    call(gas(), token, 0, 0x1c, 0x64, 0x00, 0x20)
                )
            ) {
                mstore(0x00, 0x7939f424) // `TransferFromFailed()`.
                revert(0x1c, 0x04)
            }
            mstore(0x60, 0) // Restore the zero slot to zero.
            mstore(0x40, m) // Restore the free memory pointer.
        }
    }

    /// @dev Sends all of ERC20 `token` from `from` to `to`.
    /// Reverts upon failure.
    ///
    /// The `from` account must have their entire balance approved for
    /// the current contract to manage.
    function safeTransferAllFrom(address token, address from, address to)
        internal
        returns (uint256 amount)
    {
        /// @solidity memory-safe-assembly
        assembly {
            let m := mload(0x40) // Cache the free memory pointer.
            mstore(0x40, to) // Store the `to` argument.
            mstore(0x2c, shl(96, from)) // Store the `from` argument.
            mstore(0x0c, 0x70a08231000000000000000000000000) // `balanceOf(address)`.
            // Read the balance, reverting upon failure.
            if iszero(
                and( // The arguments of `and` are evaluated from right to left.
                    gt(returndatasize(), 0x1f), // At least 32 bytes returned.
                    staticcall(gas(), token, 0x1c, 0x24, 0x60, 0x20)
                )
            ) {
                mstore(0x00, 0x7939f424) // `TransferFromFailed()`.
                revert(0x1c, 0x04)
            }
            mstore(0x00, 0x23b872dd) // `transferFrom(address,address,uint256)`.
            amount := mload(0x60) // The `amount` is already at 0x60. We'll need to return it.
            // Perform the transfer, reverting upon failure.
            if iszero(
                and( // The arguments of `and` are evaluated from right to left.
                    or(eq(mload(0x00), 1), iszero(returndatasize())), // Returned 1 or nothing.
                    call(gas(), token, 0, 0x1c, 0x64, 0x00, 0x20)
                )
            ) {
                mstore(0x00, 0x7939f424) // `TransferFromFailed()`.
                revert(0x1c, 0x04)
            }
            mstore(0x60, 0) // Restore the zero slot to zero.
            mstore(0x40, m) // Restore the free memory pointer.
        }
    }

    /// @dev Sends `amount` of ERC20 `token` from the current contract to `to`.
    /// Reverts upon failure.
    function safeTransfer(address token, address to, uint256 amount) internal {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x14, to) // Store the `to` argument.
            mstore(0x34, amount) // Store the `amount` argument.
            mstore(0x00, 0xa9059cbb000000000000000000000000) // `transfer(address,uint256)`.
            // Perform the transfer, reverting upon failure.
            if iszero(
                and( // The arguments of `and` are evaluated from right to left.
                    or(eq(mload(0x00), 1), iszero(returndatasize())), // Returned 1 or nothing.
                    call(gas(), token, 0, 0x10, 0x44, 0x00, 0x20)
                )
            ) {
                mstore(0x00, 0x90b8ec18) // `TransferFailed()`.
                revert(0x1c, 0x04)
            }
            mstore(0x34, 0) // Restore the part of the free memory pointer that was overwritten.
        }
    }

    /// @dev Sends all of ERC20 `token` from the current contract to `to`.
    /// Reverts upon failure.
    function safeTransferAll(address token, address to) internal returns (uint256 amount) {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x00, 0x70a08231) // Store the function selector of `balanceOf(address)`.
            mstore(0x20, address()) // Store the address of the current contract.
            // Read the balance, reverting upon failure.
            if iszero(
                and( // The arguments of `and` are evaluated from right to left.
                    gt(returndatasize(), 0x1f), // At least 32 bytes returned.
                    staticcall(gas(), token, 0x1c, 0x24, 0x34, 0x20)
                )
            ) {
                mstore(0x00, 0x90b8ec18) // `TransferFailed()`.
                revert(0x1c, 0x04)
            }
            mstore(0x14, to) // Store the `to` argument.
            amount := mload(0x34) // The `amount` is already at 0x34. We'll need to return it.
            mstore(0x00, 0xa9059cbb000000000000000000000000) // `transfer(address,uint256)`.
            // Perform the transfer, reverting upon failure.
            if iszero(
                and( // The arguments of `and` are evaluated from right to left.
                    or(eq(mload(0x00), 1), iszero(returndatasize())), // Returned 1 or nothing.
                    call(gas(), token, 0, 0x10, 0x44, 0x00, 0x20)
                )
            ) {
                mstore(0x00, 0x90b8ec18) // `TransferFailed()`.
                revert(0x1c, 0x04)
            }
            mstore(0x34, 0) // Restore the part of the free memory pointer that was overwritten.
        }
    }

    /// @dev Sets `amount` of ERC20 `token` for `to` to manage on behalf of the current contract.
    /// Reverts upon failure.
    function safeApprove(address token, address to, uint256 amount) internal {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x14, to) // Store the `to` argument.
            mstore(0x34, amount) // Store the `amount` argument.
            mstore(0x00, 0x095ea7b3000000000000000000000000) // `approve(address,uint256)`.
            // Perform the approval, reverting upon failure.
            if iszero(
                and( // The arguments of `and` are evaluated from right to left.
                    or(eq(mload(0x00), 1), iszero(returndatasize())), // Returned 1 or nothing.
                    call(gas(), token, 0, 0x10, 0x44, 0x00, 0x20)
                )
            ) {
                mstore(0x00, 0x3e3f8f73) // `ApproveFailed()`.
                revert(0x1c, 0x04)
            }
            mstore(0x34, 0) // Restore the part of the free memory pointer that was overwritten.
        }
    }

    /// @dev Sets `amount` of ERC20 `token` for `to` to manage on behalf of the current contract.
    /// If the initial attempt to approve fails, attempts to reset the approved amount to zero,
    /// then retries the approval again (some tokens, e.g. USDT, requires this).
    /// Reverts upon failure.
    function safeApproveWithRetry(address token, address to, uint256 amount) internal {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x14, to) // Store the `to` argument.
            mstore(0x34, amount) // Store the `amount` argument.
            mstore(0x00, 0x095ea7b3000000000000000000000000) // `approve(address,uint256)`.
            // Perform the approval, retrying upon failure.
            if iszero(
                and( // The arguments of `and` are evaluated from right to left.
                    or(eq(mload(0x00), 1), iszero(returndatasize())), // Returned 1 or nothing.
                    call(gas(), token, 0, 0x10, 0x44, 0x00, 0x20)
                )
            ) {
                mstore(0x34, 0) // Store 0 for the `amount`.
                mstore(0x00, 0x095ea7b3000000000000000000000000) // `approve(address,uint256)`.
                pop(call(gas(), token, 0, 0x10, 0x44, codesize(), 0x00)) // Reset the approval.
                mstore(0x34, amount) // Store back the original `amount`.
                // Retry the approval, reverting upon failure.
                if iszero(
                    and(
                        or(eq(mload(0x00), 1), iszero(returndatasize())), // Returned 1 or nothing.
                        call(gas(), token, 0, 0x10, 0x44, 0x00, 0x20)
                    )
                ) {
                    mstore(0x00, 0x3e3f8f73) // `ApproveFailed()`.
                    revert(0x1c, 0x04)
                }
            }
            mstore(0x34, 0) // Restore the part of the free memory pointer that was overwritten.
        }
    }

    /// @dev Returns the amount of ERC20 `token` owned by `account`.
    /// Returns zero if the `token` does not exist.
    function balanceOf(address token, address account) internal view returns (uint256 amount) {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x14, account) // Store the `account` argument.
            mstore(0x00, 0x70a08231000000000000000000000000) // `balanceOf(address)`.
            amount :=
                mul(
                    mload(0x20),
                    and( // The arguments of `and` are evaluated from right to left.
                        gt(returndatasize(), 0x1f), // At least 32 bytes returned.
                        staticcall(gas(), token, 0x10, 0x24, 0x20, 0x20)
                    )
                )
        }
    }
}

// contracts/libraries/external/ERC165.sol

/**
 * @dev Implementation of the {IERC165} interface.
 *
 * Contracts that want to implement ERC165 should inherit from this contract and override {supportsInterface} to check
 * for the additional interface id that will be supported. For example:
 *
 * ```solidity
 * function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
 *     return interfaceId == type(MyInterface).interfaceId || super.supportsInterface(interfaceId);
 * }
 * ```
 *
 * Alternatively, {ERC165Storage} provides an easier to use but more expensive implementation.
 */
abstract contract ERC165 is IERC165 {
    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override returns (bool) {
        return interfaceId == type(IERC165).interfaceId;
    }
}

// contracts/libraries/external/ERC165Checker.sol

// @author Modified from OpenZeppelin Contracts (utils/introspection/ERC165Checker.sol)

/**
 * @dev Library used to query support of an interface declared via {IERC165}.
 *
 * Note that these functions return the actual result of the query: they do not
 * `revert` if an interface is not supported. It is up to the caller to decide
 * what to do in these cases.
 */
library ERC165Checker {
    // As per the EIP-165 spec, no interface should ever match 0xffffffff
    bytes4 private constant _INTERFACE_ID_INVALID = 0xffffffff;

    /**
     * @dev Returns true if `account` supports the {IERC165} interface.
     */
    function supportsERC165(address account) internal view returns (bool) {
        // Any contract that implements ERC165 must explicitly indicate support of
        // InterfaceId_ERC165 and explicitly indicate non-support of InterfaceId_Invalid
        return
            supportsERC165InterfaceUnchecked(
                account,
                type(IERC165).interfaceId
            ) &&
            !supportsERC165InterfaceUnchecked(account, _INTERFACE_ID_INVALID);
    }

    /**
     * @dev Returns true if `account` supports the interface defined by
     * `interfaceId`. Support for {IERC165} itself is queried automatically.
     *
     * See {IERC165-supportsInterface}.
     */
    function supportsInterface(
        address account,
        bytes4 interfaceId
    ) internal view returns (bool) {
        // query support of both ERC165 as per the spec and support of _interfaceId
        return
            supportsERC165(account) &&
            supportsERC165InterfaceUnchecked(account, interfaceId);
    }

    /**
     * @notice Query if a contract implements an interface, does not check ERC165 support
     * @param account The address of the contract to query for support of an interface
     * @param interfaceId The interface identifier, as specified in ERC-165
     * @return true if the contract at account indicates support of the interface with
     * identifier interfaceId, false otherwise
     * @dev Assumes that account contains a contract that supports ERC165, otherwise
     * the behavior of this method is undefined. This precondition can be checked
     * with {supportsERC165}.
     *
     * Some precompiled contracts will falsely indicate support for a given interface, so caution
     * should be exercised when using this function.
     *
     * Interface identification is specified in ERC-165.
     */
    function supportsERC165InterfaceUnchecked(
        address account,
        bytes4 interfaceId
    ) internal view returns (bool) {
        // prepare call
        bytes memory encodedParams = abi.encodeCall(
            IERC165.supportsInterface,
            (interfaceId)
        );

        // perform static call
        bool success;
        uint256 returnSize;
        uint256 returnValue;
        assembly {
            success := staticcall(
                30000,
                account,
                add(encodedParams, 0x20),
                mload(encodedParams),
                0x00,
                0x20
            )
            returnSize := returndatasize()
            returnValue := mload(0x00)
        }

        return success && returnSize >= 0x20 && returnValue > 0;
    }
}

// contracts/interfaces/ILendingOptimizer.sol

/// @notice Interface for LendingOptimizer, an ERC4626-like vault that
///         allocates deposits across multiple cToken markets.
/// @dev Integrators can call inherited ERC4626 selectors through IERC4626,
///      but preview and max values are multi-market estimates, not strict
///      ERC4626 settlement guarantees. Actual entrypoint results can differ
///      after accrual, liquidity checks, and cToken rounding.
interface ILendingOptimizer {

    /// CONSTANTS ///

    function MAX_FEE_BPS() external view returns (uint256);
    function MAX_MARKETS() external view returns (uint256);

    /// IMMUTABLES ///

    function centralRegistry() external view returns (ICentralRegistry);

    /// STORAGE ///

    function approvedCTokensList(uint256 index) external view returns (address);
    function allocationCaps(address cToken) external view returns (uint256);
    function fee() external view returns (uint256);
    function exchangeRateHighWatermark() external view returns (uint256);
    function mintPaused() external view returns (uint8);

    /// ERC4626 OVERRIDES ///
    /// @dev Declared here so LendingOptimizer can use
    ///      `override(ERC4626, ILendingOptimizer)` for functions it
    ///      customizes beyond the base ERC4626 implementation.

    function asset() external view returns (address);
    function totalAssets() external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    /// OPTIMIZER-SPECIFIC ///

    function initializeDeposits(address targetMarket) external;
    function addApprovedAsset(address newAsset, uint256 capBps) external;
    function updateCap(address cToken, uint256 newCapBps) external;
    function setFee(uint256 newFeeBps) external;
    function setMintPaused(bool state) external;
    function exchangeRate() external view returns (uint256);
    function exchangeRateUpdated() external returns (uint256);
    function accrueIfNeeded() external;
    function skim() external;
    function skimAvailable() external view returns (uint256);
    function numApprovedMarkets() external view returns (uint256);
    function getApprovedMarkets() external view returns (address[] memory);
}

// contracts/libraries/CentralRegistryLib.sol

/// @title Curvance Central Registry Validation Library
/// @notice For validating that Central Registry is configured properly
///         on launch.
library CentralRegistryLib {
    /// ERRORS ///

    error CentralRegistryLib__InvalidCentralRegistry();

    /// INTERNAL FUNCTIONS ///

    /// @notice Validates that `cr` is the Protocol Central Registry.
    /// @param cr The proposed Protocol Central Registry.
    function _isCentralRegistry(ICentralRegistry cr) internal view {
        if (
            !ERC165Checker.supportsInterface(
                address(cr),
                type(ICentralRegistry).interfaceId
            )
        ) {
            revert CentralRegistryLib__InvalidCentralRegistry();
        }
    }
}

// contracts/libraries/external/ERC4626.sol

/// @notice Simple ERC4626 tokenized Vault implementation.
/// @author Solady (https://github.com/vectorized/solady/blob/main/src/tokens/ERC4626.sol)
/// @author Modified from Solmate (https://github.com/transmissions11/solmate/blob/main/src/mixins/ERC4626.sol)
/// @author Modified from OpenZeppelin (https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/extensions/ERC4626.sol)
abstract contract ERC4626 is ERC20 {
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         CONSTANTS                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev The default underlying decimals.
    uint8 internal constant _DEFAULT_UNDERLYING_DECIMALS = 18;

    /// @dev The default decimals offset.
    uint8 internal constant _DEFAULT_DECIMALS_OFFSET = 0;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       CUSTOM ERRORS                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev Cannot deposit more than the max limit.
    error DepositMoreThanMax();

    /// @dev Cannot mint more than the max limit.
    error MintMoreThanMax();

    /// @dev Cannot withdraw more than the max limit.
    error WithdrawMoreThanMax();

    /// @dev Cannot redeem more than the max limit.
    error RedeemMoreThanMax();

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                           EVENTS                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev Emitted during a mint call or deposit call.
    event Deposit(address indexed by, address indexed owner, uint256 assets, uint256 shares);

    /// @dev Emitted during a withdraw call or redeem call.
    event Withdraw(
        address indexed by,
        address indexed to,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    /// @dev `keccak256(bytes("Deposit(address,address,uint256,uint256)"))`.
    uint256 private constant _DEPOSIT_EVENT_SIGNATURE =
        0xdcbc1c05240f31ff3ad067ef1ee35ce4997762752e3a095284754544f4c709d7;

    /// @dev `keccak256(bytes("Withdraw(address,address,address,uint256,uint256)"))`.
    uint256 private constant _WITHDRAW_EVENT_SIGNATURE =
        0xfbde797d201c681b91056529119e0b02407c7bb96a4a2c75c01fc9667232c8db;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                     ERC4626 CONSTANTS                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev To be overridden to return the address of the underlying asset.
    ///
    /// - MUST be an ERC20 token contract.
    /// - MUST NOT revert.
    function asset() public view virtual returns (address);

    /// @dev To be overridden to return the number of decimals of the underlying asset.
    /// Default: 18.
    ///
    /// - MUST NOT revert.
    function _underlyingDecimals() internal view virtual returns (uint8) {
        return _DEFAULT_UNDERLYING_DECIMALS;
    }

    /// @dev Override to return a non-zero value to make the inflation attack even more unfeasible.
    /// Only used when {_useVirtualShares} returns true.
    /// Default: 0.
    ///
    /// - MUST NOT revert.
    function _decimalsOffset() internal view virtual returns (uint8) {
        return _DEFAULT_DECIMALS_OFFSET;
    }

    /// @dev Returns whether virtual shares will be used to mitigate the inflation attack.
    /// See: https://github.com/OpenZeppelin/openzeppelin-contracts/issues/3706
    /// Override to return true or false.
    /// Default: true.
    ///
    /// - MUST NOT revert.
    function _useVirtualShares() internal view virtual returns (bool) {
        return true;
    }

    /// @dev Returns the decimals places of the token.
    ///
    /// - MUST NOT revert.
    function decimals() public view virtual override(ERC20) returns (uint8) {
        if (!_useVirtualShares()) return _underlyingDecimals();
        return _underlyingDecimals() + _decimalsOffset();
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                ASSET DECIMALS GETTER HELPER                */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev Helper function to get the decimals of the underlying asset.
    /// Useful for setting the return value of `_underlyingDecimals` during initialization.
    /// If the retrieval succeeds, `success` will be true, and `result` will hold the result.
    /// Otherwise, `success` will be false, and `result` will be zero.
    ///
    /// Example usage:
    /// ```
    /// (bool success, uint8 result) = _tryGetAssetDecimals(underlying);
    /// _decimals = success ? result : _DEFAULT_UNDERLYING_DECIMALS;
    /// ```
    function _tryGetAssetDecimals(address underlying)
        internal
        view
        returns (bool success, uint8 result)
    {
        /// @solidity memory-safe-assembly
        assembly {
            // Store the function selector of `decimals()`.
            mstore(0x00, 0x313ce567)
            // Arguments are evaluated last to first.
            success :=
                and(
                    // Returned value is less than 256, at left-padded to 32 bytes.
                    and(lt(mload(0x00), 0x100), gt(returndatasize(), 0x1f)),
                    // The staticcall succeeds.
                    staticcall(gas(), underlying, 0x1c, 0x04, 0x00, 0x20)
                )
            result := mul(mload(0x00), success)
        }
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      ACCOUNTING LOGIC                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev Returns the total amount of the underlying asset managed by the Vault.
    ///
    /// - SHOULD include any compounding that occurs from the yield.
    /// - MUST be inclusive of any fees that are charged against assets in the Vault.
    /// - MUST NOT revert.
    function totalAssets() public view virtual returns (uint256 assets) {
        assets = SafeTransferLib.balanceOf(asset(), address(this));
    }

    /// @dev Returns the amount of shares that the Vault will exchange for the amount of
    /// assets provided, in an ideal scenario where all conditions are met.
    ///
    /// - MUST NOT be inclusive of any fees that are charged against assets in the Vault.
    /// - MUST NOT show any variations depending on the caller.
    /// - MUST NOT reflect slippage or other on-chain conditions, during the actual exchange.
    /// - MUST NOT revert.
    ///
    /// Note: This calculation MAY NOT reflect the "per-user" price-per-share, and instead
    /// should reflect the "average-user's" price-per-share, i.e. what the average user should
    /// expect to see when exchanging to and from.
    function convertToShares(uint256 assets) public view virtual returns (uint256 shares) {
        if (!_useVirtualShares()) {
            uint256 supply = totalSupply();
            return _eitherIsZero(assets, supply)
                ? _initialConvertToShares(assets)
                : FixedPointMathLib.fullMulDiv(assets, supply, totalAssets());
        }
        uint256 o = _decimalsOffset();
        if (o == uint256(0)) {
            return FixedPointMathLib.fullMulDiv(assets, totalSupply() + 1, _inc(totalAssets()));
        }
        return FixedPointMathLib.fullMulDiv(assets, totalSupply() + 10 ** o, _inc(totalAssets()));
    }

    /// @dev Returns the amount of assets that the Vault will exchange for the amount of
    /// shares provided, in an ideal scenario where all conditions are met.
    ///
    /// - MUST NOT be inclusive of any fees that are charged against assets in the Vault.
    /// - MUST NOT show any variations depending on the caller.
    /// - MUST NOT reflect slippage or other on-chain conditions, during the actual exchange.
    /// - MUST NOT revert.
    ///
    /// Note: This calculation MAY NOT reflect the "per-user" price-per-share, and instead
    /// should reflect the "average-user's" price-per-share, i.e. what the average user should
    /// expect to see when exchanging to and from.
    function convertToAssets(uint256 shares) public view virtual returns (uint256 assets) {
        if (!_useVirtualShares()) {
            uint256 supply = totalSupply();
            return supply == uint256(0)
                ? _initialConvertToAssets(shares)
                : FixedPointMathLib.fullMulDiv(shares, totalAssets(), supply);
        }
        uint256 o = _decimalsOffset();
        if (o == uint256(0)) {
            return FixedPointMathLib.fullMulDiv(shares, totalAssets() + 1, _inc(totalSupply()));
        }
        return FixedPointMathLib.fullMulDiv(shares, totalAssets() + 1, totalSupply() + 10 ** o);
    }

    /// @dev Allows an on-chain or off-chain user to simulate the effects of their deposit
    /// at the current block, given current on-chain conditions.
    ///
    /// - MUST return as close to and no more than the exact amount of Vault shares that
    ///   will be minted in a deposit call in the same transaction, i.e. deposit should
    ///   return the same or more shares as `previewDeposit` if call in the same transaction.
    /// - MUST NOT account for deposit limits like those returned from `maxDeposit` and should
    ///   always act as if the deposit will be accepted, regardless of approvals, etc.
    /// - MUST be inclusive of deposit fees. Integrators should be aware of this.
    /// - MUST not revert.
    ///
    /// Note: Any unfavorable discrepancy between `convertToShares` and `previewDeposit` SHOULD
    /// be considered slippage in share price or some other type of condition, meaning
    /// the depositor will lose assets by depositing.
    function previewDeposit(uint256 assets) public view virtual returns (uint256 shares) {
        shares = convertToShares(assets);
    }

    /// @dev Allows an on-chain or off-chain user to simulate the effects of their mint
    /// at the current block, given current on-chain conditions.
    ///
    /// - MUST return as close to and no fewer than the exact amount of assets that
    ///   will be deposited in a mint call in the same transaction, i.e. mint should
    ///   return the same or fewer assets as `previewMint` if called in the same transaction.
    /// - MUST NOT account for mint limits like those returned from `maxMint` and should
    ///   always act as if the mint will be accepted, regardless of approvals, etc.
    /// - MUST be inclusive of deposit fees. Integrators should be aware of this.
    /// - MUST not revert.
    ///
    /// Note: Any unfavorable discrepancy between `convertToAssets` and `previewMint` SHOULD
    /// be considered slippage in share price or some other type of condition,
    /// meaning the depositor will lose assets by minting.
    function previewMint(uint256 shares) public view virtual returns (uint256 assets) {
        if (!_useVirtualShares()) {
            uint256 supply = totalSupply();
            return supply == uint256(0)
                ? _initialConvertToAssets(shares)
                : FixedPointMathLib.fullMulDivUp(shares, totalAssets(), supply);
        }
        uint256 o = _decimalsOffset();
        if (o == uint256(0)) {
            return FixedPointMathLib.fullMulDivUp(shares, totalAssets() + 1, _inc(totalSupply()));
        }
        return FixedPointMathLib.fullMulDivUp(shares, totalAssets() + 1, totalSupply() + 10 ** o);
    }

    /// @dev Allows an on-chain or off-chain user to simulate the effects of their withdrawal
    /// at the current block, given the current on-chain conditions.
    ///
    /// - MUST return as close to and no fewer than the exact amount of Vault shares that
    ///   will be burned in a withdraw call in the same transaction, i.e. withdraw should
    ///   return the same or fewer shares as `previewWithdraw` if call in the same transaction.
    /// - MUST NOT account for withdrawal limits like those returned from `maxWithdraw` and should
    ///   always act as if the withdrawal will be accepted, regardless of share balance, etc.
    /// - MUST be inclusive of withdrawal fees. Integrators should be aware of this.
    /// - MUST not revert.
    ///
    /// Note: Any unfavorable discrepancy between `convertToShares` and `previewWithdraw` SHOULD
    /// be considered slippage in share price or some other type of condition,
    /// meaning the depositor will lose assets by depositing.
    function previewWithdraw(uint256 assets) public view virtual returns (uint256 shares) {
        if (!_useVirtualShares()) {
            uint256 supply = totalSupply();
            return _eitherIsZero(assets, supply)
                ? _initialConvertToShares(assets)
                : FixedPointMathLib.fullMulDivUp(assets, supply, totalAssets());
        }
        uint256 o = _decimalsOffset();
        if (o == uint256(0)) {
            return FixedPointMathLib.fullMulDivUp(assets, totalSupply() + 1, _inc(totalAssets()));
        }
        return FixedPointMathLib.fullMulDivUp(assets, totalSupply() + 10 ** o, _inc(totalAssets()));
    }

    /// @dev Allows an on-chain or off-chain user to simulate the effects of their redemption
    /// at the current block, given current on-chain conditions.
    ///
    /// - MUST return as close to and no more than the exact amount of assets that
    ///   will be withdrawn in a redeem call in the same transaction, i.e. redeem should
    ///   return the same or more assets as `previewRedeem` if called in the same transaction.
    /// - MUST NOT account for redemption limits like those returned from `maxRedeem` and should
    ///   always act as if the redemption will be accepted, regardless of approvals, etc.
    /// - MUST be inclusive of withdrawal fees. Integrators should be aware of this.
    /// - MUST NOT revert.
    ///
    /// Note: Any unfavorable discrepancy between `convertToAssets` and `previewRedeem` SHOULD
    /// be considered slippage in share price or some other type of condition,
    /// meaning the depositor will lose assets by depositing.
    function previewRedeem(uint256 shares) public view virtual returns (uint256 assets) {
        assets = convertToAssets(shares);
    }

    /// @dev Private helper to return if either value is zero.
    function _eitherIsZero(uint256 a, uint256 b) private pure returns (bool result) {
        /// @solidity memory-safe-assembly
        assembly {
            result := or(iszero(a), iszero(b))
        }
    }

    /// @dev Private helper to return `x + 1` without the overflow check.
    /// Used for computing the denominator input to `FixedPointMathLib.fullMulDiv(a, b, x + 1)`.
    /// When `x == type(uint256).max`, we get `x + 1 == 0` (mod 2**256 - 1),
    /// and `FixedPointMathLib.fullMulDiv` will revert as the denominator is zero.
    function _inc(uint256 x) private pure returns (uint256) {
        unchecked {
            return x + 1;
        }
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*              DEPOSIT / WITHDRAWAL LIMIT LOGIC              */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev Returns the maximum amount of the underlying asset that can be deposited
    /// into the Vault for `to`, via a deposit call.
    ///
    /// - MUST return a limited value if `to` is subject to some deposit limit.
    /// - MUST return `2**256-1` if there is no maximum limit.
    /// - MUST NOT revert.
    function maxDeposit(address to) public view virtual returns (uint256 maxAssets) {
        to = to; // Silence unused variable warning.
        maxAssets = type(uint256).max;
    }

    /// @dev Returns the maximum amount of the Vault shares that can be minter for `to`,
    /// via a mint call.
    ///
    /// - MUST return a limited value if `to` is subject to some mint limit.
    /// - MUST return `2**256-1` if there is no maximum limit.
    /// - MUST NOT revert.
    function maxMint(address to) public view virtual returns (uint256 maxShares) {
        to = to; // Silence unused variable warning.
        maxShares = type(uint256).max;
    }

    /// @dev Returns the maximum amount of the underlying asset that can be withdrawn
    /// from the `owner`'s balance in the Vault, via a withdraw call.
    ///
    /// - MUST return a limited value if `owner` is subject to some withdrawal limit or timelock.
    /// - MUST NOT revert.
    function maxWithdraw(address owner) public view virtual returns (uint256 maxAssets) {
        maxAssets = convertToAssets(balanceOf(owner));
    }

    /// @dev Returns the maximum amount of Vault shares that can be redeemed
    /// from the `owner`'s balance in the Vault, via a redeem call.
    ///
    /// - MUST return a limited value if `owner` is subject to some withdrawal limit or timelock.
    /// - MUST return `balanceOf(owner)` otherwise.
    /// - MUST NOT revert.
    function maxRedeem(address owner) public view virtual returns (uint256 maxShares) {
        maxShares = balanceOf(owner);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                 DEPOSIT / WITHDRAWAL LOGIC                 */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev Mints `shares` Vault shares to `to` by depositing exactly `assets`
    /// of underlying tokens.
    ///
    /// - MUST emit the {Deposit} event.
    /// - MAY support an additional flow in which the underlying tokens are owned by the Vault
    ///   contract before the deposit execution, and are accounted for during deposit.
    /// - MUST revert if all of `assets` cannot be deposited, such as due to deposit limit,
    ///   slippage, insufficient approval, etc.
    ///
    /// Note: Most implementations will require pre-approval of the Vault with the
    /// Vault's underlying `asset` token.
    function deposit(uint256 assets, address to) public virtual returns (uint256 shares) {
        if (assets > maxDeposit(to)) _revert(0xb3c61a83); // `DepositMoreThanMax()`.
        shares = previewDeposit(assets);
        _deposit(msg.sender, to, assets, shares);
    }

    /// @dev Mints exactly `shares` Vault shares to `to` by depositing `assets`
    /// of underlying tokens.
    ///
    /// - MUST emit the {Deposit} event.
    /// - MAY support an additional flow in which the underlying tokens are owned by the Vault
    ///   contract before the mint execution, and are accounted for during mint.
    /// - MUST revert if all of `shares` cannot be deposited, such as due to deposit limit,
    ///   slippage, insufficient approval, etc.
    ///
    /// Note: Most implementations will require pre-approval of the Vault with the
    /// Vault's underlying `asset` token.
    function mint(uint256 shares, address to) public virtual returns (uint256 assets) {
        if (shares > maxMint(to)) _revert(0x6a695959); // `MintMoreThanMax()`.
        assets = previewMint(shares);
        _deposit(msg.sender, to, assets, shares);
    }

    /// @dev Burns `shares` from `owner` and sends exactly `assets` of underlying tokens to `to`.
    ///
    /// - MUST emit the {Withdraw} event.
    /// - MAY support an additional flow in which the underlying tokens are owned by the Vault
    ///   contract before the withdraw execution, and are accounted for during withdraw.
    /// - MUST revert if all of `assets` cannot be withdrawn, such as due to withdrawal limit,
    ///   slippage, insufficient balance, etc.
    ///
    /// Note: Some implementations will require pre-requesting to the Vault before a withdrawal
    /// may be performed. Those methods should be performed separately.
    function withdraw(uint256 assets, address to, address owner)
        public
        virtual
        returns (uint256 shares)
    {
        if (assets > maxWithdraw(owner)) _revert(0x936941fc); // `WithdrawMoreThanMax()`.
        shares = previewWithdraw(assets);
        _withdraw(msg.sender, to, owner, assets, shares);
    }

    /// @dev Burns exactly `shares` from `owner` and sends `assets` of underlying tokens to `to`.
    ///
    /// - MUST emit the {Withdraw} event.
    /// - MAY support an additional flow in which the underlying tokens are owned by the Vault
    ///   contract before the redeem execution, and are accounted for during redeem.
    /// - MUST revert if all of shares cannot be redeemed, such as due to withdrawal limit,
    ///   slippage, insufficient balance, etc.
    ///
    /// Note: Some implementations will require pre-requesting to the Vault before a redeem
    /// may be performed. Those methods should be performed separately.
    function redeem(uint256 shares, address to, address owner)
        public
        virtual
        returns (uint256 assets)
    {
        if (shares > maxRedeem(owner)) _revert(0x4656425a); // `RedeemMoreThanMax()`.
        assets = previewRedeem(shares);
        _withdraw(msg.sender, to, owner, assets, shares);
    }

    /// @dev Internal helper for reverting efficiently.
    function _revert(uint256 s) internal pure {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x00, s)
            revert(0x1c, 0x04)
        }
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      INTERNAL HELPERS                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev For deposits and mints.
    ///
    /// Emits a {Deposit} event.
    function _deposit(address by, address to, uint256 assets, uint256 shares) internal virtual {
        SafeTransferLib.safeTransferFrom(asset(), by, address(this), assets);
        _mint(to, shares);
        /// @solidity memory-safe-assembly
        assembly {
            // Emit the {Deposit} event.
            mstore(0x00, assets)
            mstore(0x20, shares)
            let m := shr(96, not(0))
            log3(0x00, 0x40, _DEPOSIT_EVENT_SIGNATURE, and(m, by), and(m, to))
        }
        _afterDeposit(assets, shares);
    }

    /// @dev For withdrawals and redemptions.
    ///
    /// Emits a {Withdraw} event.
    function _withdraw(address by, address to, address owner, uint256 assets, uint256 shares)
        internal
        virtual
    {
        if (by != owner) _spendAllowance(owner, by, shares);
        _beforeWithdraw(assets, shares);
        _burn(owner, shares);
        SafeTransferLib.safeTransfer(asset(), to, assets);
        /// @solidity memory-safe-assembly
        assembly {
            // Emit the {Withdraw} event.
            mstore(0x00, assets)
            mstore(0x20, shares)
            let m := shr(96, not(0))
            log4(0x00, 0x40, _WITHDRAW_EVENT_SIGNATURE, and(m, by), and(m, to), and(m, owner))
        }
    }

    /// @dev Internal conversion function (from assets to shares) to apply when the Vault is empty.
    /// Only used when {_useVirtualShares} returns false.
    ///
    /// Note: Make sure to keep this function consistent with {_initialConvertToAssets}
    /// when overriding it.
    function _initialConvertToShares(uint256 assets)
        internal
        view
        virtual
        returns (uint256 shares)
    {
        shares = assets;
    }

    /// @dev Internal conversion function (from shares to assets) to apply when the Vault is empty.
    /// Only used when {_useVirtualShares} returns false.
    ///
    /// Note: Make sure to keep this function consistent with {_initialConvertToShares}
    /// when overriding it.
    function _initialConvertToAssets(uint256 shares)
        internal
        view
        virtual
        returns (uint256 assets)
    {
        assets = shares;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                     HOOKS TO OVERRIDE                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev Hook that is called before any withdrawal or redemption.
    function _beforeWithdraw(uint256 assets, uint256 shares) internal virtual {}

    /// @dev Hook that is called after any deposit or mint.
    function _afterDeposit(uint256 assets, uint256 shares) internal virtual {}
}

// contracts/libraries/Multicall.sol

/// @title Curvance Multicall helper.
/// @notice Multicall implementation to support pull based oracles and
///         other chained actions within Curvance.
abstract contract Multicall {
    /// TYPES ///

    /// @notice Struct containing information on the desired
    ///         multicall action to execute. 
    /// @param target The address of the target contract to execute the call at.
    /// @param isPriceUpdate Boolean indicating if the call is a price update.
    /// @param data The data to attach to the call.
    struct MulticallAction {
        address target;
        bool isPriceUpdate;
        bytes data;
    }

    /// ERRORS ///

    error Multicall__InvalidTarget();
    error Multicall__UnknownCalldata();

    /// EXTERNAL FUNCTIONS ///

    /// @notice Executes multiple calls in a single transaction.
    ///         This can be used to update oracle prices before
    ///         a liquidity dependent action.
    function multicall(
        MulticallAction[] calldata calls
    ) external returns (bytes[] memory results) {
        ICentralRegistry cr = _getCentralRegistry();
        uint256 numCalls = calls.length;
        results = new bytes[](numCalls);
        MulticallAction memory cachedCall;

        for (uint256 i; i < numCalls; ++i) {
            cachedCall = calls[i];
            
            if (cachedCall.isPriceUpdate) {
                // CASE: We need to update a pull based price oracle and we
                //       need a direct call to the target address.
                address checker = cr.multicallChecker(cachedCall.target);

                // Validate we know how to verify this calldata.
                if (checker == address(0)) {
                    revert Multicall__UnknownCalldata();
                }

                IMulticallChecker(checker).checkCalldata(
                    msg.sender,
                    cachedCall.target,
                    cachedCall.data
                );

                results[i] = LowLevelCallsHelper.
                    _call(cachedCall.target, cachedCall.data);
                
                continue;
            }

            // CASE: Not a price update and we need delegate the call to the
            //       current address.

            if (address(this) != cachedCall.target) {
                revert Multicall__InvalidTarget();
            }

            results[i] = LowLevelCallsHelper.
                _delegateCall(address(this), cachedCall.data);
        }
    }

    /// @notice Returns the Protocol Central Registry contract in interface
    ///         form.
    /// @dev MUST be overridden in every multicallable contract's
    ///      implementation.
    function _getCentralRegistry()
        internal
        view
        virtual
        returns (ICentralRegistry);
}

// contracts/libraries/CommonLib.sol

/// @title Curvance Common Library
/// @notice A utility library for common functions used throughout the
///        Curvance Protocol.
library CommonLib {

    /// @notice Returns whether `tokenA` matches `tokenB` or not.
    /// @param tokenA The first token address to compare.
    /// @param tokenB The second token address to compare.
    /// @return Whether `tokenA` matches `tokenB` or not.
    function _isMatchingToken(
        address tokenA,
        address tokenB
    ) internal pure returns (bool) {
        if (tokenA == tokenB) {
            return true;
        }

        if (_isNative(tokenA) && _isNative(tokenB)) {
            return true;
        }

        return false;
    }

    /// @notice Returns whether `token` is referring to network gas token
    ///         or not.
    /// @param token The address to review.
    /// @return result Whether `token` is referring to network gas token or
    ///                not.
    function _isNative(address token) internal pure returns (bool result) {
        result = token == address(0) ||
            token == 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    }

    /// @notice Returns balance of `token` for this contract.
    /// @param token The token address to query balance of.
    /// @return b The balance of `token` inside address(this).
    function _balanceOf(address token) internal view returns (uint256 b) {
        b = _isNative(token) ? address(this).balance :
            IERC20(token).balanceOf(address(this));
    }

    /// @notice Returns the Oracle Manager in interface form from `cr`.
    /// @param cr The address of the Protocol Central Registry.
    /// @return oracleManager The Oracle Manager in interface form.
    function _oracleManager(
        ICentralRegistry cr
    ) internal view returns (IOracleManager oracleManager) {
        oracleManager = IOracleManager(cr.oracleManager());
    }
}

// contracts/interfaces/IBorrowableCToken.sol

interface IBorrowableCToken {
    /// ICToken GENERIC FUNCTIONS ///

    /// @notice Starts a cToken market, executed via marketManager.
    /// @dev This initial mint is a failsafe against rounding exploits,
    ///      although, we protect against them in many ways,
    ///      better safe than sorry.
    /// @param by The account initializing deposits.
    function initializeDeposits(address by) external returns (bool);

    /// @notice Returns the decimals of the cToken.
    /// @dev We pull directly from underlying incase its a proxy contract,
    ///      and changes decimals on us.
    /// @return The number of decimals for this cToken,
    ///         matching the underlying token.
    function decimals() external view returns (uint8);

    /// @notice Returns whether the underlying token can be borrowed.
    /// @dev true = Borrowable; false = Not Borrowable.
    /// @return Whether this token is borrowable or not.
    function isBorrowable() external view returns (bool);

    /// @notice The token balance of an account.
    /// @dev Account address => account token balance.
    /// @param account The address of the account to query token balance for.
    function balanceOf(address account) external view returns (uint256);

    /// @notice Returns the address of the underlying asset.
    /// @return The address of the underlying asset.
    function asset() external view returns (address);

    /// @notice Returns the current vesting yield information.
    /// @return vestingRate % per second in `asset()`.
    /// @return vestingEnd When the current vesting period ends and interest
    ///                    rates paid will update.
    /// @return lastVestingClaim Last time pending vested yield was claimed.
    /// @return debtIndex The current market debt index.
    function getYieldInformation() external view returns (
        uint256 vestingRate,
        uint256 vestingEnd,
        uint256 lastVestingClaim,
        uint256 debtIndex
    );

    /// @notice Get a snapshot of `account` data in this Curvance token.
    /// @dev Used by marketManager to more efficiently perform
    ///      liquidity checks.
    ///      NOTE: Does not accrue pending interest as part of the call.
    /// @param account The address of the account to snapshot.
    /// @return The account snapshot of `account`.
    function getSnapshot(
        address account
    ) external view returns (AccountSnapshot memory);

    /// @notice Total number of cTokens in circulation.
    function totalSupply() external view returns (uint256);

    /// @notice Returns the total amount of assets held by the market.
    /// @return The total amount of assets held by the market.
    function totalAssets() external view returns (uint256);

    /// @notice Address of the Market Manager linked to this contract.
    function marketManager() external view returns (IMarketManager);

    /// @notice Returns the amount of assets that would be exchanged
    ///         by the vault for `shares` provided.
    /// @param shares The number of shares to theoretically use
    ///               for conversion to assets.
    /// @return The number of assets a user would receive for converting
    ///         `shares`.
    function convertToAssets(uint256 shares) external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);

    /// @notice Returns share -> asset exchange rate, in `WAD`.
    /// @dev Oracle Manager calculates cToken value from this exchange rate.
    function exchangeRate() external view returns (uint256);

    /// @notice Executes multiple calls in a single transaction.
    ///         This can be used to update oracle prices before
    ///         a liquidity dependent action.
    function multicall(
        Multicall.MulticallAction[] memory calls
    ) external returns (bytes[] memory results);

    /// @notice Caller deposits `assets` into the market and `receiver`
    ///         receives shares.
    /// @param assets The amount of the underlying assets to deposit.
    /// @param receiver The account that should receive the shares.
    /// @return shares The amount of shares received by `receiver`.
    function deposit(
        uint256 assets,
        address receiver
    ) external returns (uint256 shares);

    /// @notice Caller deposits `assets` into the market, `receiver` receives
    ///         shares, and collateralization of `assets` is enabled.
    /// @dev The caller must be depositing for themselves, or be managing
    ///      their position through a Position Manager contract.
    ///      If the caller is not approved to collateralize the function will
    ///      simply deposit assets on behalf of `receiver`.
    /// @param assets The amount of the underlying assets to deposit.
    /// @param receiver The account that should receive the shares.
    /// @return shares The amount of shares received by `receiver`.
    function depositAsCollateral(
        uint256 assets,
        address receiver
    ) external returns (uint256 shares);

    /// @notice Caller deposits `assets` into the market, `receiver` receives
    ///         shares, and collateralization of `assets` is enabled.
    /// @dev Requires that `receiver` approves the caller prior to
    ///      collateralize on their behalf.
    ///      NOTE: Be careful who you approve here!
    ///      They can delay redemption of assets through repeated
    ///      collateralization preventing withdrawal.
    ///      If the caller is not approved to collateralize the function will
    ///      simply deposit assets on behalf of `receiver`.
    /// @param assets The amount of the underlying assets to deposit.
    /// @param receiver The account that should receive the shares.
    /// @return shares The amount of shares received by `receiver`.
    function depositAsCollateralFor(
        uint256 assets,
        address receiver
    ) external returns (uint256 shares);

    /// @notice Withdraws assets, quoted in `shares` from the market,
    ///         and burns `owner` shares.
    /// @dev Does not force collateral to be withdrawn.
    /// @param shares The amount of shares to be redeemed.
    /// @param receiver The account that should receive the assets.
    /// @param owner The account that will burn their shares to withdraw
    ///              assets.
    /// @return assets The amount of assets redeemed by `owner`.
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) external returns (uint256 assets);

    /// @notice Withdraws assets, quoted in `shares` from the market,
    ///         and burns `owner` shares, sending assets to `receiver`.
    /// @dev Does not force collateral to be withdrawn.
    /// @param shares The amount of shares to redeemed.
    /// @param receiver The account that should receive the assets.
    /// @param owner The account that will burn their shares to withdraw
    ///              assets.
    /// @return assets The amount of assets redeemed by `owner` and sent to
    ///                `receiver`.
    function redeemFor(
        uint256 shares,
        address receiver,
        address owner
    ) external returns (uint256 assets);

    /// @notice Caller withdraws assets from the market and burns their
    ///         shares, on behalf of `owner`.
    /// @dev Forces collateral to be withdrawn from `owner` collateralPosted.
    /// @param shares The amount of shares to redeemed.
    /// @param receiver The account that should receive the assets.
    /// @param owner The account that will burn their shares to withdraw
    ///              assets.
    /// @return assets The amount of assets redeemed by `owner` and sent to
    ///                `receiver`.
    function redeemCollateralFor(
        uint256 shares,
        address receiver,
        address owner
    ) external returns (uint256 assets);

    /// @notice Used by a Position Manager contract to redeem assets from
    ///         collateralized shares by `account` to perform a complex
    ///         action.
    /// @param assets The amount of the underlying assets to redeem.
    /// @param owner The owner address of assets to redeem.
    /// @param action Instructions for a deleverage action containing:
    ///               cToken Address of the cToken that will be redeemed from
    ///                      and assets swapped into `borrowableCToken` asset.
    ///               collateralAssets The amount of `cToken` that will be
    ///                                deleveraged, in assets.
    ///               borrowableCToken Address of the borrowableCToken that
    ///                                will have its debt paid.
    ///               repayAssets The amount of `borrowableCToken` asset that
    ///                           will be repaid to lenders.
    ///               swapActions Swap actions instructions converting
    ///                           collateral asset into debt asset to
    ///                           facilitate deleveraging.
    ///               auxData Optional auxiliary data for execution of a
    ///                       deleverage action.
    function withdrawByPositionManager(
        uint256 assets,
        address owner,
        IPositionManager.DeleverageAction memory action
    ) external;

    /// @notice Withdraws `assets` from the market, and burns `owner` shares.
    /// @dev Does not force collateral posted to be withdrawn.
    /// @param assets The amount of the underlying assets to withdraw.
    /// @param receiver The account that should receive the assets.
    /// @param owner The account that will burn their shares to withdraw
    ///              assets.
    /// @return shares The amount of cToken shares redeemed by `owner`.
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) external returns (uint256 shares);

    /// @notice Amount of tokens that has been posted as collateral,
    ///         in shares.
    function marketCollateralPosted() external view returns (uint256);

    /// @notice Shares of this token that an account has posted as collateral.
    /// @param account The address of the account to check collateral posted
    ///                of.
    function collateralPosted(address account) external view returns (uint256);

    /// @notice Transfers tokens from `account` to `liquidator`.
    /// @dev Will fail unless called by a cToken during the process
    ///      of liquidation.
    /// @param shares An array containing the number of cToken shares
    ///               to seize.
    /// @param liquidator The account receiving seized cTokens.
    /// @param accounts An array containing the accounts having
    ///                 collateral seized.
    function seize(
        uint256[] calldata shares,
        address liquidator,
        address[] calldata accounts
    ) external;

    /// @notice Allows users to simulate the effects of their deposit at
    ///         the current block.
    /// @param assets The number of assets to preview a deposit call.
    /// @return The shares received for depositing `assets`.
    function previewDeposit(uint256 assets) external view returns (uint256);
    function previewWithdraw(uint256 assets) external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256);
    function previewMint(uint256 shares) external view returns (uint256);

    /// IBorrowableCToken SPECIFIC FUNCTIONS ///

    /// @notice Address of the current Dynamic IRM.
    function IRM() external view returns (IDynamicIRM);

    /// @notice Fee that goes to protocol for interest generated for
    ///         lenders, in `BPS`.
    function interestFee() external view returns (uint256);

    /// @notice Can accrue interest yield, configure next interest accrual
    ///         period, and updates vesting data, if needed.
    /// @dev May emit a {RatesAdjusted} event.
    function accrueIfNeeded() external;

    /// @notice The amount of tokens that has been borrowed as debt,
    ///         in assets.
    function marketOutstandingDebt() external view returns (uint256);

    /// @notice Returns the current debt balance for `account`.
    /// @dev Note: Pending interest is not applied in this calculation.
    /// @param account The address whose debt balance should be calculated.
    /// @return result The current outstanding debt balance of `account`.
    function debtBalance(
        address account
    ) external view returns (uint256 result);

    /// @notice Updates pending interest and returns the current outstanding
    ///         debt owed by `account`.
    /// @param account The address whose debt balance should be calculated.
    /// @return result The current outstanding debt of `account`, with pending
    ///                interest applied.
    function debtBalanceUpdated(
        address account
    ) external returns (uint256 result);

    /// @notice Updates pending interest and returns the up-to-date exchange
    ///         rate from the underlying to the BorrowableCToken.
    /// @return result The share -> asset exchange rate, in `WAD`.
    function exchangeRateUpdated() external returns (uint256);

    /// @notice Used by a delegated user to borrow underlying tokens
    ///         from lenders, based on collateral posted inside this market
    ///         by `account`.
    /// @dev Updates pending interest before executing the borrow.
    ///      NOTE: Be careful who you approve here!
    ///      Not only can they take borrowed funds, but, they can delay
    ///      repayment through repeated borrows preventing withdrawal.
    /// @param assets The amount of the underlying asset to borrow.
    /// @param receiver The account who will receive the borrowed assets.
    /// @param owner The account who will have their assets borrowed
    ///              against.
    function borrowFor(
        uint256 assets,
        address receiver,
        address owner
    ) external;

    /// @notice Used by a Position Manager contract to borrow assets from
    ///         lenders, based on collateralized shares by `account` to
    ///         perform a complex action.
    /// @param assets The amount of the underlying assets to borrow.
    /// @param owner The account address to borrow on behalf of.
    /// @param action Instructions for a leverage action containing:
    ///               borrowableCToken Address of the borrowableCToken that
    ///                                will be borrowed from and assets
    ///                                swapped into `cToken` asset.
    ///               borrowAssets The amount borrowed from
    ///                            `borrowableCToken`, in assets.
    ///               cToken Curvance token assets that borrowed funds will be
    ///                      swapped into.
    ///               swapAction Swap action instructions converting debt
    ///                          asset into collateral asset to facilitate
    ///                          leveraging.
    ///               auxData Optional auxiliary data for execution of a
    ///                       leverage action.
    function borrowForPositionManager(
        uint256 assets,
        address owner,
        IPositionManager.LeverageAction memory action
    ) external;

    /// @notice Repays underlying tokens to lenders, on behalf of `account`,
    ///         freeing up their collateral posted inside this market.
    /// @dev Updates pending interest before executing the repay.
    /// @param assets The amount to repay, or 0 for the full outstanding
    ///               amount.
    /// @param owner The account address to repay on behalf of.
    function repayFor(uint256 assets, address owner) external;

    /// @notice Gets balance of this contract, in terms of the underlying.
    /// @dev This excludes changes in underlying token balance by the
    ///      current transaction, if any.
    /// @return The quantity of underlying tokens held by the market.
    function assetsHeld() external view returns (uint256);

    /// @notice Borrows underlying tokens from lenders, based on collateral
    ///         posted inside this market by the caller.
    /// @dev Updates pending interest before executing the borrow.
    /// @param assets The amount of the underlying asset to borrow.
    /// @param receiver The account who will receive the borrowed assets.
    function borrow(uint256 assets, address receiver) external;

}

// contracts/interfaces/ICToken.sol

struct AccountSnapshot {
    address asset;
    address underlying;
    uint8 decimals;
    bool isCollateral;
    uint256 collateralPosted;
    uint256 debtBalance;
}

interface ICToken {
    /// @notice Starts a cToken market, executed via marketManager.
    /// @dev This initial mint is a failsafe against rounding exploits,
    ///      although, we protect against them in many ways,
    ///      better safe than sorry.
    /// @param by The account initializing deposits.
    function initializeDeposits(address by) external returns (bool);

    /// @notice Returns the decimals of the cToken.
    /// @dev We pull directly from underlying incase its a proxy contract,
    ///      and changes decimals on us.
    /// @return The number of decimals for this cToken,
    ///         matching the underlying token.
    function decimals() external view returns (uint8);

    function name() external view returns (string memory);
    function symbol() external view returns (string memory);

    /// @notice Returns whether the underlying token can be borrowed.
    /// @dev true = Borrowable; false = Not Borrowable.
    /// @return Whether this token is borrowable or not.
    function isBorrowable() external view returns (bool);

    /// @notice The token balance of an account.
    /// @dev Account address => account token balance.
    /// @param account The address of the account to query token balance for.
    function balanceOf(address account) external view returns (uint256);

    /// @notice Returns the address of the underlying asset.
    /// @return The address of the underlying asset.
    function asset() external view returns (address);

    /// @notice Updates pending assets and returns a snapshot of the cToken
    ///         and `account` data.
    /// @dev Used by marketManager to more efficiently perform
    ///      liquidity checks.
    /// @return result The snapshot of the cToken and `account` data.
    function getSnapshotUpdated(
        address account
    ) external returns (AccountSnapshot memory result);

    /// @notice Get a snapshot of `account` data in this Curvance token.
    /// @dev NOTE: Does not accrue pending assets as part of the call.
    /// @param account The address of the account to snapshot.
    /// @return The account snapshot of `account`.
    function getSnapshot(
        address account
    ) external view returns (AccountSnapshot memory);

    /// @notice Total number of cTokens in circulation.
    function totalSupply() external view returns (uint256);

    /// @notice Returns the total amount of assets held by the market.
    /// @return The total amount of assets held by the market.
    function totalAssets() external view returns (uint256);

    /// @notice Address of the Market Manager linked to this contract.
    function marketManager() external view returns (IMarketManager);

    /// @notice Returns the amount of assets that would be exchanged
    ///         by the vault for `shares` provided.
    /// @param shares The number of shares to theoretically use
    ///               for conversion to assets.
    /// @return The number of assets a user would receive for converting
    ///         `shares`.
    function convertToAssets(uint256 shares) external view returns (uint256);

    /// @notice Updates pending assets and returns the up-to-date exchange
    ///         rate from the underlying to the BorrowableCToken.
    /// @dev Oracle Manager calculates cToken value from this exchange rate.
    /// @return The share -> asset exchange rate, in `WAD`.
    function exchangeRateUpdated() external returns (uint256) ;

    /// @notice Returns the up-to-date exchange rate from the underlying to
    ///         the BorrowableCToken.
    /// @dev Oracle Manager calculates cToken value from this exchange rate.
    /// @return The share -> asset exchange rate, in `WAD`.
    function exchangeRate() external view returns (uint256);

    /// @notice Executes multiple calls in a single transaction.
    ///         This can be used to update oracle prices before
    ///         a liquidity dependent action.
    function multicall(
        Multicall.MulticallAction[] memory calls
    ) external returns (bytes[] memory results);

    /// @notice Caller deposits `assets` into the market and `receiver`
    ///         receives shares.
    /// @param assets The amount of the underlying assets to deposit.
    /// @param receiver The account that should receive the shares.
    /// @return shares The amount of shares received by `receiver`.
    function deposit(
        uint256 assets,
        address receiver
    ) external returns (uint256 shares);

    /// @notice Caller deposits `assets` into the market, `receiver` receives
    ///         shares, and collateralization of `assets` is enabled.
    /// @dev The caller must be depositing for themselves, or be managing
    ///      their position through a Position Manager contract.
    /// @param assets The amount of the underlying assets to deposit.
    /// @param receiver The account that should receive the shares.
    /// @return shares The amount of shares received by `receiver`.
    function depositAsCollateral(
        uint256 assets,
        address receiver
    ) external returns (uint256 shares);

    /// @notice Caller deposits `assets` into the market, `receiver` receives
    ///         shares, and collateralization of `assets` is enabled.
    /// @dev Requires that `receiver` approves the caller prior to
    ///      collateralize on their behalf.
    ///      NOTE: Be careful who you approve here!
    ///      They can delay redemption of assets through repeated
    ///      collateralization preventing withdrawal.
    /// @param assets The amount of the underlying assets to deposit.
    /// @param receiver The account that should receive the shares.
    /// @return shares The amount of shares received by `receiver`.
    function depositAsCollateralFor(
        uint256 assets,
        address receiver
    ) external returns (uint256 shares);

    /// @notice Withdraws assets, quoted in `shares` from the market,
    ///         and burns `owner` shares.
    /// @dev Does not force collateral to be withdrawn.
    /// @param shares The amount of shares to be redeemed.
    /// @param receiver The account that should receive the assets.
    /// @param owner The account that will burn their shares to withdraw
    ///              assets.
    /// @return assets The amount of assets redeemed by `owner`.
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) external returns (uint256 assets);

    /// @notice Withdraws assets, quoted in `shares` from the market,
    ///         and burns `owner` shares, sending assets to `receiver`.
    /// @dev Does not force collateral to be withdrawn.
    /// @param shares The amount of shares to redeemed.
    /// @param receiver The account that should receive the assets.
    /// @param owner The account that will burn their shares to withdraw
    ///              assets.
    /// @return assets The amount of assets redeemed by `owner` and sent to
    ///                `receiver`.
    function redeemFor(
        uint256 shares,
        address receiver,
        address owner
    ) external returns (uint256 assets);

    /// @notice Caller withdraws assets from the market and burns their
    ///         shares, on behalf of `owner`.
    /// @dev Forces collateral to be withdrawn from `owner` collateralPosted.
    /// @param shares The amount of shares to redeemed.
    /// @param receiver The account that should receive the assets.
    /// @param owner The account that will burn their shares to withdraw
    ///              assets.
    /// @return assets The amount of assets redeemed by `owner` and sent to
    ///                `receiver`.
    function redeemCollateralFor(
        uint256 shares,
        address receiver,
        address owner
    ) external returns (uint256 assets);

    /// @notice Used by a Position Manager contract to redeem assets from
    ///         collateralized shares by `account` to perform a complex
    ///         action.
    /// @param assets The amount of the underlying assets to redeem.
    /// @param owner The owner address of assets to redeem.
    /// @param action Instructions for a deleverage action containing:
    ///               cToken Address of the cToken that will be redeemed from
    ///                      and assets swapped into `borrowableCToken` asset.
    ///               collateralAssets The amount of `cToken` that will be
    ///                                deleveraged, in assets.
    ///               borrowableCToken Address of the borrowableCToken that
    ///                                will have its debt paid.
    ///               repayAssets The amount of `borrowableCToken` asset that
    ///                           will be repaid to lenders.
    ///               swapActions Swap actions instructions converting
    ///                           collateral asset into debt asset to
    ///                           facilitate deleveraging.
    ///               auxData Optional auxiliary data for execution of a
    ///                       deleverage action.
    function withdrawByPositionManager(
        uint256 assets,
        address owner,
        IPositionManager.DeleverageAction memory action
    ) external;

    /// @notice Amount of tokens that has been posted as collateral,
    ///         in shares.
    function marketCollateralPosted() external view returns (uint256);

    /// @notice Shares of this token that an account has posted as collateral.
    /// @param account The address of the account to check collateral posted
    ///                of.
    function collateralPosted(address account) external view returns (uint256);

    /// @notice Transfers tokens from `account` to `liquidator`.
    /// @dev Will fail unless called by a cToken during the process
    ///      of liquidation.
    /// @param shares An array containing the number of cToken shares
    ///               to seize.
    /// @param liquidator The account receiving seized cTokens.
    /// @param accounts An array containing the accounts having
    ///                 collateral seized.
    function seize(
        uint256[] calldata shares,
        address liquidator,
        address[] calldata accounts
    ) external;

    /// @notice Allows users to simulate the effects of their deposit at
    ///         the current block.
    /// @param assets The number of assets to preview a deposit call.
    /// @return The shares received for depositing `assets`.
    function previewDeposit(uint256 assets) external view returns (uint256);
}

// contracts/interfaces/IExternalCalldataChecker.sol

interface IExternalCalldataChecker {
    /// @notice Inspects calldata for compliance with other swap instruction
    ///         parameters.
    /// @dev Used on swap to inspect and validate calldata safety.
    /// @param swapAction Swap action instructions including both direct
    ///                   parameters and decodeable calldata.
    /// @param expectedRecipient Address who will receive proceeds of
    ///                          `swapAction`.
    function checkCalldata(
        SwapperLib.Swap memory swapAction,
        address expectedRecipient
    ) external returns (uint256);
}

// contracts/interfaces/IOracleManager.sol

interface IOracleManager {
    /// @notice Retrieves the price of a specified asset from either single
    ///         or dual oracles.
    /// @dev If the asset has one oracle, it fetches the price from a single feed.
    ///      If it has two or more oracles, it fetches the price from both feeds.
    /// @param asset The address of the asset to retrieve the price for.
    /// @param inUSD Whether the price should be returned in USD or ETH.
    /// @param getLower Whether the lower or higher price should be returned
    ///                 if two feeds are available.
    /// @return price The current price of `asset`.
    /// @return errorCode An error code related to fetching the price:
    ///                   '0' indicates no error fetching price.
    ///                   '1' indicates that price should be taken with
    ///                   caution.
    ///                   '2' indicates a complete failure in receiving
    ///                   a price.
    function getPrice(
        address asset,
        bool inUSD,
        bool getLower
    ) external view returns (uint256 price, uint256 errorCode);

    /// @notice Retrieves the prices of a collateral token and debt token
    ///         underlyings.
    /// @param collateralToken The cToken currently collateralized to price.
    /// @param debtToken The cToken borrowed from to price.
    /// @param errorCodeBreakpoint The error code that will cause liquidity
    ///                            operations to revert.
    /// @return collateralUnderlyingPrice The current price of
    ///                                   `collateralToken` underlying.
    /// @return debtUnderlyingPrice The current price of `debtToken`
    ///                             underlying.
    function getPriceIsolatedPair(
        address collateralToken,
        address debtToken,
        uint256 errorCodeBreakpoint
    ) external returns (uint256, uint256);

    /// @notice Retrieves the prices and account data of multiple assets
    ///         inside a Curvance Market.
    /// @param account The account to retrieve data for.
    /// @param assets An array of asset addresses to retrieve the prices for.
    /// @param errorCodeBreakpoint The error code that will cause liquidity
    ///                            operations to revert.
    /// @dev Zero-collateral and zero-debt rows are returned without oracle
    ///      validation and keep their price entry at zero.
    /// @return AccountSnapshot[] Contains `assets` data for `account`
    /// @return uint256[] Contains prices for `assets`.
    /// @return uint256 The number of assets `account` is in.
    function getPricesForMarket(
        address account,
        address[] calldata assets,
        uint256 errorCodeBreakpoint
    )
        external
        returns (AccountSnapshot[] memory, uint256[] memory, uint256);

    /// @notice Potentially removes the dependency on pricing from `adaptor`
    ///         for `asset`, triggered by an adaptor's notification of a price
    ///         feed's removal.
    /// @notice Removes a pricing adaptor for `asset` triggered by an
    ///         adaptor's notification of a price feed's removal.
    /// @dev Requires that the adaptor is currently being used for pricing
    ///      for `asset`.
    ///      NOTE: This intentionally does not modify asset deviation values
    ///            because they simply wont be used if there are less than two
    ///            pricing adaptors in use, so no reason to delete data as
    ///            when a second pricing adaptor is configured the deviation
    ///            has the opportunity be to reconfigured anyway.
    /// @param asset The address of the asset to potentially remove the
    ///              pricing adaptor dependency from depending on current
    ///              `asset` configuration.
    function notifyFeedRemoval(address asset) external;

    /// @notice Returns the adaptors used for pricing `asset`.
    /// @param asset The address of the asset to get pricing adaptors for.
    /// @return The current adaptor(s) used for pricing `asset`.
    function getPricingAdaptors(
        address asset
    ) external view returns(address[] memory);

    /// @notice Address => Adaptor approval status.
    /// @param adaptor The address of the adaptor to check.
    /// @return True if the adaptor is supported, false otherwise.
    function isApprovedAdaptor(address adaptor) external view returns (bool);

    /// @notice Whether a token is recognized as a Curvance token or not,
    ///         if it is, will return its underlying asset address instead
    ///         of address (0).
    /// @return The cToken's underlying asset, or address(0) if not a cToken.
    function cTokens(address cToken) external view returns (address);

    /// @notice Checks if a given asset is supported by the Oracle Manager.
    /// @dev An asset is considered supported if it has one
    ///      or more associated price feeds.
    /// @param asset The address of the asset to check.
    /// @return True if the asset is supported, false otherwise.
    function isSupportedAsset(address asset) external view returns (bool);

    /// @notice Check whether L2 sequencer is valid or down.
    /// @return True if sequencer is valid.
    function isSequencerValid() external view returns (bool);
}

// contracts/interfaces/IPositionManager.sol

interface IPositionManager {
    /// TYPES ///

    /// @notice Instructions for a leverage action.
    /// @param borrowableCToken Address of the borrowableCToken that will be
    ///                         borrowed from and assets swapped into `cToken`
    ///                         asset.
    /// @param borrowAssets The amount borrowed from `borrowableCToken`,
    ///                     in assets.
    /// @param cToken Curvance token assets that borrowed funds will be
    ///               swapped into.
    /// @param expectedShares The expected shares received from depositing
    ///                       into `cToken` with swapped `borrowAssets`.
    /// @param swapAction Swap action instructions converting debt asset into
    ///                   collateral asset to facilitate leveraging.
    /// @param auxData Optional auxiliary data for execution of a leverage
    ///                action.
    struct LeverageAction {
        IBorrowableCToken borrowableCToken;
        uint256 borrowAssets;
        ICToken cToken;
        uint256 expectedShares;
        SwapperLib.Swap swapAction;
        bytes auxData;
    }

    /// @notice Instructions for a deleverage action.
    /// @param cToken Address of the cToken that will be redeemed from and
    ///               assets swapped into `borrowableCToken` asset.
    /// @param collateralAssets The amount of `cToken` that will be
    ///                         deleveraged, in assets.
    /// @param borrowableCToken Address of the borrowableCToken that will
    ///                         have its debt paid.
    /// @param repayAssets The amount of `borrowableCToken` asset that will
    ///                    be repaid to lenders.
    /// @param swapActions Swap actions instructions converting collateral
    ///                    asset into debt asset to facilitate deleveraging.
    /// @param auxData Optional auxiliary data for execution of a deleverage
    ///                action.
    struct DeleverageAction {
        ICToken cToken;
        uint256 collateralAssets;
        IBorrowableCToken borrowableCToken;
        uint256 repayAssets;
        SwapperLib.Swap[] swapActions;
        bytes auxData;
    }

    /// @notice Callback function to execute post borrow of
    ///         `borrowableCToken`'s asset and swap it to deposit
    ///         new collateralized shares for `owner`.
    /// @dev Measures slippage after this callback validating that `owner`
    ///      is still within acceptable liquidity requirements.
    /// @param borrowableCToken The borrowableCToken borrowed from.
    /// @param borrowAssets The amount of `borrowableCToken`'s asset borrowed.
    /// @param owner The account borrowing that will be swapped into
    ///              collateral assets deposited into Curvance.
    /// @param action Instructions for a leverage action containing:
    ///               borrowableCToken Address of the borrowableCToken that
    ///                                will be borrowed from and assets
    ///                                swapped into `cToken` asset.
    ///               borrowAssets The amount borrowed from
    ///                            `borrowableCToken`, in assets.
    ///               cToken Curvance token assets that borrowed funds will be
    ///                      swapped into.
    ///               swapAction Swap action instructions converting debt
    ///                          asset into collateral asset to facilitate
    ///                          leveraging.
    ///               auxData Optional auxiliary data for execution of a
    ///                       leverage action.
    function onBorrow(
        address borrowableCToken,
        uint256 borrowAssets,
        address owner,
        LeverageAction memory action
    ) external;

    /// @notice Callback function to execute post redemption of `cToken`'s
    ///         asset and swap it to repay outstanding debt for `owner`.
    /// @dev Measures slippage after this callback validating that `owner`
    ///      is still within acceptable liquidity requirements.
    /// @param cToken The Curvance token redeemed for its underlying.
    /// @param collateralAssets The amount of `cToken` underlying redeemed.
    /// @param owner The account redeeming collateral that will be used to
    ///              repay their active debt.
    /// @param action Instructions for a deleverage action containing:
    ///               cToken Address of the cToken that will be redeemed from
    ///                      and assets swapped into `borrowableCToken` asset.
    ///               collateralAssets The amount of `cToken` that will be
    ///                                deleveraged, in assets.
    ///               borrowableCToken Address of the borrowableCToken that
    ///                                will have its debt paid.
    ///               repayAssets The amount of `borrowableCToken` asset that
    ///                           will be repaid to lenders.
    ///               swapAction Swap actions instructions converting
    ///                          collateral asset into debt asset to
    ///                          facilitate deleveraging.
    ///               auxData Optional auxiliary data for execution of a
    ///                       deleverage action.
    function onRedeem(
        address cToken,
        uint256 collateralAssets,
        address owner,
        DeleverageAction memory action
    ) external;
}

// contracts/libraries/SwapperLib.sol

/// @title Curvance Swapper Library.
/// @notice Helper Library for performing composable swaps with varying
///         degrees of slippage tolerance. "Unsafe" swaps perform a standard
///         slippage check whereas "safe" swaps not only check for standard
///         slippage but also check against the Oracle Manager's prices as
///         well.
///         NOTE: This library does not intend to provide support for fee on
///               transfer tokens though support may be built in the future.
library SwapperLib {
    /// TYPES ///

    /// @notice Instructions to execute a swap, selling `inputToken` for
    ///         `outputToken`.
    /// @param inputToken Address of input token to swap from.
    /// @param inputAmount The amount of `inputToken` to swap.
    /// @param outputToken Address of token to swap into.
    /// @param target Address of the swapper, usually an aggregator.
    /// @param slippage The amount of value-loss acceptable from swapping
    ///                 between tokens.
    /// @param call Swap instruction calldata.
    struct Swap {
        address inputToken;
        uint256 inputAmount;
        address outputToken;
        address target;
        uint256 slippage;
        bytes call;
    }

    /// @notice Address identifying a chain's native token.
    address public constant native =
        0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /// ERRORS ///

    error SwapperLib__UnknownCalldata();
    error SwapperLib__TokenPrice(address inputToken);
    error SwapperLib__Slippage(uint256 slippage);
    error SwapperLib__SameTokens();

    /// INTERNAL FUNCTIONS ///

    /// @notice Swaps `action.inputToken` into a `action.outputToken`
    ///         without an extra slippage check.
    /// @param cr The address of the Protocol Central Registry to pull
    ///           addresses from.
    /// @param action Instructions for a swap action containing:
    ///               inputToken Address of input token to swap from.
    ///               inputAmount The amount of `inputToken` to swap.
    ///               outputToken Address of token to swap into.
    ///               target Address of the swapper, usually an aggregator.
    ///               slippage The amount of value-loss acceptable from
    ///                        swapping between tokens.
    ///               call Swap instruction calldata.
    /// @return outAmount The output amount received from swapping.
    function _swapUnsafe(
        ICentralRegistry cr,
        Swap memory action
    ) internal returns (uint256 outAmount) {
        address outputToken = action.outputToken;
        address inputToken = action.inputToken;

        // Do not use this library if the tokens are the same.
        if (CommonLib._isMatchingToken(inputToken, outputToken)) {
            revert SwapperLib__SameTokens();
        }

        address callDataChecker = cr.externalCalldataChecker(action.target);

        // Validate we know how to verify this calldata.
        if (callDataChecker == address(0)) {
            revert SwapperLib__UnknownCalldata();
        }

        // Verify calldata integrity.
        uint256 minOutAmount = IExternalCalldataChecker(callDataChecker)
            .checkCalldata(action, address(this));

        // Approve `action.inputToken` to target contract, if necessary.
        _approveIfNeeded(inputToken, action.target, action.inputAmount);

        // Cache output token from struct for easier querying.
        
        uint256 balanceBefore = CommonLib._balanceOf(outputToken);

        uint256 callValue = CommonLib._isNative(inputToken) ?
            action.inputAmount : 0;

        // Execute the swap.
        LowLevelCallsHelper._callWithNative(
            action.target,
            action.call,
            callValue
        );

        // Remove any excess approval.
        _removeApprovalIfNeeded(inputToken, action.target);

        outAmount = CommonLib._balanceOf(outputToken) - balanceBefore;

        if (outAmount < minOutAmount) {
            revert SwapperLib__Slippage(minOutAmount);
        }
    }

    /// @notice Swaps `action.inputToken` into a `action.outputToken`
    ///         with an extra slippage check.
    /// @param cr The address of the Protocol Central Registry to pull
    ///           addresses from.
    /// @param action Instructions for a swap action containing:
    ///                   inputToken Address of input token to swap from.
    ///                   inputAmount The amount of `inputToken` to swap.
    ///                   outputToken Address of token to swap into.
    ///                   target Address of the swapper, usually an
    ///                          aggregator.
    ///                   slippage The amount of value-loss acceptable from
    ///                            swapping between tokens.
    ///                   call Swap instruction calldata.
    /// @return outAmount The output amount received from swapping.
    function _swapSafe(
        ICentralRegistry cr,
        Swap memory action
    ) internal returns (uint256 outAmount) {
        if (action.slippage >= WAD) {
            revert SwapperLib__Slippage(action.slippage);
        }

        outAmount = _swapUnsafe(cr, action);

        IOracleManager om = CommonLib._oracleManager(cr);
        uint256 valueIn = _getValue(om, action.inputToken, action.inputAmount);
        uint256 valueOut = _getValue(om, action.outputToken, outAmount);

        // Check if swap received positive slippage.
        if (valueOut > valueIn) {
            return outAmount;
        }

        // Calculate % slippage from executed swap.
        uint256 slippage = FixedPointMathLib.mulDivUp(
            valueIn - valueOut,
            WAD,
            valueIn
        );

        if (slippage > action.slippage) {
            revert SwapperLib__Slippage(slippage);
        }
    }

    /// @notice Get the value of a token amount.
    /// @notice Approves `token` spending allowance, if needed.
    /// @param om The Oracle Manager address to call for pricing `token`.
    /// @param token The token address to get the value of.
    /// @param amount The amount of `token` to get the value of.
    function _getValue(
        IOracleManager om,
        address token,
        uint256 amount
    ) internal view returns (uint256 result) {
        // If token is native, normalize to address(0) so it is compatible 
        // with the Oracle Manager.
        if (token == address(0)) {
            token = native;
        }
        
        (uint256 price, uint256 errorCode) = om.getPrice(token, true, true);
        if (errorCode != NO_ERROR) {
            revert SwapperLib__TokenPrice(token);
        }

        // Return price in WAD form.
        result = FixedPointMathLib.mulDiv(
            price,
            amount,
            10 ** (CommonLib._isNative(token) ? 18 : IERC20(token).decimals())
        );
    }

    /// @notice Approves `token` spending allowance, if needed.
    /// @param token The token address to approve.
    /// @param spender The spender address.
    /// @param amount The approval amount.
    function _approveIfNeeded(
        address token,
        address spender,
        uint256 amount
    ) internal {
        if (!CommonLib._isNative(token)) {
            SafeTransferLib.safeApprove(token, spender, amount);
        }
    }

    /// @notice Removes `token` spending allowance, if needed.
    /// @param token The token address to remove approval.
    /// @param spender The spender address.
    function _removeApprovalIfNeeded(address token, address spender) internal {
        if (!CommonLib._isNative(token)) {
            if (IERC20(token).allowance(address(this), spender) > 0) {
                SafeTransferLib.safeApprove(token, spender, 0);
            }
        }
    }
}

// contracts/market/isolated/LiquidityManagerIsolated.sol

/// @title Curvance Liquidity Manager.
/// @notice Calculates liquidity of an account in various positions.
/// @dev NOTE: Only use this as an abstract contract as no account
///            data is written here.
abstract contract LiquidityManagerIsolated {
    /// TYPES ///

    /// @notice Storage structure for Account data involving liquidity
    ///         positions, and pending redemption cooldown.
    /// @param cooldownTimestamp Timestamp corresponding to when the last time
    ///                          `account` performed a liquidity focused
    ///                          action, which activates a cooldown period on
    ///                          redemptions/repayment/collateral removal.
    /// @param assets Array containing all Curvance tokens an account has
    ///               active liquidity positions in.
    struct AccountData {
        uint256 cooldownTimestamp;
        address[] assets;
    }

    /// @notice Storage configuration for how a Curvance token should behave
    ///         in the liquidity manager.
    /// @param isListed Whether or not this Curvance token is listed.
    /// @dev false = unlisted; true = listed.
    /// @param mintPaused Whether token minting is paused.
    /// @dev Token Address => 0 or 1 = unpaused; 2 = paused.
    /// @param collateralizationPaused Whether token collateralization is paused.
    /// @dev Token Address => 0 or 1 = unpaused; 2 = paused.
    /// @param borrowPaused Whether token borrowing is paused.
    /// @dev Token Address => 0 or 1 = unpaused; 2 = paused.
    /// @param collRatio The ratio at which this token can be borrowed against
    ///                  when collateralized.
    /// @dev In `BPS`, e.g. 0.8e18 = 80% collateral value borrowable.
    /// @param collReqSoft The collateral requirement where dipping below this
    ///                    will cause a soft liquidation.
    /// @dev In `BPS`, e.g. 1.2e18 = 120% collateral vs debt value.
    /// @param collReqHard The collateral requirement where dipping below
    ///                    this will cause a hard liquidation.
    /// @dev In `BPS`, e.g. 1.1e18 = 110% collateral vs debt value.
    /// @param liqIncBase The base ratio at which this token will be
    ///                   compensated on soft liquidation.
    /// @dev In `BPS`, stored as Incentive + BPS e.g. 1.05e18 = 5% incentive.
    /// @param liqIncCurve The liquidation incentive curve length between
    ///                    soft liquidation to hard liquidation.
    ///                    e.g. 5% base incentive with 8% curve length results
    ///                    in 13% liquidation incentive on hard liquidation.
    /// @dev In `BPS`, e.g. 0.05e18 = 5% maximum additional incentive.
    /// @param liqIncMin The minimum possible liquidation incentive for
    ///                  during an auction.
    /// @dev In `BPS`, stored as Incentive + BPS e.g. 1.03e18 = 3% incentive.
    /// @param liqIncMax The maximum possible liquidation incentive for
    ///                  during an auction.
    /// @dev In `BPS`, stored as Incentive + BPS e.g. 1.07e18 = 7% incentive.
    /// @param closeFactorBase Maximum % that a liquidator can repay when soft
    ///                        liquidating an account.
    /// @dev In `BPS` format, e.g. 0.1e18 = 10% base close factor.
    /// @param closeFactorCurve Curve length between soft liquidation and hard
    ///                         liquidation, should be equal to
    ///                         100% - `closeFactorBase`.
    /// @dev In `BPS` format, e.g. 0.9e18 = 90% distance between
    ///      `closeFactorBase`, and 100%.
    /// @param closeFactorMin The minimum possible close factor for during an
    ///                       auction.
    /// @dev In `BPS` format, e.g. 0.2e18 = 20% minimum close factor.
    /// @param closeFactorMax The maximum possible close factor for during an 
    ///                       auction.
    /// @dev In `BPS` format, e.g. 0.4e18 = 40% maximum close factor.
    struct CurvanceToken {
        bool isListed;
        uint8 mintPaused;
        uint8 collateralizationPaused;
        uint8 borrowPaused;
        uint24 collRatio;
        uint24 collReqSoft;
        uint24 collReqHard;
        uint16 liqIncBase;
        uint16 liqIncCurve;
        uint16 liqIncMin;
        uint16 liqIncMax;
        uint16 closeFactorBase;
        uint16 closeFactorCurve;
        uint16 closeFactorMin;
        uint16 closeFactorMax;
    }

    /// @notice Data structure containing information on hypothetical action
    ///         to execute.
    /// @param cTokenModified The cToken to hypothetically redeem/borrow.
    /// @param redemptionShares The number of tokens to hypothetically redeem,
    ///                         in `shares`.
    /// @param borrowAssets The amount of underlying to hypothetically borrow,
    ///                     in `assets`.
    /// @param errorCodeBreakpoint The error code that will cause liquidity
    ///                            operations to revert. We reuse
    ///                            `errorCodeBreakpoint` as a return variable
    ///                            as a garbage collection flag to minimize
    ///                            local variables.
    struct HypotheticalAction {
        address cTokenModified;
        uint256 redemptionShares;
        uint256 borrowAssets;
        uint256 errorCodeBreakpoint;
    }

    /// @notice Data structure returned on liquidation threshold calculation
    ///         containing an accounts collateral values under specific
    ///         (soft liquidation versus hard liquidation) methodology
    ///         that will lead to liquidations.
    /// @param cSoft The account's soft collateral value (collateral adjusted
    ///              by soft requirements).
    /// @param cHard The account's hard collateral value (collateral adjusted
    ///              by hard requirements).
    /// @param debt The account's total outstanding debt.
    struct AccountLiqResult {
        uint256 cSoft;
        uint256 cHard;
        uint256 debt;
    }

    /// @notice Data structure returned on querying a liquidation's current
    ///         configuration based on the auction liquidation system.
    /// @param lFactor The liquidation factor for an account, indicating the
    ///                severity of a liquidation, between 0 and WAD.
    /// @param debtBalance An account's outstanding debt to a cToken.
    /// @param liqInc The ratio at which debt repayment will be compensated on
    ///               liquidation.
    /// @param liqIncBase The base ratio at which this token will be
    ///                   compensated on soft liquidation.
    /// @param liqIncCurve The liquidation incentive curve length between soft
    ///                 liquidation to hard liquidation.
    /// @param closeFactor Maximum debt % that a liquidator can repay
    ///                    during a liquidation of an account.
    /// @param closeFactorBase Maximum % that a liquidator can repay when soft
    ///                        liquidating an account.
    /// @param closeFactorCurve Curve length between soft liquidation and hard
    ///                         liquidation, should be equal to
    ///                         100% - `closeFactorBase`.
    struct AccountLiqData {
        uint256 lFactor;
        uint256 debtBalance;
        uint256 liqInc;
        uint256 liqIncBase;
        uint256 liqIncCurve;
        uint256 closeFactor;
        uint256 closeFactorBase;
        uint256 closeFactorCurve;
    }

    /// @notice Data structure returned on querying a liquidation's current
    ///         configuration based on the aggregate liquidation system.
    /// @param collateralToken The address of the Curvance token to be seized
    ///                        during in the liquidation.
    /// @param collateralExchangeRate The exchange rate of `collateralToken`'s
    ///                               underlying token to the cToken itself.
    /// @param collateralReqSoft The collateral requirement where dipping
    ///                          below this will cause a soft liquidation.
    /// @param collateralReqHard The collateral requirement where dipping
    ///                          below this will cause a hard liquidation.
    /// @param collateralSharesPrice The current price of `collateralToken`,
    ///                              in `shares`.
    /// @param collateralDecimals The decimals that `collateralToken` is
    ///                           measured in.
    /// @param debtToken The address of the Curvance token to be repaid during
    ///                  the liquidation.
    /// @param debtDecimals The decimals that `debtToken` is measured in.
    /// @param debtUnderlyingPrice The current price of the underlying token
    ///                            of `debtToken`, in `assets`.
    /// @param auctionBuffer The current buffer that `cSoft` and `cHard` are 
    ///                      multiplied against, 10 bps, or 0 if not an 
    ///                      auction-based liquidation.
    struct TokenLiqData {
        address collateralToken;
        uint256 collateralReqSoft;
        uint256 collateralReqHard;
        uint256 collateralSharesPrice;
        uint256 collateralDecimals;
        address debtToken;
        uint256 debtDecimals;
        uint256 debtUnderlyingPrice;
        uint256 auctionBuffer;
    }

    /// CONSTANTS ///

    /// @notice Maximum collateralization ratio, in `BPS`.
    /// @dev 9750 = 97.50%.
    ///      ~40x leverage calculated from: 1 / (1 - Collateralization Ratio).
    uint256 public constant MAX_COLL_RATIO_CORRELATED = 9750;
    /// @notice Maximum collateralization ratio, in `BPS`.
    /// @dev 9696 = 96.96%.
    ///      ~33x leverage calculated from: 1 / (1 - Collateralization Ratio).
    uint256 public constant MAX_COLL_RATIO_UNCORRELATED = 9696;
    /// @notice Buffer to ensure orderflow auction-based liquidations have
    ///         priority versus basic liquidations, for correlated assets,
    ///         in `BPS`.
    /// @dev 9990 = 99.9%. Multiplied then divided by `BPS` = 10 bps buffer
    ///                    auction liquidation priority for correlated assets.
    uint256 public constant AUCTION_BUFFER_CORRELATED = 9990;
    /// @notice Buffer to ensure orderflow auction-based liquidations have
    ///         priority versus basic liquidations, for uncorrelated assets,
    ///         in `BPS`.
    /// @dev 9950 = 99.5%. Multiplied then divided by `BPS` = 50 bps buffer
    ///                    auction liquidation priority for uncorrelated assets.
    uint256 public constant AUCTION_BUFFER_UNCORRELATED = 9950;
    /// @notice Minimum Liquidity buffer provided to maximally leveraged users
    ///         before a liquidation can occur. This value is adjusted by
    ///         `AUCTION_BUFFER` to calculate `MIN_LIQUIDATION_BUFFER_REQUIRED`
    ///         inside a market, in `BPS`.
    /// @dev 9960 = 0.4% buffer. An additional 40 basis points buffer before a
    ///      liquidation can trigger (Then modified by `AUCTION_BUFFER`).
    uint256 public constant EXTRA_BUFFER_BEFORE_LIQUIDATION = 9960;

    /// @notice Enforced buffer provided to maximally leveraged users before a
    ///         liquidation can occur, stored in `BPS`^2.
    /// @dev 99,500,000 = ~99.5% bps^2 = 0.5% buffer. An additional 50 basis
    ///      points buffer before a liquidation can trigger.
    uint256 public immutable MIN_LIQUIDATION_BUFFER;
    /// @notice Whether this market is for correlated assets or not, this
    ///         impacts auction buffer and maximum theoretical
    ///         collateralization ratio allowed.
    bool public immutable IS_CORRELATED_ASSET_MARKET;
    /// @notice Maximum collateralization ratio ratio allowed for any asset
    ///         inside this market, in `BPS`, e.g. 9696 = 96.96%, or ~33x
    ///         leverage calculated from: 1 / (1 - Collateralization Ratio).
    uint256 public immutable MAX_COLL_RATIO;
    /// @notice Buffer to ensure auction-based liquidations have priority
    ///         versus basic liquidations by multiplying a user's active
    ///         collateral $ value by `AUCTION_BUFFER` then dividing by `BPS`.
    ///         Denominated in `BPS`, e.g. 9990 = 99.9% -> 10 bps priority.
    uint256 public immutable AUCTION_BUFFER;
    /// @notice Minimum excess collateral requirement before soft liquidation
    ///         can occur, in `BPS`, e.g. 9950 = 99.5% -> 50 bps drop before a
    ///         liquidation can step in, used during `updateTokenConfig`.
    uint256 public immutable MIN_LIQUIDATION_BUFFER_REQUIRED;
    /// @notice Minimum loan size allowed inside Curvance that can be created
    ///         from a new line of credit inside a market.
    /// @dev This restriction is to minimize the potential of debt positions
    ///      being created that cannot not be profitably closed.
    uint256 public immutable MIN_LOAN_SIZE;
    /// @notice Curvance DAO hub.
    ICentralRegistry public immutable centralRegistry;

    /// STORAGE ///

    /// @notice Curvance token data including listing status,
    ///         action enablement, collateralization configuration,
    ///         and liquidation configuration.
    /// @dev Curvance Token Address => CurvanceToken struct.
    mapping(address => CurvanceToken) internal _tokenConfig;

    // ACCOUNT LIQUIDITY DATA //

    /// @notice Value that indicates whether an account has an
    ///         active position in the token.
    /// @dev Curvance Token address => Account address => Active position
    ///      status. 0 or 1 for no; 2 for yes.
    mapping(address => mapping(address => uint256)) public accountPositions;
    /// @notice Assets and redemption cooldown data for an account.
    /// @dev Account => AccountData struct.
    mapping(address => AccountData) public accountAssets;

    /// ERRORS ///

    error LiquidityManager__InsufficientLoanSize();
    error LiquidityManager__PriceError();

    /// @param cr The address of the Protocol Central Registry.
    /// @param minLoanSize The minimum active loan size for this isolated
    ///                    market, must be between $10 - $100 in `WAD`.
    /// @param isCorrelatedMarket Whether this market is for correlated assets
    ///                           or not, this impacts auction buffer and
    ///                           maximum theoretical collateralization
    ///                           ratio allowed.
    constructor(
        ICentralRegistry cr,
        uint256 minLoanSize,
        bool isCorrelatedMarket
    ) {
        if (minLoanSize < 10e18 || minLoanSize > 100e18) {
            revert LiquidityManager__InsufficientLoanSize();
        }
        CentralRegistryLib._isCentralRegistry(cr);

        centralRegistry = cr;
        MIN_LOAN_SIZE = minLoanSize;
        IS_CORRELATED_ASSET_MARKET = isCorrelatedMarket;
        MAX_COLL_RATIO = isCorrelatedMarket ?
            MAX_COLL_RATIO_CORRELATED :
            MAX_COLL_RATIO_UNCORRELATED;
        AUCTION_BUFFER = isCorrelatedMarket ? AUCTION_BUFFER_CORRELATED :
            AUCTION_BUFFER_UNCORRELATED;
        
        // Calculates the minimum liquidation buffer the market needs to give
        // users before liquidation. E.g. 9960 extra buffer * 10 bps auction
        // buffer = 9960 * 9990 = 99.5 bps^2 or ~50 bps buffer from max
        // leverage to liquidation.
        MIN_LIQUIDATION_BUFFER =
            EXTRA_BUFFER_BEFORE_LIQUIDATION * AUCTION_BUFFER;
    }

    /// @notice Determine `account`'s current status between collateral,
    ///         debt, and additional liquidity.
    /// @param account The account to determine liquidity for.
    /// @return collateral Total value of `account`'s collateral across
    ///                    all positions.
    /// @return maxDebt The maximum amount of debt `account`
    ///                 could take on based on `collateral`.
    /// @return debt Total value of `account`'s current outstanding
    ///              debt across all positions.
    function _statusOf(address account) internal returns (
        uint256 collateral,
        uint256 maxDebt,
        uint256 debt
    ) {
        (
            AccountSnapshot[] memory snapshots,
            uint256[] memory prices,
            uint256 numAssets
        ) = _assetDataOf(account, BAD_SOURCE);
        AccountSnapshot memory snap;

        for (uint256 i; i < numAssets; ++i) {
            snap = snapshots[i];

            if (snap.isCollateral) {
                uint256 collateralValue = _assetValue(
                    snap.collateralPosted,
                    prices[i],
                    10 ** snap.decimals,
                    true
                );
                collateral += collateralValue;
                maxDebt += _mulDiv(
                    collateralValue,
                    _tokenConfig[snap.asset].collRatio,
                    BPS
                );
            } else {
                // If they have a debt balance, increment their debt.
                if (snap.debtBalance > 0) {
                    debt += _assetValue(
                        snap.debtBalance,
                        prices[i],
                        10 ** snap.decimals,
                        false
                    );
                }
            }
        }
    }

    /// @notice Calculates hypothetical liquidity for an account after a
    ///         potential action such as redemption and borrowing.
    /// @param account The address of the account being evaluated for `action`
    ///                being done.
    /// @param action Instructions for a hypothetical action containing:
    ///               cTokenModified The address of the token being modified
    ///                              by the action.
    ///               redemptionShares The amount of tokens to hypothetically
    ///                                redeem, in `shares`.
    ///               borrowAssets The amount of underlying to hypothetically
    ///                            borrow, in `assets`.
    ///               errorCodeBreakpoint The error code that will cause
    ///                                   liquidity operations to revert.
    /// @return uint256 Excess collateral capacity after the action.
    ///         uint256 Shortfall in collateral capacity after the action.
    function _hypotheticalLiquidityOf(
        address account,
        HypotheticalAction memory action
    ) internal returns (uint256, uint256) {
        (
            AccountSnapshot[] memory snapshots,
            uint256[] memory prices,
            uint256 numAssets
        ) = _assetDataOf(account, action.errorCodeBreakpoint);
        AccountSnapshot memory snap;
        uint256 maxDebt;
        uint256 newDebt;
        
        for (uint256 i; i < numAssets; ++i) {
            snap = snapshots[i];

            // Generally `isCollateral` tells us if an entry is collateral or
            // debt, but on a fresh borrow, the debt row can be inserted
            // before debtBalance is written. The zero-exposure snapshot can
            // still report `isCollateral` as true and skip pricing in
            // `getPricesForMarket`, so price the modified token as debt here
            // before adding the pending borrow assets below.
            if (
                action.cTokenModified == snap.asset && snap.isCollateral &&
                action.borrowAssets > 0
            ) {
                uint256 errorCode;
                (prices[i], errorCode) =
                    CommonLib._oracleManager(centralRegistry).
                        getPrice(snap.underlying, true, false);

                if (errorCode >= action.errorCodeBreakpoint) {
                    revert LiquidityManager__PriceError();
                }

                // Adjust `isCollateral` to be false since this is a debt
                // entry not a collateral entry.
                delete snap.isCollateral;
            }

            if (snap.isCollateral) {
                // If the user is redeeming collateral, offset their
                // collateral posted.
                if (action.cTokenModified == snap.asset) {
                    snap.collateralPosted -= action.redemptionShares;
                }

                // CASE: There is no collateral posted. Either the position
                // will be closed through a full redemption, or the user
                // already had their position closed via liquidation.
                if (snap.collateralPosted > 0) {
                    // CASE: There is collateral posted in this cToken,
                    // the user can take on more debt from lenders.
                    maxDebt += _mulDiv(
                        _assetValue(
                            snap.collateralPosted,
                            prices[i],
                            10 ** snap.decimals,
                            true
                        ),
                        _tokenConfig[snap.asset].collRatio,
                        BPS
                    );
                }
            } else {
                if (action.cTokenModified == snap.asset) {
                    snap.debtBalance += action.borrowAssets;
                }

                // CASE: There is no outstanding debt, clean up the position
                // entry as the user was liquidated, otherwise add to the
                // user's outstanding debt.
                if (snap.debtBalance > 0) {
                    // CASE: There is outstanding debt to lenders, add it to
                    // `newDebt` to check against `maxDebt`.
                    newDebt += _assetValue(
                        snap.debtBalance,
                        prices[i],
                        10 ** snap.decimals,
                        false
                    );

                    // Check `newDebt` to make sure the loan size will not be
                    // too small for us to allow issuing the loan.
                    if (newDebt < MIN_LOAN_SIZE) {
                        revert LiquidityManager__InsufficientLoanSize();
                    }
                }
            }
        }

        // Returns excess liquidity on hypothetical positions.
        if (maxDebt > newDebt) {
            return (maxDebt - newDebt, 0);
        }

        // Returns shortfall on hypothetical positions.
        return (0, newDebt - maxDebt);
    }

    /// @notice Evaluates an account's collateral and debt positions to
    ///         determine liquidation factor using cached data.
    /// @param account The address of the account being evaluated for
    ///                 liquidation.
    /// @param tData A TokenLiqData struct containing:
    ///              collateralToken The token which is used as collateral
    ///                               by `account` and may be seized.
    ///              collateralExchangeRate The exchange rate of
    ///                                     `collateralToken` underlying token
    ///                                     to `collateralToken`.
    ///              collateralReqSoft The collateral requirement where
    ///                                dipping below this will cause a soft
    ///                                liquidation.
    ///              collateralReqHard The collateral requirement where
    ///                                dipping below this will cause a hard
    ///                                liquidation.
    ///              collateralUnderlyingPrice The current price of the
    ///                                        underlying token of
    ///                                        `collateralToken`.
    ///              collateralDecimals The decimals that `collateralToken`
    ///                                 is measured in.
    ///              debtToken The token to potentially repay which has
    ///                        outstanding debt by `account`.
    ///              debtDecimals The decimals that `debtToken` is measured
    ///                           in.
    ///              debtUnderlyingPrice The current price of the underlying
    ///                                  token of `debtToken`.
    ///              auctionBuffer The current buffer that `cSoft` and `cHard` 
    ///                            are multiplied against, 10 bps, or 0 if not
    ///                            an auction-based liquidation.
    ///  @return lFactor The liquidation factor where:
    ///                  0: No liquidation (account is healthy).
    ///                  1 to WAD - 1: Soft liquidation (partial liquidation
    ///                                allowed).
    ///                  WAD: Hard liquidation (full liquidation, possibly
    ///                       including bad debt).
    ///  @return debt The current debt position in `liqData.debtToken` for
    ///               `account`.
    function _liquidationValuesOf(
        address account,
        TokenLiqData memory tData
    ) internal view returns (uint256 lFactor, uint256 debt) {
        AccountLiqResult memory r;
        address[] memory assets = accountAssets[account].assets;

        address asset;
        uint256 numAssets = assets.length;
        for (uint256 i; i < numAssets; ) {
            asset = assets[i++];
            if (asset == tData.collateralToken) {
                (r.cSoft, r.cHard) = _addLiquidationValues(
                    tData.collateralDecimals,
                    tData.collateralReqSoft,
                    tData.collateralReqHard,
                    tData.collateralSharesPrice,
                    ICToken(tData.collateralToken).collateralPosted(account),
                    r.cSoft,
                    r.cHard
                );
            } else {
                // If the asset is not `collateralToken`, the asset must
                // be the `debtToken` debt position because this market
                // only has two tokens.
                debt =
                    IBorrowableCToken(tData.debtToken).debtBalance(account);

                // If they have a debt balance, document additional
                // collateral requirements.
                if (debt > 0) {
                    r.debt += _assetValue(
                        debt,
                        tData.debtUnderlyingPrice,
                        tData.debtDecimals,
                        false
                    );
                }
            }
        }
        
        // If this is a potential liquidation from an auction, apply the
        // auction buffer to collateral values, discounting collateral values.
        if (tData.auctionBuffer != 0) {
            r.cSoft = _mulDiv(r.cSoft, tData.auctionBuffer, BPS);
            r.cHard = _mulDiv(r.cHard, tData.auctionBuffer, BPS);
        }

        // Get `account` lFactor.
        if (r.cSoft >= r.debt) {
            // Indicates no liquidation.
            lFactor = 0;
        } else {
            lFactor = r.debt >= r.cHard ? WAD // Indicates hard liquidation.
            // Indicates soft liquidation, we round up here in favor of the
            // protocol, we know that we wont run into a value > WAD due to
            // cHard being at least 1 higher than debt.
            : FixedPointMathLib.mulDivUp(r.debt - r.cSoft, WAD, r.cHard - r.cSoft);
        }
    }

    /// @notice Retrieves the prices and account data of multiple assets
    ///         inside this market.
    /// @param account The account to retrieve data for.
    /// @param errorCodeBreakpoint The error code that will cause liquidity
    ///                            operations to revert.
    /// @return Assets data for `account`.
    /// @return Prices for `account` assets.
    /// @return The number of assets `account` is in.
    function _assetDataOf(address account, uint256 errorCodeBreakpoint)
        internal
        returns (AccountSnapshot[] memory, uint256[] memory, uint256) {
        return CommonLib._oracleManager(centralRegistry).getPricesForMarket(
            account,
            accountAssets[account].assets,
            errorCodeBreakpoint
        );
    }

    /// @notice Calculates an assets value based on its `price`,
    ///         `amount`, and adjusts for decimals.
    /// @param amount The asset amount to calculate asset value from.
    /// @param price The asset price to calculate asset value from, in `WAD`.
    /// @param decimals The asset decimals to adjust asset value
    ///                 into proper form.
    /// @param increasesCollateral Whether the asset adds positive value or
    ///        not to the liquidity check, we round down when increasing
    ///        collateral value and round up when increasing collateral
    ///        value/increasing debt.
    /// @return The calculated asset value.
    function _assetValue(
        uint256 amount,
        uint256 price,
        uint256 decimals,
        bool increasesCollateral
    ) internal pure returns (uint256) {
        if (increasesCollateral) {
            return _mulDiv(amount, price, decimals);
        }

        return FixedPointMathLib.mulDivUp(amount, price, decimals);
    }

    /// @notice Calculates and adds soft and hard collateral values for
    ///         liquidation assessment with cached data.
    /// @param decimals The number of decimals for the collateral token.
    /// @param collReqSoft The soft collateral requirement ratio, in WAD.
    /// @param collReqHard The hard collateral requirement ratio, in WAD.
    /// @param price The price of the underlying asset, in `WAD`.
    /// @param collateralPosted The amount of collateral token posted as
    ///                         collateral by the account.
    /// @param softSumPrior The previous sum of soft collateral values.
    /// @param hardSumPrior The previous sum of hard collateral values.
    /// @return softSum The updated sum of soft collateral values.
    /// @return hardSum The updated sum of hard collateral values.
    function _addLiquidationValues(
        uint256 decimals,
        uint256 collReqSoft,
        uint256 collReqHard,
        uint256 price,
        uint256 collateralPosted,
        uint256 softSumPrior,
        uint256 hardSumPrior
    ) internal pure returns (uint256 softSum, uint256 hardSum) {
        uint256 assetValue = _assetValue(
            collateralPosted,
            price,
            decimals,
            true
        ) * BPS;

        softSum = softSumPrior + (assetValue / collReqSoft);
        hardSum = hardSumPrior + (assetValue / collReqHard);
    }

    /// @dev Returns `floor(x * y / d)`.
    /// Reverts if `x * y` overflows, or `d` is zero.
    function _mulDiv(
        uint256 x,
        uint256 y,
        uint256 d
    ) internal pure returns (uint256 z) {
        z = FixedPointMathLib.mulDiv(x, y, d);
    }

    /// @dev Internal helper for reverting efficiently.
    function _revert(uint256 s) internal pure {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x00, s)
            revert(0x1c, 0x04)
        }
    }
}

// contracts/market/isolated/MarketManagerIsolated.sol

/// @title Curvance DAO Market Manager.
/// @notice Manages risk within the Curvance DAO markets.
/// @dev Curvance Market Managers are built as "thesis driven" micro
///      ecosystems. This means that a market may be focused specifically
///      on interest-bearing stablecoins, or bluechip long market exposure,
///      volatile LP tokens for a particular dex or perpetual platform. This
///      minimizes systemic risk by having many market managers with unique
///      opportunities and risk profiles.
///
///      All management of token actions are managed by the Market Manager.
///      These tokens are collectively referred to as Curvance tokens,
///      or cTokens. Each market has a maximum number of supportable assets
///      this is to minimize systemic risk and gas costs on liquidity checks.
///
///      Curvance offers the ability to store unlimited tokens inside Curvance
///      token contracts while restricting the scale of exogenous risk.
///      Every collateral asset has a "Collateral Cap", measured in shares.
///      As collateral is posted, the `collateralPosted` invariant increases,
///      and is compared to `collateralCaps`. By measuring collateral posted
///      in shares, this allows collateral caps to grow proportionally with
///      any auto compounding mechanism strategy attached to the token.
///
///      It is important to note that, in theory, collateral caps can be
///      decreased below current market collateral posted levels. This would
///      restrict the addition of new exogenous risk being added to the
///      system, but will not result in forced unwinding of user positions.
///
///      Curvance also employs a 20-minute minimum duration of posting of
///      collateral and borrowing of tokens. This restriction improves
///      the security model of Curvance and allows for more advanced
///      interest rate methodology.
///
///      Additionally, a new "Dynamic Liquidation Engine" or DLE
///      allows for more nuanced position management inside the system.
///      The DLE facilitates aggressive asset support and elevated
///      collateralization ratios paired with reduced minimum liquidation
///      penalties. In periods of low volatility, users will experience soft
///      liquidations. But, when volatility is elevated, users may experience
///      more aggressive or complete liquidation of positions.
///
///      Bad debt is minimized via a "Bad Debt Socialization" system.
///      When a user's debt is greater than their collateral assets,
///      the entire user's account can be liquidated with lenders paying any
///      collateral shortfall.
///
contract MarketManagerIsolated is
    LiquidityManagerIsolated,
    IMarketManager,
    ERC165,
    Multicall
{
    /// TYPES ///

    struct TokenConfig {
        address cToken;
        uint256 collRatio;
        uint256 collReqSoft;
        uint256 collReqHard;
        uint256 liqIncBase;
        uint256 liqIncHard;
        uint256 liqIncMin;
        uint256 liqIncMax;
        uint256 closeFactorBase;
        uint256 closeFactorMin;
        uint256 closeFactorMax;
        uint256 collateralCap;
        uint256 debtCap;
    }

    /// CONSTANTS ///

    /// @notice Maximum collateral requirement to avoid liquidation, in `BPS`.
    /// @dev 23400 = 234%. Resulting in 1 / (BPS + 2.34 BPS),
    ///      or ~30% maximum LTV soft liquidation level.
    uint256 public constant MAX_COLLATERAL_REQUIREMENT = 23400;
    /// @notice Minimum excess collateral requirement on top of liquidation
    ///         incentives, in `BPS`.
    /// @dev 100 = 1.0%.
    uint256 public constant MIN_EXCESS_COLL_REQUIRED = 100;
    /// @notice Minimum excess collateral requirement before soft liquidation
    ///         can occur, in `BPS`.
    /// @notice The maximum liquidation incentive, in `BPS`.
    /// @dev 3000 = 30%.
    uint256 public constant MAX_LIQUIDATION_INCENTIVE = 3000;
    /// @notice The maximum base cFactor, in `BPS`.
    /// @dev 5000 = 50%. NOTE: This can NEVER be changed to 100% or offchain
    ///      parameters can be unintentionally ignored.
    uint256 public constant MAX_BASE_CFACTOR = 5000;
    /// @notice The minimum base cFactor, in `BPS`.
    /// @dev 1000 = 10%.
    uint256 public constant MIN_BASE_CFACTOR = 1000;
    /// @notice Minimum hold time to minimize external risks, in seconds.
    /// @dev 20 minutes = 1,200 seconds.
    ///      The 20 minute holding period is intentionally set so that every
    ///      borrower experiences a minimum 2 interest rate adjustments from a
    ///      standard borrow action (10 minute interest rate adjustment rate).
    uint256 public constant MIN_HOLD_PERIOD = 20 minutes;

    /// @dev Limit for market debt cap to max sure outstanding user debt
    ///      never overflows `outstandingDebt` value inside _debtOf.
    uint256 internal constant _MAX_DEBT_CAP = type(uint136).max;
    /// @dev `bytes4(keccak256(bytes("MarketManager__InvalidParameter()")))`
    uint256 internal constant _INVALID_PARAMETER_SELECTOR = 0x65513fc1;
    /// @dev `bytes4(keccak256(bytes("MarketManager__Unauthorized()")))`
    uint256 internal constant _UNAUTHORIZED_SELECTOR = 0x37cf6ad5;
    /// @dev `bytes4(keccak256(bytes("MarketManager__InvariantError()")))`
    uint256 internal constant _INVARIANT_ERROR_SELECTOR = 0x5518d5cb;
    /// @dev A fixed key to use in transient storage for offchain liquidation
    ///      configuration.
    ///      Key value = `uint256(keccak256(_TRANSIENT_LIQUIDATION_CONFIG_KEY))`.
    ///      Bits Layout:
    ///      - [0..159]   `COLLATERAL_UNLOCKED`.
    ///      - [160..175] `LIQ_INCENTIVE`.
    ///      - [176..191] `CLOSE_FACTOR`.
    uint256 internal constant _TRANSIENT_LIQUIDATION_CONFIG_KEY
        = 0x1966ec4daf81281b2aba49348128e9b155301b8486bde131e0db16a52b730b82;
    uint256 internal constant _BITMASK_COLLATERAL_UNLOCKED = (1 << 160) - 1;
    /// @dev The bit position of `LIQ_INCENTIVE` in
    ///      `_TRANSIENT_LIQUIDATION_CONFIG_KEY`.
    uint256 internal constant _BITPOS_LIQ_INCENTIVE = 160;
    /// @dev The bit position of `CLOSE_FACTOR` in
    ///      `_TRANSIENT_LIQUIDATION_CONFIG_KEY`.
    uint256 internal constant _BITPOS_CLOSE_FACTOR = 176;
    
    /// STORAGE ///

    /// @notice A list of all tokens inside this market for
    ///         offchain querying.
    address[] public tokensListed;

    /// MARKET STATE

    /// @notice Whether market-wide liquidations are paused.
    /// @dev 1 = unpaused; 2 = paused.
    uint8 public liquidationPaused = 1;
    /// @notice Whether market-wide token redemptions are paused.
    /// @dev 1 = unpaused; 2 = paused.
    uint8 public redeemPaused = 1;
    /// @notice Whether market-wide token transfers are paused.
    /// @dev 1 = unpaused; 2 = paused.
    uint8 public transferPaused = 1;

    /// @notice The total amount of `cToken` that can be posted as collateral,
    ///         in shares.
    /// @dev Token Address => Market-wide Collateral Cap, in shares.
    mapping(address => uint256) public collateralCaps;
    /// @notice The total amount of `cToken` underlying that can be borrowed,
    ///         in assets.
    /// @dev Token Address => Market-wide Debt Cap, in assets.
    mapping(address => uint256) public debtCaps;

    /// @notice Whether an address is an authorized position manager or not.
    /// @dev Address => Is an approved position management operator.
    mapping(address => bool) public isPositionManager;

    /// EVENTS ///

    event PositionUpdated(address cToken, address account, bool open);
    event TokenListed(address cToken);
    event TokenConfigUpdated(TokenConfig config);
    event PositionManagerUpdated(address positionManager, bool addPerms);
    event ActionPaused(string action, bool pauseState);
    event TokenActionPaused(address cToken, string action, bool pauseState);

    /// ERRORS ///

    error MarketManager__Unauthorized();
    error MarketManager__UnauthorizedLiquidation();
    error MarketManager__TokenNotListed();
    error MarketManager__Paused();
    error MarketManager__InsufficientCollateral();
    error MarketManager__NoLiquidationAvailable();
    error MarketManager__PriceError();
    error MarketManager__CapReached();
    error MarketManager__MarketManagerMismatch();
    error MarketManager__InvalidParameter();
    error MarketManager__MinimumHoldPeriod();
    error MarketManager__InvariantError();
    
    /// CONSTRUCTOR ///

    /// @param cr The address of the Protocol Central Registry.
    /// @param minLoanSize The minimum active loan size for this isolated
    ///                    market (must be between $10-$100 in WAD).
    /// @param isCorrelatedMarket Whether this market is for correlated assets
    ///                           or not, this impacts auction buffer and
    ///                           maximum theoretical collateralization
    ///                           ratio allowed.
    constructor(
        ICentralRegistry cr,
        uint256 minLoanSize,
        bool isCorrelatedMarket
    ) LiquidityManagerIsolated(cr, minLoanSize, isCorrelatedMarket) {}

    /// EXTERNAL FUNCTIONS ///

    /// @notice Returns whether `cToken` is listed in the lending market.
    /// @param cToken The address of a token to check for listing status.
    /// @return result Whether `cToken` is listed inside this lending market
    ///                or not.
    function isListed(address cToken) external view returns (bool result) {
        result = _tokenConfig[cToken].isListed;
    }

    /// @notice Returns whether minting, collateralization, borrowing of
    ///         `cToken` is disabled.
    /// @param cToken The address of the Curvance token to return
    ///               action statuses of.
    /// @return mintPaused Whether minting `cToken` is paused or not.
    /// @return collateralizationPaused Whether collateralization `cToken`
    ///                                 is paused or not.
    /// @return borrowPaused Whether borrowing `cToken` is paused or not.
    function actionsPaused(address cToken) external view returns (
        bool mintPaused,
        bool collateralizationPaused,
        bool borrowPaused
    ) {
        CurvanceToken storage c = _tokenConfig[cToken];
        mintPaused = c.mintPaused == 2;
        collateralizationPaused = c.collateralizationPaused == 2;
        borrowPaused = c.borrowPaused == 2;
    }

    /// @notice Returns the current collateralization configuration
    ///         of `cToken`.
    /// @param cToken The address of the Curvance token to return
    ///               collateralization configuration of.
    /// @return The ratio at which this token can be borrowed against
    ///         when collateralized, in `BPS`.
    /// @return The collateral requirement where dipping below this
    ///         will cause a soft liquidation, in `BPS`.
    /// @return The collateral requirement where dipping below
    ///         this will cause a hard liquidation, in `BPS`.
    function collConfig(address cToken) external view returns (
         uint256, uint256, uint256
    ) {
        CurvanceToken storage c = _tokenConfig[cToken];
        return (c.collRatio, c.collReqSoft, c.collReqHard);
    }

    /// @notice Returns the current liquidation configuration
    ///         of `cToken`.
    /// @param cToken The address of the Curvance token to return
    ///               liquidation configuration of.
    /// @return The base ratio at which this token will be
    ///         compensated on soft liquidation.
    /// @return The liquidation incentive curve length between soft
    ///         liquidation to hard liquidation, in `BPS`. e.g. 5% base
    ///         incentive with 8% curve length results in 13% liquidation
    ///         incentive on hard liquidation.
    /// @return The minimum possible liquidation incentive for during an
    ///         auction, in `BPS`.
    /// @return The maximum possible liquidation incentive for during an
    ///         auction, in `BPS`.
    /// @return Maximum % that a liquidator can repay when soft
    ///         liquidating an account, in `BPS`.
    /// @return Curve length between soft liquidation and hard liquidation,
    ///         should be equal to 100% - `closeFactorBase`, in `BPS`.
    /// @return The minimum possible close factor for during an auction,
    ///         in `BPS`.
    /// @return The maximum possible close factor for during an auction,
    ///         in `BPS`.
    function liquidationConfig(address cToken) external view returns (
        uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256
    ) {
        CurvanceToken storage c = _tokenConfig[cToken];
        return (
            c.liqIncBase,
            c.liqIncCurve,
            c.liqIncMin,
            c.liqIncMax,
            c.closeFactorBase,
            c.closeFactorCurve,
            c.closeFactorMin,
            c.closeFactorMax
        );
    }

    /// @notice Helper function for querying the current Curvance tokens listed
    ///         inside this market.
    /// @return r Array containing list of all Curvance token addresses
    ///           listed in this market.
    function queryTokensListed() external view returns (address[] memory r) {
        r = tokensListed;
    }

    /// ACCOUNT SPECIFIC FUNCTIONS ///

    /// @notice Returns the assets `account` has an open position in.
    /// @param account The address of the account to pull assets for.
    /// @return result An array containing the assets `account` has
    ///                positions in.
    function assetsOf(
        address account
    ) external view returns (address[] memory result) {
        result = accountAssets[account].assets;
    }

    /// @notice Determine `account`'s current status between collateral,
    ///         debt, and additional liquidity.
    /// @param account The account to determine liquidity for.
    /// @return The current total collateral amount of `account`.
    /// @return The maximum debt amount of `account` can take out with
    ///         their current collateral.
    /// @return The current total borrow amount of `account`.
    function statusOf(
        address account
    ) external returns (uint256, uint256, uint256) {
        return _statusOf(account);
    }

    /// @notice Checks if the account should be allowed to mint tokens
    ///         in the given market.
    /// @param cToken The Curvance token to verify mintability of.
    function canMint(address cToken) external view virtual {
        if (_tokenConfig[cToken].mintPaused == 2) {
            revert MarketManager__Paused();
        }

        _checkIsListedToken(cToken);
    }

    /// @notice Checks if the account should be allowed to collateralize
    ///         their shares of the given market.
    ///         Prunes unused positions in `account` data.
    /// @dev May emit a {PositionUpdated} event.
    /// @param collateralToken The token to verify collateralization of.
    /// @param account The account which would collateralize the asset.
    /// @param newNetCollateral The amount of shares that would be
    ///                         collateralized in total if allowed.
    function canCollateralize(
        address collateralToken,
        address account,
        uint256 newNetCollateral
    ) external {
        _checkIsToken(collateralToken);
        // Can skip token listing check since collateralCaps[collateralToken]
        // can only be set above 0 if `debtToken` is listed already, so we
        // only need to check that `newNetCollateral` != 0 instead, which
        // should be impossible but only costs 2 gas.

        /// @solidity memory-safe-assembly
        assembly {
            if iszero(newNetCollateral) {
                mstore(0x00, _INVARIANT_ERROR_SELECTOR)
                // Return bytes 29-32 for the selector.
                revert(0x1c, 0x04)
            }
        }

        if (_tokenConfig[collateralToken].collateralizationPaused == 2) {
            revert MarketManager__Paused();
        }

        // This also acts as a check that collateralization ratio is > 0,
        // since collateralCaps can only be raised above zero if the
        // its collateralization ratio is > 0.
        if (newNetCollateral > collateralCaps[collateralToken]) {
            revert MarketManager__CapReached();
        }

        // On collateral posting:
        // We need to flip their cooldown flag to prevent flashloan attacks.
        accountAssets[account].cooldownTimestamp = block.timestamp;
        // If `account` does not have a position in `collateralToken`,
        // open one.
        if (accountPositions[collateralToken][account] != 2) {
            accountPositions[collateralToken][account] = 2;
            accountAssets[account].assets.push(collateralToken);

            emit PositionUpdated(collateralToken, account, true);
        }
    }

    /// @notice Checks if the account should be allowed to redeem tokens
    ///         in the given market, and then redeems.
    /// @dev This can only be called by the cToken itself.
    /// @param cToken The token to verify the redemption against.
    /// @param shares The number of cToken shares to redeem for the
    ///               underlying asset in the market.
    /// @param account The account which would redeem `shares`.
    /// @param balanceOf The current cToken share balance of `account`.
    /// @param collateralPosted The current cToken shares posted as
    ///                         collateral by `account`.
    /// @param forceRedeemCollateral Whether the collateral should be always
    ///                              reduced.
    /// @return collateralRedeemed The amount of collateral shares redeemed.
    function canRedeemWithCollateralRemoval(
        address cToken,
        uint256 shares,
        address account,
        uint256 balanceOf,
        uint256 collateralPosted,
        bool forceRedeemCollateral
    ) external returns (uint256 collateralRedeemed) {
        _checkIsToken(cToken);
        if (redeemPaused == 2) {
            revert MarketManager__Paused();
        }

        collateralRedeemed = _canRedeem(
            cToken,
            shares,
            account,
            balanceOf,
            collateralPosted,
            true,
            forceRedeemCollateral
        );
    }

    /// @notice Checks if the account should be allowed to borrow
    ///         the underlying asset of the given market.
    ///         Prunes unused positions in `account` data.
    /// @dev May emit a {PositionUpdated} event.
    /// @param cToken The token to verify borrowability of.
    /// @param assets The amount of underlying the account would borrow.
    /// @param account The account which would borrow the asset.
    /// @param newNetDebt The amount of assets that would be
    ///                   outstanding debt in total if allowed.
    function canBorrow(
        address cToken,
        uint256 assets,
        address account,
        uint256 newNetDebt
    ) external {
        _canBorrow(cToken, assets, account, newNetDebt);
    }

    /// @notice Checks if the account should be allowed to borrow
    ///         the underlying asset of the given market,
    ///         and notifies the market of the borrow.
    /// @dev This can only be called by the market itself.
    /// @param cToken The token to verify borrowability of.
    /// @param assets The amount of underlying the account would borrow.
    /// @param account The account which would borrow the asset.
    /// @param newNetDebt The amount of assets that would be
    ///                   outstanding debt in total if allowed.
    function canBorrowWithNotify(
        address cToken,
        uint256 assets,
        address account,
        uint256 newNetDebt
    ) external {
        accountAssets[account].cooldownTimestamp = block.timestamp;
        _canBorrow(cToken, assets, account, newNetDebt);
    }

    /// @notice Updates `account` cooldownTimestamp to the current block
    ///         timestamp.
    /// @dev The caller must be a listed cToken in the `markets` mapping.
    /// @param cToken The address of the cToken that the account is borrowing.
    /// @param account The address of the account that has just borrowed.
    function notifyBorrow(address cToken, address account) external {
        _checkIsToken(cToken);
        _checkIsListedToken(cToken);

        accountAssets[account].cooldownTimestamp = block.timestamp;
    }

    /// @notice Checks if the account should be allowed to repay a borrow
    ///         in the given market, may clean up positions.
    /// @param cToken The Curvance token to verify the repayment of.
    /// @param newNetDebt The new debt amount owed by `account` after
    ///                   repayment.
    /// @param debtAsset The debt asset being repaid to `cToken`.
    /// @param decimals The decimals that `debtToken` is measured in.
    /// @param account The account who will have their loan repaid.
    function canRepayWithReview(
        address cToken,
        uint256 newNetDebt,
        address debtAsset,
        uint256 decimals,
        address account
    ) external view {
        _checkIsToken(cToken);
        _checkIsListedToken(cToken);
        _checkHoldPeriod(account);

        // Validate `account` actually has a debt position in `cToken`.
        if (accountPositions[cToken][account] != 2) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // If `account` is fully repaying their debt, we can skip loan size
        // check.
        if (newNetDebt == 0) {
            return;
        }
        // We round down to favor the protocol here even though typically
        // we use !getLower for debt.
        (uint256 price, uint256 errorCode) =
            CommonLib._oracleManager(centralRegistry)
                .getPrice(debtAsset, true, true);

        // If there an issue pricing we should bubble up an error since we
        // cannot validate the loan size.
        if (errorCode != NO_ERROR) {
            revert MarketManager__PriceError();
        }

        // Check `account`'s new debt position in $ and review if the loan
        // size is too small for us to allow issuing the loan.
        if (
            _assetValue(newNetDebt, price, 10 ** decimals, true) <
            MIN_LOAN_SIZE
        ) {
            revert LiquidityManager__InsufficientLoanSize();
        }
    }

    /// @notice Validates and processes batch liquidations for multiple
    ///         accounts, calculating collateral seizure amounts, debt
    ///         repayment, and bad debt based on account health and market
    ///         parameters.
    /// @param debtAmounts The amounts of outstanding debt the liquidator
    ///                    wishes to repay, in underlying assets, empty if
    ///                    intention is to liquidate maximum amount possible
    ///                    for each account.
    /// @param liquidator The address of the account trying to liquidate
    ///                   `accounts`.
    /// @param accounts The addresses of the accounts to be liquidated.
    /// @param action Instructions for a liquidation action containing:
    ///               collateralToken The token which is used as collateral
    ///                               by `account` and may be seized.
    ///               debtToken The token to potentially repay which has 
    ///                         outstanding debt by `account`.
    ///               numAccounts The number of accounts to be, potentially,
    ///                           liquidated.
    ///               liquidateExact Whether the liquidator desires a
    ///                              specific liquidation amount.
    ///               liquidatedShares Empty variable slot to store how much
    ///                                `collateralToken` will be seized as
    ///                                part of a particular liquidation.
    ///               debtRepaid Empty variable slot to store how much
    ///                          `debtToken` will be repaid as part of a
    ///                          particular liquidation.
    ///               badDebt Empty variable slot to store how much bad debt
    ///                       will be realized as part of a particular
    ///                       liquidation.
    /// @return result Hypothetical results for an action containing:
    ///                liquidatedShares An array containing the collateral
    ///                                 amounts to liquidate from
    ///                                 `accounts`.
    ///                debtRepaid The total amount of debt to repay from
    ///                           `accounts`.
    ///                badDebtRealized The total amount of debt to realize as
    ///                                losses for lenders inside this market.
    /// @return An array containing the debt amounts to repay from
    ///        `accounts`, in assets.
    function canLiquidate(
        uint256[] memory debtAmounts,
        address liquidator,
        address[] calldata accounts,
        IMarketManager.LiqAction memory action
    ) external returns (
        IMarketManager.LiqResult memory result,
        uint256[] memory
    ) {
        if (liquidationPaused == 2) {
            revert MarketManager__Paused();
        }

        _checkIsToken(action.debtToken);
        _checkIsListedToken(action.collateralToken);
        _checkIsListedToken(action.debtToken);

        (TokenLiqData memory tData, AccountLiqData memory aData) =
            _getLiquidationConfig(action.collateralToken, action.debtToken);

        // Amounts array is empty since the max amount possible
        // will be liquidated.
        result.liquidatedShares = new uint256[](action.numAccounts);
        address cachedAccount;
        address priorAccount;
        for (uint256 i; i < action.numAccounts; ++i) {
            cachedAccount = accounts[i];
            
            // Do not let an account liquidate themselves.
            if (liquidator == cachedAccount) {
                _revert(_UNAUTHORIZED_SELECTOR);
            }

            // Liquidators MUST sort the token addresses offchain from
            // smallest to largest to validate there are no duplicate
            // liquidations.
            if (priorAccount >= cachedAccount) {
                _revert(_UNAUTHORIZED_SELECTOR);
            }

            (
                action.liquidatedShares,
                action.debtRepaid,
                action.badDebt
            ) = _canLiquidate(
                debtAmounts[i],
                cachedAccount,
                tData,
                aData,
                action.liquidateExact
            );

            // We optimistically update values even if they are setting from
            // 0 -> 0 to act as an invariant check for the sum of all debt
            // values in `debtAmounts` equal to `debtRepaid`.
            result.debtRepaid += action.debtRepaid;
            result.liquidatedShares[i] = action.liquidatedShares;

            if (action.badDebt > 0) {
                result.badDebtRealized += action.badDebt;
                // Add the bad debt to debt to remove from the liquidated
                // account.
                action.debtRepaid += action.badDebt;
            }

            // If its an exact liquidation this will be a redundant setter
            // but anticipation is majority of liquidators will use
            // non-exact so checking for liquidateExact each time is a
            // waste.
            debtAmounts[i] = action.debtRepaid;

            // Update prior account to current account.
            priorAccount = cachedAccount;
        }

        // If theres no debt to repay then there were no liquidations.
        if (result.debtRepaid == 0) {
            revert MarketManager__NoLiquidationAvailable();
        }

        return (result, debtAmounts);
    }

    /// @notice Checks if the seizing of `collateralToken` by repayment of
    ///         `debtToken` should be allowed.
    /// @param collateralToken The Curvance token which was used as collateral
    ///                        and will be seized.
    /// @param debtToken The Curvance token which has outstanding debt to and
    ///                  would be repaid during `collateralToken` seizure.
    function canSeize(
        address collateralToken,
        address debtToken
    ) external view {
        _checkIsListedToken(collateralToken);
        _checkIsListedToken(debtToken);

        if (
            ICToken(collateralToken).marketManager() !=
            ICToken(debtToken).marketManager()
        ) {
            revert MarketManager__MarketManagerMismatch();
        }
    }

    /// @notice Checks if the account should be allowed to transfer collateral
    ///         tokens in the given market.
    /// @param cToken The Curvance token to verify the transfer of.
    /// @param shares The amount of `cToken` to transfer.
    /// @param account The account which will transfer `shares`.
    /// @param balanceOf The current balance that `account` has of `cToken`
    ///                  shares.
    /// @param collateralPosted The amount of `cToken` shares posted as
    ///                         collateral by `account`.
    /// @param isCollateral Boolean indicating whether the token is currently
    ///                     being used as collateral.
    /// @return collateralRedeemed The amount of collateral shares redeemed
    ///                            on transfer.
    function canTransfer(
        address cToken,
        uint256 shares,
        address account,
        uint256 balanceOf,
        uint256 collateralPosted,
        bool isCollateral
    ) external returns (uint256 collateralRedeemed) {
        _checkIsToken(cToken);
        if (transferPaused == 2) {
            revert MarketManager__Paused();
        }

        collateralRedeemed = _canRedeem(
            cToken,
            shares,
            account,
            balanceOf,
            collateralPosted,
            isCollateral,
            false
        );
    }

    /// PERMISSIONED EXTERNAL FUNCTIONS ///

    /// @notice List isolated Curvance token pair to the market and enable
    ///         deposits.
    /// @dev Admin function to set isListed for token pair and add support
    ///      for the market. Only callable once due to isolated market design.
    ///      Emits {TokenListed} event twice.
    /// @param token0 The address of the first Curvance token to list in this
    ///               isolated market.
    /// @param token1 The address of the second Curvance token to list in this
    ///               isolated market.
    function listTokens(address token0, address token1) external {
        _checkMarketPermissions();

        // The same token cannot be listed twice in a market.
        if (token0 == token1) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // The same underlying asset cannot be listed twice in a market.
        if (ICToken(token0).asset() == ICToken(token1).asset()) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Validate that tokens are not already listed inside this market.
        if (tokensListed.length != 0) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // At least one of the two tokens has to be borrowable or the
        // market does not make any sense to create.
        if (!ICToken(token0).isBorrowable() && !ICToken(token1).isBorrowable()) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // List the tokens, we do this prior since some _afterDeposit
        // hooks could require listing.
        _tokenConfig[token0].isListed = true;
        _tokenConfig[token1].isListed = true;

        // Immediately deposits into the cToken before anyone else can,
        // preventing any rounding attack vectors.
        if (!ICToken(token0).initializeDeposits(msg.sender)) {
            _revert(_INVARIANT_ERROR_SELECTOR);
        }
        
        if (!ICToken(token1).initializeDeposits(msg.sender)) {
            _revert(_INVARIANT_ERROR_SELECTOR);
        }

        // Update `tokenListed` array and emit events for any frontends that
        // need this information.
        tokensListed.push(token0);
        tokensListed.push(token1);
        
        emit TokenListed(token0);
        emit TokenListed(token1);
    }

    /// @notice Sets token liquidity configuration values for
    ///         `newConfig.cToken` a listed cToken inside this market.
    /// @dev Emits a {TokenConfigUpdated} event.
    /// @param newConfig A TokenConfig struct containing:
    ///                  cToken The Curvance token to update liquidity
    ///                         configuration values of.
    ///                  collRatio The ratio at which $1 of collateral can be
    ///                            borrowed against, for `newConfig.cToken`,
    ///                            in `BPS`.
    ///                  collReqSoft The premium of excess collateral required
    ///                              to avoid soft liquidation, in `BPS`.
    ///                  collReqHard The premium of excess collateral required
    ///                              to avoid hard liquidation, in `BPS`.
    ///                  liqIncBase The default liquidation incentive for
    ///                             `newConfig.cToken`, in `BPS`.
    ///                  liqIncHard The hard liquidation incentive for
    ///                             `newConfig.cToken`, in `BPS`.
    ///                  liqIncMin The minimum possible liquidation incentive
    ///                            for `newConfig.cToken` during an auction,
    ///                            in `BPS`.
    ///                  liqIncMax The maximum possible liquidation incentive
    ///                            for `newConfig.cToken` during an auction,
    ///                            in `BPS`.
    ///                  closeFactorBase Maximum % that a liquidator can repay
    ///                                  when soft liquidating
    ///                                  `newConfig.cToken` for an account.
    ///                  closeFactorMin The minimum possible close factor for
    ///                                 `newConfig.cToken` during an auction,
    ///                                 in `BPS`.
    ///                  closeFactorMax The maximum possible close factor for
    ///                                 `newConfig.cToken` during an auction,
    ///                                 in `BPS`.
    ///                  collateralCap The maximum amount of shares that can
    ///                                be collateralized of `newConfig.cToken`
    ///                                inside this market.
    ///                  debtCap The maximum amount of assets that can be
    ///                          borrowed of `newConfig.cToken` inside this
    ///                          market.
    function updateTokenConfig(TokenConfig memory newConfig) external {
        _checkIsListedToken(newConfig.cToken);
        _checkMarketPermissions();

        // Validate collateralization ratio is not above the maximum allowed,
        // and that hard liquidation collateral requirement is not above
        // the soft liquidation requirement. Liquidations occur when
        // collateral dries up so hard liquidation should be less collateral
        // than soft liquidation.
        if (
            newConfig.collRatio > MAX_COLL_RATIO ||
            newConfig.collReqSoft > MAX_COLLATERAL_REQUIREMENT ||
            newConfig.collReqHard >= newConfig.collReqSoft
        ) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Validate hard liquidation incentive is higher than the soft
        // liquidation incentive. We should give heavier incentives when
        // collateral is running out to reduce lender delta exposure.
        // The maximum dynamic penalty is not greater than the base
        // liquidation incentive and that the minimum dynamic penalty is not
        // less than the base liquidation incentive.
        // Validate maximum liquidation incentive and default is
        // equal or higher than the minimum liquidation incentive.
        // Validate minimum liquidation incentive is non-zero to ensure
        // liquidators have economic incentive to perform liquidations.
        // Validate both hard and max liquidation incentives do not exceed
        // the protocol maximum.
        if (
            newConfig.liqIncBase >= newConfig.liqIncHard ||
            newConfig.liqIncBase > newConfig.liqIncMax ||
            newConfig.liqIncBase < newConfig.liqIncMin ||
            newConfig.liqIncMin >= newConfig.liqIncMax ||
            newConfig.liqIncMax > MAX_LIQUIDATION_INCENTIVE ||
            newConfig.liqIncMin == 0 ||
            newConfig.liqIncHard > MAX_LIQUIDATION_INCENTIVE
        ) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Validate hard and max liquidation collateral requirements are larger
        // than the hard liquidation incentive. We cannot give more incentives
        // than are available. We do not need to check soft liquidation as the
        // restrictions are thinner than this case.
        if (
            newConfig.liqIncHard + MIN_EXCESS_COLL_REQUIRED > newConfig.collReqHard ||
            newConfig.liqIncMax + MIN_EXCESS_COLL_REQUIRED > newConfig.collReqHard
        ) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Validate that soft liquidation is within acceptable bounds.
        if (
            newConfig.closeFactorBase > MAX_BASE_CFACTOR ||
            newConfig.closeFactorBase < MIN_BASE_CFACTOR
        ) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Validate closeFactorMin and closeFactorMax are properly configured.
        // closeFactorBase should be between min and max, min should be less
        // than max, but greater than 0, and max cannot exceed BPS.
        if (
            newConfig.closeFactorBase > newConfig.closeFactorMax ||
            newConfig.closeFactorBase < newConfig.closeFactorMin ||
            newConfig.closeFactorMin >= newConfig.closeFactorMax ||
            newConfig.closeFactorMin == 0 ||
            newConfig.closeFactorMax > BPS
        ) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Validate the soft liquidation collateral premium is not stricter
        // than its `collRatio` and has a sufficient buffer against
        // soft liquidation.
        if (
            newConfig.collRatio >
            (MIN_LIQUIDATION_BUFFER / (BPS + newConfig.collReqSoft))
        ) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Validate that collateral is not trying to be turned on without
        // setting a collateralization ratio.
        if (newConfig.collRatio == 0 && newConfig.collateralCap > 0) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Do not let people borrow assets if they are not intended to be.
        if (newConfig.debtCap > 0) {
            if (
                newConfig.debtCap > _MAX_DEBT_CAP ||
                !ICToken(newConfig.cToken).isBorrowable()
            ) {
                _revert(_INVALID_PARAMETER_SELECTOR);
            }
        }

        CurvanceToken storage storedConfig = _tokenConfig[newConfig.cToken];

        // If this token already has collateralization enabled,
        // we cannot turn collateralization off completely as this
        // would cause downstream effects to the DLE.
        if (storedConfig.collRatio != 0 && newConfig.collRatio == 0) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Validate we get a safe price when pricing both as a debt or
        // collateral asset, even if the asset cannot be collateralized.
        (, uint256 errorCode) = CommonLib._oracleManager(centralRegistry)
            .getPrice(newConfig.cToken, true, true);

        // Validate a safe price for our more important action, liquidations.
        if (errorCode == BAD_SOURCE) {
            revert MarketManager__PriceError();
        }

        (, errorCode) = CommonLib._oracleManager(centralRegistry)
            .getPrice(newConfig.cToken, true, false);

        // Validate a safe price for our more important action, liquidations.
        if (errorCode == BAD_SOURCE) {
            revert MarketManager__PriceError();
        }

        // Set new collateralization ratio.
        // Note that a collateralization ratio of 0 corresponds to
        // no collateralization of `cToken`.
        storedConfig.collRatio = uint24(newConfig.collRatio);

        // Store the collateral requirement as a premium above `BPS`,
        // that way we can calculate solvency via division
        // efficiently in _liquidationStatusOf.
        storedConfig.collReqSoft = uint24(newConfig.collReqSoft + BPS);
        storedConfig.collReqHard = uint24(newConfig.collReqHard + BPS);

        // We use the liquidation incentive values as a premium in
        // `_canLiquidate`, so it needs to be 1 + incentive.
        storedConfig.liqIncBase = uint16(BPS + newConfig.liqIncBase);
        storedConfig.liqIncMin = uint16(BPS + newConfig.liqIncMin);
        storedConfig.liqIncMax = uint16(BPS + newConfig.liqIncMax);

        // Store the distance between liquidation incentive A & B,
        // so we can quickly scale between [base, 100%] based on lFactor.
        storedConfig.liqIncCurve = uint16(newConfig.liqIncHard - newConfig.liqIncBase);

        // Assign the base cFactor.
        storedConfig.closeFactorBase = uint16(newConfig.closeFactorBase);
        // Store the distance between base cFactor and 100%,
        // that way we can quickly scale between [base, 100%] based on lFactor.
        storedConfig.closeFactorCurve = uint16(BPS - newConfig.closeFactorBase);

        // Assign the min and max effective closeFactor.
        storedConfig.closeFactorMin = uint16(newConfig.closeFactorMin);
        storedConfig.closeFactorMax = uint16(newConfig.closeFactorMax);

        // Assign the collateral posted cap of `newConfig.cToken`.
        collateralCaps[newConfig.cToken] = newConfig.collateralCap;

        // Assign the outstanding debt cap of `newConfig.cToken`.
        debtCaps[newConfig.cToken] = newConfig.debtCap;

        emit TokenConfigUpdated(newConfig);
    }

    /// @notice Admin function to set market-wide liquidation status.
    /// @dev Requires market permissions, corresponding contracts may restrict
    ///      `state` input. Emits an {ActionPaused} event.
    /// @param state Whether the desired action is pausing or unpausing.
    function setLiquidationPaused(bool state) external {
        _checkMarketPermissions();

        liquidationPaused = state ? 2 : 1;
        emit ActionPaused("Liquidation Paused", state);
    }

    /// @notice Admin function to set market-wide redemption status.
    /// @dev Requires market permissions, corresponding contracts may restrict
    ///      `state` input. Emits an {ActionPaused} event.
    /// @param state Whether redemptions should be paused or unpaused.
    function setRedeemPaused(bool state) external {
        _checkMarketPermissions();

        redeemPaused = state ? 2 : 1;
        emit ActionPaused("Redeem Paused", state);
    }

    /// @notice Admin function to set market-wide transfer status.
    /// @dev Requires market permissions, corresponding contracts may restrict
    ///      `state` input. Emits an {ActionPaused} event.
    /// @param state Whether transfers should be paused or unpaused.
    function setTransferPaused(bool state) external {
        _checkMarketPermissions();

        transferPaused = state ? 2 : 1;
        emit ActionPaused("Transfer Paused", state);
    }

    /// @notice Admin function to set token-specific Curvance token
    ///         minting status.
    /// @dev Requires market permissions, corresponding contracts may restrict
    ///      `state` input. Emits a {TokenActionPaused} event.
    /// @param cToken The Curvance token to set minting status for.
    /// @param state Whether minting should be paused or unpaused.
    function setMintPaused(address cToken, bool state) external {
        _checkMarketPermissions();
        _checkIsListedToken(cToken);

        _tokenConfig[cToken].mintPaused = state ? 2 : 1;
        emit TokenActionPaused(cToken, "Mint Paused", state);
    }

    /// @notice Admin function to set token-specific Curvance token
    ///         collateralization status.
    /// @dev Requires market permissions, corresponding contracts may restrict
    ///      `state` input. Emits a {TokenActionPaused} event.
    /// @param cToken The Curvance token to set collateralization status for.
    /// @param state Whether collateralization should be paused or unpaused.
    function setCollateralizationPaused(address cToken, bool state) external {
        _checkMarketPermissions();
        _checkIsListedToken(cToken);

        _tokenConfig[cToken].collateralizationPaused = state ? 2 : 1;
        emit TokenActionPaused(cToken, "Collateralization Paused", state);
    }

    /// @notice Admin function to set token-specific Curvance token
    ///         borrowing status.
    /// @dev Requires market permissions, corresponding contracts may restrict
    ///      `state` input. Emits a {TokenActionPaused} event.
    /// @param cToken The Curvance token to set borrowing status for.
    /// @param state Whether borrowing should be paused or unpaused.
    function setBorrowPaused(address cToken, bool state) external {
        _checkMarketPermissions();
        _checkIsListedToken(cToken);

        _tokenConfig[cToken].borrowPaused = state ? 2 : 1;
        emit TokenActionPaused(cToken, "Borrow Paused", state);
    }

    /// @notice Adds a new position manager address for complex
    ///         position actions.
    /// @dev Requires timelock authority.
    ///      Emits a {PositionManagerUpdated} event.
    /// @param newPM The address to add position manager permissions for.
    function addPositionManager(address newPM) external {
        _checkMarketPermissions();

        if (
            !ERC165Checker
                .supportsInterface(newPM, type(IPositionManager).interfaceId)
        ) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Validate `newPM` does not have permissions.
        if (isPositionManager[newPM]) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Add `isPositionManager` permissions to `newPM`.
        isPositionManager[newPM] = true;

        emit PositionManagerUpdated(newPM, true);
    }

    /// @notice Removes a current position manager address from complex
    ///         position actions.
    /// @dev Requires timelock authority.
    ///      Emits a {PositionManagerUpdated} event.
    /// @param oldPM The address to remove position manager permissions for.
    function removePositionManager(address oldPM) external {
        _checkMarketPermissions();

        // Validate `oldPM` already has permissions.
        if (!isPositionManager[oldPM]) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Remove `isPositionManager` permissions.
        delete isPositionManager[oldPM];

        emit PositionManagerUpdated(oldPM, false);
    }

    /// @notice Enables an auction-based liquidation, potentially with a dynamic
    ///         close factor and liquidation penalty values in transient storage.
    /// @dev Transient storage enforces any liquidator outside auction-based
    ///      liquidations uses the default risk parameters.
    /// @param cToken The Curvance token to configure liquidations for during
    ///               an auction-based liquidation.
    /// @param incentive The auction liquidation incentive stored BPS
    ///                  multiplier (`BPS + premium`), or 0 to use
    ///                  protocol-derived values.
    /// @param closeFactor The auction close factor value, in raw `BPS`, or
    ///                    0 to use protocol-derived values.
    function setTransientLiquidationConfig(
        address cToken,
        uint256 incentive,
        uint256 closeFactor
    ) external {
        _checkAuctionPermissions();
        _checkIsListedToken(cToken);

         CurvanceToken memory c = _tokenConfig[cToken];

        // Make sure this token actually can be liquidated, by being
        // collateralizable in the first place.
        if (c.collRatio == 0) {
            revert MarketManager__UnauthorizedLiquidation();
        }

        // Validate `incentive` is within configured incentive bounds, unless
        // zero is passed to signal protocol-derived values should be used.
        // This also validates `incentive` is not > the 16 bits we have allocated.
        if (
            incentive != 0 &&
            (incentive < c.liqIncMin || incentive > c.liqIncMax)
        ) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Validate `closeFactor` is within configured allowed close factor
        // range, unless zero is passed to signal protocol-derived values
        // should be used. This also validates `closeFactor` is not > the 16
        // bits we have allocated.
        if (
            closeFactor != 0 &&
            (closeFactor < c.closeFactorMin || closeFactor > c.closeFactorMax)
        ) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        uint256 liqConfig = uint256(uint160(cToken));
        assembly {
            // Mask `liqConfig` to the lower 160 bits, in case the upper bits
            // somehow are not clean.
            liqConfig := and(liqConfig, _BITMASK_COLLATERAL_UNLOCKED)
            // Equals: liqConfig | (incentive << _BITPOS_LIQ_INCENTIVE) |
            //         closeFactor << _BITPOS_CLOSE_FACTOR.
            liqConfig := or(
                liqConfig,
                or(
                    shl(_BITPOS_LIQ_INCENTIVE, incentive),
                    shl(_BITPOS_CLOSE_FACTOR, closeFactor)
                )  
            )

            tstore(_TRANSIENT_LIQUIDATION_CONFIG_KEY, liqConfig)
        }
    }

    /// @notice Called from the AuctionManager as a post hook after liquidations
    ///         are tried to enable all collateral to be liquidated outside
    ///         an Auction tx.
    /// @notice Resets the liquidation risk parameters in transient storage to
    ///         zero.
    /// @dev This is redundant since the transient values will be reset after
    ///      the liquidation transaction, but can be useful during meta calls
    ///      with multiple liquidations during a single transaction. 
    function resetTransientLiquidationConfig() external {
        _checkAuctionPermissions();

        /// @solidity memory-safe-assembly
        assembly {
            tstore(_TRANSIENT_LIQUIDATION_CONFIG_KEY, 0)
        }
    }

    /// PUBLIC FUNCTIONS ///

    /// @notice Returns the current liquidation configuration in an active
    ///         transaction.
    /// @dev If a liquidation configuration value is set in transient storage,
    ///      that value is returned, 0 is returned if no set value.
    /// @return cTokenUnlocked The Curvance token unlocked for auction-based
    ///                        liquidations.
    /// @return incentive The liquidation incentive stored BPS multiplier
    ///                   (`BPS + premium`), or 0 if unset.
    /// @return closeFactor The close factor value, in raw `BPS`, or 0 if
    ///                     unset.
    function getTransientLiquidationConfig() public view returns (
        address cTokenUnlocked,
        uint256 incentive,
        uint256 closeFactor
    ) {
        uint256 liqConfig;
        /// @solidity memory-safe-assembly
        assembly {
            liqConfig := tload(_TRANSIENT_LIQUIDATION_CONFIG_KEY)
        }

        cTokenUnlocked = address(uint160(liqConfig));
        incentive = uint16(liqConfig >> _BITPOS_LIQ_INCENTIVE);
        closeFactor = uint16(liqConfig >> _BITPOS_CLOSE_FACTOR);
    }

    /// @dev Returns true that this contract implements both IMarketManager
    ///      and ERC165 interfaces.
    /// @param interfaceId The interface ID to check.
    /// @return result Whether the contract implements the interface.
    function supportsInterface(
        bytes4 interfaceId
    ) public view override returns (bool result) {
        result = interfaceId == type(IMarketManager).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Checks if the account should be allowed to borrow
    ///         the underlying asset of the given market.
    /// @dev Will natively revert if a hypothetical new borrow will result in
    ///      a loan less than `MIN_LOAN_SIZE`,
    ///      set in `LiquidityManager`. May emit a {PositionUpdated} event.
    /// @param debtToken The token to borrow from.
    /// @param assets The amount of underlying the account would borrow.
    /// @param account The account which would borrow the asset.
    /// @param newNetDebt The amount of assets that would be
    ///                   outstanding debt in total if allowed. 
    function _canBorrow(
        address debtToken,
        uint256 assets,
        address account,
        uint256 newNetDebt
    ) internal {
        _checkIsToken(debtToken);
        // Can skip token listing check since debtCaps[debtToken] can only
        // be set above 0 if `debtToken` is listed already, so we only need
        // to check that `newNetDebt` != 0 instead, which should be impossible
        // but only costs 2 gas.

        /// @solidity memory-safe-assembly
        assembly {
            if iszero(newNetDebt) {
                mstore(0x00, _INVARIANT_ERROR_SELECTOR)
                // Return bytes 29-32 for the selector.
                revert(0x1c, 0x04)
            }
        }

        if (_tokenConfig[debtToken].borrowPaused == 2) {
            revert MarketManager__Paused();
        }

        // Validates that newNetDebt is not an empty value and this borrow
        // action will not push net debt above the debt limit.
        // DEV: By rounding up the debt of each user, up to 1 wei for each
        // time a user has their interest accrued, the actual sum of user
        // debts may exceed marketOutstandingDebt and thus debtCap.
        if (newNetDebt > debtCaps[debtToken]) {
            revert MarketManager__CapReached();
        }

        // Check if the user already has an outstanding debt position in
        // `debtToken`.
        if (accountPositions[debtToken][account] != 2) {
            // The account does not have outstanding debt position in
            // `debtToken`, so add `debtToken` as an active position for
            // `account`.
            accountPositions[debtToken][account] = 2;
            accountAssets[account].assets.push(debtToken);

            emit PositionUpdated(debtToken, account, true);
        }

        // Check if the user has sufficient liquidity to borrow,
        // with heavier error code scrutiny.
        (, uint256 liquidityDeficit) = _hypotheticalLiquidityOf(
                account,
                HypotheticalAction({
                    cTokenModified: debtToken,
                    redemptionShares: 0,
                    borrowAssets: assets,
                    errorCodeBreakpoint: CAUTION
                })
            );

        // Validate that `account` will not run out of collateral based
        // on their collateralization ratio(s).
        if (liquidityDeficit > 0) {
            revert MarketManager__InsufficientCollateral();
        }
    }

    /// @notice Checks if the account should be allowed to redeem tokens
    ///         in the given market, and then redeems.
    /// @dev This can only be called by the cToken itself.
    /// @param cToken The token to verify the redemption against.
    /// @param shares The number of cToken shares to redeem for the
    ///               underlying asset in the market.
    /// @param account The account which would redeem `shares`.
    /// @param balance The current cToken share balance of `account`.
    /// @param collateralPosted The current cToken shares posted as
    ///                         collateral by `account`.
    /// @param isCollateral Boolean indicating whether the token is currently
    ///                     being used as collateral.
    /// @param forceRedeemCollateral Whether the collateral should be force
    ///                              reduced, used if isCollateral is true.
    /// @return collateralRedeemed The amount of collateral shares redeemed.
    function _canRedeem(
        address cToken,
        uint256 shares,
        address account,
        uint256 balance,
        uint256 collateralPosted,
        bool isCollateral,
        bool forceRedeemCollateral
    ) internal returns (uint256 collateralRedeemed) {
        _checkIsListedToken(cToken);
        _checkTransfersAllowed(account);

        if (isCollateral) {
            // If collateral is being directly removed by user intention,
            // or liquidation we can skip balance checks.
            if (forceRedeemCollateral) {
                // Explicitly revert here if trying to redeem too much
                // collateral rather than panic revert.
                if (shares > collateralPosted) {
                    revert MarketManager__InsufficientCollateral();
                }

                collateralRedeemed = shares;
            } else {
                // We know that shares <= balance because of
                // `_checkRedemption` check inside cToken contracts prior so
                // no need for overflow check here. If they want to redeem
                // more `cToken` shares than they have idle, calculate how
                // much posted collateral will be redeemed from the delta.
                // Otherwise `collateralRedeemed` = 0 is correct. 
                if (collateralPosted + shares >= balance) {
                    collateralRedeemed = collateralPosted + shares - balance;
                }
            }
        }

        // If `collateralRedeemed` is 0 or the account does not have an
        // active position in `cToken`, we can bypass the liquidity check.
        if (collateralRedeemed == 0 || accountPositions[cToken][account] != 2) {
            return collateralRedeemed;
        }

        // Check account liquidity with hypothetical cToken redemption.
        (, uint256 liquidityDeficit) = _hypotheticalLiquidityOf(
                account,
                HypotheticalAction({
                    cTokenModified: cToken,
                    redemptionShares: collateralRedeemed,
                    borrowAssets: 0,
                    errorCodeBreakpoint: CAUTION
                })
            );

        // Validate that `account` will not run out of collateral based
        // on their collateralization ratio(s).
        if (liquidityDeficit > 0) {
            revert MarketManager__InsufficientCollateral();
        }
    }

    /// @notice Determines if an account can be liquidated and calculates
    ///         liquidation parameters. Computes liquidation amounts,
    ///         collateral seizure, and potential bad debt based on `account`
    ///         health.
    /// @param debtAmount The amount of debt to repay, used only if
    ///                   `liquidateExact` is true, in assets.
    /// @param account The address of the account being evaluated for
    ///                liquidation.
    /// @param tData A TokenLiqData struct containing:
    ///              collateralToken The token which is used as collateral
    ///                               by `account` and may be seized.
    ///              collateralExchangeRate The exchange rate of
    ///                                     `collateralToken` underlying token
    ///                                     to `collateralToken`.
    ///              collateralReqSoft The collateral requirement where
    ///                                dipping below this will cause a soft
    ///                                liquidation.
    ///              collateralReqHard The collateral requirement where
    ///                                dipping below this will cause a hard
    ///                                liquidation.
    ///              collateralUnderlyingPrice The current price of the
    ///                                        underlying token of
    ///                                        `collateralToken`.
    ///              collateralDecimals The decimals that `collateralToken`
    ///                                 is measured in.
    ///              debtToken The token to potentially repay which has
    ///                        outstanding debt by `account`.
    ///              debtDecimals The decimals that `debtToken` is measured
    ///                           in.
    ///              debtUnderlyingPrice The current price of the underlying
    ///                                  token of `debtToken`.
    ///              auctionBuffer The current buffer that `cSoft` and `cHard` are
    ///                            multiplied against, 10 bps, or 0 if not an
    ///                            auction-based liquidation.
    /// @param aData An AccountLiqData struct containing:
    ///              lFactor Empty variable to hold an account's liquidation
    ///                      factor later.
    ///              debtBalance Empty variable to hold an account's debt's 
    ///                          active debt to `tData.debtToken` later.
    ///              liqInc The ratio at which debt repayment will be
    ///                     compensated on liquidation.
    ///              liqIncBase The base ratio at which debt repayment will be
    ///                         compensated on soft liquidation.
    ///              liqIncCurve The liquidation incentive curve length
    ///                          between soft liquidation to hard liquidation.
    ///              closeFactor Maximum debt % that a liquidator can repay
    ///                          during a liquidation of an account.
    ///              closeFactorBase Maximum debt % that a liquidator can
    ///                              repay when soft liquidating an account.
    ///              closeFactorCurve Curve length between soft liquidation
    ///                               and hard liquidation, should be equal
    ///                               to 100% - `closeFactorBase`.
    /// @param liquidateExact If true, liquidate exactly `debtAmount`; if
    ///                       false, liquidate maximum possible.
    /// @return liquidatedShares The amount of `tData.collateralToken`
    ///                          that will be seized as collateral.
    /// @return uint256 The amount of `debtToken` outstanding debt that will be
    ///                 repaid.
    /// @return badDebt The amount of bad debt to recognize as part of the
    ///                 liquidation (if any).
    function _canLiquidate(
        uint256 debtAmount,
        address account,
        TokenLiqData memory tData,
        AccountLiqData memory aData,
        bool liquidateExact
    ) internal view returns (
        uint256 liquidatedShares,
        uint256,
        uint256 badDebt
    ) {
        // Calculate the users lFactor and bubble up their active debt.
        (aData.lFactor, aData.debtBalance) =
            _liquidationValuesOf(account, tData);

        if (aData.lFactor == 0) {
            return (0, 0, 0);
        }

        // If this liquidation does not have offchain submitted parameters
        // then closeFactorCurve and liqIncCurve will not be 0. Because
        // closeFactorCurve is BPS - closeFactorBase and closeFactorBase is
        // limited to MAX_BASE_CFACTOR meaning closeFactorCurve cannot ever be
        // 0. liqIncCurve cannot be zero due to the `updateTokenConfig`
        // c.liqIncBase >= c.liqIncHard inline check.
        if (aData.closeFactorCurve != 0) {
            aData.closeFactor = aData.closeFactorBase +
                _mulDiv(aData.closeFactorCurve, aData.lFactor, WAD);
        }

        if (aData.liqIncCurve != 0) {
            aData.liqInc = aData.liqIncBase +
                _mulDiv(aData.liqIncCurve, aData.lFactor, WAD);
        }
        
        // Get the exchange rate, and calculate the number of collateralized
        // shares to seize.
        // Convert liqInc to WAD via `WAD_SQUARED_BPS_OFFSET` so we dont run
        // into precision loss from only multiplying into WAD_SQUARED form.
        uint256 debtToCollateral = FixedPointMathLib.fullMulDiv(
            FixedPointMathLib.fullMulDiv(
                aData.liqInc * tData.debtUnderlyingPrice,
                WAD_SQUARED_BPS_OFFSET,
                tData.collateralSharesPrice
            ),
            tData.collateralDecimals,
            tData.debtDecimals
        );
        uint256 maxDebt = (aData.closeFactor * aData.debtBalance) / BPS;
        // If they want to liquidate an exact amount, liquidate `debtAmount`,
        // otherwise liquidate the maximum amount possible.
        if (!liquidateExact) {
            debtAmount = maxDebt;
        }
        
        // Calculate how many shares should be liquidated.
        liquidatedShares = FixedPointMathLib.fullMulDiv(
            debtAmount,
            debtToCollateral,
            WAD_SQUARED
        );

        // Cache `account`'s collateral posted of
        // `tData.collateralToken`.
        uint256 sharesPosted =
            ICToken(tData.collateralToken).collateralPosted(account);

        // If the user wants to liquidate an exact amount, make sure theres
        // enough collateral available to liquidate, otherwise
        // liquidate as much as possible.
        if (liquidateExact) {
            if (debtAmount > maxDebt || liquidatedShares > sharesPosted) {
                // Make sure that the liquidation limit,
                // and collateral posted >= amount.
                _revert(_INVALID_PARAMETER_SELECTOR);
            }
        } else {
            // If there is not enough shares available for liquidation,
            // liquidate what is available.
            if (liquidatedShares > sharesPosted) {
                debtAmount = FixedPointMathLib.fullMulDivUp(
                    debtAmount,
                    sharesPosted,
                    liquidatedShares
                );
                liquidatedShares = sharesPosted;
            }
        }

        // If the necessary collateral shares to liquidate `account`'s debt is
        // more than their shares posted, there is bad debt that should be
        // socialized among lenders, calculate using the same formula we used
        // for `liquidatedShares`.
        uint256 sharesNeeded = FixedPointMathLib.fullMulDivUp(
            aData.debtBalance,
            debtToCollateral,
            WAD_SQUARED
        );
        if (sharesNeeded > sharesPosted) {
            // Calculate total debt necessary to compensate liquidators
            // in full based on `sharesNeeded` vs `sharesPosted`.
            // `sharesPosted` = `sharesNeeded` / 2 means 50%
            // of debt should be recognized as bad debt, so this
            // intermediary step for `badDebt` would be 2x `debtAmount`.
            // Invariant: `sharesPosted > 0` here. Any liquidation that
            // zeroes shares also zeroes debt via the clamp below, so a
            // follow-up call cannot enter this branch with sharesPosted=0.
            badDebt = FixedPointMathLib
                .fullMulDivUp(debtAmount, sharesNeeded, sharesPosted);

            // Calculate if compensation calculation will overflow, this can
            // happen in scenarios where collateral goes to near 0.
            // If it would cause an underflow -> clamp the bad debt down,
            // siding with lenders over liquidators.
            if (badDebt > aData.debtBalance) {
                // CASE: Unhappy path, collateral went to near zero, reduce
                // bad debt and keep liquidator's `debtAmount` consistent.
                badDebt = aData.debtBalance - debtAmount;
            } else {
                // CASE: Happy path, normal calculation of recognizing bad
                // debt pro-rata based on shortfall of `sharesNeeded` versus
                // sharesPosted.
                badDebt = badDebt - debtAmount;
            }
        }

        // Calculate the maximum amount of debt that can be liquidated
        // and what collateral will be received. As well as any bad debt
        // to recognize.
        return (liquidatedShares, debtAmount, badDebt);
    }

    /// @notice Retrieves and caches liquidation configuration data for a
    ///         given token pair.
    /// @param collateralToken The address of the Curvance token to be seized
    ///                        during in the liquidation.
    /// @param debtToken The address of the Curvance token to be repaid during
    ///                  the liquidation.
    /// @return tData A TokenLiqData struct containing:
    ///               collateralToken The token which is used as collateral
    ///                               by `account` and may be seized.
    ///               collateralExchangeRate The exchange rate of
    ///                                      `collateralToken` underlying
    ///                                      token to `collateralToken`.
    ///               collateralReqSoft The collateral requirement where
    ///                                 dipping below this will cause a soft
    ///                                 liquidation.
    ///               collateralReqHard The collateral requirement where
    ///                                 dipping below this will cause a hard
    ///                                 liquidation.
    ///               collateralUnderlyingPrice The current price of the
    ///                                         underlying token of
    ///                                         `collateralToken`.
    ///               collateralDecimals The decimals that `collateralToken`
    ///                                  is measured in.
    ///               debtToken The token to potentially repay which has
    ///                         outstanding debt by `account`.
    ///               debtDecimals The decimals that `debtToken` is measured
    ///                            in.
    ///               debtUnderlyingPrice The current price of the underlying
    ///                                   token of `debtToken`.
    ///               auctionBuffer The current buffer that `cSoft` and `cHard` are
    ///                             multiplied against, 10 bps, or 0 if not an
    ///                             an auction-based liquidation.
    /// @return aData An AccountLiqData struct containing:
    ///               lFactor Empty variable to hold an account's liquidation
    ///                       factor later.
    ///               debtBalance Empty variable to hold an account's debt's 
    ///                           active debt to `tData.debtToken` later.
    ///               liqInc The ratio at which debt repayment will be
    ///                      compensated on liquidation.
    ///               liqIncBase The base ratio at which debt repayment will
    ///                          be compensated on soft liquidation.
    ///               liqIncCurve The liquidation incentive curve length
    ///                           between soft liquidation to hard
    ///                           liquidation.
    ///               closeFactor Maximum debt % that a liquidator can repay
    ///                           during a liquidation of an account.
    ///               closeFactorBase Maximum debt % that a liquidator can
    ///                               repay when soft liquidating an account.
    ///               closeFactorCurve Curve length between soft liquidation
    ///                                and hard liquidation, should be equal
    ///                                to 100% - `closeFactorBase`.
    function _getLiquidationConfig(
        address collateralToken,
        address debtToken
    ) internal returns (
        TokenLiqData memory tData,
        AccountLiqData memory aData
    ) {
        CurvanceToken memory c = _tokenConfig[collateralToken];
        // Do not let people liquidate 0% collateralization ratio assets.
        if (c.collRatio == 0) {
            _revert(_INVALID_PARAMETER_SELECTOR);
        }

        // Will revert if this liquidation is an attempted auction liquidator
        // and liquidator has chosen incorrect collateral or market.
        // Pulls any relevant offchain liquidation configuration.
        (tData.auctionBuffer, aData.liqInc, aData.closeFactor) =
            _checkLiquidationConfig(collateralToken);

        // Liquidations are only blocked if an error code of 2 (NO_SOURCE)
        // is calculated.
        (tData.collateralSharesPrice, tData.debtUnderlyingPrice) =
            CommonLib._oracleManager(centralRegistry)
                .getPriceIsolatedPair(collateralToken, debtToken, BAD_SOURCE);

        // Cache all variables needed for computing liquidation levels.
        tData.collateralToken = collateralToken;
        tData.collateralReqSoft = c.collReqSoft;
        tData.collateralReqHard = c.collReqHard;
        tData.collateralDecimals = 10 ** IERC20(collateralToken).decimals();
        tData.debtToken = debtToken;
        tData.debtDecimals = 10 ** IERC20(debtToken).decimals();

        // We only need to cache these variables if we did not receive close
        // factor/liquidation incentive from `getLiquidationConfig`.
        if (aData.closeFactor == 0) {
            aData.closeFactorBase = c.closeFactorBase;
            aData.closeFactorCurve = c.closeFactorCurve;
        }

        if (aData.liqInc == 0) {
            aData.liqIncBase = c.liqIncBase;
            aData.liqIncCurve = c.liqIncCurve;
        }
    }

    /// @notice Check whether the hold period is met.
    /// @param account The account to check the hold period for.
    function _checkHoldPeriod(address account) internal view {
        // We require a `minimumHoldPeriod` to break flashloan
        // and multi-block price manipulations if the dynamic dual oracle
        // fails to protect the market somehow.
        if (
            accountAssets[account].cooldownTimestamp + MIN_HOLD_PERIOD >
            block.timestamp
        ) {
            revert MarketManager__MinimumHoldPeriod();
        }
    }

    /// @notice Checks whether `token` is listed in this Market Manager.
    /// @param token The token to check whether it's listed or not.
    function _checkIsListedToken(address token) internal view {
        if (!_tokenConfig[token].isListed) {
            revert MarketManager__TokenNotListed();
        }
    }

    /// @dev Checks whether the caller is `token`.
    function _checkIsToken(address token) internal view {
        /// @solidity memory-safe-assembly
        assembly {
            // Equal to if (msg.sender != token)
            if iszero(eq(caller(), token)) {
                mstore(0x00, _UNAUTHORIZED_SELECTOR)
                // Return bytes 29-32 for the selector.
                revert(0x1c, 0x04)
            }
        }
    }

    /// @dev Checks whether `account` has token transfers enabled.
    function _checkTransfersAllowed(address account) internal view {
        if (centralRegistry.checkTransfersDisabled(account)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }

        _checkHoldPeriod(account);
    }

    /// @notice Will revert and block liquidations of collateral that are not
    ///         currently allowed by Auction, only if this is an Auction tx.
    /// @param cToken The address of the collateral token to liquidate.
    /// @return The buffer priority value to apply as a discount to collateral
    ///         during auctioned liquidations.
    function _checkLiquidationConfig(
        address cToken
    ) internal view returns (uint256, uint256, uint256) {
        (address unlockedCToken, uint256 liqIncentive, uint256 closeFactor) =
            getTransientLiquidationConfig();

        bool unlockedMarket = centralRegistry.isMarketUnlocked();
        bool unlockedCollateral = unlockedCToken == cToken;

        if (unlockedMarket || unlockedCollateral) {
            // This is an attempted auction liquidation, and is configured
            // correctly so give them the auction priority buffer.
            if (unlockedMarket && unlockedCollateral) {
                return (AUCTION_BUFFER, liqIncentive, closeFactor);
            }

            // This is an attempted auction liquidation, but its misconfigured
            // and unauthorized because of this.
            revert MarketManager__UnauthorizedLiquidation();
        }

        // This is not an attempted auction liquidation, so approve the
        // liquidation, but without any offchain liquidation config values.
        return (0, 0, 0);
    }

    /// @dev Checks whether the caller has sufficient permissioning.
    ///      NOTE: Market Permissioned contracts should have corresponding
    ///            restrictions handled within the contract itself such as
    ///            enforcing a specific party to pause but not unpause
    ///            markets.
    function _checkMarketPermissions() internal view virtual {
        if (!centralRegistry.hasMarketPermissions(msg.sender)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }
    }

    /// @dev Checks whether the caller has sufficient permissioning.
    function _checkAuctionPermissions() internal view {
        if (!centralRegistry.hasAuctionPermissions(msg.sender)) {
            _revert(_UNAUTHORIZED_SELECTOR);
        }
    }

    /// @dev Returns the Protocol Central Registry contract in interface
    ///      form.
    function _getCentralRegistry()
        internal
        view
        override
        returns (ICentralRegistry)
    {
        return centralRegistry;
    }
}

// contracts/market/optimizer/LendingOptimizer.sol

/// @title Curvance Lending Optimizer Vault.
/// @notice Optimizes yield across multiple Curvance lending markets
///         for a single underlying asset.
/// @dev This contract is ERC4626-like with multi-market allocation
///      support, enabling users to deposit a single asset and have it
///      distributed across multiple Curvance lending markets (cTokens)
///      based on configurable allocation caps.
///      Preview and max methods are estimates, not exact settlement guarantees:
///      state-changing entrypoints accrue underlying markets before routing,
///      and cToken rounding or liquidity can make actual results differ.
///      The share token is intentionally not vanilla ERC20:
///      zero-amount transfers and self-transfers revert, and share movement
///      accrues underlying market NAV before execution.
///
///      Deposits and withdrawals are routed pro-rata across approved
///      markets to maintain current allocation percentages. Only
///      `rebalance()` can shift allocation percentages.
///
///      Yield from underlying cToken markets is absorbed immediately
///      into `_totalAssets` on every accrual (cToken-style). Since
///      `_accrueIfNeeded()` runs before every user action, frontrunning
///      is blocked: depositors earn from block 1 with no temporary loss.
///
///      Performance fees are charged on yield above a high watermark,
///      ensuring fees are only taken on new all-time-high profits. This
///      prevents double-charging after drawdowns recover.
///
///      Shares represent proportional ownership of total assets across
///      all markets. The exchange rate is calculated as:
///      `(totalAssets * WAD) / totalSupply`.
///
///      Allocation caps (stored internally in WAD, configured in BPS)
///      define the maximum percentage each market can hold. The sum of
///      all caps must be >= 100% to ensure
///      full allocation is possible. Authorized harvesters can rebalance
///      assets across markets while respecting these caps.
///
///      Dead shares minted to address(0) on initialization prevent
///      inflation attacks. All state-changing functions have reentrancy
///      protection.
contract LendingOptimizer is ILendingOptimizer, ERC4626, ReentrancyGuard, ERC165 {

    /// TYPES ///

    /// @notice Represents a single reallocation operation for moving assets between markets.
    /// @dev Used in rebalance() and removeApprovedAsset(). In rebalance(),
    ///      positive values indicate deposits and negative values indicate
    ///      withdrawals. In removeApprovedAsset(), values represent BPS
    ///      percentages (1-10000) that must sum to exactly 10000.
    struct ReallocationAction {
        /// @notice The cToken market to interact with.
        IBorrowableCToken cToken;
        /// @notice In rebalance(): the amount of underlying assets to deposit
        ///         (positive) or withdraw (negative).
        ///         In removeApprovedAsset(): the BPS percentage of redeemed assets.
        int256 assetsOrBps;
    }

    /// @notice Bounds for post-rebalance allocation validation per market.
    /// @dev Used to protect against race conditions where market state
    ///      changes between off-chain computation and on-chain execution.
    struct AllocationBound {
        /// @notice The cToken market address. Must match approvedCTokensList
        ///         ordering to commit the caller to a specific market layout.
        address cToken;
        /// @notice Minimum allocation in BPS for this market.
        uint256 minBps;
        /// @notice Maximum allocation in BPS for this market.
        uint256 maxBps;
    }

    /// CONSTANTS ///

    /// @dev Maximum fee in BPS (50% = 5000 BPS).
    uint256 public constant MAX_FEE_BPS = 5000;
    /// @dev Maximum number of supported markets.
    uint256 public constant MAX_MARKETS = 8;
    /// @dev Minimum allowed value for ReallocationAction.assetsOrBps (withdrawals).
    ///      type(int256).min is the only int256 value whose negation overflows,
    ///      so we set the floor to type(int256).min + 1.
    int256 public constant MIN_REALLOCATION_AMOUNT = type(int256).min + 1;
    /// @dev The base underlying asset requirement held in order to minimize
    ///      rounding exploits, and more generally, invariant manipulation.
    uint256 internal constant _BASE_UNDERLYING_RESERVE = 77777;

    /// @dev Minimum acceptable trackedAssets from the initial deposit.
    ///      Ensures cToken rounding never silently reduces the dead share
    ///      count below a safe threshold. Set to _BASE_UNDERLYING_RESERVE - 7
    ///      to tolerate minor rounding while catching pathological cases.
    uint256 internal constant _BASE_UNDERLYING_RESERVE_FLOOR = 77770;

    /// STORAGE ///

    /// @notice The underlying asset address.
    IERC20 public immutable _asset;
    /// @notice Token name for the optimizer shares.
    string internal _name;
    /// @notice Token symbol for the optimizer shares.
    string internal _symbol;
    /// @notice Underlying token decimals.
    uint8 internal immutable _decimals;
    /// @notice List of approved cTokens for allocation.
    address[] public approvedCTokensList;
    /// @notice Allocation cap per cToken in WAD (1e18 = 100%).
    mapping(address => uint256) public allocationCaps;
    /// @notice Performance fee in BPS.
    uint256 public fee;
    /// @notice Highest exchange rate ever achieved (for fee calculation).
    uint256 public exchangeRateHighWatermark;
    /// @notice Last recognized total assets.
    uint256 internal _totalAssets;
    /// @notice Whether deposits are enabled.
    /// @dev 0 = uninitialized; 1 = active; 2 = paused.
    uint8 public mintPaused;
    /// @notice Central registry for permissions and market manager lookups.
    ICentralRegistry public immutable centralRegistry;

    /// EVENTS ///

    event MarketAdded(address indexed cToken, uint256 allocationCap);
    event MarketRemoved(address indexed cToken);
    event AllocationCapUpdated(address indexed cToken, uint256 newCap);
    event FeeUpdated(uint256 newFee);
    event Rebalanced(uint256 totalAssets, address[] markets, uint256[] allocations);
    event PerformanceFeeAccrued(uint256 feeShares, address indexed recipient);
    event ActionPaused(string action, bool state);
    event ExcessRecovered(uint256 amount, address indexed recipient);

    /// ERRORS ///

    error LendingOptimizer__Unauthorized();
    error LendingOptimizer__ZeroAmount();
    error LendingOptimizer__InvalidParameter();
    error LendingOptimizer__TooManyMarkets();
    error LendingOptimizer__ArrayLengthMismatch();
    error LendingOptimizer__InvalidUnderlying();
    error LendingOptimizer__InvalidMarketManager();
    error LendingOptimizer__InsufficientAllocationCaps();
    error LendingOptimizer__MarketNotApproved();
    error LendingOptimizer__MarketAlreadyApproved();
    error LendingOptimizer__AllocationExceedsCap();
    error LendingOptimizer__AssetMismatch();
    error LendingOptimizer__FeeTooHigh();
    error LendingOptimizer__InsufficientLiquidity();
    error LendingOptimizer__NotInitialized();
    error LendingOptimizer__AlreadyInitialized();
    error LendingOptimizer__MintPaused();
    error LendingOptimizer__MarketPaused();
    error LendingOptimizer__AllocationOutOfBounds();

    /// @notice Deploys a new LendingOptimizer for a single underlying asset.
    /// @dev Performs four categories of setup:
    ///      1. Validation -- enforces array bounds, length parity, fee ceiling,
    ///         per-market cap range (0 < cap <= 100%), no duplicates, correct
    ///         underlying asset, and registered market manager for each cToken.
    ///      2. ERC20 metadata -- derives the share token name/symbol/decimals
    ///         from offchain-managed vault labels and the underlying asset symbol.
    ///      3. Market registration -- converts each allocation cap from BPS to
    ///         WAD and stores the approved cToken list. Reverts if total caps
    ///         sum to less than 100%.
    ///      4. Fee initialization -- stores the performance fee in BPS and sets
    ///         the high watermark to WAD (1:1 exchange rate).
    ///
    ///      After construction the optimizer is NOT yet active; `initializeDeposits()`
    ///      must be called to mint dead shares and enable deposits.
    /// @param asset_ The underlying ERC20 asset (e.g. USDC).
    /// @param vaultNamePrefix_ Vault name prefix (e.g. Flagship, Prime).
    /// @param vaultSymbolPrefix_ Vault symbol prefix (e.g. Flag, Prime).
    /// @param _centralRegistry Protocol registry for permissions and market manager lookups.
    /// @param _approvedCTokens Initial set of Curvance cToken markets (max 8).
    /// @param _allocationCapsBps Per-market allocation caps in BPS (1-10000). Must sum >= 10000.
    /// @param _feeBps Performance fee in BPS charged on yield above the high watermark (max 5000).
    constructor(
        IERC20 asset_,
        string memory vaultNamePrefix_,
        string memory vaultSymbolPrefix_,
        ICentralRegistry _centralRegistry,
        address[] memory _approvedCTokens,
        uint256[] memory _allocationCapsBps,
        uint256 _feeBps
    ) {
        uint256 numApprovedCTokens = _approvedCTokens.length;

        // Revert if trying to add more than `MAX_MARKETS`.
        if (numApprovedCTokens > MAX_MARKETS) revert LendingOptimizer__TooManyMarkets();
        if (numApprovedCTokens == 0) revert LendingOptimizer__InvalidParameter();
        // Revert if constructor's arrays mismatch in length.
        if (numApprovedCTokens != _allocationCapsBps.length) revert LendingOptimizer__ArrayLengthMismatch();
        // Revert if the performance fee is more than the allowed max.
        if (_feeBps > MAX_FEE_BPS) revert LendingOptimizer__FeeTooHigh();

        // Set essential storage slots.
        centralRegistry = _centralRegistry;
        _asset = asset_;
        _name = string.concat(vaultNamePrefix_, " ", asset_.symbol(), " Vault");
        _symbol = string.concat(vaultSymbolPrefix_, asset_.symbol());
        _decimals = asset_.decimals();
        // Store fee as BPS.
        fee = _feeBps;

        // Counter to find the sum of all allocation amounts.
        uint256 totalAllocation;

        // Loop through all cTokens and validate.
        for (uint256 i; i < numApprovedCTokens; ++i) {
            // Revert if allocation cap is 0 which would cause a dead market,
            // and also prevent allocating cap > 100% to cause dirty allocation math.
            if (_allocationCapsBps[i] == 0 || _allocationCapsBps[i] > BPS)
                    revert LendingOptimizer__InvalidParameter();

            address cToken = _approvedCTokens[i];

            // Revert if the cToken has already been added (duplicate check).
            if (allocationCaps[cToken] != 0) revert LendingOptimizer__MarketAlreadyApproved();

            // Validate the cToken's underlying and market manager.
            _validateCToken(cToken);

            // Convert cap from BPS to WAD.
            uint256 alloCapWAD = _bpsToWad(_allocationCapsBps[i]);
            // Store cap into allocation cap mapping.
            allocationCaps[cToken] = alloCapWAD;
            // Add alloCapWAD to the totalAllocation counter.
            totalAllocation += alloCapWAD;
        }

        // Revert if the totalAllocation is less than 100% (WAD).
        if (totalAllocation < WAD) revert LendingOptimizer__InsufficientAllocationCaps();

        // Store the provided cToken list.
        approvedCTokensList = _approvedCTokens;
        // Store the high watermark exchange rate as 100% (WAD).
        exchangeRateHighWatermark = WAD;
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Initializes the optimizer with dead shares to prevent inflation attacks.
    /// @dev This initial mint is a failsafe against rounding exploits.
    ///      Must be called before any deposits can be made.
    /// @param targetMarket The address of the market to deposit initial assets into.
    function initializeDeposits(
        address targetMarket
    ) external nonReentrant {
        // Revert if the caller does not have market permissions.
        _hasMarketPermissions();

        // Revert if the market has already been initialized.
        if (mintPaused != 0) revert LendingOptimizer__AlreadyInitialized();
        // Revert if the target market is not approved.
        if (!_isApprovedMarket(targetMarket)) revert LendingOptimizer__MarketNotApproved();
        _approvedMarketIndex(targetMarket, approvedCTokensList.length);

        // Transfer _BASE_UNDERLYING_RESERVE assets.
        uint256 assets = _BASE_UNDERLYING_RESERVE;
        SafeTransferLib.safeTransferFrom(address(_asset), msg.sender, address(this), assets);

        // Deposit into target market.
        uint256 trackedAssets = _depositToMarket(targetMarket, assets);
        // Sanity check: revert if cToken rounding reduced the dead share
        // count below the safety floor. This should never happen at
        // initialization (1:1 exchange rate) but guards against edge cases.
        if (trackedAssets < _BASE_UNDERLYING_RESERVE_FLOOR) revert LendingOptimizer__InvalidParameter();

        // Update _totalAssets with the actual recoverable value.
        _totalAssets += trackedAssets;

        // Mint dead shares equal to actual tracked assets.
        // We use trackedAssets (returned by _depositToMarket) rather than input assets
        // because cToken share rounding may cause the recoverable value to differ
        // slightly from the input. This ensures the initial exchange rate is exactly 1:1.
        _mint(address(0), trackedAssets);

        // Set mintPaused to 1 to indicate deposits are active.
        mintPaused = 1;

        emit Deposit(msg.sender, address(0), assets, trackedAssets);
    }

    /// @notice ERC4626-like deposit - deposits pro-rata across active
    ///         markets to maintain current allocation percentages.
    /// @param assets The amount of underlying assets to deposit.
    /// @param receiver The address to receive the minted shares.
    /// @return shares The amount of shares minted.
    function deposit(
        uint256 assets,
        address receiver
    ) public override(ERC4626, ILendingOptimizer) nonReentrant returns (uint256 shares) {
        if (assets == 0) revert LendingOptimizer__InvalidParameter();
        if (receiver == address(0)) revert LendingOptimizer__InvalidParameter();
        _checkMintPaused();
        _accrueIfNeeded();

        // Pull assets from the caller into the optimizer.
        SafeTransferLib.safeTransferFrom(address(_asset), msg.sender, address(this), assets);

        // Route the deposit pro-rata across all approved markets,
        // maintaining current allocation percentages.
        // trackedAssets = sum of recoverable values after cToken rounding.
        uint256[] memory perMarket = _calculateDepositProRata(assets, false);
        uint256 trackedAssets;
        uint256 numApprovedCTokens = approvedCTokensList.length;
        for (uint256 i; i < numApprovedCTokens; ++i) {
            // Skip deposits that would round to zero cToken shares.
            if (perMarket[i] == 0 || IBorrowableCToken(approvedCTokensList[i]).convertToShares(perMarket[i]) == 0) continue;
            trackedAssets += _depositToMarket(approvedCTokensList[i], perMarket[i]);
        }

        // Derive shares from trackedAssets (not input assets) BEFORE updating
        // _totalAssets, so convertToShares uses the pre-deposit denominator.
        shares = convertToShares(trackedAssets);
        // Revert if the deposit is too small to mint any shares.
        if (shares == 0) revert LendingOptimizer__ZeroAmount();
        _totalAssets += trackedAssets;
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /// @notice ERC4626-like mint - mints exact shares by depositing
    ///         pro-rata across active markets.
    /// @dev `previewMint(shares)` prices the optimizer-level share amount.
    ///      `mint()` can require more assets because each per-market leg uses
    ///      `previewMint(previewWithdraw(amount))` to cover cToken rounding and
    ///      avoid undercharging existing depositors.
    /// @param shares The exact amount of shares to mint.
    /// @param receiver The address to receive the minted shares.
    /// @return assets The amount of assets deposited.
    function mint(
        uint256 shares,
        address receiver
    ) public override nonReentrant returns (uint256 assets) {
        if (receiver == address(0)) revert LendingOptimizer__InvalidParameter();
        _checkMintPaused();
        _accrueIfNeeded();

        if (shares == 0) revert LendingOptimizer__InvalidParameter();

        // Compute asset cost for the requested shares, rounding up
        // so the vault never under-charges. totalSupply() is always > 0
        // because initializeDeposits() must be called before any deposits.
        assets = FixedPointMathLib.fullMulDivUp(shares, _totalAssets, totalSupply());

        // Compute pro-rata amounts with conversion roundtrip so that
        // each per-market deposit covers the full withdrawal cost of the
        // shares being minted. This prevents mint() from rounding in
        // favor of the user at the expense of existing depositors.
        uint256[] memory perMarket = _calculateDepositProRata(assets, true);
        assets = 0;
        uint256 numApprovedCTokens = approvedCTokensList.length;
        for (uint256 i; i < numApprovedCTokens; ++i) {
            assets += perMarket[i];
        }

        // Pull the (potentially inflated) assets and deposit to markets.
        SafeTransferLib.safeTransferFrom(address(_asset), msg.sender, address(this), assets);
        uint256 trackedAssets;
        for (uint256 i; i < numApprovedCTokens; ++i) {
            // Skip deposits that would round to zero cToken shares.
            if (perMarket[i] == 0 || IBorrowableCToken(approvedCTokensList[i]).convertToShares(perMarket[i]) == 0) continue;
            trackedAssets += _depositToMarket(approvedCTokensList[i], perMarket[i]);
        }

        // Track recoverable value only; rounding excess from the per-market
        // roundtrip stays as idle balance, recoverable by DAO via `skim()`.
        if (convertToShares(trackedAssets) < shares) {
            revert LendingOptimizer__AssetMismatch();
        }
        _totalAssets += trackedAssets;
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /// @notice ERC4626-like withdraw - withdraws pro-rata across
    ///         all approved markets while respecting liquidity constraints.
    /// @dev Executes withdrawals first (violating CEI), then measures the
    ///      actual cToken rounding loss by re-reading positions. Shares
    ///      burned reflect the true cost including rounding loss, so
    ///      remaining depositors are not diluted. CEI violation is safe
    ///      because cToken markets are trusted and nonReentrant is enforced.
    /// @param assets The amount of underlying assets to withdraw.
    /// @param receiver The address to receive the withdrawn assets.
    /// @param owner The address that owns the shares being burned.
    /// @return shares The amount of shares burned.
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public override nonReentrant returns (uint256 shares) {
        if (assets == 0) revert LendingOptimizer__InvalidParameter();
        if (receiver == address(0)) revert LendingOptimizer__InvalidParameter();
        _checkRedeemPaused();
        _accrueIfNeeded();

        uint256 taBefore = _totalAssets;
        uint256 supplyBefore = totalSupply();

        // Execute pro-rata withdrawals and re-sync _totalAssets from
        // actual cToken positions. The difference taBefore - _totalAssets
        // captures both the withdrawn assets and any cToken rounding loss.
        (_totalAssets,) = _executeWithdraw(assets, false);

        // Burn shares based on actual cost (assets + rounding loss).
        uint256 actualCost = taBefore - _totalAssets;
        shares = FixedPointMathLib.fullMulDivUp(
            actualCost, supplyBefore, taBefore
        );

        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);
        _burn(owner, shares);

        SafeTransferLib.safeTransfer(address(_asset), receiver, assets);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /// @notice ERC4626-like redeem - redeems pro-rata across
    ///         all approved markets while respecting liquidity constraints.
    /// @dev Executes withdrawals with a conversion roundtrip to ensure
    ///      the optimizer's position drops by exactly the fair amount.
    /// @param shares The amount of shares to redeem.
    /// @param receiver The address to receive the underlying assets.
    /// @param owner The address that owns the shares being burned.
    /// @return assets The amount of assets withdrawn.
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public override nonReentrant returns (uint256 assets) {
        if (receiver == address(0)) revert LendingOptimizer__InvalidParameter();
        _checkRedeemPaused();
        _accrueIfNeeded();

        // Convert shares to assets before state changes.
        assets = convertToAssets(shares);
        if (assets == 0) revert LendingOptimizer__InvalidParameter();

        // Execute pro-rata withdrawals with conversion roundtrip to
        // ensure the optimizer's position drops by exactly what is fair
        // for the redeemed shares. Without this, cToken rounding loss
        // leaves dust stuck in the optimizer and drops the exchange rate.
        (_totalAssets, assets) = _executeWithdraw(assets, true);

        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);
        _burn(owner, shares);

        SafeTransferLib.safeTransfer(address(_asset), receiver, assets);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /// @notice Transfers optimizer shares after synchronizing underlying market NAV.
    /// @dev Unlike vanilla ERC20, zero-amount transfers and self-transfers revert.
    /// @param to The address receiving shares.
    /// @param amount The amount of shares to transfer.
    /// @return Whether or not the transfer succeeded.
    function transfer(address to, uint256 amount) public override nonReentrant returns (bool) {
        _accrueIfNeeded();
        if (amount == 0) revert LendingOptimizer__ZeroAmount();
        if (msg.sender == to) revert LendingOptimizer__InvalidParameter();

        return super.transfer(to, amount);
    }

    /// @notice Transfers optimizer shares from `from` after synchronizing underlying market NAV.
    /// @dev Unlike vanilla ERC20, zero-amount transfers and self-transfers revert.
    /// @param from The address transferring shares.
    /// @param to The address receiving shares.
    /// @param amount The amount of shares to transfer.
    /// @return Whether or not the transfer succeeded.
    function transferFrom(address from, address to, uint256 amount) public override nonReentrant returns (bool) {
        _accrueIfNeeded();
        if (amount == 0) revert LendingOptimizer__ZeroAmount();
        if (from == to) revert LendingOptimizer__InvalidParameter();

        return super.transferFrom(from, to, amount);
    }

    /// @notice Rebalances assets across approved markets.
    /// @dev Requires harvester permissions. Actions are processed in two passes:
    ///      withdrawals first, then deposits. This ensures sufficient liquidity
    ///      for deposits without requiring external capital.
    ///
    ///      The actions array must:
    ///      1. Have exactly `approvedCTokensList.length` elements.
    ///      2. Match the order of `approvedCTokensList` (actions[i].cToken must
    ///         equal approvedCTokensList[i]).
    ///      3. Include an entry for every market, even if no action is needed
    ///         (use assets=0 for no-op).
    ///      4. Have total withdrawal amounts equal to total deposit amounts.
    ///
    ///      Positive `assets` values indicate deposits, negative values indicate
    ///      withdrawals.
    ///
    ///      After rebalancing, each market's allocation must not exceed its cap
    ///      and must fall within the caller-specified allocation bounds.
    ///      NOTE: cToken deposit/withdraw rounding incurs a small asset loss
    ///      (~1-2 wei per action). This is absorbed on the next accrual.
    /// @param actions Array of reallocation actions, one per approved market.
    /// @param bounds Array of allocation bounds, one per approved market.
    ///               Each market's post-rebalance allocation (in BPS) must be
    ///               within [minBps, maxBps]. Use [0, 10000] for unconstrained.
    function rebalance(
        ReallocationAction[] calldata actions,
        AllocationBound[] calldata bounds
    ) external nonReentrant {
        // Revert if the caller does not have harvester or market permissions.
        _hasRebalancePermissions();

        // Accrue yield and charge protocol's performance fee.
        _accrueIfNeeded();

        // Cache approved markets length.
        uint256 l = approvedCTokensList.length;
        // Revert if the actions or bounds array length does not match approved markets.
        if (actions.length != l) revert LendingOptimizer__ArrayLengthMismatch();
        if (bounds.length != l) revert LendingOptimizer__ArrayLengthMismatch();

        uint256 sumDeclaredWithdrawals;
        // First pass: process withdrawals (negative assets).
        for (uint256 i; i < l; ++i) {
            // Revert if action cToken does not match expected market at index.
            if (address(actions[i].cToken) != approvedCTokensList[i]) revert LendingOptimizer__InvalidParameter();

            // Process withdrawal if assets is negative.
            if (actions[i].assetsOrBps < 0) {
                if (actions[i].assetsOrBps < MIN_REALLOCATION_AMOUNT) revert LendingOptimizer__InvalidParameter();
                if (_isMarketPausedForAction(address(actions[i].cToken), false)) {
                    revert LendingOptimizer__MarketPaused();
                }
                uint256 withdrawAmount = uint256(-actions[i].assetsOrBps);
                sumDeclaredWithdrawals += withdrawAmount;
                actions[i].cToken.withdraw(
                    withdrawAmount,
                    address(this),
                    address(this)
                );
            }
        }

        // Track the intended deposited assets.
        uint256 sumDeclaredReallocated;
        // Second pass: process deposits (positive assets).
        for (uint256 i; i < l; ++i) {
            // Process deposit if assets is positive.
            if (actions[i].assetsOrBps > 0) {
                if (_isMarketPausedForAction(address(actions[i].cToken), true)) {
                    revert LendingOptimizer__MarketPaused();
                }
                uint256 depositAmount = uint256(actions[i].assetsOrBps);
                _depositToMarket(address(actions[i].cToken), depositAmount);
                sumDeclaredReallocated += depositAmount;
            }
        }

        // Check that the manager intended to withdraw and deposit the same amount of assets.
        if (sumDeclaredWithdrawals != sumDeclaredReallocated) revert LendingOptimizer__AssetMismatch();

        // Verify allocation caps, bounds, and emit post-rebalance state.
        _verifyAllocations(bounds);
    }

    /// @notice Removes an approved market and reallocates its assets.
    /// @dev After removal, remaining market caps must sum to >= 100%. If not,
    ///      call `updateCap()` to increase a remaining market's cap before removal.
    ///      The caller specifies BPS-based percentages for redistribution
    ///      via the `assetsOrBps` field of each ReallocationAction. BPS values
    ///      must be positive and sum to exactly 10000 (100%).
    ///      The last target receives the remainder to avoid dust.
    /// @param cTokenToRemove Address of the market to remove.
    /// @param removeActions Reallocation targets. `assetsOrBps` field is BPS (1-10000).
    /// @param bounds Post-removal allocation bounds, one per remaining market.
    ///               Must match the post-removal approvedCTokensList order (swap-and-pop).
    function removeApprovedAsset(
        address cTokenToRemove,
        ReallocationAction[] calldata removeActions,
        AllocationBound[] calldata bounds
    ) external nonReentrant {
        // Revert if the caller does not have market permissions.
        _hasMarketPermissions();

        {
            uint256 numApprovedCTokens = approvedCTokensList.length;

            // Revert if there is only one market.
            if (numApprovedCTokens == 1) revert LendingOptimizer__InvalidParameter();
            // Always require an explicit reallocation plan so donated cToken
            // shares cannot grief an otherwise empty market removal.
            if (removeActions.length == 0) revert LendingOptimizer__InvalidParameter();
            // Bounds must match the post-removal market count.
            if (bounds.length != numApprovedCTokens - 1) revert LendingOptimizer__ArrayLengthMismatch();
        }

        // Revert if the market to remove is not approved.
        if (!_isApprovedMarket(cTokenToRemove)) revert LendingOptimizer__MarketNotApproved();

        // Revert if the market to remove is paused for redemptions.
        if (_isMarketPausedForAction(cTokenToRemove, false)) {
            revert LendingOptimizer__MarketPaused();
        }

        // Validate remaining allocation caps sum to >= 100%.
        _validateAllocationCaps(cTokenToRemove, 0);

        // Accrue yield and charge protocol's performance fee.
        _accrueIfNeeded();

        // Delete the allocation cap for the removed market.
        delete allocationCaps[cTokenToRemove];

        {
            IBorrowableCToken cToken = IBorrowableCToken(cTokenToRemove);
            uint256 sharesToRedeem = cToken.balanceOf(address(this));
            uint256 previewedAssets = sharesToRedeem > 0
                ? cToken.convertToAssets(sharesToRedeem)
                : 0;

            // Only redeem and reallocate if there are previewed assets.
            // Zero-asset cToken dust is swept to DAO before removal so it cannot
            // be orphaned on the optimizer or used to grief removal.
            if (previewedAssets > 0) {
                // Redeem all shares from the market being removed.
                uint256 assetsRedeemed = cToken.redeem(
                    sharesToRedeem,
                    address(this),
                    address(this)
                );

                // Distribute redeemed assets proportionally via BPS.
                uint256 totalBps;
                uint256 totalDeposited;
                uint256 lastAction = removeActions.length - 1;

                for (uint256 i; i <= lastAction; ++i) {
                    address cTokenAddress = address(removeActions[i].cToken);

                    // Validate the reallocation target.
                    {
                        int256 bps = removeActions[i].assetsOrBps;
                        // Revert if BPS is not positive.
                        if (bps <= 0) revert LendingOptimizer__InvalidParameter();
                        // Revert if target is the market being removed.
                        if (cTokenAddress == cTokenToRemove) revert LendingOptimizer__InvalidParameter();
                        // Revert if the reallocation target is not an approved market.
                        if (!_isApprovedMarket(cTokenAddress)) revert LendingOptimizer__MarketNotApproved();
                        _approvedMarketIndex(cTokenAddress, approvedCTokensList.length);
                        // Revert if duplicate reallocation target.
                        for (uint256 j; j < i; ++j) {
                            if (address(removeActions[j].cToken) == cTokenAddress) revert LendingOptimizer__InvalidParameter();
                        }
                        // Revert if the reallocation target is paused for minting.
                        if (_isMarketPausedForAction(cTokenAddress, true)) {
                            revert LendingOptimizer__MarketPaused();
                        }
                        totalBps += uint256(bps);
                    }

                    // Last target receives the remainder to avoid dust.
                    // Else deposit normally.
                    uint256 depositAmount;
                    if (i == lastAction) {
                        depositAmount = assetsRedeemed - totalDeposited;
                    } else {
                        depositAmount = FixedPointMathLib.fullMulDiv(assetsRedeemed, uint256(removeActions[i].assetsOrBps), BPS);
                        totalDeposited += depositAmount;
                    }

                    // Skip deposit if dust amount rounds to zero cToken shares.
                    if (IBorrowableCToken(cTokenAddress).convertToShares(depositAmount) > 0) {
                        _depositToMarket(cTokenAddress, depositAmount);
                    } else if (i != lastAction) {
                        // Use the dust in a later deposit if it's not the last.
                        // Last-iteration dust stays idle on the optimizer
                        // (recoverable via skim).
                        totalDeposited -= depositAmount;
                    }
                }

                // Revert if BPS values do not sum to exactly 100%.
                if (totalBps != BPS) revert LendingOptimizer__InvalidParameter();
            } else if (sharesToRedeem > 0) {
                SafeTransferLib.safeTransfer(
                    cTokenToRemove,
                    centralRegistry.daoAddress(),
                    sharesToRedeem
                );
            }
        }

        // Find the index of the cToken to remove.
        {
            uint256 l = approvedCTokensList.length;
            uint256 removeIndex = _approvedMarketIndex(cTokenToRemove, l);

            // Update approved markets list using swap and pop.
            uint256 swapIndex = l - 1;
            if (removeIndex != swapIndex) {
                approvedCTokensList[removeIndex] = approvedCTokensList[swapIndex];
            }
            approvedCTokensList.pop();
        }

        // Verify allocation caps and caller-specified bounds after reallocation.
        _verifyAllocations(bounds);

        emit MarketRemoved(cTokenToRemove);
    }

    /// @notice Adds a new approved market for allocation.
    /// @dev Requires elevated permissions. The cToken must have matching
    ///      underlying asset and a registered market manager. Max 8 markets.
    /// @param newAsset Address of the cToken market to add.
    /// @param capBps Allocation cap in BPS. Stored as WAD internally.
    function addApprovedAsset(address newAsset, uint256 capBps) external nonReentrant {
        // Revert if the caller does not have elevated permissions.
        _hasElevatedPermissions();

        // Revert if the new asset address is zero.
        if (newAsset == address(0)) revert LendingOptimizer__InvalidParameter();
        // Revert if the cap is zero or exceeds 100%.
        if (capBps == 0 || capBps > BPS) revert LendingOptimizer__InvalidParameter();
        // Revert if the market is already approved.
        if (_isApprovedMarket(newAsset)) revert LendingOptimizer__MarketAlreadyApproved();
        // Revert if adding would exceed maximum markets.
        if (approvedCTokensList.length >= MAX_MARKETS) revert LendingOptimizer__TooManyMarkets();

        // Validate the cToken's underlying and market manager.
        _validateCToken(newAsset);

        // Add market to approved list and set allocation cap.
        uint256 capWad = _bpsToWad(capBps);
        approvedCTokensList.push(newAsset);
        allocationCaps[newAsset] = capWad;

        emit MarketAdded(newAsset, capBps);
    }

    /// @notice Updates the allocation cap for an approved market.
    /// @dev Requires market permissions. If decreasing, validates total
    ///      caps remain >= 100% to ensure full allocation is possible.
    /// @param cToken Address of the cToken market (must be approved).
    /// @param newCapBps New allocation cap in BPS (1-10000).
    function updateCap(address cToken, uint256 newCapBps) external nonReentrant {
        // Revert if the caller does not have market permissions.
        _hasMarketPermissions();

        // Revert if the market is not approved.
        if (!_isApprovedMarket(cToken)) revert LendingOptimizer__MarketNotApproved();
        // Revert if the new cap is zero or exceeds 100%.
        if (newCapBps > BPS || newCapBps == 0) revert LendingOptimizer__InvalidParameter();

        uint256 newCapWad = _bpsToWad(newCapBps);

        // If decreasing cap, validate total caps still >= 100%.
        if (newCapWad < allocationCaps[cToken]) {
            _validateAllocationCaps(cToken, newCapWad);
        }

        // Update the allocation cap.
        allocationCaps[cToken] = newCapWad;

        emit AllocationCapUpdated(cToken, newCapBps);
    }

    /// @notice Updates the performance fee charged on yield above watermark.
    /// @dev Requires market permissions. Accrues existing fees before updating.
    ///      If enabling from 0, watermark resets to current rate so fees only
    ///      apply to future yield. Max 50%.
    /// @param newFeeBps New fee in BPS.
    function setFee(uint256 newFeeBps) external nonReentrant {
        // Revert if the caller does not have market permissions.
        _hasMarketPermissions();

        // Revert if the new fee exceeds the maximum allowed (50%).
        if (newFeeBps > MAX_FEE_BPS) revert LendingOptimizer__FeeTooHigh();

        // Accrue fees on existing profits before changing fee.
        _accrueIfNeeded();

        // If enabling fees from 0, update watermark to current rate
        // so fees only apply to future yield.
        if (fee == 0 && newFeeBps > 0) {
            if (totalSupply() > 0) {
                uint256 exchangeRateCurrent = _exchangeRate();
                // Never lower the watermark.
                if (exchangeRateCurrent > exchangeRateHighWatermark) {
                    exchangeRateHighWatermark = exchangeRateCurrent;
                }
            }
        }

        fee = newFeeBps;
        emit FeeUpdated(newFeeBps);
    }

    /// @notice Pauses or unpauses deposits. Emits an {ActionPaused} event.
    /// @dev Requires market permissions.
    /// @param state True to pause, false to unpause.
    function setMintPaused(bool state) external nonReentrant {
        _hasMarketPermissions();

        // Cannot pause or unpause if not initialized.
        if (mintPaused == 0) revert LendingOptimizer__NotInitialized();

        mintPaused = state ? 2 : 1; // 2 = paused; 1 = active.

        emit ActionPaused("Mint Paused", state);
    }

    /// @notice Returns the cached exchange rate. Accurate post-accrual,
    ///         slightly stale between accruals as market interest accrues
    ///         continuously. For real-time accuracy, call `accrueIfNeeded()`
    ///         first or use `exchangeRateUpdated()`.
    /// @return Current exchange rate in WAD (1e18 = 1:1). Returns WAD if no supply.
    function exchangeRate() public view returns (uint256) {
        return _exchangeRate();
    }

    /// @notice Accrues interest, absorbs yield, charges fees, and returns exchange rate.
    /// @dev Triggers full state update: accrues underlying markets, absorbs
    ///      yield, and charges performance fees if rate exceeds watermark.
    /// @return Current exchange rate in WAD (1e18 = 1:1). Returns WAD if no supply.
    function exchangeRateUpdated() public nonReentrant returns (uint256) {
        _accrueIfNeeded();
        return _exchangeRate();
    }

    /// @notice Accrues yield from underlying markets and absorbs it.
    function accrueIfNeeded() external nonReentrant {
        _accrueIfNeeded();
    }

    /// @notice Recovers underlying assets incorrectly sent to the optimizer.
    /// @dev All assets should be deployed in cToken markets, so any idle
    ///      underlying balance is excess. Does not modify `_totalAssets`.
    ///      Requires DAO permissions.
    function skim() external nonReentrant {
        _hasDaoPermissions();
        uint256 excess = skimAvailable();

        address daoAddress = centralRegistry.daoAddress();
        SafeTransferLib.safeTransfer(address(_asset), daoAddress, excess);

        emit ExcessRecovered(excess, daoAddress);
    }

    /// @notice Returns the amount of excess underlying that can be recovered.
    /// @dev The optimizer should hold no idle underlying — any balance is excess.
    /// @return excess The recoverable excess underlying amount.
    function skimAvailable() public view returns (uint256 excess) {
        excess = _asset.balanceOf(address(this));
        if (excess == 0) revert LendingOptimizer__ZeroAmount();
    }

    /// VIEW FUNCTIONS ///

    /// @notice Returns the cached total assets held across all approved markets.
    /// @dev Returns the internally tracked `_totalAssets`, which is updated
    ///      on every state-changing operation (deposit, withdraw, rebalance).
    ///      This value may be slightly stale between accruals as market
    ///      interest accrues continuously.
    ///
    ///      NOTE: `totalAssets()` intentionally returns the cached value
    ///      because `deposit()` calls `convertToShares()` — which reads
    ///      `totalAssets()` — AFTER depositing into cTokens. An accrued read
    ///      would include the just-deposited amount, inflating the denominator
    ///      and minting fewer shares than intended.
    /// @return The cached total assets held by the optimizer.
    function totalAssets() public view override(ERC4626, ILendingOptimizer) returns (uint256) {
        return _totalAssets;
    }

    /// @notice Returns the maximum amount of assets that can be deposited.
    /// @dev Returns 0 when deposits are paused, uninitialized,
    ///      or any approved market has minting paused.
    /// @return Maximum depositable assets, or 0 if deposits are blocked.
    function maxDeposit(address) public view override returns (uint256) {
        return mintPaused == 1 && !_anyMarketPaused(true)
            ? type(uint256).max
            : 0;
    }

    /// @notice Returns the maximum amount of shares that can be minted.
    /// @dev Returns 0 when deposits are paused, uninitialized,
    ///      or any approved market has minting paused.
    /// @return Maximum mintable shares, or 0 if deposits are blocked.
    function maxMint(address) public view override returns (uint256) {
        return mintPaused == 1 && !_anyMarketPaused(true)
            ? type(uint256).max
            : 0;
    }

    /// @notice Returns the maximum amount of assets that `owner` can withdraw.
    /// @dev Returns 0 when any approved market has redemptions paused.
    ///      Uses cached `_totalAssets` — accurate post-accrual.
    ///      This is a view estimate for owner assets and market liquidity, not
    ///      a guarantee that `withdraw(maxWithdraw(owner))` will succeed after
    ///      cToken rounding loss. Use `redeem(maxRedeem(owner))` for full exits.
    /// @param owner The address that owns the shares.
    /// @return Maximum withdrawable assets, or 0 if withdrawals are blocked.
    function maxWithdraw(address owner) public view override returns (uint256) {
        if (_anyMarketPaused(false)) return 0;
        uint256 ownerAssets = convertToAssets(balanceOf(owner));
        if (ownerAssets == 0) return 0;
        uint256 availableAssets = _availableWithdrawLiquidity();
        return ownerAssets < availableAssets ? ownerAssets : availableAssets;
    }

    /// @notice Returns the maximum amount of shares that `owner` can redeem.
    /// @dev Returns 0 when any approved market has redemptions paused.
    /// @param owner The address that owns the shares.
    /// @return Maximum redeemable shares, or 0 if withdrawals are blocked.
    function maxRedeem(address owner) public view override returns (uint256) {
        if (_anyMarketPaused(false)) return 0;
        uint256 ownerShares = balanceOf(owner);
        uint256 ownerAssets = convertToAssets(ownerShares);
        if (ownerAssets == 0) return 0;

        uint256 availableAssets = _availableWithdrawLiquidity();
        if (ownerAssets <= availableAssets) return ownerShares;

        return convertToShares(availableAssets);
    }

    /// @notice Returns the number of approved markets.
    function numApprovedMarkets() external view returns (uint256) {
        return approvedCTokensList.length;
    }

    /// @notice Returns all approved market addresses.
    function getApprovedMarkets() external view returns (address[] memory) {
        return approvedCTokensList;
    }

    /// @notice Returns the name of the token.
    function name() public view override returns (string memory) {
        return _name;
    }

    /// @notice Returns the symbol of the token.
    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    /// @notice Returns the underlying asset address.
    function asset() public view override(ERC4626, ILendingOptimizer) returns (address) {
        return address(_asset);
    }

    /// @inheritdoc ERC4626
    function convertToAssets(uint256 shares) public view override(ERC4626, ILendingOptimizer) returns (uint256 assets) {
        return super.convertToAssets(shares);
    }

    /// @inheritdoc ERC20
    function balanceOf(address owner) public view override(ERC20, ILendingOptimizer) returns (uint256 result) {
        return super.balanceOf(owner);
    }

    /// @notice Returns true if this contract implements the interface.
    /// @param interfaceId The interface identifier to check.
    /// @return result True if the interface is supported.
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override returns (bool result) {
        result = interfaceId == type(ILendingOptimizer).interfaceId ||
            interfaceId == type(IERC20).interfaceId ||
            interfaceId == type(ERC4626).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /// INTERNAL FUNCTIONS ///

    /// @dev Returns true if any approved market is paused for the given action.
    ///      Used to propagate cToken pause state to the optimizer level:
    ///      any single market paused → entire optimizer paused for that action.
    /// @param isDeposit True to check mint-paused, false to check redeem-paused.
    /// @return True if at least one approved market is paused for the action.
    function _anyMarketPaused(bool isDeposit) internal view returns (bool) {
        uint256 l = approvedCTokensList.length;
        for (uint256 i; i < l; ++i) {
            if (_isMarketPausedForAction(approvedCTokensList[i], isDeposit)) return true;
        }
        return false;
    }

    /// @dev Returns true if the market is paused for the given action.
    ///      Deposits check per-cToken `mintPaused` via the market manager;
    ///      withdrawals check market-wide `redeemPaused`.
    /// @param cToken The cToken market address to check.
    /// @param isDeposit True to check mint-paused, false to check redeem-paused.
    /// @return True if the market is paused for the specified action.
    function _isMarketPausedForAction(
        address cToken,
        bool isDeposit
    ) internal view returns (bool) {
        MarketManagerIsolated mm =
            MarketManagerIsolated(address(IBorrowableCToken(cToken).marketManager()));
        if (isDeposit) {
            (bool mintPaused_,,) = mm.actionsPaused(cToken);
            return mintPaused_;
        } else {
            return mm.redeemPaused() == 2;
        }
    }

    /// @dev Accrues interest on all markets and returns total assets.
    function _accrueMarkets() internal returns (uint256 ta) {
        uint256 l = approvedCTokensList.length;
        for (uint256 i; i < l; ++i) {
            address cToken = approvedCTokensList[i];
            IBorrowableCToken(cToken).accrueIfNeeded();
            ta += _getMarketAssets(cToken);
        }
    }

    /// @dev Returns the total underlying liquidity the optimizer can currently
    ///      withdraw across approved markets, capped by this optimizer's shares.
    function _availableWithdrawLiquidity()
        internal
        view
        returns (uint256 availableAssets)
    {
        uint256 l = approvedCTokensList.length;
        for (uint256 i; i < l; ++i) {
            IBorrowableCToken cToken = IBorrowableCToken(approvedCTokensList[i]);
            uint256 optimizerAssets = cToken.convertToAssets(
                cToken.balanceOf(address(this))
            );
            if (optimizerAssets == 0) continue;

            uint256 marketLiquidity = cToken.assetsHeld();
            availableAssets += optimizerAssets < marketLiquidity
                ? optimizerAssets
                : marketLiquidity;
        }
    }

    /// @dev Deposits assets into a specific cToken market.
    /// @param cToken The cToken market to deposit into.
    /// @param assets The amount of assets to deposit.
    /// @return trackedAssets The actual recoverable value (for _totalAssets tracking).
    function _depositToMarket(
        address cToken,
        uint256 assets
    ) internal returns (uint256 trackedAssets) {
        SwapperLib._approveIfNeeded(address(_asset), cToken, assets);

        IBorrowableCToken cToken_ = IBorrowableCToken(cToken);

        // Track the actual recoverable value of shares received, not the input amount.
        // cToken share math involves two rounding operations (assets→shares, shares→assets)
        // which can cause a small difference between input and recoverable value.
        trackedAssets = cToken_.convertToAssets(cToken_.deposit(assets, address(this)));
        if (trackedAssets > assets) revert LendingOptimizer__AssetMismatch();

        // Remove any residual approval for USDT-like token compatibility.
        SwapperLib._removeApprovalIfNeeded(address(_asset), cToken);
    }

    /// @dev Executes pro-rata withdrawals across all approved markets and
    ///      returns the total remaining position (for `_totalAssets` re-sync).
    ///      Entry point reverts if any market is paused for redemptions.
    /// @param assets Total underlying assets to withdraw.
    /// @param conversionRoundtrip If true, adjusts each per-market amount
    ///        via previewRedeem(previewDeposit(amount)) so the optimizer's
    ///        position drops by exactly the fair amount for the redeemed
    ///        shares. Used by redeem() to prevent dust accumulation.
    /// @return newTotalAssets Sum of optimizer positions after withdrawals.
    /// @return totalWithdrawn Sum of adjusted per-market withdrawal amounts.
    function _executeWithdraw(uint256 assets, bool conversionRoundtrip) internal returns (uint256 newTotalAssets, uint256 totalWithdrawn) {
        uint256 l = approvedCTokensList.length;
        uint256[] memory marketAssets = new uint256[](l);
        uint256[] memory liquidityLimit = new uint256[](l);
        uint256 totalMarketAssets;

        // Read each market's optimizer position and available liquidity.
        // marketAssets[i]    = optimizer's full position (pro-rata weight).
        // liquidityLimit[i]  = min(position, idle cash) — max withdrawable.
        for (uint256 i; i < l; ++i) {
            IBorrowableCToken cToken = IBorrowableCToken(approvedCTokensList[i]);
            uint256 optimizerShares = cToken.balanceOf(address(this));
            if (optimizerShares == 0) continue;

            uint256 optimizerAssets = cToken.convertToAssets(optimizerShares);
            if (optimizerAssets == 0) continue;

            uint256 marketLiquidity = cToken.assetsHeld();

            marketAssets[i] = optimizerAssets;
            liquidityLimit[i] = optimizerAssets < marketLiquidity
                ? optimizerAssets
                : marketLiquidity;
            totalMarketAssets += optimizerAssets;
        }
        if (totalMarketAssets == 0) {
            revert LendingOptimizer__InsufficientLiquidity();
        }

        // Split withdrawal pro-rata by position size, capped by each
        // market's available liquidity. Shortfalls from liquidity-limited
        // markets are redistributed sequentially to others.
        uint256[] memory amounts = _calcProRata(
            assets, marketAssets, liquidityLimit, totalMarketAssets
        );

        // Verify the full amount was allocated. If total available
        // liquidity across all markets is insufficient, revert.
        uint256 totalAllocated;
        for (uint256 i; i < l; ++i) {
            totalAllocated += amounts[i];
            // For redeem(): adjust each amount via previewRedeem(previewDeposit(amount))
            // so the withdrawn amount rounds down to exactly what the cToken would
            // give back, preventing dust from accumulating in the optimizer.
            if (conversionRoundtrip) {
                amounts[i] = IBorrowableCToken(approvedCTokensList[i]).previewRedeem(
                    IBorrowableCToken(approvedCTokensList[i]).previewDeposit(amounts[i])
                );
            }
            totalWithdrawn += amounts[i];
        }

        // Revert if roundtrip adjustment reduced all withdrawals to zero.
        if (conversionRoundtrip && totalWithdrawn == 0) revert LendingOptimizer__ZeroAmount();
        if (totalAllocated < assets) revert LendingOptimizer__InsufficientLiquidity();

        // Execute cToken withdrawals and re-read positions in a single
        // pass. The returned newTotalAssets reflects ground truth after
        // withdrawals, capturing any cToken rounding loss (from ceil
        // share burns) that the caller uses for accounting.
        for (uint256 i; i < l; ++i) {
            if (amounts[i] > 0) {
                IBorrowableCToken(approvedCTokensList[i]).withdraw(
                    amounts[i], address(this), address(this)
                );
            }
            newTotalAssets += _getMarketAssets(approvedCTokensList[i]);
        }
    }

    /// @dev Computes pro-rata deposit amounts across all approved markets,
    ///      maintaining current allocation percentages. Only callable
    ///      post-initializeDeposits (totalMarketAssets > 0).
    ///      Entry point reverts if any market is paused for minting.
    /// @param assets Total assets to deposit.
    /// @param conversionRoundtrip If true, inflates each per-market amount
    ///        via previewMint(previewWithdraw(amount)) so that the deposited
    ///        cToken position can cover a full withdrawal of `amount`. Used by
    ///        mint() to prevent rounding in the user's favor.
    function _calculateDepositProRata(uint256 assets, bool conversionRoundtrip) internal view returns (uint256[] memory amounts) {
        uint256 l = approvedCTokensList.length;
        amounts = new uint256[](l);
        uint256[] memory marketAssets = new uint256[](l);
        uint256 totalMarketAssets;
        uint256 lastNonZero;

        // Gather each market's current asset allocation.
        // Entry point reverts if any market is paused for minting.
        // totalMarketAssets is always > 0 post-initializeDeposits.
        for (uint256 i; i < l; ++i) {
            marketAssets[i] = _getMarketAssets(approvedCTokensList[i]);
            totalMarketAssets += marketAssets[i];
            if (marketAssets[i] > 0) lastNonZero = i;
        }
        if (totalMarketAssets == 0) revert LendingOptimizer__ZeroAmount();

        // Split the deposit proportionally by current allocation.
        // No liquidity cap needed for deposits — last non-zero market
        // receives the remainder to handle mulDiv rounding dust.
        uint256 deposited;
        for (uint256 i; i < l; ++i) {
            uint256 amount;
            if (i == lastNonZero) {
                // Last market gets the remainder to avoid dust.
                amount = assets - deposited;
            } else {
                amount = FixedPointMathLib.fullMulDiv(
                    assets, marketAssets[i], totalMarketAssets
                );
                deposited += amount;
            }

            // For mint(): inflate amount so the deposited cToken position
            // covers a full withdrawal of the pro-rata share.
            if (conversionRoundtrip) {
                amount = IBorrowableCToken(approvedCTokensList[i]).previewMint(
                    IBorrowableCToken(approvedCTokensList[i]).previewWithdraw(amount)
                );
            }
            amounts[i] = amount;
        }
    }

    /// @dev Computes pro-rata allocation of `total` across markets based on
    ///      `weights`, bounded by `liquidityLimit` per market. Any shortfall
    ///      from rounding or liquidity-limited markets is redistributed
    ///      sequentially.
    /// @param total Total amount to allocate.
    /// @param marketAssets Per-market optimizer position (used as pro-rata weights).
    /// @param liquidityLimit Per-market maximum allocation (available liquidity).
    /// @param totalMarketAssets Sum of all market assets.
    /// @return amounts Per-market allocated amounts.
    function _calcProRata(
        uint256 total,
        uint256[] memory marketAssets,
        uint256[] memory liquidityLimit,
        uint256 totalMarketAssets
    ) internal pure returns (uint256[] memory amounts) {
        // Always approvedCTokensList length, saves a storage read.
        uint256 l = marketAssets.length;
        amounts = new uint256[](l);

        // First pass: assign each market its proportional share,
        // capped by that market's liquidity limit.
        uint256 allocated;
        for (uint256 i; i < l; ++i) {
            // Proportional amount = total * (market assets / total market assets).
            uint256 proportional = FixedPointMathLib.fullMulDiv(
                total, marketAssets[i], totalMarketAssets
            );

            // Cap by available liquidity.
            amounts[i] = proportional < liquidityLimit[i] ? proportional : liquidityLimit[i];
            allocated += amounts[i];
        }

        // Second pass: redistribute any unallocated remainder.
        // Remainder comes from two sources:
        //   1. mulDiv rounding (typically 0-2 wei across all markets)
        //   2. Liquidity-capped markets that couldn't take their full share
        // Redistributed sequentially to the first markets with spare capacity.
        if (allocated < total) {
            uint256 remaining = total - allocated;
            for (uint256 i; i < l && remaining > 0; ++i) {
                uint256 spare = liquidityLimit[i] - amounts[i];
                if (spare == 0) continue;
                uint256 extra = remaining < spare ? remaining : spare;
                amounts[i] += extra;
                remaining -= extra;
            }
        }
    }

    /// @dev Validates that total allocation caps sum to at least 100% (WAD).
    ///      Used when decreasing a cap or removing a market to ensure
    ///      full allocation remains possible.
    /// @param marketToModify The market whose cap is being changed.
    /// @param newCap The proposed new cap in WAD (pass 0 for removal).
    function _validateAllocationCaps(address marketToModify, uint256 newCap) internal view {
        uint256 totalCaps;
        uint256 l = approvedCTokensList.length;

        for (uint256 i; i < l; ++i) {
            address market = approvedCTokensList[i];
            if (market == marketToModify) {
                totalCaps += newCap;
            } else {
                totalCaps += allocationCaps[market];
            }
        }
        if (totalCaps < WAD) revert LendingOptimizer__InsufficientAllocationCaps();
    }

    /// @dev Converts BPS to WAD (e.g., 1000 BPS = 0.1 WAD = 10%).
    /// @param bps Value in basis points (1 BPS = 0.01%).
    /// @return WAD-scaled value (1e14 per BPS).
    function _bpsToWad(uint256 bps) internal pure returns (uint256) {
        return bps * 1e14;
    }

    /// @dev Returns the optimizer's asset value in a specific market.
    /// @param cToken The cToken market address.
    /// @return The optimizer's position in underlying asset terms.
    function _getMarketAssets(address cToken) internal view returns (uint256) {
        IBorrowableCToken ct = IBorrowableCToken(cToken);
        return ct.convertToAssets(ct.balanceOf(address(this)));
    }

    /// @dev Validates cToken has correct underlying, is borrowable,
    ///      has a registered market manager, is listed in that manager,
    ///      and is not paired with this optimizer's share token.
    /// @param cToken The cToken market address to validate.
    function _validateCToken(address cToken) internal view {
        if (IBorrowableCToken(cToken).asset() != address(_asset)) revert LendingOptimizer__InvalidUnderlying();
        if (!IBorrowableCToken(cToken).isBorrowable()) revert LendingOptimizer__InvalidParameter();

        address marketManager = address(IBorrowableCToken(cToken).marketManager());
        if (!centralRegistry.isMarketManager(marketManager)) revert LendingOptimizer__InvalidMarketManager();
        if (!IMarketManager(marketManager).isListed(cToken)) revert LendingOptimizer__InvalidMarketManager();

        address[] memory listedTokens = IMarketManager(marketManager).queryTokensListed();
        for (uint256 i; i < listedTokens.length; ++i) {
            if (listedTokens[i] != cToken && ICToken(listedTokens[i]).asset() == address(this)) {
                revert LendingOptimizer__InvalidMarketManager();
            }
        }
    }

    /// @dev Returns whether a market is approved for allocation.
    /// @param market The market address to check.
    /// @return True if the market has a non-zero allocation cap.
    function _isApprovedMarket(address market) internal view returns (bool) {
        return allocationCaps[market] != 0;
    }

    /// @dev Returns a market's approved-list index or reverts if absent.
    function _approvedMarketIndex(address market, uint256 l) internal view returns (uint256) {
        for (uint256 i; i < l; ++i) {
            if (approvedCTokensList[i] == market) return i;
        }
        revert LendingOptimizer__MarketNotApproved();
    }

    /// @dev Returns the current exchange rate in WAD. Returns WAD if no supply.
    ///      Uses cached `_totalAssets` — accurate post-accrual.
    /// @return Exchange rate scaled by WAD (1e18 = 1:1 ratio).
    function _exchangeRate() internal view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return WAD;
        return FixedPointMathLib.fullMulDiv(WAD, totalAssets(), supply);
    }

    /// @dev Verifies allocation caps and bounds, syncs _totalAssets,
    ///      and emits the post-rebalance state. Reads each market's balance
    ///      once, avoiding redundant external calls.
    ///
    ///      Both caps and bounds are always checked. Bounds protect against
    ///      race conditions where state changes between off-chain computation
    ///      and on-chain execution (e.g., a deposit shifts allocations before
    ///      the harvester's rebalance tx lands).
    /// @param bounds Array of allocation bounds, one per approved market.
    ///               Must match approvedCTokensList length.
    function _verifyAllocations(AllocationBound[] memory bounds) internal {
        uint256 l = approvedCTokensList.length;
        uint256[] memory allocations = new uint256[](l);
        uint256 ta;
        bool checkBounds = bounds.length > 0;

        // Compute fresh total from actual post-rebalance market balances
        // instead of using the cached _totalAssets, which may be stale
        // due to rounding losses from cToken withdraw/deposit round-trips.
        for (uint256 i; i < l; ++i) {
            allocations[i] = _getMarketAssets(approvedCTokensList[i]);
            ta += allocations[i];
            // Validate bounds ordering and sanity when provided.
            if (checkBounds) {
                if (bounds[i].cToken != approvedCTokensList[i]) revert LendingOptimizer__InvalidParameter();
                if (bounds[i].minBps > bounds[i].maxBps) revert LendingOptimizer__InvalidParameter();
            }
        }

        // Sync cached total assets to the post-rebalance state.
        _totalAssets = ta;

        if (ta > 0) {
            for (uint256 i; i < l; ++i) {
                // Check allocation cap (WAD-based).
                uint256 allocationWad = FixedPointMathLib.fullMulDiv(allocations[i], WAD, ta);
                if (allocationWad > allocationCaps[approvedCTokensList[i]]) {
                    revert LendingOptimizer__AllocationExceedsCap();
                }

                // Check caller-specified bounds (BPS-based) if provided.
                if (checkBounds) {
                    uint256 allocationBps = FixedPointMathLib.fullMulDiv(allocations[i], BPS, ta);
                    if (allocationBps < bounds[i].minBps) {
                        revert LendingOptimizer__AllocationOutOfBounds();
                    }
                    allocationBps = FixedPointMathLib.fullMulDivUp(allocations[i], BPS, ta);
                    if (allocationBps > bounds[i].maxBps) {
                        revert LendingOptimizer__AllocationOutOfBounds();
                    }
                }
            }
        } else {
            // If totalAssets is zero, all bounds must allow zero allocation.
            if (checkBounds) {
                for (uint256 i; i < l; ++i) {
                    if (bounds[i].minBps > 0) {
                        revert LendingOptimizer__AllocationOutOfBounds();
                    }
                }
            }
        }

        emit Rebalanced(ta, approvedCTokensList, allocations);
    }

    /// @dev Synchronizes optimizer state: absorbs yield from underlying
    ///      markets immediately and accrues performance fees.
    ///
    ///      Yield is absorbed immediately into `_totalAssets` (cToken-style).
    ///      Since this runs before every user action, frontrunning is blocked:
    ///      an attacker depositing at an accrual boundary gets no excess yield
    ///      because yield is already priced in.
    ///
    ///      Performance Fees
    ///      Fees are charged on yield above a high watermark, ensuring fees
    ///      are only taken on new all-time-high profits. This prevents
    ///      double-charging after drawdowns recover.
    function _accrueIfNeeded() internal {
        // Sync with underlying cToken markets and absorb yield
        uint256 rawTa = _accrueMarkets();
        _totalAssets = rawTa;

        // Charge performance fee on absorbed yield
        if (fee > 0) {
            uint256 supply = totalSupply();
            if (supply > 0) {
                uint256 currentRate = FixedPointMathLib.fullMulDiv(WAD, rawTa, supply);
                uint256 highRate = exchangeRateHighWatermark;

                if (currentRate > highRate) {
                    // Round up to prevent fee undercharge on dust profits.
                    uint256 profit = rawTa - FixedPointMathLib.fullMulDivUp(highRate, supply, WAD);
                    uint256 feeAssets = FixedPointMathLib.fullMulDiv(profit, fee, BPS);

                    if (feeAssets > 0) {
                        uint256 feeShares = FixedPointMathLib.fullMulDiv(
                            feeAssets, supply, rawTa - feeAssets
                        );
                        address dao = centralRegistry.daoAddress();
                        _mint(dao, feeShares);
                        exchangeRateHighWatermark = FixedPointMathLib.fullMulDiv(
                            WAD, rawTa, supply + feeShares
                        );
                        emit PerformanceFeeAccrued(feeShares, dao);
                    } else {
                        exchangeRateHighWatermark = currentRate;
                    }
                }
            }
        }
    }

    /// @dev Reverts if deposits are paused. Deposits are paused when:
    ///      1. The optimizer itself is paused (mintPaused > 1) or uninitialized (0).
    ///      2. Any approved market has minting paused — prevents new depositors
    ///         from entering a degraded pool where some markets are unreachable.
    function _checkMintPaused() internal view {
        uint256 mintPaused_ = mintPaused;
        if (mintPaused_ == 0) revert LendingOptimizer__NotInitialized();
        if (mintPaused_ > 1) revert LendingOptimizer__MintPaused();
        if (_anyMarketPaused(true)) revert LendingOptimizer__MarketPaused();
    }

    /// @dev Reverts if any approved market has redemptions paused.
    ///      Prevents bank-run scenario where early withdrawers drain
    ///      liquidity from active markets, leaving later withdrawers
    ///      with funds locked in the paused market.
    function _checkRedeemPaused() internal view {
        if (_anyMarketPaused(false)) revert LendingOptimizer__MarketPaused();
    }

    /// @dev Returns the underlying token decimals.
    function _underlyingDecimals() internal view override returns (uint8) {
        return _decimals;
    }

    /// @dev Returns the decimals offset for virtual shares.
    /// @dev No offset used - inflation protection via initializeDeposits dead shares.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 0;
    }

    /// @dev Returns false - no virtual shares, use dead shares instead.
    function _useVirtualShares() internal pure override returns (bool) {
        return false;
    }

    /// @dev Checks if caller has harvester or market permissions.
    ///      Used by rebalance() to allow both the harvester bot and
    ///      the DAO/market admin to reallocate assets.
    function _hasRebalancePermissions() internal view {
        if (!centralRegistry.hasHarvestPermissions(msg.sender) &&
            !centralRegistry.hasMarketPermissions(msg.sender)) revert LendingOptimizer__Unauthorized();
    }

    /// @dev Checks if caller has elevated permissions.
    function _hasElevatedPermissions() internal view {
        if (!centralRegistry.hasElevatedPermissions(msg.sender)) revert LendingOptimizer__Unauthorized();
    }

    /// @dev Checks if caller has market permissions.
    function _hasMarketPermissions() internal view {
        if (!centralRegistry.hasMarketPermissions(msg.sender)) revert LendingOptimizer__Unauthorized();
    }

    /// @dev Checks if caller has DAO permissions.
    function _hasDaoPermissions() internal view {
        if (!centralRegistry.hasDaoPermissions(msg.sender)) revert LendingOptimizer__Unauthorized();
    }
}

// contracts/views/OptimizerReader.sol

interface IChainlinkAdaptor {
    function assetConfig(
        address asset,
        bool inUSD
    ) external view returns (bool isConfigured, address aggregatorProxy, uint8 decimals, uint24 heartbeat);
}

contract OptimizerReader {
    struct OptimizerCTokenData {
        /// @notice The cToken address.
        address _address;
        /// @notice Underlying assets allocated to this cToken by the optimizer.
        uint256 allocatedAssets;
        /// @notice Idle (non-loaned) liquidity available in this cToken market.
        uint256 liquidity;
        /// @notice Allocation cap for this cToken in WAD (1e18 = 100%).
        uint256 allocationCap;
        /// @notice Current allocation relative to the theoretical max allocation
        ///         allowed by the cap, in BPS. 10000 = at cap.
        uint256 allocationCapUtilizationBps;
    }

    struct OptimizerMarketData {
        /// @notice The optimizer address.
        address _address;
        /// @notice The underlying asset address (e.g., USDC).
        address asset;
        /// @notice Total underlying assets held across all markets.
        uint256 totalAssets;
        /// @notice Per-cToken market data.
        OptimizerCTokenData[] markets;
        /// @notice Total idle liquidity across all cToken markets.
        uint256 totalLiquidity;
        /// @notice Optimizer share price (exchange rate) in WAD.
        uint256 sharePrice;
        /// @notice Optimizer high-watermark exchange rate used for performance fees.
        uint256 exchangeRateHighWatermark;
        /// @notice Performance fee in BPS.
        uint256 performanceFee;
        /// @notice Number of approved cToken markets for this optimizer.
        uint256 numApprovedMarkets;
        /// @notice Annualized weighted-average supply APY in WAD (1e18 = 100%),
        ///         pre-performance-fee. Matches getOptimizerAPY() semantics.
        uint256 apy;
    }

    struct OptimizerUserData {
        /// @notice The optimizer address.
        address _address;
        /// @notice User's optimizer share balance.
        uint256 shareBalance;
        /// @notice User's redeemable underlying amount (from their optimizer shares).
        uint256 redeemable;
    }

    /// @dev Internal struct to pack per-market allocation state into a single
    ///      array, avoiding stack-too-deep in _computeIdealAllocation.
    struct MarketAlloc {
        uint256 simAssetsHeld;
        uint256 debt;
        uint256 fees;
        uint256 maxAllocation;
        IDynamicIRM irm;
    }

    /// ERRORS ///

    error OptimizerReader__Unauthorized();
    error OptimizerReader__InvalidMultiplier();
    error OptimizerReader__InvalidRebalanceChunks();

    /// EVENTS ///

    event StalenessMultiplierUpdated(uint256 oldMultiplier, uint256 newMultiplier);

    /// CONSTANTS ///

    /// @notice Minimum total rebalance value in USD (WAD) below which
    ///         optimalRebalance returns empty arrays. 1e18 = $1.
    uint256 public constant USD_THRESHOLD = 100e18;

    /// @notice Default cap headroom used by optimalRebalance planning.
    uint256 public constant CAP_BUFFER_BPS = 5;

    /// IMMUTABLES ///

    /// @notice The OracleManager address.
    IOracleManager public immutable ORACLE_MANAGER;

    /// @notice Curvance Protocol Central Registry, used for permissioning.
    ICentralRegistry public immutable centralRegistry;

    /// @notice Multiplier in BPS applied to each oracle's configured heartbeat
    ///         to determine the staleness threshold. 0 = staleness check disabled.
    ///         e.g., 15000 (1.5x) means a feed with a 1h heartbeat is stale after 1.5h.
    uint256 public stalenessMultiplierBps;

    /// CONSTRUCTOR ///

    constructor(
        ICentralRegistry _centralRegistry,
        uint256 _stalenessMultiplier
    ) {
        centralRegistry = _centralRegistry;
        ORACLE_MANAGER = IOracleManager(_centralRegistry.oracleManager());
        stalenessMultiplierBps = _stalenessMultiplier;
    }

    /// PERMISSIONED FUNCTIONS ///

    /// @notice Updates the global staleness multiplier.
    /// @dev Only callable by an address with elevated permissions.
    ///      Set to 0 to disable staleness checking.
    /// @param newMultiplierBps The new multiplier in BPS (e.g., 15000 = 1.5x heartbeat).
    function setStalenessMultiplier(uint256 newMultiplierBps) external {
        if (!centralRegistry.hasElevatedPermissions(msg.sender)) {
            revert OptimizerReader__Unauthorized();
        }

        if (newMultiplierBps != 0 && newMultiplierBps < 10_000) {
            revert OptimizerReader__InvalidMultiplier();
        }

        uint256 oldMultiplier = stalenessMultiplierBps;
        stalenessMultiplierBps = newMultiplierBps;

        emit StalenessMultiplierUpdated(oldMultiplier, newMultiplierBps);
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Checks multiple optimizers for bad markets in a single call.
    /// @param optimizers The LendingOptimizer addresses.
    /// @return badOptimizers An array of cToken arrays, where each inner array
    ///         contains the bad markets for the corresponding optimizer.
    function multiIsBadCheck(
        address[] calldata optimizers
    ) external view returns (address[][] memory badOptimizers) {
        uint256 len = optimizers.length;
        badOptimizers = new address[][](len);

        for (uint256 i; i < len; ++i) {
            badOptimizers[i] = this.isBad(optimizers[i]);
        }
    }

    /// @notice Checks whether any approved market should be considered
    ///         unsafe due to a stale oracle feed or breached PriceGuard.
    /// @dev For each approved market in the optimizer:
    ///      1. Checks if the collateral's oracle feed is stale (if
    ///         stalenessMultiplier > 0).
    ///      2. Checks if the collateral's adjusted price is zero. Curvance
    ///         PriceGuards return zero when the guarded price breaches the
    ///         configured floor, so this acts as the PriceGuard breach check.
    ///      A market is flagged if either condition is met.
    /// @param optimizer The LendingOptimizer address.
    /// @return bad Array of optimizer cToken addresses whose
    ///         collateral has a stale oracle or breached PriceGuard.
    function isBad(
        address optimizer
    ) external view returns (address[] memory bad) {
        address[] memory markets = ILendingOptimizer(optimizer).getApprovedMarkets();
        uint256 numMarkets = markets.length;

        // Temporary array sized to max possible flags.
        address[] memory temp = new address[](numMarkets);
        uint256 flagCount;

        uint256 _stalenessMultiplierBps = stalenessMultiplierBps;

        for (uint256 i; i < numMarkets; ++i) {
            // Find the collateral cToken for this market by walking
            // the market manager's listed tokens.
            IMarketManager mm = _marketManager(markets[i]);
            address[] memory listed = mm.queryTokensListed();

            bool flagged;

            for (uint256 j; j < listed.length; ++j) {
                // Skip the optimizer's own cToken — the other token
                // is the collateral.
                if (listed[j] == markets[i]) continue;

                address collateralAsset = ICToken(listed[j]).asset();

                // Check oracle staleness (applies to all markets).
                if (_stalenessMultiplierBps > 0 &&
                    _isOracleStale(collateralAsset, _stalenessMultiplierBps)
                ) {
                    flagged = true;
                    break;
                }

                // A zero adjusted price is the simplified PriceGuard breach
                // signal emitted by oracle adaptors and wrapped aggregators.
                if (_isOraclePriceZero(collateralAsset)) {
                    flagged = true;
                    break;
                }
            }

            if (flagged) {
                temp[flagCount++] = markets[i];
            }
        }

        // Copy to correctly sized array.
        bad = new address[](flagCount);
        for (uint256 i; i < flagCount; ++i) {
            bad[i] = temp[i];
        }
    }

    /// @notice Returns market data for a list of LendingOptimizers.
    /// @param optimizers The LendingOptimizer addresses.
    /// @return data The market data for each optimizer.
    function getOptimizerMarketData(
        address[] calldata optimizers
    ) external returns (OptimizerMarketData[] memory data) {
        uint256 len = optimizers.length;
        data = new OptimizerMarketData[](len);

        for (uint256 i; i < len; ++i) {
            ILendingOptimizer opt = ILendingOptimizer(optimizers[i]);

            data[i]._address = optimizers[i];
            data[i].asset = opt.asset();
            data[i].sharePrice = opt.exchangeRateUpdated();
            data[i].totalAssets = opt.totalAssets();
            data[i].exchangeRateHighWatermark = opt.exchangeRateHighWatermark();
            data[i].performanceFee = opt.fee();
            data[i].apy = _getOptimizerAPY(optimizers[i]);

            address[] memory cTokens = opt.getApprovedMarkets();
            uint256 l = cTokens.length;
            data[i].numApprovedMarkets = l;
            data[i].markets = new OptimizerCTokenData[](l);

            for (uint256 j; j < l; ++j) {
                IBorrowableCToken cToken = IBorrowableCToken(cTokens[j]);
                uint256 allocated = cToken.convertToAssets(
                    _balanceOf(address(cToken), optimizers[i])
                );
                uint256 liquidity = _assetsHeld(cToken);
                uint256 allocationCap = opt.allocationCaps(cTokens[j]);
                uint256 maxAllocation = FixedPointMathLib.mulDiv(
                    data[i].totalAssets,
                    allocationCap,
                    WAD
                );
                uint256 allocationCapUtilizationBps = maxAllocation == 0
                    ? 0
                    : FixedPointMathLib.mulDiv(allocated, BPS, maxAllocation);

                data[i].markets[j] = OptimizerCTokenData({
                    _address: cTokens[j],
                    allocatedAssets: allocated,
                    liquidity: liquidity,
                    allocationCap: allocationCap,
                    allocationCapUtilizationBps: allocationCapUtilizationBps
                });
                data[i].totalLiquidity += liquidity;
            }
        }
    }

    /// @notice Returns user-specific data for a list of LendingOptimizers.
    /// @param optimizers The LendingOptimizer addresses.
    /// @param account The user address to query.
    /// @return data The user data for each optimizer.
    function getOptimizerUserData(
        address[] calldata optimizers,
        address account
    ) external returns (OptimizerUserData[] memory data) {
        uint256 len = optimizers.length;
        data = new OptimizerUserData[](len);

        for (uint256 i; i < len; ++i) {
            ILendingOptimizer opt = ILendingOptimizer(optimizers[i]);
            opt.accrueIfNeeded();
            uint256 shares = _balanceOf(optimizers[i], account);

            data[i]._address = optimizers[i];
            data[i].shareBalance = shares;
            data[i].redeemable = opt.convertToAssets(shares);
        }
    }

    /// @notice Returns the annualized weighted-average supply APY for a
    ///         LendingOptimizer, in WAD (1e18 = 100%).
    /// @dev Does not account for the optimizer's performance fee.
    /// @param optimizer The LendingOptimizer address.
    /// @return apy The annualized supply APY in WAD.
    function getOptimizerAPY(
        address optimizer
    ) public returns (uint256 apy) {
        ILendingOptimizer(optimizer).accrueIfNeeded();
        apy = _getOptimizerAPY(optimizer);
    }

    function _getOptimizerAPY(
        address optimizer
    ) internal view returns (uint256 apy) {
        ILendingOptimizer opt = ILendingOptimizer(optimizer);
        uint256 ta = opt.totalAssets();
        if (ta == 0) return 0;

        address[] memory markets = opt.getApprovedMarkets();
        uint256 weightedRate;

        for (uint256 i; i < markets.length; ++i) {
            IBorrowableCToken ct = IBorrowableCToken(markets[i]);
            uint256 allocated = ct.convertToAssets(
                _balanceOf(address(ct), optimizer)
            );

            uint256 rate = _IRM(ct).supplyRate(
                _assetsHeld(ct),
                _outstandingDebt(ct),
                _interestFee(ct)
            );

            weightedRate += FixedPointMathLib.mulDiv(allocated, rate, ta);
        }

        apy = weightedRate * 31_536_000;
    }

    /// @notice Computes optimal rebalance actions, automatically excluding
    ///         any markets flagged by isBad(). In normal conditions (no bad
    ///         markets), this is a pure yield-optimization. When bad markets
    ///         exist, it withdraws everything from them and optimally
    ///         redistributes across the remaining good markets.
    ///         Returns empty arrays when no actionable rebalance exists
    ///         (all deltas are zero or dust).
    /// @param optimizer The LendingOptimizer address.
    /// @param slippageBps Tolerance in BPS around each market's ideal allocation.
    ///                    e.g., 100 = +/- 1%.
    /// @param rebalanceChunks Number of chunks used by the greedy allocation.
    /// @return actions The rebalance actions array matching approvedCTokensList order,
    ///                 or empty if no rebalance is needed.
    /// @return bounds The allocation bounds array matching approvedCTokensList order,
    ///                or empty if no rebalance is needed.
    function optimalRebalance(
        address optimizer,
        uint256 slippageBps,
        uint256 rebalanceChunks
    ) external returns (
        LendingOptimizer.ReallocationAction[] memory actions,
        LendingOptimizer.AllocationBound[] memory bounds
    ) {
        if (rebalanceChunks == 0) {
            revert OptimizerReader__InvalidRebalanceChunks();
        }

        ILendingOptimizer(optimizer).accrueIfNeeded();
        return _optimalRebalance(optimizer, slippageBps, rebalanceChunks);
    }

    function _optimalRebalance(
        address optimizer,
        uint256 slippageBps,
        uint256 rebalanceChunks
    ) internal view returns (
        LendingOptimizer.ReallocationAction[] memory actions,
        LendingOptimizer.AllocationBound[] memory bounds
    ) {
        address[] memory markets = ILendingOptimizer(optimizer).getApprovedMarkets();

        if (markets.length == 0) return (actions, bounds);

        // Automatically exclude bad markets from allocation.
        address[] memory badMarkets = this.isBad(optimizer);

        uint256[] memory idealAssets;
        uint256[] memory currentAssets;
        uint256 totalAssets;
        (idealAssets, currentAssets,) =
            _computeIdealAllocation(optimizer, markets, badMarkets, rebalanceChunks);
        for (uint256 i; i < currentAssets.length; ++i) {
            totalAssets += currentAssets[i];
        }

        if (!_fullyAllocated(idealAssets, totalAssets)) {
            return (actions, bounds);
        }

        // Remove dust actions that would revert at the cToken level
        // (convertToShares == 0) and rebalance to maintain zero-sum.
        // Returns empty arrays if no actionable rebalance remains.
        if (!_removeDustActions(markets, idealAssets, currentAssets)) {
            return (actions, bounds);
        }

        actions = new LendingOptimizer.ReallocationAction[](markets.length);
        bounds = new LendingOptimizer.AllocationBound[](markets.length);

        _buildActionsAndBounds(markets, idealAssets, currentAssets, totalAssets, slippageBps, actions, bounds);

        if (badMarkets.length == 0) {
            address underlying = ILendingOptimizer(optimizer).asset();
            (uint256 price, uint256 errorCode) = ORACLE_MANAGER.getPrice(underlying, true, true);

            // Only apply threshold if price is reliable.
            if (errorCode == 0 && price > 0) {
                uint256 assetDecimals = IERC20(underlying).decimals();

                uint256 totalAbsAssets;
                for (uint256 i; i < actions.length; ++i) {
                    int256 v = actions[i].assetsOrBps;
                    totalAbsAssets += v > 0 ? uint256(v) : uint256(-v);
                }

                // Only half matters (deposits == withdrawals), so divide by 2.
                uint256 usdValue = FixedPointMathLib.mulDiv(
                    totalAbsAssets / 2, price, 10 ** assetDecimals
                );

                if (usdValue < USD_THRESHOLD) {
                    return (
                        new LendingOptimizer.ReallocationAction[](0),
                        new LendingOptimizer.AllocationBound[](0)
                    );
                }
            }
        }
    }

    /// @dev Chunked greedy allocation: computes the ideal per-market asset
    ///      distribution for a LendingOptimizer, respecting allocation caps
    ///      and market pause states.
    ///      When `badMarkets` is non-empty, those markets are forced to
    ///      maxAllocation = 0, causing full withdrawal and optimal
    ///      redistribution across the remaining good markets.
    ///      Separated from the public functions to avoid stack-too-deep.
    function _computeIdealAllocation(
        address optimizer,
        address[] memory markets,
        address[] memory badMarkets,
        uint256 rebalanceChunks
    ) internal view returns (
        uint256[] memory idealAssets,
        uint256[] memory currentAssets,
        MarketAlloc[] memory m
    ) {
        uint256 numMarkets = markets.length;
        idealAssets = new uint256[](numMarkets);
        currentAssets = new uint256[](numMarkets);
        m = new MarketAlloc[](numMarkets);

        // First pass: snapshot per-market state and compute total assets.
        uint256 ta;
        {
            for (uint256 i; i < numMarkets; ++i) {
                IBorrowableCToken ct = IBorrowableCToken(markets[i]);
                uint256 ca = ct.convertToAssets(
                    _balanceOf(address(ct), optimizer)
                );
                currentAssets[i] = ca;
                ta += ca;

                uint256 assetsHeld = _assetsHeld(ct);
                m[i].simAssetsHeld = assetsHeld > ca
                    ? assetsHeld - ca
                    : 0;
                m[i].debt = _outstandingDebt(ct);
                m[i].fees = _interestFee(ct);
                m[i].irm = _IRM(ct);
            }
        }

        if (ta == 0) return (idealAssets, currentAssets, m);

        // Second pass: compute maxAllocation, adjust for pause states,
        // and force bad markets to zero allocation.
        uint256 lockedAssets;
        {
            ILendingOptimizer opt = ILendingOptimizer(optimizer);
            uint256 bufferBps = _selectCapBuffer(opt, markets, badMarkets, currentAssets, ta);
            for (uint256 i; i < numMarkets; ++i) {
                uint256 current = currentAssets[i];
                m[i].maxAllocation = _bufferedMaxAllocation(opt, markets[i], ta, bufferBps);

                MarketManagerIsolated mm = MarketManagerIsolated(address(_marketManager(markets[i])));
                // Two orthogonal constraints drive allocation policy:
                //  - cannotAddMore: bad or mint-paused — no new deposits.
                //  - cannotWithdraw: redeem-paused — must keep current position.
                bool cannotAddMore = _isBadMarket(markets[i], badMarkets)
                    || _isMintPaused(markets[i], IMarketManager(address(mm)));
                bool cannotWithdraw = mm.redeemPaused() == 2;

                if (cannotWithdraw) {
                    // Position is locked; exclude from distributable pool.
                    m[i].simAssetsHeld += current;
                    lockedAssets += current;
                    idealAssets[i] = current;
                    // If also cannot add, freeze at current; otherwise floor at current.
                    if (cannotAddMore) {
                        m[i].maxAllocation = current;
                    } else if (m[i].maxAllocation < current) {
                        m[i].maxAllocation = current;
                    }
                } else if (cannotAddMore) {
                    // Can withdraw, cannot add → drain to 0.
                    m[i].maxAllocation = 0;
                }
                // else: normal greedy allocation at cap-based maxAllocation.
            }
        }

        // Subtract locked assets from the distributable total.
        ta -= lockedAssets;

        // Chunked greedy allocation: split distributable total into fixed-size chunks.
        uint256 chunkSize = ta / rebalanceChunks;

        for (uint256 c; c < rebalanceChunks; ++c) {
            uint256 chunk = (c == rebalanceChunks - 1) ? ta - (chunkSize * (rebalanceChunks - 1)) : chunkSize;
            if (chunk == 0) continue;

            uint256 bestRate;
            uint256 bestIdx;
            bool found;

            for (uint256 i; i < numMarkets; ++i) {
                if (idealAssets[i] + chunk > m[i].maxAllocation) continue;

                uint256 rate = m[i].irm.supplyRate(
                    m[i].simAssetsHeld + chunk,
                    m[i].debt,
                    m[i].fees
                );

                if (!found || rate > bestRate) {
                    bestRate = rate;
                    bestIdx = i;
                    found = true;
                }
            }

            if (found) {
                idealAssets[bestIdx] += chunk;
                m[bestIdx].simAssetsHeld += chunk;
            }
        }

        _fillResidualAllocation(idealAssets, m, ta);
    }

    function _fillResidualAllocation(
        uint256[] memory idealAssets,
        MarketAlloc[] memory m,
        uint256 totalAssets
    ) internal view {
        uint256 allocated;
        for (uint256 i; i < idealAssets.length; ++i) {
            allocated += idealAssets[i];
        }

        if (allocated >= totalAssets) return;

        uint256 remaining = totalAssets - allocated;
        while (remaining > 0) {
            uint256 bestRate;
            uint256 bestIdx;
            uint256 bestAmount;
            bool found;

            for (uint256 i; i < idealAssets.length; ++i) {
                if (idealAssets[i] >= m[i].maxAllocation) continue;

                uint256 capacity = m[i].maxAllocation - idealAssets[i];
                uint256 amount = capacity < remaining ? capacity : remaining;
                if (amount == 0) continue;

                uint256 rate = m[i].irm.supplyRate(
                    m[i].simAssetsHeld + amount,
                    m[i].debt,
                    m[i].fees
                );

                if (!found || rate > bestRate) {
                    bestRate = rate;
                    bestIdx = i;
                    bestAmount = amount;
                    found = true;
                }
            }

            if (!found) break;

            idealAssets[bestIdx] += bestAmount;
            m[bestIdx].simAssetsHeld += bestAmount;
            remaining -= bestAmount;
        }

        if (remaining > 0 && remaining <= idealAssets.length) {
            _allocateRoundingResidual(idealAssets, m, remaining);
        }
    }

    function _allocateRoundingResidual(
        uint256[] memory idealAssets,
        MarketAlloc[] memory m,
        uint256 remaining
    ) internal view {
        uint256 bestRate;
        uint256 bestIdx;
        bool found;

        for (uint256 i; i < idealAssets.length; ++i) {
            uint256 rate = m[i].irm.supplyRate(
                m[i].simAssetsHeld + remaining,
                m[i].debt,
                m[i].fees
            );

            if (!found || rate > bestRate) {
                bestRate = rate;
                bestIdx = i;
                found = true;
            }
        }

        if (found) {
            idealAssets[bestIdx] += remaining;
            m[bestIdx].simAssetsHeld += remaining;
        }
    }

    function _fullyAllocated(
        uint256[] memory idealAssets,
        uint256 totalAssets
    ) internal pure returns (bool) {
        uint256 allocated;
        for (uint256 i; i < idealAssets.length; ++i) {
            allocated += idealAssets[i];
        }

        return allocated >= totalAssets;
    }

    /// @dev Diffs ideal vs current allocations to produce deposit/withdraw
    ///      actions, and computes bounds around each market's ideal BPS.
    function _buildActionsAndBounds(
        address[] memory markets,
        uint256[] memory idealAssets,
        uint256[] memory currentAssets,
        uint256 ta,
        uint256 slippageBps,
        LendingOptimizer.ReallocationAction[] memory actions,
        LendingOptimizer.AllocationBound[] memory bounds
    ) internal pure {
        for (uint256 i; i < markets.length; ++i) {
            if (idealAssets[i] > currentAssets[i]) {
                actions[i] = LendingOptimizer.ReallocationAction(
                    IBorrowableCToken(markets[i]),
                    int256(idealAssets[i] - currentAssets[i])
                );
            } else if (currentAssets[i] > idealAssets[i]) {
                actions[i] = LendingOptimizer.ReallocationAction(
                    IBorrowableCToken(markets[i]),
                    -int256(currentAssets[i] - idealAssets[i])
                );
            } else {
                actions[i] = LendingOptimizer.ReallocationAction(
                    IBorrowableCToken(markets[i]),
                    int256(0)
                );
            }

            if (ta > 0) {
                uint256 idealBps = FixedPointMathLib.mulDiv(idealAssets[i], 10000, ta);
                bounds[i] = LendingOptimizer.AllocationBound(
                    markets[i],
                    idealBps > slippageBps ? idealBps - slippageBps : 0,
                    idealBps + slippageBps > 10000 ? 10000 : idealBps + slippageBps
                );
            } else {
                bounds[i] = LendingOptimizer.AllocationBound(markets[i], 0, 10000);
            }
        }
    }

    function _selectCapBuffer(
        ILendingOptimizer opt,
        address[] memory markets,
        address[] memory badMarkets,
        uint256[] memory currentAssets,
        uint256 totalAssets
    ) internal view returns (uint256 bufferBps) {
        for (uint256 i = CAP_BUFFER_BPS;; --i) {
            if (_hasEnoughBufferedCapacity(opt, markets, badMarkets, currentAssets, totalAssets, i)) {
                return i;
            }

            if (i == 0) return 0;
        }
    }

    function _hasEnoughBufferedCapacity(
        ILendingOptimizer opt,
        address[] memory markets,
        address[] memory badMarkets,
        uint256[] memory currentAssets,
        uint256 totalAssets,
        uint256 bufferBps
    ) internal view returns (bool) {
        uint256 capacity;

        for (uint256 i; i < markets.length; ++i) {
            MarketManagerIsolated mm = MarketManagerIsolated(address(_marketManager(markets[i])));
            bool cannotAddMore = _isBadMarket(markets[i], badMarkets)
                || _isMintPaused(markets[i], IMarketManager(address(mm)));
            bool cannotWithdraw = mm.redeemPaused() == 2;

            if (cannotWithdraw) {
                capacity += currentAssets[i];
            } else if (!cannotAddMore) {
                capacity += _bufferedMaxAllocation(opt, markets[i], totalAssets, bufferBps);
            }

            if (capacity >= totalAssets) return true;
        }

        return false;
    }

    function _bufferedMaxAllocation(
        ILendingOptimizer opt,
        address market,
        uint256 totalAssets,
        uint256 bufferBps
    ) internal view returns (uint256) {
        uint256 cap = opt.allocationCaps(market);
        uint256 buffer = bufferBps * 1e14;
        if (cap <= buffer) return 0;

        return FixedPointMathLib.mulDiv(totalAssets, cap - buffer, WAD);
    }

    /// @dev Removes dust rebalance deltas — entries whose absolute value
    ///      converts to zero cToken shares (and would revert on-chain).
    ///      Maintains the zero-sum invariant by trimming the smallest
    ///      action on the opposing side. If trimming creates new dust the
    ///      direction flips and the loop continues.
    ///      Modifies `idealAssets` in place.
    /// @return hasActions True if at least one non-zero delta remains.
    function _removeDustActions(
        address[] memory markets,
        uint256[] memory idealAssets,
        uint256[] memory currentAssets
    ) internal view returns (bool hasActions) {
        uint256 numMarkets = markets.length;

        // Phase 1: Zero dust entries and compute signed imbalance.
        // Positive imbalance → excess deposits → must reduce deposits.
        // Negative imbalance → excess withdrawals → must reduce withdrawals.
        int256 imbalance;

        for (uint256 i; i < numMarkets; ++i) {
            if (idealAssets[i] == currentAssets[i]) continue;

            bool isDeposit = idealAssets[i] > currentAssets[i];
            uint256 absDelta = isDeposit
                ? idealAssets[i] - currentAssets[i]
                : currentAssets[i] - idealAssets[i];

            if (IBorrowableCToken(markets[i]).convertToShares(absDelta) == 0) {
                imbalance += isDeposit
                    ? -int256(absDelta)
                    : int256(absDelta);
                idealAssets[i] = currentAssets[i];
            }
        }

        // Phase 2: Rebalance by trimming the smallest entry on the
        // over-represented side. If trimming creates new dust the
        // excess flips direction and the loop continues.
        if (imbalance != 0) {
            uint256 excess = imbalance > 0
                ? uint256(imbalance)
                : uint256(-imbalance);
            bool reduceDeposits = imbalance > 0;

            while (excess > 0) {
                uint256 bestIdx;
                uint256 bestAmt = type(uint256).max;
                bool found;

                for (uint256 i; i < numMarkets; ++i) {
                    if (idealAssets[i] == currentAssets[i]) continue;

                    bool isDeposit = idealAssets[i] > currentAssets[i];
                    if (isDeposit != reduceDeposits) continue;

                    uint256 amt = isDeposit
                        ? idealAssets[i] - currentAssets[i]
                        : currentAssets[i] - idealAssets[i];

                    if (amt < bestAmt) {
                        bestAmt = amt;
                        bestIdx = i;
                        found = true;
                    }
                }

                if (!found) {
                    // Cannot balance — zero all remaining actions.
                    for (uint256 i; i < numMarkets; ++i) {
                        idealAssets[i] = currentAssets[i];
                    }
                    break;
                }

                if (excess >= bestAmt) {
                    // Zero this entry entirely.
                    idealAssets[bestIdx] = currentAssets[bestIdx];
                    excess -= bestAmt;
                } else {
                    // Partially reduce.
                    if (reduceDeposits) {
                        idealAssets[bestIdx] -= excess;
                    } else {
                        idealAssets[bestIdx] += excess;
                    }

                    // Check if the remainder is now dust.
                    uint256 remaining = reduceDeposits
                        ? idealAssets[bestIdx] - currentAssets[bestIdx]
                        : currentAssets[bestIdx] - idealAssets[bestIdx];

                    if (IBorrowableCToken(markets[bestIdx]).convertToShares(remaining) == 0) {
                        // Over-reduced: remainder is dust. Zero it
                        // and flip direction with the leftover.
                        idealAssets[bestIdx] = currentAssets[bestIdx];
                        excess = remaining;
                        reduceDeposits = !reduceDeposits;
                    } else {
                        excess = 0;
                    }
                }
            }
        }

        // Phase 3: Return true if any non-zero delta remains.
        for (uint256 i; i < numMarkets; ++i) {
            if (idealAssets[i] != currentAssets[i]) return true;
        }
        return false;
    }

    /// @dev Returns true if `market` is in the `badMarkets` array.
    function _isBadMarket(
        address market,
        address[] memory badMarkets
    ) internal pure returns (bool) {
        for (uint256 i; i < badMarkets.length; ++i) {
            if (badMarkets[i] == market) return true;
        }
        return false;
    }

    function _balanceOf(
        address token,
        address account
    ) internal view returns (uint256 result) {
        result = ICToken(token).balanceOf(account);
    }

    function _assetsHeld(
        IBorrowableCToken token
    ) internal view returns (uint256 result) {
        result = token.assetsHeld();
    }

    /// @dev Returns true if minting is paused for `cToken`.
    function _isMintPaused(
        address cToken,
        IMarketManager mm
    ) internal view returns (bool mp) {
        (mp,,) = mm.actionsPaused(cToken);
    }

    /// @dev Convenience overload — resolves market manager from cToken.
    function _isMintPaused(address cToken) internal view returns (bool mp) {
        mp = _isMintPaused(cToken, _marketManager(cToken));
    }

    function _marketManager(
        address cToken
    ) internal view returns (IMarketManager mm) {
        mm = ICToken(cToken).marketManager();
    }

    function _IRM(
        IBorrowableCToken token
    ) internal view returns (IDynamicIRM result) {
        result = token.IRM();
    }

    function _outstandingDebt(
        IBorrowableCToken token
    ) internal view returns (uint256 result) {
        result = token.marketOutstandingDebt();
    }

    function _interestFee(
        IBorrowableCToken token
    ) internal view returns (uint256 result) {
        result = token.interestFee();
    }

    /// @dev Checks whether a collateral asset's oracle feed is stale.
    ///      Compares the time since the last oracle update against the
    ///      feed's configured heartbeat scaled by `multiplierBps`.
    /// @param collateralAsset The underlying collateral asset address.
    /// @param multiplierBps The staleness multiplier in BPS (e.g., 15000 = 1.5x).
    /// @return True if the oracle feed is stale.
    function _isOracleStale(
        address collateralAsset,
        uint256 multiplierBps
    ) internal view returns (bool) {
        address[] memory adaptors = ORACLE_MANAGER.getPricingAdaptors(
            collateralAsset
        );

        (, address aggregatorProxy,, uint24 heartbeat) =
            IChainlinkAdaptor(adaptors[0]).assetConfig(collateralAsset, true);

        (,,, uint256 updatedAt,) = IChainlink(aggregatorProxy).latestRoundData();

        unchecked {
            return block.timestamp - updatedAt >
                uint256(heartbeat) * multiplierBps / 10000;
        }
    }

    /// @dev Checks whether a collateral asset's adjusted oracle price is zero,
    ///      which indicates a PriceGuard floor breach in Curvance adaptors.
    function _isOraclePriceZero(
        address collateralAsset
    ) internal view returns (bool) {
        address[] memory adaptors = ORACLE_MANAGER.getPricingAdaptors(
            collateralAsset
        );

        IOracleAdaptor.PricingResult memory result = IOracleAdaptor(adaptors[0])
            .getPrice(
                collateralAsset,
                true,
                true
            );

        return result.price == 0;
    }
}
