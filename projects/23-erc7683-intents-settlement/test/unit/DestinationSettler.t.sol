// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC20} from "@openzeppelin-contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin-contracts/utils/ReentrancyGuardTransient.sol";

import {DestinationSettler} from "../../src/DestinationSettler.sol";
import {DutchDecay} from "../../src/libraries/DutchDecay.sol";
import {FillProofLib} from "../../src/libraries/FillProofLib.sol";
import {Intent} from "../../src/libraries/IntentLib.sol";
import {IntentTestBase} from "../utils/IntentTestBase.sol";

/// @notice Output token that re-enters the settler from inside transferFrom.
contract ReentrantToken is ERC20 {
    DestinationSettler internal settler;
    bytes32 internal orderId;
    bytes internal originData;

    constructor() ERC20("Reentrant", "RE") {}

    function arm(DestinationSettler settler_, bytes32 orderId_, bytes memory originData_) external {
        settler = settler_;
        orderId = orderId_;
        originData = originData_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (address(settler) != address(0)) settler.fill(orderId, originData, "");
        return super.transferFrom(from, to, value);
    }
}

contract DestinationSettlerTest is IntentTestBase {
    bytes32 internal orderId;
    bytes internal originData;
    OrderParams internal p;

    function setUp() public override {
        super.setUp();
        p = _params(address(mailboxModule));
        (orderId, originData) = _ids(_onchainIntent(p, user, 0));
        vm.chainId(DEST);
    }

    function _fund(address filler, uint256 amount) internal {
        outputToken.mint(filler, amount);
        vm.prank(filler);
        outputToken.approve(address(dest), type(uint256).max);
    }

    function test_fill_paysRecipientAndRecords() public {
        _fund(solver, p.outputStart);
        vm.expectEmit(address(dest));
        emit DestinationSettler.OrderFilled(
            orderId, solver, solverRepayment, recipient, address(outputToken), p.outputStart, keccak256(originData)
        );
        vm.prank(solver);
        dest.fill(orderId, originData, abi.encode(solverRepayment));

        assertEq(outputToken.balanceOf(recipient), p.outputStart);
        DestinationSettler.FillRecord memory record = dest.fillRecord(orderId);
        assertEq(record.filler, solverRepayment);
        assertEq(record.filledAt, block.timestamp);
        assertEq(record.fillHash, keccak256(originData));
    }

    function test_fill_emptyFillerDataRepaysCaller() public {
        _fund(solver, p.outputStart);
        vm.prank(solver);
        dest.fill(orderId, originData, "");
        assertEq(dest.fillRecord(orderId).filler, solver);
    }

    function test_fillWithRepayment_recordsRecipient() public {
        _fund(solver, p.outputStart);
        vm.prank(solver);
        dest.fillWithRepayment(orderId, originData, solverRepayment);
        assertEq(dest.fillRecord(orderId).filler, solverRepayment);
    }

    function test_fillWithRepayment_rejectsZero() public {
        vm.expectRevert(abi.encodeWithSelector(DestinationSettler.InvalidFillerData.selector, abi.encode(address(0))));
        dest.fillWithRepayment(orderId, originData, address(0));
    }

    function test_fill_rejectsMalformedFillerData() public {
        bytes memory shortData = hex"1234";
        vm.expectRevert(abi.encodeWithSelector(DestinationSettler.InvalidFillerData.selector, shortData));
        dest.fill(orderId, originData, shortData);
        bytes memory zero = abi.encode(address(0));
        vm.expectRevert(abi.encodeWithSelector(DestinationSettler.InvalidFillerData.selector, zero));
        dest.fill(orderId, originData, zero);
    }

    function test_fill_rejectsDoubleFill() public {
        _fund(solver, p.outputStart);
        _fund(rival, p.outputStart);
        vm.prank(solver);
        dest.fill(orderId, originData, abi.encode(solverRepayment));
        vm.prank(rival);
        vm.expectRevert(abi.encodeWithSelector(DestinationSettler.AlreadyFilled.selector, orderId, solverRepayment));
        dest.fill(orderId, originData, "");
    }

    function test_fill_rejectsPayloadThatDoesNotHashToOrderId() public {
        Intent memory forged = _onchainIntent(p, user, 0);
        forged.data.outputEndAmount = 1; // a cheaper payload under the real order id
        bytes memory forgedData = abi.encode(forged);
        (bytes32 forgedId,) = _ids(forged);
        vm.expectRevert(abi.encodeWithSelector(DestinationSettler.OrderIdMismatch.selector, orderId, forgedId));
        dest.fill(orderId, forgedData, "");
    }

    function test_fill_rejectsWrongDestinationChain() public {
        vm.chainId(1003);
        vm.expectRevert(abi.encodeWithSelector(DestinationSettler.WrongDestinationChain.selector, 1003, DEST));
        dest.fill(orderId, originData, "");
    }

    function test_fill_rejectsWrongDestinationSettler() public {
        DestinationSettler other = new DestinationSettler();
        vm.expectRevert(
            abi.encodeWithSelector(DestinationSettler.WrongDestinationSettler.selector, address(other), address(dest))
        );
        other.fill(orderId, originData, "");
    }

    function test_fill_atDeadlineThenRejectsAfter() public {
        _fund(solver, p.outputStart);
        uint256 snapshot = vm.snapshotState();
        vm.warp(p.fillDeadline);
        vm.prank(solver);
        dest.fill(orderId, originData, "");
        assertEq(outputToken.balanceOf(recipient), p.outputEnd);
        vm.revertToState(snapshot);

        vm.warp(uint256(p.fillDeadline) + 1);
        vm.prank(solver);
        vm.expectRevert(
            abi.encodeWithSelector(DestinationSettler.FillDeadlinePassed.selector, p.fillDeadline, block.timestamp)
        );
        dest.fill(orderId, originData, "");
    }

    function test_exclusivity_onlyExclusiveFillerDuringWindow() public {
        p.exclusiveFiller = solver;
        (bytes32 id, bytes memory data) = _ids(_onchainIntent(p, user, 0));
        _fund(rival, p.outputStart);
        _fund(solver, p.outputStart);

        vm.warp(p.exclusivityDeadline);
        vm.prank(rival);
        vm.expectRevert(
            abi.encodeWithSelector(DestinationSettler.NotExclusiveFiller.selector, solver, p.exclusivityDeadline)
        );
        dest.fill(id, data, "");

        vm.prank(solver);
        dest.fill(id, data, "");
        assertEq(outputToken.balanceOf(recipient), p.outputStart, "exclusive fill pays the start amount");
    }

    function test_exclusivity_anyoneAfterWindowAtDecayedPrice() public {
        p.exclusiveFiller = solver;
        (bytes32 id, bytes memory data) = _ids(_onchainIntent(p, user, 0));
        _fund(rival, p.outputStart);
        uint256 middle = (uint256(p.exclusivityDeadline) + p.fillDeadline) / 2;
        vm.warp(middle);
        vm.prank(rival);
        dest.fill(id, data, "");
        uint256 expected =
            DutchDecay.amountAt(p.outputStart, p.outputEnd, p.exclusivityDeadline, p.fillDeadline, middle);
        assertEq(outputToken.balanceOf(recipient), expected);
        assertLt(expected, p.outputStart);
        assertGt(expected, p.outputEnd);
    }

    function test_outputAt_followsCurve() public view {
        assertEq(dest.outputAt(originData, 0), p.outputStart);
        assertEq(dest.outputAt(originData, p.exclusivityDeadline), p.outputStart);
        assertEq(dest.outputAt(originData, p.fillDeadline), p.outputEnd);
        assertEq(dest.outputAt(originData, type(uint64).max), p.outputEnd);
    }

    /// @dev The storage layout is part of the protocol: settlement mode 3 proves exactly these slots.
    function test_storageLayout_isPinned() public {
        assertEq(dest.FILLS_SLOT(), 0);
        assertEq(dest.FILLS_SLOT(), FillProofLib.FILLS_SLOT);
        bytes32 slot = dest.fillRecordSlot(orderId);
        assertEq(slot, FillProofLib.fillerSlot(orderId));
        assertEq(slot, keccak256(abi.encode(orderId, uint256(0))));

        _fund(solver, p.outputStart);
        vm.prank(solver);
        dest.fill(orderId, originData, abi.encode(solverRepayment));
        uint256 packed = uint256(vm.load(address(dest), slot));
        assertEq(packed, FillProofLib.pack(solverRepayment, uint64(block.timestamp)));
        (address filler, uint64 filledAt) = FillProofLib.unpack(packed);
        assertEq(filler, solverRepayment);
        assertEq(filledAt, block.timestamp);
        assertEq(vm.load(address(dest), bytes32(uint256(slot) + 1)), keccak256(originData));
    }

    function test_fill_isNonReentrant() public {
        ReentrantToken token = new ReentrantToken();
        Intent memory intent = _onchainIntent(p, user, 0);
        intent.data.outputToken = address(token);
        (bytes32 id, bytes memory data) = _ids(intent);
        token.mint(solver, p.outputStart);
        vm.prank(solver);
        token.approve(address(dest), type(uint256).max);
        token.arm(dest, id, data);
        vm.prank(solver);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        dest.fill(id, data, "");
    }

    /// @dev Whatever the fill time, the user receives the curve's amount, within [end, start].
    function testFuzz_fill_paysCurveAmount(uint256 start, uint256 end, uint32 exclusivity, uint32 window, uint256 t)
        public
    {
        start = bound(start, 1, 1e36);
        end = bound(end, 1, start);
        exclusivity = uint32(bound(exclusivity, block.timestamp, block.timestamp + 1 days));
        uint32 deadline = uint32(bound(window, exclusivity, uint256(exclusivity) + 7 days));
        t = bound(t, block.timestamp, deadline);
        p.outputStart = start;
        p.outputEnd = end;
        p.exclusivityDeadline = exclusivity;
        p.fillDeadline = deadline;
        (bytes32 id, bytes memory data) = _ids(_onchainIntent(p, user, 0));
        _fund(solver, start);
        vm.warp(t);
        vm.prank(solver);
        dest.fill(id, data, "");
        uint256 received = outputToken.balanceOf(recipient);
        assertEq(received, DutchDecay.amountAt(start, end, exclusivity, deadline, t));
        assertGe(received, end);
        assertLe(received, start);
    }
}
