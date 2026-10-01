// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { SignatureChecker } from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { KestrelPool } from "./KestrelPool.sol";

/// @title KestrelRelayer
/// @notice Relays EIP-712-signed swaps so users can trade gaslessly: a user signs a
///         {SwapRequest}, any relayer submits it, and the relayer contract pulls the user's input
///         token and routes the swap through the pool.
/// @dev    Signatures are verified with OpenZeppelin `SignatureChecker`, so both EOAs (ECDSA)
///         and contract wallets (ERC-1271) can sign.
contract KestrelRelayer is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice The pool swaps are routed through.
    KestrelPool public immutable pool;

    /// @notice EIP-712 domain type hash. [REPLAY] It binds the chain id.
    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    /// @notice EIP-712 type hash for {SwapRequest}.
    bytes32 private constant SWAP_REQUEST_TYPEHASH = keccak256(
        "SwapRequest(address user,address tokenIn,uint256 amountIn,uint256 minOut,address to,uint256 nonce,uint256 deadline)"
    );
    /// @notice keccak256 of the EIP-712 domain name.
    bytes32 private constant NAME_HASH = keccak256("KestrelRelayer");
    /// @notice keccak256 of the EIP-712 domain version.
    bytes32 private constant VERSION_HASH = keccak256("1");

    /// @notice Domain separator computed at deployment.
    bytes32 private immutable _cachedDomainSeparator;
    /// @notice Chain id the cached separator was computed for. [REPLAY]
    uint256 private immutable _cachedChainId;

    /// @notice Next nonce each user must sign.
    mapping(address user => uint256 nonce) public nonces;

    /// @notice A gasless swap authorization.
    /// @param user Signer whose tokens are spent.
    /// @param tokenIn Input token.
    /// @param amountIn Input amount.
    /// @param minOut Minimum acceptable output.
    /// @param to Output recipient.
    /// @param nonce The user's current {nonces} value.
    /// @param deadline Unix timestamp after which the request is invalid.
    struct SwapRequest {
        address user;
        address tokenIn;
        uint256 amountIn;
        uint256 minOut;
        address to;
        uint256 nonce;
        uint256 deadline;
    }

    /// @notice Emitted when a relayed swap executes.
    /// @param user Authorizing signer.
    /// @param tokenIn Input token.
    /// @param amountIn Input amount.
    /// @param amountOut Output amount.
    /// @param nonce Nonce the request carried.
    event SwapRelayed(
        address indexed user, address indexed tokenIn, uint256 amountIn, uint256 amountOut, uint256 nonce
    );

    /// @notice Thrown when the request deadline has passed.
    /// @param deadline The request deadline.
    error ExpiredSignature(uint256 deadline);
    /// @notice Thrown when `signature` is not a valid signature by `req.user` over the request.
    error InvalidSignature();
    /// @notice Thrown when the request's nonce is not the user's current nonce. [REPLAY]
    /// @param provided Nonce in the request.
    /// @param expected Current nonce.
    error InvalidNonce(uint256 provided, uint256 expected);

    /// @notice Deploy the relayer.
    /// @param _pool The pool to route swaps through.
    constructor(KestrelPool _pool) {
        pool = _pool;
        _cachedChainId = block.chainid; // [REPLAY]
        _cachedDomainSeparator = _buildDomainSeparator();
    }

    /// @notice The EIP-712 domain separator signatures must use.
    /// @return separator The domain separator.
    function domainSeparator() public view returns (bytes32 separator) {
        // [REPLAY] Recompute after a fork or on another chain: the separator follows the chain id.
        separator = block.chainid == _cachedChainId ? _cachedDomainSeparator : _buildDomainSeparator();
    }

    /// @notice EIP-712 digest a user signs for `req`.
    /// @param req The request.
    /// @return digest The typed-data hash.
    function hashRequest(SwapRequest calldata req) public view returns (bytes32 digest) {
        bytes32 structHash = keccak256(
            abi.encode(
                SWAP_REQUEST_TYPEHASH,
                req.user,
                req.tokenIn,
                req.amountIn,
                req.minOut,
                req.to,
                req.nonce,
                req.deadline
            )
        );
        digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator(), structHash));
    }

    /// @notice Relay a signed swap.
    /// @param req The signed request.
    /// @param signature The user's EIP-712 signature over `req` (ECDSA or ERC-1271).
    /// @return amountOut Output tokens delivered to `req.to`.
    function relaySwap(SwapRequest calldata req, bytes calldata signature)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        require(block.timestamp <= req.deadline, ExpiredSignature(req.deadline));
        require(
            SignatureChecker.isValidSignatureNow(req.user, hashRequest(req), signature), InvalidSignature()
        );
        // [REPLAY] Verify and consume the user's nonce: each signature is valid exactly once.
        uint256 expected = nonces[req.user];
        require(req.nonce == expected, InvalidNonce(req.nonce, expected));
        nonces[req.user] = expected + 1;

        IERC20(req.tokenIn).safeTransferFrom(req.user, address(this), req.amountIn);
        IERC20(req.tokenIn).forceApprove(address(pool), req.amountIn);
        amountOut = pool.swap(req.tokenIn, req.amountIn, req.minOut, req.to);
        emit SwapRelayed(req.user, req.tokenIn, req.amountIn, amountOut, req.nonce);
    }

    /// @dev Hash the EIP-712 domain for the current chain.
    function _buildDomainSeparator() private view returns (bytes32 separator) {
        // [REPLAY] `block.chainid` is part of the domain, so a signature never transfers across chains.
        separator =
            keccak256(abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(this)));
    }
}
