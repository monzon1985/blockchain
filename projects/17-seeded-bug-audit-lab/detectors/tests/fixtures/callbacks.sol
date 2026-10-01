// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

interface IVotes {
    function balanceOf(address) external view returns (uint256);
    function getPastVotes(address, uint256) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

contract CallbackPositives {
    IVotes token;

    // POSITIVE: callback makes a low-level call to a parameter target with no caller check.
    function onFlashLoan(address target, bytes calldata data) external returns (bytes32) {
        (bool ok,) = target.call(data);
        require(ok);
        return bytes32(0);
    }

    // POSITIVE: unguarded low-level call to an arbitrary destination.
    function distribute(address to) external {
        (bool ok,) = to.call{ value: 1 }("");
        require(ok);
    }

    // POSITIVE: "authorized" by the caller's live balance, which a flash loan can inflate.
    function balanceGated(address target, bytes calldata data) external {
        require(token.balanceOf(msg.sender) * 3 >= token.totalSupply() * 2, "quorum");
        (bool ok,) = target.call(data);
        require(ok);
    }
}

contract CallbackNegatives {
    address owner;
    IVotes token;
    mapping(uint256 => uint256) forVotes;
    uint256 quorum;

    modifier onlyOwner() {
        require(msg.sender == owner);
        _;
    }

    // NEGATIVE: guarded by a modifier.
    function adminCall(address t, bytes calldata d) external onlyOwner {
        (bool ok,) = t.call(d);
        require(ok);
    }

    // NEGATIVE: guarded by an explicit msg.sender check.
    function authedCall(address t) external {
        require(msg.sender == owner, "no");
        (bool ok,) = t.call("");
        require(ok);
    }

    // NEGATIVE (adversarial): gated by stored, previously cast votes (no msg.sender involved).
    function quorumGated(uint256 id, address t, bytes calldata d) external {
        require(forVotes[id] >= quorum, "not passed");
        (bool ok,) = t.call(d);
        require(ok);
    }

    // NEGATIVE (adversarial): gated by historical checkpoints, immune to flash loans.
    function snapshotGated(address t, bytes calldata d) external {
        require(token.getPastVotes(msg.sender, block.number - 50) * 3 >= 2e24, "quorum");
        (bool ok,) = t.call(d);
        require(ok);
    }

    // NEGATIVE: low-level call, but only to msg.sender (a self-withdrawal).
    function withdraw() external {
        (bool ok,) = msg.sender.call{ value: 1 }("");
        require(ok);
    }

    // NEGATIVE: no external call at all.
    function ping() external pure returns (uint256) {
        return 1;
    }
}
