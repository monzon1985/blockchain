// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ICumulativeMerkleDistributor} from "../../src/interfaces/ICumulativeMerkleDistributor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {LibBitmap} from "solady/utils/LibBitmap.sol";

/// @notice Benchmark-only baselines: the classic per-epoch airdrop design, where every epoch has its own root and a leaf
///         `(index, account, token, amount)` is claimed once, tracked by a claimed flag. The two variants differ only
///         in how the flag is stored, so GasBench isolates that choice. Not deployed; no access control on purpose.
abstract contract EpochDistributorBase is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    error AlreadyClaimed(uint256 epoch, uint256 index);
    error InvalidProof();

    event Claimed(uint256 indexed epoch, uint256 indexed index, address indexed account, address token, uint256 amount);

    mapping(uint256 epoch => bytes32) public roots;

    function setRoot(uint256 epoch, bytes32 root) external {
        roots[epoch] = root;
    }

    function claim(
        uint256 epoch,
        uint256 index,
        address account,
        address token,
        uint256 amount,
        bytes32[] calldata proof
    ) external nonReentrant {
        require(!_isClaimed(epoch, index), AlreadyClaimed(epoch, index));
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(index, account, token, amount))));
        require(MerkleProof.verifyCalldata(proof, roots[epoch], leaf), InvalidProof());
        _setClaimed(epoch, index);
        emit Claimed(epoch, index, account, token, amount);
        IERC20(token).safeTransfer(account, amount);
    }

    function _isClaimed(uint256 epoch, uint256 index) internal view virtual returns (bool);
    function _setClaimed(uint256 epoch, uint256 index) internal virtual;
}

/// @notice Claimed flags packed 256 per storage slot (Solady `LibBitmap`).
contract EpochBitmapDistributor is EpochDistributorBase {
    using LibBitmap for LibBitmap.Bitmap;

    mapping(uint256 epoch => LibBitmap.Bitmap) internal claimedBits;

    function _isClaimed(uint256 epoch, uint256 index) internal view override returns (bool) {
        return claimedBits[epoch].get(index);
    }

    function _setClaimed(uint256 epoch, uint256 index) internal override {
        claimedBits[epoch].set(index);
    }
}

/// @notice One storage slot per claimed flag (`mapping(uint256 => bool)`).
contract EpochBoolDistributor is EpochDistributorBase {
    mapping(uint256 epoch => mapping(uint256 index => bool)) internal claimedFlags;

    function _isClaimed(uint256 epoch, uint256 index) internal view override returns (bool) {
        return claimedFlags[epoch][index];
    }

    function _setClaimed(uint256 epoch, uint256 index) internal override {
        claimedFlags[epoch][index] = true;
    }
}

/// @notice Submits many single-proof claims in one transaction, so the bench can separate "one proof per leaf" from
///         "one transaction per claim".
contract BatchClaimer {
    function claimAll(
        ICumulativeMerkleDistributor distributor,
        ICumulativeMerkleDistributor.ClaimLeaf[] calldata leaves,
        bytes32[][] calldata proofs
    ) external {
        for (uint256 i; i < leaves.length; ++i) {
            distributor.claim(leaves[i].account, leaves[i].token, leaves[i].cumulativeAmount, proofs[i]);
        }
    }
}
