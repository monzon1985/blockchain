# SPDX-License-Identifier: MIT
#pragma version 0.4.3
#pragma optimize gas
"""
@title QuartetVyper
@custom:contract-name QuartetVyper
@license MIT
@notice Fixed-supply ERC-20 with EIP-2612 permit in idiomatic Vyper 0.4 (snekmate-style
        assertions with reason strings). Observationally equivalent to QuartetSolidity and to
        OpenZeppelin 5.7 ERC20Permit: same check order, same infinite-allowance rule, same
        high-s rejection. Revert data is Error(string); the test harness maps each reason
        string to the shared revert class (test/utils/RevertClassifier.sol).
@dev Wrapping `unsafe_add` / `unsafe_sub` are used exactly where OpenZeppelin uses
     `unchecked`, each after an explicit bound check or on a value bounded by the fixed
     total supply, so the semantics match the Solidity implementations in every state.
"""

from ethereum.ercs import IERC20

implements: IERC20

# keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)")
_PERMIT_TYPEHASH: constant(bytes32) = keccak256(
    "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
)
# keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
_DOMAIN_TYPEHASH: constant(bytes32) = keccak256(
    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
)
_HASHED_NAME: constant(bytes32) = keccak256("Gas Golf Quartet")
_HASHED_VERSION: constant(bytes32) = keccak256("1")
# secp256k1n / 2 (0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0): larger `s`
# values are the malleable twin of a valid signature (EIP-2). Vyper reads a 32-byte hex literal
# as bytes32, hence the decimal form.
_HALF_CURVE_ORDER: constant(uint256) = (
    57896044618658097711785492504343953926418782139537452191302581570759080747168
)

# @notice Token name, also used as the EIP-712 domain name.
name: public(constant(String[16])) = "Gas Golf Quartet"
# @notice Token symbol.
symbol: public(constant(String[4])) = "GOLF"
# @notice Number of decimals used for display purposes.
decimals: public(constant(uint8)) = 18
# @notice Total supply, minted to the initial holder at construction and never changed.
totalSupply: public(immutable(uint256))

# @notice Balance of each account.
balanceOf: public(HashMap[address, uint256])
# @notice Remaining amount `spender` may move out of `owner`'s balance.
allowance: public(HashMap[address, HashMap[address, uint256]])
# @notice Next EIP-2612 nonce of each owner.
nonces: public(HashMap[address, uint256])

_CACHED_DOMAIN_SEPARATOR: immutable(bytes32)
_CACHED_CHAIN_ID: immutable(uint256)
_CACHED_SELF: immutable(address)


@deploy
def __init__(holder: address, supply: uint256):
    """
    @notice Deploys the token and mints the whole supply to `holder`.
    @param holder Receiver of the initial supply. Must not be the zero address.
    @param supply Total supply to mint.
    """
    assert holder != empty(address), "erc20: invalid receiver"
    totalSupply = supply
    self.balanceOf[holder] = supply
    _CACHED_CHAIN_ID = chain.id
    _CACHED_SELF = self
    _CACHED_DOMAIN_SEPARATOR = self._build_domain_separator()
    log IERC20.Transfer(sender=empty(address), receiver=holder, value=supply)


@external
def transfer(to: address, amount: uint256) -> bool:
    """
    @notice Moves `amount` tokens from the caller to `to`.
    @param to Recipient. Must not be the zero address.
    @param amount Amount to move.
    @return Always True; failures revert.
    """
    assert to != empty(address), "erc20: invalid receiver"
    self._move(msg.sender, to, amount)
    return True


@external
def approve(spender: address, amount: uint256) -> bool:
    """
    @notice Sets `spender`'s allowance over the caller's tokens to `amount`.
    @param spender Account allowed to spend. Must not be the zero address.
    @param amount New allowance. max_value(uint256) is an infinite allowance.
    @return Always True; failures revert.
    """
    assert spender != empty(address), "erc20: invalid spender"
    self.allowance[msg.sender][spender] = amount
    log IERC20.Approval(owner=msg.sender, spender=spender, value=amount)
    return True


@external
def transferFrom(owner: address, to: address, amount: uint256) -> bool:
    """
    @notice Moves `amount` tokens from `owner` to `to` using the caller's allowance.
    @dev Check order follows OpenZeppelin: allowance, then approver, sender, receiver, balance.
    @param owner Account debited.
    @param to Recipient. Must not be the zero address.
    @param amount Amount to move.
    @return Always True; failures revert.
    """
    current: uint256 = self.allowance[owner][msg.sender]
    if current != max_value(uint256):
        assert current >= amount, "erc20: insufficient allowance"
        assert owner != empty(address), "erc20: invalid approver"
        # Safe: `current >= amount` was asserted above.
        self.allowance[owner][msg.sender] = unsafe_sub(current, amount)
    assert owner != empty(address), "erc20: invalid sender"
    assert to != empty(address), "erc20: invalid receiver"
    self._move(owner, to, amount)
    return True


@external
def permit(
    owner: address,
    spender: address,
    amount: uint256,
    deadline: uint256,
    v: uint8,
    r: bytes32,
    s: bytes32,
):
    """
    @notice Sets `spender`'s allowance over `owner`'s tokens from an EIP-712 signature.
    @param owner Token owner who signed the permit.
    @param spender Account allowed to spend. Must not be the zero address.
    @param amount New allowance.
    @param deadline Last timestamp at which the signature is valid.
    @param v Signature recovery byte.
    @param r Signature `r` value.
    @param s Signature `s` value; must be in the lower half of the curve order.
    """
    assert block.timestamp <= deadline, "erc2612: expired deadline"
    nonce: uint256 = self.nonces[owner]
    struct_hash: bytes32 = keccak256(
        abi_encode(_PERMIT_TYPEHASH, owner, spender, amount, nonce, deadline)
    )
    digest: bytes32 = keccak256(
        concat(b"\x19\x01", self._domain_separator(), struct_hash)
    )
    assert convert(s, uint256) <= _HALF_CURVE_ORDER, "erc2612: invalid signature"
    signer: address = ecrecover(digest, v, r, s)
    assert signer != empty(address), "erc2612: invalid signature"
    assert signer == owner, "erc2612: invalid signature"
    assert spender != empty(address), "erc20: invalid spender"
    # Safe: a nonce grows by one per successful permit and can never reach 2**256 - 1.
    self.nonces[owner] = unsafe_add(nonce, 1)
    self.allowance[owner][spender] = amount
    log IERC20.Approval(owner=owner, spender=spender, value=amount)


@external
@view
def DOMAIN_SEPARATOR() -> bytes32:
    """
    @notice EIP-712 domain separator used by `permit`.
    @return The separator for the current chain id and contract address.
    """
    return self._domain_separator()


@internal
def _move(owner: address, to: address, amount: uint256):
    """
    @dev Debits `owner` and credits `to` after the balance check, then logs Transfer.
    """
    owner_balance: uint256 = self.balanceOf[owner]
    assert owner_balance >= amount, "erc20: insufficient balance"
    # Safe: `owner_balance >= amount` was asserted above.
    self.balanceOf[owner] = unsafe_sub(owner_balance, amount)
    # Safe in every reachable state: balances sum to the fixed total supply.
    self.balanceOf[to] = unsafe_add(self.balanceOf[to], amount)
    log IERC20.Transfer(sender=owner, receiver=to, value=amount)


@internal
@view
def _domain_separator() -> bytes32:
    """
    @dev Cached separator unless the chain id (fork) or the executing address (delegatecall)
         changed since deployment.
    """
    if self == _CACHED_SELF and chain.id == _CACHED_CHAIN_ID:
        return _CACHED_DOMAIN_SEPARATOR
    return self._build_domain_separator()


@internal
@view
def _build_domain_separator() -> bytes32:
    """
    @dev EIP-712 domain separator for the current chain id and executing address.
    """
    return keccak256(
        abi_encode(_DOMAIN_TYPEHASH, _HASHED_NAME, _HASHED_VERSION, chain.id, self)
    )
