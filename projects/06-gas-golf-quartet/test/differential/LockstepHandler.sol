// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IQuartetToken} from "../../src/interfaces/IQuartetToken.sol";
import {QuartetBase} from "../utils/QuartetBase.sol";
import {Impl, RevertClass, RevertClassifier} from "../utils/RevertClassifier.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

/// @title LockstepHandler
/// @notice Sends every fuzzed call to all five implementations (OpenZeppelin oracle, Solidity, Assembly,
///         Yul, Vyper) from the same caller, then requires them to agree on:
///           - the success flag and the exact return data,
///           - the revert class (and, for Solidity vs OpenZeppelin, the exact revert bytes),
///           - the logs: same count, topics and data, each emitted by the implementation itself.
///         State agreement (balances, allowances, nonces, supply, domain separator) is checked by the
///         invariant functions in LockstepInvariant.t.sol after every call.
/// @dev Any disagreement fails an assertion inside the handler, which the invariant runner reports
///      because `fail_on_revert = true`.
contract LockstepHandler is QuartetBase {
    uint256 internal constant N = 5;
    uint256 internal constant ACTORS = 4;

    address[N] internal _tokens;
    uint256[ACTORS] internal _keys;
    address[ACTORS] internal _actors;

    /// @notice Number of lockstep calls executed.
    uint256 public calls;
    /// @notice Successful permits per owner, as observed on the oracle (ghost for the nonce invariant).
    mapping(address owner => uint256) public ghostNonces;
    /// @notice How often the oracle ended in each RevertClass (index = uint256(RevertClass)).
    uint256[12] public classHits;
    /// @notice Calls per action (0 transfer, 1 approve, 2 transferFrom, 3 permit, 4 malformed, 5 raw).
    uint256[6] public actionHits;

    constructor() {
        for (uint256 i; i < ACTORS; ++i) {
            _keys[i] = uint256(keccak256(abi.encode("gas-golf-quartet actor", i))) % (SECP256K1_N - 1) + 1;
            _actors[i] = vm.addr(_keys[i]);
        }
        vm.warp(1_750_000_000);
        for (uint256 i; i < N; ++i) {
            _tokens[i] = address(_deploy(Impl(i), _actors[0], SUPPLY));
        }
    }

    // ------------------------------------------------------------------ views for the invariant contract

    function token(uint256 i) external view returns (IQuartetToken) {
        return IQuartetToken(_tokens[i]);
    }

    function actor(uint256 i) external view returns (address) {
        return _actors[i];
    }

    function actorCount() external pure returns (uint256) {
        return ACTORS;
    }

    function tokenCount() external pure returns (uint256) {
        return N;
    }

    // ------------------------------------------------------------------ actions

    function transfer(uint256 callerSeed, uint256 toSeed, uint256 amountSeed) external {
        address caller = _actors[callerSeed % ACTORS];
        address to = _target(toSeed);
        uint256 amount = _amount(amountSeed, IQuartetToken(_tokens[0]).balanceOf(caller));
        actionHits[0]++;
        _lockstep(caller, _same(abi.encodeCall(IERC20.transfer, (to, amount))), 0);
    }

    function approve(uint256 callerSeed, uint256 spenderSeed, uint256 amountSeed) external {
        address caller = _actors[callerSeed % ACTORS];
        address spender = _target(spenderSeed);
        uint256 amount = _amount(amountSeed, IQuartetToken(_tokens[0]).balanceOf(caller));
        actionHits[1]++;
        _lockstep(caller, _same(abi.encodeCall(IERC20.approve, (spender, amount))), 0);
    }

    function transferFrom(uint256 callerSeed, uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address caller = _actors[callerSeed % ACTORS];
        address from = _target(fromSeed);
        address to = _target(toSeed);
        IQuartetToken oracle = IQuartetToken(_tokens[0]);
        // Aim at the binding constraint: whichever of allowance and balance is smaller.
        uint256 allowed = oracle.allowance(from, caller);
        uint256 balance = oracle.balanceOf(from);
        uint256 amount = _amount(amountSeed, allowed < balance ? allowed : balance);
        actionHits[2]++;
        _lockstep(caller, _same(abi.encodeCall(IERC20.transferFrom, (from, to, amount))), 0);
    }

    /// @notice Inputs of one permit action, shared by the five per-token signatures.
    struct PermitInput {
        uint256 mode;
        address owner;
        address spender;
        uint256 value;
        uint256 deadline;
        uint256 signerKey;
        uint256 seed;
    }

    /// @notice Permit in one of ten modes: valid, expired, wrong signer, malleable high-s, bad v, wrong
    ///         nonce, zero spender, zero owner, garbage signature, deadline equal to the block timestamp.
    function permit(
        uint256 ownerSeed,
        uint256 spenderSeed,
        uint256 valueSeed,
        uint256 deadlineSeed,
        uint256 mode,
        uint256 relayerSeed
    ) external {
        PermitInput memory p;
        p.mode = mode % 10;
        p.seed = valueSeed;
        uint256 ownerIndex = ownerSeed % ACTORS;
        p.owner = p.mode == 7 ? address(0) : _actors[ownerIndex];
        p.spender = p.mode == 6 ? address(0) : _actors[spenderSeed % ACTORS];
        p.value = _amount(valueSeed, IQuartetToken(_tokens[0]).balanceOf(p.owner));
        p.deadline = block.timestamp + deadlineSeed % 365 days;
        if (p.mode == 1) p.deadline = block.timestamp - 1 - deadlineSeed % 1 days;
        if (p.mode == 9) p.deadline = block.timestamp;
        // Mode 2 signs with one of the other actors' keys; mode 4 picks one of five invalid v values.
        p.signerKey = _keys[p.mode == 2 ? (ownerIndex + 1 + deadlineSeed % (ACTORS - 1)) % ACTORS : ownerIndex];
        if (p.mode == 4) p.seed = deadlineSeed;
        bytes[N] memory data;
        for (uint256 i; i < N; ++i) {
            data[i] = _permitCalldata(p, _tokens[i]);
        }
        actionHits[3]++;
        bool ok = _lockstep(_actors[relayerSeed % ACTORS], data, 0);
        if (ok) ghostNonces[p.owner]++;
    }

    function _permitCalldata(PermitInput memory p, address token_) internal view returns (bytes memory) {
        uint256 nonce = IQuartetToken(token_).nonces(p.owner) + (p.mode == 5 ? 1 : 0);
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(p.signerKey, _permitDigest(token_, p.owner, p.spender, p.value, nonce, p.deadline));
        if (p.mode == 3) (v, s) = _malleate(v, s);
        if (p.mode == 4) v = [uint8(0), 1, 26, 29, 255][p.seed % 5];
        if (p.mode == 7 || p.mode == 8) {
            r = keccak256(abi.encode(p.seed, "r"));
            s = bytes32(uint256(keccak256(abi.encode(p.seed, "s"))) >> 1);
        }
        return abi.encodeCall(IERC20Permit.permit, (p.owner, p.spender, p.value, p.deadline, v, r, s));
    }

    /// @notice Malformed calls: truncated calldata, dirty address or uint8 bits, unknown or short
    ///         selectors, value sent to non-payable functions, or valid calls with trailing garbage.
    /// @param mode `mode % 6` picks the kind of damage; `mode / 6` is the independent seed that picks which
    ///        strictly typed word mode 1 dirties (so a scripted test can aim at every word).
    function malformed(uint256 fnSeed, uint256 mode, uint256 argSeed, uint256 callerSeed) external {
        address caller = _actors[callerSeed % ACTORS];
        bytes memory data = _validCall(fnSeed, argSeed);
        uint256 value;
        uint256 pick = mode / 6;
        mode %= 6;
        if (mode == 0) {
            // Drop 1..(len - 4) trailing bytes; zero-argument functions keep their selector only.
            uint256 cut = data.length > 4 ? 1 + argSeed % (data.length - 4) : 0;
            // Memory-safe: shortens an array this function owns.
            assembly ("memory-safe") {
                mstore(data, sub(mload(data), cut))
            }
        } else if (mode == 1 && data.length >= 36) {
            _dirtyOneStrictWord(data, pick);
        } else if (mode == 2) {
            data = abi.encodePacked(bytes4(keccak256(abi.encode(argSeed, "unknown selector"))), argSeed);
        } else if (mode == 3) {
            value = 1 + argSeed % 1 ether;
            vm.deal(caller, value * N);
        } else if (mode == 4) {
            data = bytes.concat(data, abi.encode(argSeed));
        } else {
            // 0 to 3 leading bytes of a real selector.
            uint256 len = argSeed % 4;
            // Memory-safe: shortens an array this function owns.
            assembly ("memory-safe") {
                mstore(data, len)
            }
        }
        actionHits[4]++;
        _lockstep(caller, _same(data), value);
    }

    /// @notice Arbitrary calldata behind a real selector: all five ABI decoders must agree.
    function raw(uint256 selectorSeed, bytes calldata payload, uint256 callerSeed) external {
        bytes4[12] memory selectors = _selectors();
        bytes memory data = bytes.concat(selectors[selectorSeed % 12], payload);
        actionHits[5]++;
        _lockstep(_actors[callerSeed % ACTORS], _same(data), 0);
    }

    /// @notice Time passes (makes permits expire).
    function warp(uint256 delta) external {
        vm.warp(block.timestamp + delta % 30 days);
    }

    /// @notice The chain forks to a new chain id: every domain separator must follow.
    function fork(uint256 chainIdSeed) external {
        vm.chainId(1 + chainIdSeed % type(uint64).max);
    }

    // ------------------------------------------------------------------ lockstep core

    function _lockstep(address caller, bytes[N] memory data, uint256 value) internal returns (bool ok) {
        Outcome[N] memory out;
        for (uint256 i; i < N; ++i) {
            out[i] = _capture(caller, _tokens[i], data[i], value);
        }
        calls++;
        RevertClass expected = _classOf(Impl.OpenZeppelin, out[0]);
        assertTrue(
            expected != RevertClass.Unknown && expected != RevertClass.Panic, "oracle produced an unknown revert"
        );
        classHits[uint256(expected)]++;
        // DOMAIN_SEPARATOR() is the one getter whose value depends on the contract address: each token must
        // return the EIP-712 separator of its own address instead of the oracle's bytes.
        bool perToken = out[0].ok && _isDomainSeparatorCall(data[0]);
        if (perToken) {
            assertEq(out[0].ret, abi.encode(_expectedDomainSeparator(_tokens[0])), "oracle: domain separator");
        }
        for (uint256 i = 1; i < N; ++i) {
            string memory who = _name(Impl(i));
            assertEq(out[i].ok, out[0].ok, string.concat(who, ": success flag differs"));
            if (perToken) {
                assertEq(
                    out[i].ret,
                    abi.encode(_expectedDomainSeparator(_tokens[i])),
                    string.concat(who, ": domain separator")
                );
            } else if (out[0].ok) {
                assertEq(out[i].ret, out[0].ret, string.concat(who, ": return data differs"));
            } else {
                assertEq(
                    RevertClassifier.name(_classOf(Impl(i), out[i])),
                    RevertClassifier.name(expected),
                    string.concat(who, ": revert class differs")
                );
            }
            _assertSameLogs(out[0], out[i], _tokens[i], who);
        }
        // The idiomatic Solidity version uses the oracle's own error ABI, so every byte must match, revert
        // arguments included. Permit is the exception: the digest contains the verifying contract, so a
        // recovered signer or an `s` value inside its revert data legitimately differs (ERC20Spec pins the
        // exact permit encodings instead).
        bool isPermit = data[0].length >= 4 && bytes4(data[0]) == IERC20Permit.permit.selector;
        if (!perToken && !isPermit && keccak256(data[1]) == keccak256(data[0])) {
            assertEq(out[1].ret, out[0].ret, "Solidity: bytes differ from OpenZeppelin");
        }
        return out[0].ok;
    }

    function _assertSameLogs(Outcome memory a, Outcome memory b, address emitter, string memory who) internal pure {
        assertEq(b.logs.length, a.logs.length, string.concat(who, ": log count differs"));
        for (uint256 j; j < a.logs.length; ++j) {
            assertEq(b.logs[j].emitter, emitter, string.concat(who, ": log emitter"));
            assertEq(b.logs[j].topics, a.logs[j].topics, string.concat(who, ": log topics differ"));
            assertEq(b.logs[j].data, a.logs[j].data, string.concat(who, ": log data differs"));
        }
    }

    function _isDomainSeparatorCall(bytes memory data) internal pure returns (bool) {
        return data.length >= 4 && bytes4(data) == IERC20Permit.DOMAIN_SEPARATOR.selector;
    }

    // ------------------------------------------------------------------ input shaping

    function _same(bytes memory data) internal pure returns (bytes[N] memory all) {
        for (uint256 i; i < N; ++i) {
            all[i] = data;
        }
    }

    /// @dev One of the actors, or the zero address one time in five.
    function _target(uint256 seed) internal view returns (address) {
        return seed % 5 == 4 ? address(0) : _actors[seed % ACTORS];
    }

    /// @dev Biased amounts around the constraint `limit`: 0, exactly limit, limit + 1, within, max, raw.
    function _amount(uint256 seed, uint256 limit) internal pure returns (uint256) {
        uint256 mode = seed % 6;
        if (mode == 0) return 0;
        if (mode == 1) return limit;
        if (mode == 2) return limit == type(uint256).max ? limit : limit + 1;
        if (mode == 3) return limit == 0 ? 0 : (seed >> 8) % (limit + (limit < type(uint256).max ? 1 : 0));
        if (mode == 4) return type(uint256).max;
        return seed >> 8;
    }

    /// @notice The strictly typed argument words of `selector`: their indices and how many leading bytes of
    ///         each must be zero (12 for an address, 31 for permit's uint8 v). Every function of the surface
    ///         that takes arguments starts with an address word.
    function strictWords(bytes4 selector) public pure returns (uint256[] memory words, uint256[] memory zeroBytes) {
        if (selector == IERC20Permit.permit.selector) {
            words = new uint256[](3);
            zeroBytes = new uint256[](3);
            (words[0], words[1], words[2]) = (0, 1, 4);
            (zeroBytes[0], zeroBytes[1], zeroBytes[2]) = (12, 12, 31);
        } else if (selector == IERC20.transferFrom.selector || selector == IERC20.allowance.selector) {
            words = new uint256[](2);
            zeroBytes = new uint256[](2);
            (words[0], words[1]) = (0, 1);
            (zeroBytes[0], zeroBytes[1]) = (12, 12);
        } else {
            words = new uint256[](1);
            zeroBytes = new uint256[](1);
            zeroBytes[0] = 12;
        }
    }

    /// @dev Sets one bit in the must-be-zero bytes of exactly one strictly typed word (chosen by `pick`) and
    ///      leaves every other word clean. Dirtying only one word at a time is what catches a decoder that
    ///      validates the first address but not the second (the Yul object checks pairs with one shift).
    function _dirtyOneStrictWord(bytes memory data, uint256 pick) internal pure {
        (uint256[] memory words, uint256[] memory zeroBytes) = strictWords(bytes4(data));
        uint256 k = pick % words.length;
        uint256 position = 4 + 32 * words[k] + (pick >> 8) % zeroBytes[k];
        data[position] = bytes1(uint8(1 << ((pick >> 16) % 8)));
    }

    function _selectors() internal pure returns (bytes4[12] memory) {
        return [
            IERC20.transfer.selector,
            IERC20.approve.selector,
            IERC20.transferFrom.selector,
            IERC20.balanceOf.selector,
            IERC20.allowance.selector,
            IERC20.totalSupply.selector,
            IERC20Permit.permit.selector,
            IERC20Permit.nonces.selector,
            IERC20Permit.DOMAIN_SEPARATOR.selector,
            bytes4(keccak256("name()")),
            bytes4(keccak256("symbol()")),
            bytes4(keccak256("decimals()"))
        ];
    }

    function _validCall(uint256 fnSeed, uint256 argSeed) internal view returns (bytes memory) {
        address a = _target(argSeed);
        address b = _target(argSeed >> 8);
        uint256 amount = argSeed >> 16;
        uint256 fn = fnSeed % 12;
        if (fn == 0) return abi.encodeCall(IERC20.transfer, (b, amount));
        if (fn == 1) return abi.encodeCall(IERC20.approve, (b, amount));
        if (fn == 2) return abi.encodeCall(IERC20.transferFrom, (a, b, amount));
        if (fn == 3) return abi.encodeCall(IERC20.balanceOf, (a));
        if (fn == 4) return abi.encodeCall(IERC20.allowance, (a, b));
        if (fn == 5) return abi.encodeCall(IERC20Permit.nonces, (a));
        if (fn == 6) {
            return
                abi.encodeCall(
                    IERC20Permit.permit, (a, b, amount, block.timestamp, 27, bytes32(argSeed), bytes32(amount))
                );
        }
        if (fn == 7) return abi.encodePacked(IERC20.totalSupply.selector);
        // 8..11: DOMAIN_SEPARATOR, name, symbol, decimals.
        return abi.encodePacked(_selectors()[fn]);
    }
}
