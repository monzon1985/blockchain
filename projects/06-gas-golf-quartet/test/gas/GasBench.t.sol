// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IQuartetToken} from "../../src/interfaces/IQuartetToken.sol";
import {QuartetBase} from "../utils/QuartetBase.sol";
import {Impl} from "../utils/RevertClassifier.sol";
import {GolfProbe, IMathProbe, LegacyProbe, OzProbe, RefProbe, SoladyProbe} from "./MathProbes.sol";
import {
    BranchProbe,
    CallMeter,
    DispatchFrequencyProbe,
    DispatchSortedProbe,
    ErrorSelectorOnlyProbe,
    ErrorWithArgsProbe,
    ReturnAbiProbe,
    ReturnScratchProbe,
    SlotProbe
} from "./TrickProbes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

/// @title GasBench
/// @notice Deterministic gas benchmark. Results are written to snapshots/GasBench.json (read by
///         scripts/gen-tables.mjs) and the per-test totals to .gas-snapshot (checked by
///         `forge snapshot --check --match-contract GasBench`).
///
///         ERC-20 numbers are full transaction gas: `isolate = true` runs every top-level call as its own
///         transaction with cold storage, so each figure includes the 21,000 base cost and calldata cost
///         (identical across implementations, since the calldata is identical).
///         Math numbers are execution gas of the library call alone (a GAS-to-GAS window minus the cost of
///         an empty window).
contract GasBench is QuartetBase {
    uint256 internal constant OWNER_KEY = 0x0DD;
    address internal owner;
    address internal holder = makeAddr("existing holder");
    address internal spender = makeAddr("spender");
    address internal maxSpender = makeAddr("infinite spender");
    address internal relayer = makeAddr("relayer");

    IQuartetToken[5] internal tokens;

    function setUp() public {
        vm.warp(1_750_000_000);
        owner = vm.addr(OWNER_KEY);
        for (uint256 i; i < 5; ++i) {
            IQuartetToken token = _deploy(Impl(i), owner, SUPPLY);
            tokens[i] = token;
            vm.startPrank(owner);
            token.transfer(holder, 1e18);
            token.approve(spender, 1000e18);
            token.approve(maxSpender, type(uint256).max);
            vm.stopPrank();
        }
    }

    function _key(string memory section, string memory metric, Impl impl) internal pure returns (string memory) {
        return string.concat(section, ".", metric, ".", _name(impl));
    }

    // ------------------------------------------------------------------ ERC-20 (transaction gas)

    function test_Erc20_TransferToNewHolder() public {
        for (uint256 i; i < 5; ++i) {
            vm.prank(owner);
            tokens[i].transfer(makeAddr("fresh"), 1e18);
            vm.snapshotGasLastFrame(_key("erc20", "transfer_new_holder", Impl(i)));
        }
    }

    function test_Erc20_TransferToExistingHolder() public {
        for (uint256 i; i < 5; ++i) {
            vm.prank(owner);
            tokens[i].transfer(holder, 1e18);
            vm.snapshotGasLastFrame(_key("erc20", "transfer_existing_holder", Impl(i)));
        }
    }

    function test_Erc20_Approve() public {
        for (uint256 i; i < 5; ++i) {
            vm.prank(owner);
            tokens[i].approve(makeAddr("new spender"), 5e18);
            vm.snapshotGasLastFrame(_key("erc20", "approve", Impl(i)));
        }
    }

    function test_Erc20_TransferFromFiniteAllowance() public {
        for (uint256 i; i < 5; ++i) {
            vm.prank(spender);
            tokens[i].transferFrom(owner, holder, 1e18);
            vm.snapshotGasLastFrame(_key("erc20", "transferFrom_finite", Impl(i)));
        }
    }

    function test_Erc20_TransferFromInfiniteAllowance() public {
        for (uint256 i; i < 5; ++i) {
            vm.prank(maxSpender);
            tokens[i].transferFrom(owner, holder, 1e18);
            vm.snapshotGasLastFrame(_key("erc20", "transferFrom_infinite", Impl(i)));
        }
    }

    function test_Erc20_Permit() public {
        for (uint256 i; i < 5; ++i) {
            IQuartetToken token = tokens[i];
            uint256 deadline = block.timestamp + 1 hours;
            (uint8 v, bytes32 r, bytes32 s) = _signPermit(OWNER_KEY, token, relayer, 7e18, deadline);
            vm.prank(relayer);
            token.permit(owner, relayer, 7e18, deadline, v, r, s);
            vm.snapshotGasLastFrame(_key("erc20", "permit", Impl(i)));
        }
    }

    function test_Erc20_Views() public {
        for (uint256 i; i < 5; ++i) {
            IQuartetToken token = tokens[i];
            token.balanceOf(owner);
            vm.snapshotGasLastFrame(_key("erc20", "balanceOf", Impl(i)));
            token.allowance(owner, spender);
            vm.snapshotGasLastFrame(_key("erc20", "allowance", Impl(i)));
            token.DOMAIN_SEPARATOR();
            vm.snapshotGasLastFrame(_key("erc20", "DOMAIN_SEPARATOR", Impl(i)));
        }
    }

    // ------------------------------------------------------------------ deployment

    function test_Deploy() public {
        for (uint256 i; i < 5; ++i) {
            (address deployed,) = _create(_initcode(Impl(i), owner, SUPPLY), 0);
            vm.snapshotGasLastFrame(_key("deploy", "gas", Impl(i)));
            vm.snapshotValue(_key("deploy", "runtime_bytes", Impl(i)), deployed.code.length);
        }
    }

    // ------------------------------------------------------------------ math kernel (execution gas)

    function _probes() internal returns (IMathProbe[5] memory p, string[5] memory names) {
        p = [
            IMathProbe(address(new RefProbe())),
            IMathProbe(address(new GolfProbe())),
            IMathProbe(address(new LegacyProbe())),
            IMathProbe(address(new OzProbe())),
            IMathProbe(address(new SoladyProbe()))
        ];
        names = ["Reference", "Golf", "Legacy", "OpenZeppelin", "Solady"];
    }

    function _record(string memory metric, string memory kernel, uint256 used, uint256 overhead) internal {
        vm.snapshotValue(string.concat("math.", metric, ".", kernel), used - overhead);
    }

    function test_MathKernel() public {
        (IMathProbe[5] memory p, string[5] memory names) = _probes();
        // Fixed inputs: a 512-bit product with an odd 256-bit denominator (full path), a product that fits
        // in 256 bits (fast path), a large and a small radicand, and a large log2 argument.
        uint256 x = 0x9b4e5f1c0d7a8e3b2c6f41d5a7e9c3b1f0e2d4c6a8b9d7e5f3c1a2b4d6e8f0a1;
        uint256 y = 0x7f3e9a1b5c2d8e4f6a0b3c7d9e1f5a2b4c6d8e0f1a3b5c7d9e2f4a6b8c0d1e3f;
        uint256 d = 0xc3a5e7f9b1d2c4e6a8f0b2d4c6e8a1f3b5d7c9e0f2a4b6d8c1e3f5a7b9d0c2e5;
        for (uint256 k; k < 5; ++k) {
            (, uint256 overhead) = p[k].baseline(1);
            (uint256 r0, uint256 g) = p[k].mulDiv(x, y, d);
            _record("mulDiv_512bit", names[k], g, overhead);
            (, g) = p[k].mulDiv(3e27, 7e18, 1e18);
            _record("mulDiv_fits_256", names[k], g, overhead);
            (uint256 r1, uint256 g1) = p[k].mulDivUp(x, y, d);
            _record("mulDivUp_512bit", names[k], g1, overhead);
            assertEq(r1, r0 + 1, "the full-path inputs have a remainder");
            (, g) = p[k].sqrt(type(uint256).max - 12_345);
            _record("sqrt_2pow256", names[k], g, overhead);
            (, g) = p[k].sqrt(2e18);
            _record("sqrt_2e18", names[k], g, overhead);
            (, g) = p[k].log2(x);
            _record("log2", names[k], g, overhead);
            (, g) = p[k].log2Up(x);
            _record("log2Up", names[k], g, overhead);
            (, g) = p[k].clz(x >> 77);
            _record("clz", names[k], g, overhead);
        }
    }

    // ------------------------------------------------------------------ tricks (A/B, docs/TRICKS.md)

    function _ab(string memory id, uint256 a, uint256 b) internal {
        vm.snapshotValue(string.concat("trick.", id, ".A"), a);
        vm.snapshotValue(string.concat("trick.", id, ".B"), b);
    }

    function test_Tricks() public {
        SlotProbe slots = new SlotProbe();
        (, uint256 mappingGas) = slots.mappingGas(holder);
        (, uint256 seededGas) = slots.seededGas(holder);
        (, uint256 identityGas) = slots.identityGas(holder);
        _ab("seeded_slot", mappingGas, seededGas);
        _ab("identity_slot", mappingGas, identityGas);

        // Selector-only errors: gas of the failing call as metered by a caller, and runtime size. (A whole
        // failing transaction is dominated by the EIP-7623 calldata floor, which hides the difference.)
        address withArgs = address(new ErrorWithArgsProbe());
        address selectorOnly = address(new ErrorSelectorOnlyProbe());
        CallMeter meter = new CallMeter();
        (bool okA, uint256 revertA) = meter.meter(withArgs, abi.encodeCall(ErrorWithArgsProbe.spend, (1, 2)));
        (bool okB, uint256 revertB) = meter.meter(selectorOnly, abi.encodeCall(ErrorSelectorOnlyProbe.spend, (1, 2)));
        assertFalse(okA || okB);
        _ab("selector_errors_call", revertA, revertB);
        _ab("selector_errors_bytes", withArgs.code.length, selectorOnly.code.length);

        // Returning from scratch space instead of through the ABI encoder.
        ReturnAbiProbe abiReturn = new ReturnAbiProbe();
        ReturnScratchProbe scratchReturn = new ReturnScratchProbe();
        abiReturn.ok();
        vm.snapshotGasLastFrame("trick.scratch_return_tx.A");
        scratchReturn.ok();
        vm.snapshotGasLastFrame("trick.scratch_return_tx.B");
        _ab("scratch_return_bytes", address(abiReturn).code.length, address(scratchReturn).code.length);

        // Dispatch order and the single callvalue check (T11): the same twelve selectors, metered by a caller.
        address sorted = address(new DispatchSortedProbe());
        address byFrequency = address(new DispatchFrequencyProbe());
        bytes memory transferCall = abi.encodeCall(IERC20.transfer, (holder, 1));
        bytes memory separatorCall = abi.encodeCall(IERC20Permit.DOMAIN_SEPARATOR, ());
        (, uint256 a) = meter.meter(sorted, transferCall);
        (, uint256 b) = meter.meter(byFrequency, transferCall);
        _ab("dispatch_transfer", a, b);
        (, a) = meter.meter(sorted, separatorCall);
        (, b) = meter.meter(byFrequency, separatorCall);
        _ab("dispatch_domain_separator", a, b);
        _ab("dispatch_bytes", sorted.code.length, byFrequency.code.length);

        BranchProbe branches = new BranchProbe();
        (, a) = branches.infiniteLtGas(5);
        (, b) = branches.infiniteNotGas(5);
        _ab("infinite_not", a, b);
        (, a) = branches.signerTwoTestsGas(7, 7);
        (, b) = branches.signerMulGas(7, 7);
        _ab("signer_mul", a, b);
        (, a) = branches.cacheAndGas();
        (, b) = branches.cacheXorGas();
        _ab("cache_xor", a, b);
        (, a) = branches.validateTwoGas(1, 2);
        (, b) = branches.validateOrGas(1, 2);
        _ab("validate_or", a, b);
        (, a) = branches.log2BranchGas(1 << 200);
        (, b) = branches.log2OrOneGas(1 << 200);
        _ab("log2_or_one", a, b);
        // Hot path of transferFrom: non-zero `from`, finite allowance 5, amount 3.
        (, a) = branches.fromCheckTwiceGas(uint160(holder), 5, 3);
        (, b) = branches.fromCheckOnceGas(uint160(holder), 5, 3);
        _ab("from_check_once", a, b);
        (, a) = branches.clzInlineGas(1 << 200);
        (, b) = branches.clzSeamGas(1 << 200);
        _ab("proof_seam", a, b);
        a = branches.senderCheckGas();
        b = branches.noSenderCheckGas();
        _ab("no_sender_check", a, b);
    }
}
