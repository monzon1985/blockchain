// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IQuartetToken} from "../interfaces/IQuartetToken.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @title QuartetSolidity
/// @author Gas Golf Quartet
/// @notice Fixed-supply ERC-20 with EIP-2612 permit, written as idiomatic, assembly-free Solidity.
///         It is the readable baseline of the quartet: the inline-assembly, Yul and Vyper versions
///         must be observationally equivalent to it (and to OpenZeppelin 5.7 `ERC20Permit`).
/// @dev Semantics mirror OpenZeppelin 5.7 `ERC20` + `ERC20Permit` exactly: ERC-6093 errors with the
///      offending values, zero-address checks in the same order, the infinite allowance is never
///      decreased, `transferFrom` emits no `Approval`, and permits reject high-`s` signatures.
///      The whole supply is minted once in the constructor, so `totalSupply` is an immutable.
contract QuartetSolidity is IQuartetToken, IERC20Errors {
    /// @notice The permit deadline has passed.
    /// @param deadline The deadline that was exceeded.
    error ERC2612ExpiredSignature(uint256 deadline);

    /// @notice The permit signature recovers to an address other than `owner`.
    /// @param signer The recovered signer.
    /// @param owner The owner named in the permit.
    error ERC2612InvalidSigner(address signer, address owner);

    /// @dev keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)")
    bytes32 private constant _PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    /// @dev keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
    bytes32 private constant _DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    /// @dev EIP-712 domain name hash; the name is the token name.
    bytes32 private constant _HASHED_NAME = keccak256("Gas Golf Quartet");

    /// @dev EIP-712 domain version hash.
    bytes32 private constant _HASHED_VERSION = keccak256("1");

    /// @notice Token name, also used as the EIP-712 domain name.
    string public constant override name = "Gas Golf Quartet";

    /// @notice Token symbol.
    string public constant override symbol = "GOLF";

    /// @notice Number of decimals used for display purposes.
    uint8 public constant override decimals = 18;

    /// @notice Total supply, minted to the initial holder at construction and never changed.
    uint256 public immutable override totalSupply;

    /// @notice Balance of each account.
    mapping(address account => uint256) public override balanceOf;

    /// @notice Remaining amount `spender` may move out of `owner`'s balance.
    mapping(address owner => mapping(address spender => uint256)) public override allowance;

    /// @notice Next EIP-2612 nonce of each owner. Increments by one per successful permit.
    mapping(address owner => uint256) public override nonces;

    /// @dev Domain separator computed at deployment, valid while `chainid` and `address(this)` match.
    bytes32 private immutable _cachedDomainSeparator;

    /// @dev Chain id at deployment; a fork to another chain id forces recomputation.
    uint256 private immutable _cachedChainId;

    /// @dev Deployment address; a delegatecall from a proxy forces recomputation.
    address private immutable _cachedThis;

    /// @notice Deploys the token and mints the whole supply to `holder`.
    /// @param holder Receiver of the initial supply. Must not be the zero address.
    /// @param supply Total supply to mint.
    constructor(address holder, uint256 supply) {
        if (holder == address(0)) revert ERC20InvalidReceiver(address(0));
        totalSupply = supply;
        balanceOf[holder] = supply;
        _cachedChainId = block.chainid;
        _cachedThis = address(this);
        _cachedDomainSeparator = _buildDomainSeparator();
        emit Transfer(address(0), holder, supply);
    }

    /// @notice Moves `value` tokens from the caller to `to`.
    /// @param to Recipient. Must not be the zero address.
    /// @param value Amount to move.
    /// @return Always true; failures revert.
    function transfer(address to, uint256 value) external override returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    /// @notice Sets `spender`'s allowance over the caller's tokens to `value`.
    /// @param spender Account allowed to spend. Must not be the zero address.
    /// @param value New allowance. `type(uint256).max` is an infinite allowance.
    /// @return Always true; failures revert.
    function approve(address spender, uint256 value) external override returns (bool) {
        _approve(msg.sender, spender, value, true);
        return true;
    }

    /// @notice Moves `value` tokens from `from` to `to` using the caller's allowance.
    /// @dev The allowance is checked and decreased before the transfer, as in OpenZeppelin, so an
    ///      insufficient allowance is reported before a bad receiver or an insufficient balance.
    /// @param from Account debited.
    /// @param to Recipient. Must not be the zero address.
    /// @param value Amount to move.
    /// @return Always true; failures revert.
    function transferFrom(address from, address to, uint256 value) external override returns (bool) {
        _spendAllowance(from, msg.sender, value);
        _transfer(from, to, value);
        return true;
    }

    /// @notice Sets `spender`'s allowance over `owner`'s tokens from an EIP-712 signature.
    /// @param owner Token owner who signed the permit.
    /// @param spender Account allowed to spend. Must not be the zero address.
    /// @param value New allowance.
    /// @param deadline Last timestamp at which the signature is valid.
    /// @param v Signature recovery byte.
    /// @param r Signature `r` value.
    /// @param s Signature `s` value; must be in the lower half of the curve order.
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
        override
    {
        // EIP-2612 defines the deadline in block time; a proposer's few seconds of skew are accepted by design.
        // slither-disable-start timestamp
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > deadline) revert ERC2612ExpiredSignature(deadline);
        // slither-disable-end timestamp
        uint256 nonce;
        unchecked {
            // Safe: a nonce only grows by one per successful permit, so it can never reach 2**256 - 1.
            nonce = nonces[owner]++;
        }
        bytes32 structHash = keccak256(abi.encode(_PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));
        address signer = ECDSA.recover(MessageHashUtils.toTypedDataHash(_domainSeparator(), structHash), v, r, s);
        if (signer != owner) revert ERC2612InvalidSigner(signer, owner);
        _approve(owner, spender, value, true);
    }

    /// @notice EIP-712 domain separator used by `permit`.
    /// @return The separator for the current chain id and contract address.
    // forge-lint: disable-next-line(mixed-case-function)
    function DOMAIN_SEPARATOR() external view override returns (bytes32) {
        return _domainSeparator();
    }

    /// @dev Moves `value` from `from` to `to` after the ERC-6093 checks, in OpenZeppelin's order.
    function _transfer(address from, address to, uint256 value) private {
        if (from == address(0)) revert ERC20InvalidSender(address(0));
        if (to == address(0)) revert ERC20InvalidReceiver(address(0));
        uint256 fromBalance = balanceOf[from];
        if (fromBalance < value) revert ERC20InsufficientBalance(from, fromBalance, value);
        unchecked {
            // Safe: `fromBalance >= value` was checked above.
            balanceOf[from] = fromBalance - value;
            // Safe in every reachable state: balances sum to `totalSupply`, which fits in 256 bits.
            // Wrapping (not reverting) keeps the semantics identical to OpenZeppelin in all states.
            balanceOf[to] += value;
        }
        emit Transfer(from, to, value);
    }

    /// @dev Writes an allowance after the zero-address checks; emits `Approval` only when asked.
    function _approve(address owner, address spender, uint256 value, bool emitEvent) private {
        if (owner == address(0)) revert ERC20InvalidApprover(address(0));
        if (spender == address(0)) revert ERC20InvalidSpender(address(0));
        allowance[owner][spender] = value;
        // The only "external call" on any path here is the ecrecover precompile, reached with a STATICCALL
        // from ECDSA.recover in `permit`: it cannot re-enter, so the event order is fixed.
        // forge-lint: disable-next-line(reentrancy-events)
        if (emitEvent) emit Approval(owner, spender, value);
    }

    /// @dev Consumes `value` of `spender`'s allowance over `owner`. The infinite allowance is kept.
    function _spendAllowance(address owner, address spender, uint256 value) private {
        uint256 currentAllowance = allowance[owner][spender];
        if (currentAllowance < type(uint256).max) {
            if (currentAllowance < value) revert ERC20InsufficientAllowance(spender, currentAllowance, value);
            unchecked {
                // Safe: `currentAllowance >= value` was checked above.
                _approve(owner, spender, currentAllowance - value, false);
            }
        }
    }

    /// @dev Returns the cached separator unless the chain id or the executing address changed.
    function _domainSeparator() private view returns (bytes32) {
        if (address(this) == _cachedThis && block.chainid == _cachedChainId) return _cachedDomainSeparator;
        return _buildDomainSeparator();
    }

    /// @dev EIP-712 domain separator for the current chain id and executing address.
    function _buildDomainSeparator() private view returns (bytes32) {
        return keccak256(abi.encode(_DOMAIN_TYPEHASH, _HASHED_NAME, _HASHED_VERSION, block.chainid, address(this)));
    }
}
