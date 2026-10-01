// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice ERC-20 that burns 1% of every transfer (fee-on-transfer).
contract FeeOnTransferToken is ERC20 {
    uint256 public constant FEE_BPS = 100;

    constructor() ERC20("Fee On Transfer", "FOT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }
        uint256 fee = (value * FEE_BPS) / 10_000;
        super._update(from, address(0), fee);
        super._update(from, to, value - fee);
    }
}

/// @notice Share-based rebasing token: balances are shares scaled by a global index the owner can move up or down.
contract RebasingToken {
    string public constant name = "Rebasing";
    string public constant symbol = "REB";
    uint8 public constant decimals = 18;

    uint256 public index = 1e18;
    uint256 public totalShares;
    mapping(address => uint256) public sharesOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function totalSupply() external view returns (uint256) {
        return (totalShares * index) / 1e18;
    }

    function balanceOf(address account) public view returns (uint256) {
        return (sharesOf[account] * index) / 1e18;
    }

    function rebase(uint256 newIndex) external {
        index = newIndex;
    }

    function mint(address to, uint256 amount) external {
        uint256 shares = (amount * 1e18) / index;
        sharesOf[to] += shares;
        totalShares += shares;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) private {
        uint256 shares = (amount * 1e18 + index - 1) / index;
        sharesOf[from] -= shares;
        sharesOf[to] += shares;
        emit Transfer(from, to, amount);
    }
}
