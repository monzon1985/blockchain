// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IAMMCallee} from "../../src/interfaces/IAMMCallee.sol";
import {IAMMFactory} from "../../src/interfaces/IAMMFactory.sol";
import {IAMMPair} from "../../src/interfaces/IAMMPair.sol";

/// @notice Well-behaved flash-swap receiver: authenticates the pair and the initiator, then repays the loan
///         (plus `extraRepay`, which tests set to 0 or negative-by-omission to probe the k check).
contract FlashBorrower is IAMMCallee {
    IAMMFactory public immutable factory;
    uint256 public repayNumerator = 1000; // repay = out * repayNumerator / 997 + 1
    bool public observedLocked;
    uint112 public observedReserve0;

    error UnknownPair(address caller);
    error UntrustedInitiator(address sender);

    constructor(IAMMFactory factory_) {
        factory = factory_;
    }

    function setRepayNumerator(uint256 n) external {
        repayNumerator = n;
    }

    function borrow(IAMMPair pair, uint256 amount0Out, uint256 amount1Out) external {
        pair.swap(amount0Out, amount1Out, address(this), abi.encode(msg.sender));
    }

    function ammSwapCall(address sender, uint256 amount0Out, uint256 amount1Out, bytes calldata)
        external
        returns (bytes32)
    {
        address token0 = IAMMPair(msg.sender).token0();
        address token1 = IAMMPair(msg.sender).token1();
        // Callee-side validation the pair cannot do for us.
        require(factory.getPair(token0, token1) == msg.sender, UnknownPair(msg.sender));
        require(sender == address(this), UntrustedInitiator(sender));
        observedLocked = IAMMPair(msg.sender).isLocked();
        if (amount0Out > 0) IERC20(token0).transfer(msg.sender, amount0Out * repayNumerator / 997 + 1);
        if (amount1Out > 0) IERC20(token1).transfer(msg.sender, amount1Out * repayNumerator / 997 + 1);
        return keccak256("IAMMCallee.ammSwapCall");
    }
}

/// @notice Repays in full but returns the wrong magic value.
contract WrongMagicCallee is IAMMCallee {
    function borrow(IAMMPair pair, uint256 amount0Out, uint256 amount1Out) external {
        pair.swap(amount0Out, amount1Out, address(this), hex"01");
    }

    function ammSwapCall(address, uint256 amount0Out, uint256 amount1Out, bytes calldata) external returns (bytes32) {
        IAMMPair pair = IAMMPair(msg.sender);
        if (amount0Out > 0) IERC20(pair.token0()).transfer(msg.sender, amount0Out * 2);
        if (amount1Out > 0) IERC20(pair.token1()).transfer(msg.sender, amount1Out * 2);
        return bytes32(0);
    }
}

/// @notice During the callback, tries every read and write path of the pair and records what happened.
contract ReentrancyProbe is IAMMCallee {
    enum Attempt {
        GetReserves,
        Swap,
        Mint,
        Burn,
        Skim,
        Sync
    }

    Attempt public attempt;
    bool public sawLocked;
    bytes public revertData;

    function run(IAMMPair pair, Attempt attempt_, uint256 amount0Out, uint256 amount1Out) external {
        attempt = attempt_;
        pair.swap(amount0Out, amount1Out, address(this), hex"01");
    }

    function ammSwapCall(address, uint256 amount0Out, uint256 amount1Out, bytes calldata) external returns (bytes32) {
        IAMMPair pair = IAMMPair(msg.sender);
        sawLocked = pair.isLocked();
        bytes memory call;
        if (attempt == Attempt.GetReserves) call = abi.encodeCall(IAMMPair.getReserves, ());
        else if (attempt == Attempt.Swap) call = abi.encodeCall(IAMMPair.swap, (1, 0, address(this), ""));
        else if (attempt == Attempt.Mint) call = abi.encodeCall(IAMMPair.mint, (address(this)));
        else if (attempt == Attempt.Burn) call = abi.encodeCall(IAMMPair.burn, (address(this)));
        else if (attempt == Attempt.Skim) call = abi.encodeCall(IAMMPair.skim, (address(this)));
        else call = abi.encodeCall(IAMMPair.sync, ());
        (bool ok, bytes memory data) = address(pair).call(call);
        require(!ok, "reentry unexpectedly succeeded");
        revertData = data;
        if (amount0Out > 0) IERC20(pair.token0()).transfer(msg.sender, amount0Out * 1000 / 997 + 1);
        if (amount1Out > 0) IERC20(pair.token1()).transfer(msg.sender, amount1Out * 1000 / 997 + 1);
        return keccak256("IAMMCallee.ammSwapCall");
    }
}
